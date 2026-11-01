import AppKit
import CoreVideo
import RemoteCore
import WebRTC
import XCTest
@testable import WAIRemote

/// Experiment only: a sender budget cap, not a shaped network or optical latency test.
@MainActor
final class BandwidthStepBenchmarkTests: XCTestCase {
    func testCompareResolutionPoliciesAtSteppedBudget() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAI_BANDWIDTH_STEP"] == "1")
        _ = NSApplication.shared
        ScreenVideoPolicy.initializeWebRTC()
        RTCInitializeSSL()
        let baseline = ProcessInfo.processInfo.environment["WAI_BANDWIDTH_MODE"] == "baseline"
        let desktop = SyntheticDesktop()
        let scenes = try BudgetSceneSource(desktop)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAI_BANDWIDTH_OUTPUT"] ?? ".runtime/bandwidth-experiment")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profile = try scenes.profile()
        try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("source-profile.json"))
        let pacing = try await pacingProfiles(scenes: scenes, directory: directory)
        guard pacing else { return }
        let policies: [(String, RTCDegradationPreference)] = baseline
            ? [("baseline", .maintainFramerateAndResolution)]
            : [("preserve-both", .maintainFramerateAndResolution), ("maintain-framerate", .maintainFramerate)]
        for (name, preference) in policies {
            let result = try await run(name, preference, scenes: scenes, baseline: baseline, directory: directory)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
            print("BANDWIDTH_STEP \(name) \(String(data: try JSONSerialization.data(withJSONObject: result["summary"]!), encoding: .utf8)!)")
            XCTAssertGreaterThan(result["decodedFrames"] as? Int ?? 0, 0, "No actual decoded video")
            XCTAssertGreaterThan(result["readableStamps"] as? Int ?? 0, 0, "No synthetic pixel stamp survived")
            for phase in result["summary"] as! [[String: Any]] {
                XCTAssertGreaterThan(phase["decoded"] as! Int, 0, "No actual decoded frames during measured phase")
                XCTAssertGreaterThanOrEqual(Double(phase["source"] as! Int) / (phase["durationSeconds"] as! Double), 55,
                                            "CI source below 55 fps; this phase is not a valid sustained-source comparison")
            }
            let sourceGaps = result["sourceGapsMs"] as! [String: Double]
            XCTAssertGreaterThanOrEqual(sourceGaps["min"] ?? 0, 1000.0 / 120, "Source submissions must not bunch")
            // run() closes both transports before returning; allow destruction before the next factory.
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func run(_ name: String, _ preference: RTCDegradationPreference, scenes: BudgetSceneSource,
                     baseline: Bool, directory: URL) async throws -> [String: Any] {
        let duration = baseline ? 30.0 : 86.0
        let frameCount = Int(duration * 60)
        let trace = BudgetTrace()
        let samples = BudgetSamples(phase: "startup")
        let factory = RTCPeerConnectionFactory(encoderFactory: BudgetEncoderFactory(trace), decoderFactory: ScreenVideoDecoderFactory())
        let source = factory.videoSource(forScreenCast: true)
        let capturer = RTCVideoCapturer(delegate: source)
        let host = PeerTransport(factory: factory, source: source, ice: .local)
        let viewer = ViewerTransport(ice: .local)
        let firstDecoded = expectation(description: "Negotiated encoder and decoder startup")
        let sink = BudgetRenderer(trace, samples: samples, maximumIndex: frameCount) { firstDecoded.fulfill() }
        var track: RTCVideoTrack?
        viewer.onVideo = { track = $0; $0.add(sink) }
        defer { track?.remove(sink); host.close(); viewer.close() }
        let pc: RTCPeerConnection = try XCTUnwrap(child(host, "pc"))
        let remote: RTCPeerConnection = try XCTUnwrap(child(viewer, "peer"))
        let sender = try XCTUnwrap(pc.senders.first)
        func cap(_ bitrate: Int) throws {
            let parameters = sender.parameters
            parameters.degradationPreference = NSNumber(value: preference.rawValue)
            for encoding in parameters.encodings { encoding.maxBitrateBps = NSNumber(value: bitrate) }
            sender.parameters = parameters
            let readback = sender.parameters
            let actual = try XCTUnwrap(readback.encodings.first?.maxBitrateBps?.intValue)
            XCTAssertEqual(actual, bitrate)
            XCTAssertEqual(readback.degradationPreference?.intValue, preference.rawValue)
            trace.add("cap", ["requestedBps": bitrate, "readbackBps": actual,
                              "preference": readback.degradationPreference?.intValue ?? -1])
        }
        try cap(4_000_000)
        let ready = expectation(description: "Local production peer channel: \(name)")
        ready.assertForOverFulfill = false
        host.onOpen = { ready.fulfill() }
        host.onState = { trace.add("host-state", ["state": $0.rawValue]) }
        viewer.onState = { trace.add("viewer-state", ["state": $0.rawValue]) }
        viewer.offer { offer in
            guard case .success(let offer) = offer else { ready.fulfill(); return }
            host.answer(offer: offer) { answer in
                guard case .success(let answer) = answer else { ready.fulfill(); return }
                viewer.answer(answer) { error in if error != nil { ready.fulfill() } }
            }
        }
        await fulfillment(of: [ready], timeout: 25)
        guard host.isReady else {
            print("BANDWIDTH_STEP_SETUP_FAILED \(name) \(trace.snapshot())")
            throw BudgetFailure.noLocalConnection
        }
        // Reapply/read back after SDP has negotiated the real sender.
        try cap(4_000_000)
        let startupStart = ProcessInfo.processInfo.systemUptime + 0.2
        let startupStopped = expectation(description: "Warm-up source stopped")
        let warmup = BudgetFeeder(source: scenes, clock: .strictTimer, start: startupStart, duration: 5,
                                  fps: 12, stampOffset: 60_000, emit: { generated, _, pushedAt in
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: generated.pixels), rotation: ._0,
                                      timeStampNs: Int64(pushedAt * 1_000_000_000))
            let submittedAt = ProcessInfo.processInfo.systemUptime
            source.capturer(capturer, didCapture: frame)
            return submittedAt
        }, record: { trace.add("startup-" + $0, $1, at: $2) }, completed: { startupStopped.fulfill() })
        warmup.startFeeding()
        await fulfillment(of: [firstDecoded], timeout: 7)
        warmup.stop()
        await fulfillment(of: [startupStopped], timeout: 1)
        let startupRows = trace.snapshot().map { row -> [String: Any] in
            var row = row; row["t"] = (row.removeValue(forKey: "time") as! Double) - startupStart; return row
        }
        let decodedAt = startupRows.first { ["decoded", "startup-decoded"].contains($0["stage"] as? String ?? "") }?["t"] as? Double
        let startup: [String: Any] = ["sourceRevision": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "unknown",
                                     "firstDecodedSeconds": decodedAt.map { $0 as Any } ?? NSNull(), "maximumRepeatFPS": 12,
                                     "maximumSourceSeconds": 5, "decodeTimeoutSeconds": 7,
                                     "submittedFrames": startupRows.filter { $0["stage"] as? String == "startup-source" }.count,
                                     "allocationFailures": startupRows.filter { $0["stage"] as? String == "startup-source-allocation-failed" }.count,
                                     "skippedAttempts": startupRows.filter { $0["stage"] as? String == "startup-source-skipped" }.count,
                                     "method": "Actual negotiated media path; bounded 12Hz warm-up with separate stamps 60000-60059. Hard 8-buffer limit; allocation pressure skips a paced attempt. Stop after first decoded frame, then begin measured 30s. Unused slots in the maximum 5s window are not observed dropped frames.",
                                     "rows": startupRows]
        try JSONSerialization.data(withJSONObject: startup, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + "-startup.json"))
        guard decodedAt != nil else { throw BudgetFailure.noWarmFrame }
        samples.setPhase(baseline ? "baseline" : "initial")
        let start = ProcessInfo.processInfo.systemUptime + 0.2
        let finished = expectation(description: "\(duration)-second synthetic desktop")
        let feeder = BudgetFeeder(source: scenes, clock: .strictTimer, start: start, duration: duration,
                                  emit: { generated, _, pushedAt in
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: generated.pixels), rotation: ._0,
                                      timeStampNs: Int64(pushedAt * 1_000_000_000))
            let submittedAt = ProcessInfo.processInfo.systemUptime
            source.capturer(capturer, didCapture: frame)
            return submittedAt
        }, record: { trace.add($0, $1, at: $2) }, completed: { finished.fulfill() })
        feeder.startFeeding()
        defer { feeder.stop() }
        func statistics() {
            pc.statistics { trace.statistics($0, stage: "host-rtc", type: "outbound-rtp", counter: "framesEncoded") }
            remote.statistics { trace.statistics($0, stage: "viewer-rtc", type: "inbound-rtp", counter: "framesDecoded") }
        }
        statistics()
        let timer = Timer.connectionTimer(withTimeInterval: 1, repeats: true) { _ in statistics() }
        defer { timer.invalidate() }
        if !baseline {
            try await Task.sleep(for: .seconds(10.2))
            try cap(250_000); samples.setPhase("limited")
            try await Task.sleep(for: .seconds(15))
            try cap(4_000_000); samples.setPhase("recovery")
        }
        await fulfillment(of: [finished], timeout: baseline ? 35 : 66)
        try await Task.sleep(for: .seconds(1))
        statistics()
        try await Task.sleep(for: .seconds(0.3))
        timer.invalidate()
        track?.remove(sink)
        host.close(); viewer.close()
        trace.add("closed", ["hostReady": host.isReady])
        try await Task.sleep(for: .seconds(0.5))
        let detail = try samples.write(source: scenes, directory: directory, prefix: name, start: start)
        let rows = trace.snapshot().map { row -> [String: Any] in
            var row = row; row["t"] = (row.removeValue(forKey: "time") as! Double) - start; return row
        }
        let caps = rows.filter { $0["stage"] as? String == "cap" && ($0["t"] as! Double) >= 0 }
        let limitedAt = caps.first?["t"] as? Double ?? 10
        let recoveryAt = caps.last?["t"] as? Double ?? 25
        let allDecoded = rows.filter { $0["stage"] as? String == "decoded" }
        let allGaps = zip(allDecoded, allDecoded.dropFirst()).map { before, after in
            (end: after["t"] as! Double, ms: ((after["t"] as! Double) - (before["t"] as! Double)) * 1000)
        }
        if !baseline { XCTAssertGreaterThanOrEqual(duration - recoveryAt, 60, "Recovery observation must be at least 60 seconds") }
        let phases: [(String, Double, Double)] = baseline ? [("baseline", 0, duration)]
            : [("initial", 0, limitedAt), ("limited", limitedAt, recoveryAt), ("recovery", recoveryAt, duration)]
        let summaries: [[String: Any]] = phases.map { label, begin, end in
            let selected = rows.filter { ($0["t"] as! Double) >= begin && ($0["t"] as! Double) < end }
            let decoded = selected.filter { $0["stage"] as? String == "decoded" }
            // Attribute a crossing gap to its ending frame, retaining budget-transition stalls.
            let gaps = allGaps.filter { $0.end >= begin && $0.end < end }.map(\.ms)
            let lastBeforeEnd = allDecoded.last { ($0["t"] as! Double) < end }?["t"] as? Double ?? begin
            let sizes = Set(decoded.map { "\($0["width"]!)x\($0["height"]!)" }).sorted()
            let count: (String) -> Int = { stage in selected.filter { $0["stage"] as? String == stage }.count }
            return ["phase": label, "startSeconds": begin, "durationSeconds": end - begin, "source": count("source"),
                    "encoderInputs": count("encode-input"), "encoderOutputs": count("encode-output"),
                    "decoded": decoded.count, "sizes": sizes,
                    "decodeGapMaxMs": gaps.max() ?? 0, "decodeGapsOver200Ms": gaps.filter { $0 > 200 }.count,
                    "decodeTailSilenceMs": max(0, end - max(begin, lastBeforeEnd)) * 1000,
                    "readableStamps": decoded.filter { ($0["index"] as? Int ?? -1) >= 0 }.count]
        }
        return ["policy": name, "sourceRevision": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "unknown",
                "baseRevision": "b799faefe011d254eac491769231bb38e1087bc0", "durationSeconds": duration, "baselineOnly": baseline,
                "sourceSize": [3840, 2160], "requestedSourceFPS": 60,
                "method": "Local ICE and production transports/factories. Baseline: 30s at 4Mbps. Comparison mode: 4Mbps for 10s, 250kbps for 15s, 4Mbps for at least 60s. Sender cap is not network shaping or optical latency. Two pre-rendered text scenes alternate every 300 emitted frames with a moving bar and unique sequential frame stamp; this is not scrolling and must not be compared directly with the prior workload. Stamps count emitted frames, not planned 60Hz slots. Strict one-shot timer prepares before waiting and rebases on actual previous emission; missed slots are never replayed. Hard pool limit 8; allocation pressure skips a paced attempt and reduces actual source cadence. Encoder/decoder startup uses separately recorded bounded 12Hz repeats before the full measured phase. PNG/detail work happens after measurement and peer closure.",
                "sourceGapsMs": gapSummary(rows.filter { $0["stage"] as? String == "source" }.map { $0["t"] as! Double }),
                "sourceFrames": rows.filter { $0["stage"] as? String == "source" }.count,
                "sourceAllocationFailures": rows.filter { $0["stage"] as? String == "source-allocation-failed" }.count,
                "sourceSkippedAttempts": rows.filter { $0["stage"] as? String == "source-skipped" }.count,
                "decodedFrames": rows.filter { $0["stage"] as? String == "decoded" }.count,
                "readableStamps": rows.filter { $0["stage"] as? String == "decoded" && ($0["index"] as? Int ?? -1) >= 0 }.count,
                "startup": startup, "detail": detail, "summary": summaries, "rows": rows]
    }
    private func pacingProfiles(scenes: BudgetSceneSource, directory: URL) async throws -> Bool {
        var profiles: [[String: Any]] = []
        var strictValid = false
        for clock in [BudgetFeeder.Clock.threadSleep, .strictTimer] {
            let trace = BudgetTrace(), done = expectation(description: "10s source-only \(clock.rawValue)")
            let start = ProcessInfo.processInfo.systemUptime + 0.2
            let feeder = BudgetFeeder(source: scenes, clock: clock, start: start, duration: 10,
                                      emit: { _, _, time in time }, record: { trace.add($0, $1, at: $2) }, completed: { done.fulfill() })
            feeder.startFeeding()
            await fulfillment(of: [done], timeout: 12)
            feeder.stop()
            let rows = trace.snapshot().map { row -> [String: Any] in
                var row = row; row["t"] = (row.removeValue(forKey: "time") as! Double) - start; return row
            }
            let source = rows.filter { $0["stage"] as? String == "source" }
            let gaps = gapSummary(source.map { $0["t"] as! Double })
            let valid = Double(source.count) / 10 >= 55 && (gaps["min"] ?? 0) >= 1000.0 / 120
            profiles.append(["clock": clock.rawValue, "durationSeconds": 10, "sourceFrames": source.count,
                             "sourceFPS": Double(source.count) / 10, "sourceGapsMs": gaps, "valid": valid,
                             "method": "No WebRTC source submission; actual generated frame emissions counted over 10s. Frames prepared before the wait; deadlines rebase on actual prior emission. Stamps are contiguous emission indices; plannedMissedSlots counts skipped 60Hz schedule slots separately.",
                             "rows": rows])
            if clock == .strictTimer { strictValid = valid }
        }
        try JSONSerialization.data(withJSONObject: profiles, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("pacing-profiles.json"))
        XCTAssertTrue(strictValid, "Strict source-only pacing did not meet >=55fps and >=8.33ms minimum gap; media baseline withheld")
        return strictValid
    }
    private func gapSummary(_ times: [Double]) -> [String: Double] {
        let gaps = zip(times, times.dropFirst()).map { ($1 - $0) * 1000 }.sorted()
        guard !gaps.isEmpty else { return ["count": 0] }
        func percentile(_ fraction: Double) -> Double {
            let position = Double(gaps.count - 1) * fraction
            let lower = Int(position), upper = Int(ceil(position))
            return gaps[lower] + (gaps[upper] - gaps[lower]) * (position - Double(lower))
        }
        return ["count": Double(gaps.count), "min": gaps.first!, "p50": percentile(0.5), "p95": percentile(0.95), "max": gaps.last!]
    }
    private func child<T>(_ object: Any, _ label: String) -> T? {
        Mirror(reflecting: object).children.first { $0.label == label }?.value as? T
    }
}

