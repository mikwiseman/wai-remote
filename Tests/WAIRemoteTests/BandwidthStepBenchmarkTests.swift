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
        let desktop = SyntheticDesktop()
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAI_BANDWIDTH_OUTPUT"] ?? ".runtime/bandwidth-experiment")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, preference) in [("preserve-both", RTCDegradationPreference.maintainFramerateAndResolution),
                                   ("maintain-framerate", RTCDegradationPreference.maintainFramerate)] {
            let result = try await run(name, preference, desktop: desktop)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
            print("BANDWIDTH_STEP \(name) \(String(data: try JSONSerialization.data(withJSONObject: result["summary"]!), encoding: .utf8)!)")
            XCTAssertGreaterThan(result["decodedFrames"] as? Int ?? 0, 0, "No actual decoded video")
            XCTAssertGreaterThan(result["readableStamps"] as? Int ?? 0, 0, "No synthetic pixel stamp survived")
            for phase in result["summary"] as! [[String: Any]] {
                XCTAssertGreaterThanOrEqual(Double(phase["source"] as! Int) / (phase["durationSeconds"] as! Double), 55,
                                            "CI source below 55 fps; this phase is not a valid sustained-source comparison")
            }
            // run() closes both transports before returning; allow destruction before the next factory.
            try await Task.sleep(for: .seconds(1))
        }
    }

    private func run(_ name: String, _ preference: RTCDegradationPreference, desktop: SyntheticDesktop) async throws -> [String: Any] {
        let trace = BudgetTrace()
        let factory = RTCPeerConnectionFactory(encoderFactory: BudgetEncoderFactory(trace), decoderFactory: ScreenVideoDecoderFactory())
        let source = factory.videoSource(forScreenCast: true)
        let capturer = RTCVideoCapturer(delegate: source)
        let host = PeerTransport(factory: factory, source: source, ice: .local)
        let viewer = ViewerTransport(ice: .local)
        let sink = BudgetRenderer(trace)
        var track: RTCVideoTrack?
        viewer.onVideo = { track = $0; $0.add(sink) }
        defer { trace.stopFeeding(); track?.remove(sink); host.close(); viewer.close() }
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
        let pool = try XCTUnwrap(SyntheticDesktop.pool())
        let start = ProcessInfo.processInfo.systemUptime + 0.2
        let finished = expectation(description: "35-second synthetic desktop")
        let feeder = Thread {
            for index in 0..<2100 {
                if trace.feedingStopped { break }
                let deadline = start + Double(index) / 60
                let wait = deadline - ProcessInfo.processInfo.systemUptime
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                // Never manufacture a burst of catch-up frames on a slow runner.
                guard ProcessInfo.processInfo.systemUptime - deadline < 1.0 / 60 else {
                    trace.add("source-missed", ["index": index]); continue
                }
                autoreleasepool {
                    guard let pixel = SyntheticDesktop.buffer(pool: pool) else { trace.add("source-allocation-failed"); return }
                    // Identical continuous scrolling with a full scene change every five seconds.
                    var state = SyntheticDesktop.State()
                    state.window = (index / 300) % 2
                    state.offsets = [(index * 4) % 1400, (index * 4) % 1400]
                    state.typed = (index / 8) % 90
                    CVPixelBufferLockBaseAddress(pixel, [])
                    desktop.draw(state, index: index,
                        y: CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self),
                        yStride: CVPixelBufferGetBytesPerRowOfPlane(pixel, 0),
                        uv: CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt8.self),
                        uvStride: CVPixelBufferGetBytesPerRowOfPlane(pixel, 1))
                    CVPixelBufferUnlockBaseAddress(pixel, [])
                    let now = ProcessInfo.processInfo.systemUptime
                    let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixel), rotation: ._0,
                                             timeStampNs: Int64(now * 1_000_000_000))
                    trace.add("source", ["index": index, "ns": frame.timeStampNs, "scheduleLateMs": (now - deadline) * 1000])
                    source.capturer(capturer, didCapture: frame)
                }
            }
            finished.fulfill()
        }
        feeder.qualityOfService = .userInteractive
        feeder.start()
        func statistics() {
            pc.statistics { trace.statistics($0, stage: "host-rtc", type: "outbound-rtp", counter: "framesEncoded") }
            remote.statistics { trace.statistics($0, stage: "viewer-rtc", type: "inbound-rtp", counter: "framesDecoded") }
        }
        statistics()
        let timer = Timer.connectionTimer(withTimeInterval: 1, repeats: true) { _ in statistics() }
        defer { timer.invalidate() }
        try await Task.sleep(for: .seconds(10.2))
        try cap(250_000)
        try await Task.sleep(for: .seconds(15))
        try cap(4_000_000)
        await fulfillment(of: [finished], timeout: 15)
        try await Task.sleep(for: .seconds(1))
        statistics()
        try await Task.sleep(for: .seconds(0.3))
        timer.invalidate()
        track?.remove(sink)
        host.close(); viewer.close()
        trace.add("closed", ["hostReady": host.isReady])
        try await Task.sleep(for: .seconds(0.5))
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
        let summaries: [[String: Any]] = [("initial", 0.0, limitedAt), ("limited", limitedAt, recoveryAt), ("recovery", recoveryAt, 35.0)].map { label, begin, end in
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
                "baseRevision": "b799faefe011d254eac491769231bb38e1087bc0", "durationSeconds": 35,
                "sourceSize": [3840, 2160], "requestedSourceFPS": 60,
                "method": "Local ICE, production transports and H264 factory. Per-encoding maxBitrate cap 4Mbps/10s, 250kbps/15s, 4Mbps/10s. This is not network shaping or optical latency. Continuous synthetic scrolling; scene changes every 5s. Policies run sequentially, preserve-both first. No screen capture or input injection.",
                "sourceFrames": rows.filter { $0["stage"] as? String == "source" }.count,
                "decodedFrames": rows.filter { $0["stage"] as? String == "decoded" }.count,
                "readableStamps": rows.filter { $0["stage"] as? String == "decoded" && ($0["index"] as? Int ?? -1) >= 0 }.count,
                "summary": summaries, "rows": rows]
    }
    private func child<T>(_ object: Any, _ label: String) -> T? {
        Mirror(reflecting: object).children.first { $0.label == label }?.value as? T
    }
}