private enum BudgetFailure: Error { case noLocalConnection, noWarmFrame }

private final class BudgetTrace {
    private let lock = NSLock()
    private var rows: [[String: Any]] = []
    func add(_ stage: String, _ values: [String: Any] = [:], at time: Double? = nil) {
        var row = values; row["stage"] = stage; row["time"] = time ?? ProcessInfo.processInfo.systemUptime
        lock.lock(); rows.append(row); lock.unlock()
    }
    func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows.sorted { ($0["time"] as! Double) < ($1["time"] as! Double) } }
    func statistics(_ report: RTCStatisticsReport, stage: String, type: String, counter: String) {
        let fields: Set<String> = ["framesEncoded", "framesSent", "framesDecoded", "framesReceived", "framesDropped",
            "frameWidth", "frameHeight", "framesPerSecond", "bytesSent", "totalEncodeTime", "totalDecodeTime",
            "qpSum", "targetBitrate", "freezeCount", "totalFreezesDuration", "keyFramesEncoded", "keyFramesDecoded", "qualityLimitationResolutionChanges"]
        for stat in report.statistics.values where stat.type == type && stat.values["kind"] as? String == "video" && stat.values[counter] != nil {
            var values: [String: Any] = stat.values.filter { fields.contains($0.key) && $0.value is NSNumber }
            for key in ["encoderImplementation", "decoderImplementation", "powerEfficientEncoder", "powerEfficientDecoder", "qualityLimitationReason"] {
                values[key] = stat.values[key] ?? NSNull()
            }
            let codec = (stat.values["codecId"] as? String).flatMap { report.statistics[$0] }
            values["mimeType"] = codec?.values["mimeType"] ?? NSNull()
            let durations = stat.values["qualityLimitationDurations"] as? [String: Any]
            values["qualityLimitationDurations"] = durations?.filter { ["none", "cpu", "bandwidth", "other"].contains($0.key) && $0.value is NSNumber } ?? [:]
            add(stage, values)
        }
    }
}

private final class BudgetEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let base = ScreenVideoEncoderFactory()
    private let trace: BudgetTrace
    init(_ trace: BudgetTrace) { self.trace = trace }
    func supportedCodecs() -> [RTCVideoCodecInfo] { base.supportedCodecs() }
    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        guard let encoder = base.createEncoder(info) else { return nil }
        return BudgetEncoder(encoder, trace)
    }
}

private final class BudgetEncoder: NSObject, RTCVideoEncoder {
    private let base: RTCVideoEncoder
    private let trace: BudgetTrace
    init(_ base: RTCVideoEncoder, _ trace: BudgetTrace) { self.base = base; self.trace = trace }
    func implementationName() -> String { base.implementationName() }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { base.scalingSettings() }
    var resolutionAlignment: Int { base.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { base.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { base.supportsNativeHandle }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores cores: Int32) -> Int {
        trace.add("encoder-start", ["width": settings.width, "height": settings.height, "fps": settings.maxFramerate,
                                    "startKbps": settings.startBitrate, "codec": settings.name, "implementation": base.implementationName(),
                                    "qpLow": base.scalingSettings()?.low ?? -1, "qpHigh": base.scalingSettings()?.high ?? -1])
        return base.startEncode(with: settings, numberOfCores: cores)
    }
    func release() -> Int { base.release() }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        let result = base.setBitrate(bitrateKbit, framerate: framerate)
        trace.add("encoder-rate", ["kbps": bitrateKbit, "fps": framerate, "result": result]); return result
    }
    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        guard let callback else { base.setCallback(nil); return }
        base.setCallback { [trace] image, info in
            trace.add("encode-output", ["rtp": image.timeStamp, "width": image.encodedWidth, "height": image.encodedHeight,
                                        "bytes": image.buffer.count, "qp": image.qp.intValue, "key": image.frameType == .videoFrameKey])
            return callback(image, info)
        }
    }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: RTCCodecSpecificInfo?, frameTypes: [NSNumber]) -> Int {
        let start = ProcessInfo.processInfo.systemUptime
        trace.add("encode-input", ["rtp": UInt32(bitPattern: frame.timeStamp), "ns": frame.timeStampNs,
                                   "width": frame.width, "height": frame.height])
        let result = base.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes)
        trace.add("encode-return", ["rtp": UInt32(bitPattern: frame.timeStamp), "ms": (ProcessInfo.processInfo.systemUptime - start) * 1000, "result": result])
        return result
    }
}