private enum BudgetFailure: Error { case noLocalConnection }

private final class BudgetTrace {
    private let lock = NSLock()
    private var rows: [[String: Any]] = []
    private var stopped = false
    var feedingStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stopFeeding() { lock.lock(); stopped = true; lock.unlock() }
    func add(_ stage: String, _ values: [String: Any] = [:]) {
        var row = values; row["stage"] = stage; row["time"] = ProcessInfo.processInfo.systemUptime
        lock.lock(); rows.append(row); lock.unlock()
    }
    func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows.sorted { ($0["time"] as! Double) < ($1["time"] as! Double) } }
    func statistics(_ report: RTCStatisticsReport, stage: String, type: String, counter: String) {
        let fields: Set<String> = ["framesEncoded", "framesSent", "framesDecoded", "framesReceived", "framesDropped",
            "frameWidth", "frameHeight", "framesPerSecond", "bytesSent", "totalEncodeTime", "totalDecodeTime",
            "qpSum", "targetBitrate", "freezeCount", "totalFreezesDuration", "keyFramesEncoded", "keyFramesDecoded"]
        for stat in report.statistics.values where stat.type == type && stat.values["kind"] as? String == "video" && stat.values[counter] != nil {
            add(stage, stat.values.filter { fields.contains($0.key) && $0.value is NSNumber })
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
                                    "startKbps": settings.startBitrate, "implementation": base.implementationName()])
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
    init(_ trace: BudgetTrace) { self.trace = trace }
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
        trace.add("decoded", ["index": index, "width": frame.width, "height": frame.height, "ns": frame.timeStampNs])
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
        return index < 2100 && checksum == ((index ^ (index >> 8) ^ 0x5A) & 0xff) ? index : -1
    }
}