private final class BudgetRenderer: NSObject, RTCVideoRenderer {
    private let trace: BudgetTrace
    private let samples: BudgetSamples
    private let maximumIndex: Int
    private let firstFrame: () -> Void
    private let firstFrameLock = NSLock()
    private var reportedFirstFrame = false
    private var measuredFrameSeen = false
    init(_ trace: BudgetTrace, samples: BudgetSamples, maximumIndex: Int, firstFrame: @escaping () -> Void) {
        self.trace = trace; self.samples = samples; self.maximumIndex = maximumIndex; self.firstFrame = firstFrame
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let index: Int
        if let native = frame.buffer as? RTCCVPixelBuffer,
           CVPixelBufferGetPlaneCount(native.pixelBuffer) == 2,
           CVPixelBufferGetWidth(native.pixelBuffer) == Int(frame.width),
           CVPixelBufferGetHeight(native.pixelBuffer) == Int(frame.height) {
            let pixel = native.pixelBuffer
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            index = Self.stamp(CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self),
                               stride: CVPixelBufferGetBytesPerRowOfPlane(pixel, 0), width: Int(frame.width), height: Int(frame.height))
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        } else {
            let i420 = frame.buffer.toI420()
            index = Self.stamp(i420.dataY, stride: Int(i420.strideY), width: Int(i420.width), height: Int(i420.height))
        }
        let validatedIndex = index < maximumIndex ? index : -1
        firstFrameLock.lock()
        let first = !reportedFirstFrame; reportedFirstFrame = true
        if validatedIndex >= 0 { measuredFrameSeen = true }
        let startupFrame = index >= 60_000 || (index < 0 && !measuredFrameSeen)
        firstFrameLock.unlock()
        trace.add(startupFrame ? "startup-decoded" : "decoded",
                  ["index": validatedIndex, "stampIndex": index, "width": frame.width, "height": frame.height, "ns": frame.timeStampNs])
        samples.capture(frame, index: validatedIndex)
        if first { firstFrame() }
    }
    private static func stamp(_ y: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int) -> Int {
        var value = 0
        for bit in 0..<24 {
            var sum = 0
            for dy in [16, 24, 31] { for dx in [16, 24, 31] {
                let x = min(width - 1, ((bit % 12) * 48 + dx) * width / 3840)
                let row = min(height - 1, (2064 + (bit / 12) * 48 + dy) * height / 2160)
                sum += Int(y[row * stride + x])
            } }
            if sum / 9 > 126 { value |= 1 << bit }
        }
        let index = value & 0xffff, checksum = (value >> 16) & 0xff
        return checksum == ((index ^ (index >> 8) ^ 0x5A) & 0xff) ? index : -1
    }
}
