import AppKit
import CoreVideo
import RemoteCore
import WebRTC
import XCTest
@testable import WAIRemote

/// Experiment only: a sender budget cap, not a shaped network or optical latency test.
@MainActor
final class BandwidthStepBenchmarkTests: XCTestCase {
    func testBudgetResolutionRecoveryRestoresOnlyOnceAfterArming() {
        var recovery = BudgetResolutionRecovery()
        XCTAssertFalse(recovery.observe(allocationBps: 4_000_000))
        XCTAssertFalse(recovery.observe(allocationBps: 250_000))
        recovery.arm()
        XCTAssertFalse(recovery.observe(allocationBps: 3_999_999))
        XCTAssertTrue(recovery.observe(allocationBps: 4_000_000))
        XCTAssertFalse(recovery.observe(allocationBps: 4_000_000))
        XCTAssertFalse(recovery.observe(allocationBps: 3_333_333))
        recovery.arm()
        XCTAssertFalse(recovery.observe(allocationBps: 4_000_000))
    }

    func testNativeDropTotalsParserRequiresCompleteTeardown() {
        // Pinned M153 send_statistics_proxy.cc: the BadTimestamp separator is absent.
        let message = """
        (send_statistics_proxy.cc:821): Frames encoded 4286
        WebRTC.Video.Screenshare.DroppedFrames.Capturer 1
        WebRTC.Video.Screenshare.DroppedFrames.BadTimestamp2
        WebRTC.Video.Screenshare.DroppedFrames.EncoderQueue 3
        WebRTC.Video.Screenshare.DroppedFrames.Encoder 4
        WebRTC.Video.Screenshare.DroppedFrames.Ratelimiter 5001
        WebRTC.Video.Screenshare.DroppedFrames.CongestionWindow 6
        """
        XCTAssertEqual(BudgetDropTotals.parse(message), ["Capturer": 1, "BadTimestamp": 2,
            "EncoderQueue": 3, "Encoder": 4, "Ratelimiter": 5001, "CongestionWindow": 6])
        XCTAssertEqual(BudgetDropTotals.parse(message.replacingOccurrences(of: "BadTimestamp2", with: "BadTimestamp0"))?["BadTimestamp"], 0)
        XCTAssertEqual(BudgetDropTotals.parse(message.replacingOccurrences(of: "BadTimestamp2", with: "BadTimestamp 2"))?["BadTimestamp"], 2)
        XCTAssertNil(BudgetDropTotals.parse(message.replacingOccurrences(of: "WebRTC.Video.Screenshare.DroppedFrames.BadTimestamp2\n", with: "")))
        XCTAssertNil(BudgetDropTotals.parse(message.replacingOccurrences(of: "send_statistics_proxy.cc", with: "unrelated.cc")))
        XCTAssertNil(BudgetDropTotals.parse("WebRTC.Video.Screenshare.DroppedFrames.EncoderQueue 3"))
        XCTAssertNil(BudgetDropTotals.parse(message + "\nWebRTC.Video.Screenshare.DroppedFrames.Capturer 99"))
    }

    func testCompareResolutionPoliciesAtSteppedBudget() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAI_BANDWIDTH_STEP"] == "1")
        let mode = ProcessInfo.processInfo.environment["WAI_BANDWIDTH_MODE"]
        let candidate = mode == "budget-resolution"
        let diagnostic = mode == "diagnostic" || candidate, baseline = mode == "baseline"
        let defaults = UserDefaults.standard
        let diagnosticKeys = ["performanceDiagnostics", "performanceNetworkTrace"]
        let previousDefaults = diagnosticKeys.map { defaults.object(forKey: $0) }
        defer {
            if diagnostic {
                for (key, value) in zip(diagnosticKeys, previousDefaults) {
                    if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
                }
            }
        }
        if diagnostic {
            for key in diagnosticKeys { defaults.set(true, forKey: key) }
            // The INFO callback is separate from console logging. Never emit native logs to test.log.
            RTCSetMinDebugLogLevel(.none)
            // PerformanceLog.enabled is cached: this mode must run in a fresh test process.
            guard PerformanceLog.enabled else { throw BudgetFailure.diagnosticsInitializedDisabled }
        }
        _ = NSApplication.shared
        ScreenVideoPolicy.initializeWebRTC()
        RTCInitializeSSL()
        let desktop = SyntheticDesktop()
        let scenes = try BudgetSceneSource(desktop)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WAI_BANDWIDTH_OUTPUT"] ?? ".runtime/bandwidth-experiment")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if diagnostic {
            let temporary = FileManager.default.temporaryDirectory
            let pid = ProcessInfo.processInfo.processIdentifier
            let paths = ["performanceLog": temporary.appendingPathComponent("wai-remote-performance-\(pid).jsonl").path,
                         "hostNetworkTrace": temporary.appendingPathComponent("wai-remote-network-\(pid)-host.rtc").path,
                         "viewerNetworkTrace": temporary.appendingPathComponent("wai-remote-network-\(pid)-viewer.rtc").path]
            // Transient collector input: the workflow must exclude or remove this manifest before artifact upload.
            try JSONSerialization.data(withJSONObject: paths, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("diagnostic-inputs.json"), options: .atomic)
        }
        // Match the app's active-session assertion, including source admission and warm-up.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInteractive, reason: "WAI Remote benchmark active session")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let profile = try scenes.profile()
        try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("source-profile.json"))
        let pacing = try await pacingProfiles(scenes: scenes, directory: directory)
        guard pacing else { return }
        let policies: [(String, RTCDegradationPreference)] = diagnostic
            ? [("diagnostic", candidate ? .maintainFramerateAndResolution : .maintainFramerate)] : baseline
            ? [("baseline", .maintainFramerateAndResolution)]
            : [("preserve-both", .maintainFramerateAndResolution), ("maintain-framerate", .maintainFramerate)]
        for (name, preference) in policies {
            let result = try await run(name, preference, scenes: scenes, baseline: baseline,
                                       diagnostic: diagnostic, candidate: candidate, directory: directory)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent(name + ".json"), options: .atomic)
            print("BANDWIDTH_STEP \(name) \(String(data: try JSONSerialization.data(withJSONObject: result["summary"]!), encoding: .utf8)!)")
            XCTAssertGreaterThan(result["rendererFrames"] as? Int ?? 0, 0, "No actual rendered video")
            XCTAssertGreaterThan(result["readableStamps"] as? Int ?? 0, 0, "No synthetic pixel stamp survived")
            if diagnostic {
                let instrumentation = try XCTUnwrap(result["diagnosticInstrumentation"] as? [String: Any])
                XCTAssertEqual(instrumentation["valid"] as? Bool, true, "Diagnostic instrumentation incomplete; missing data is not zero")
            }
            if candidate {
                let acceptance = try XCTUnwrap(result["candidateAcceptance"] as? [String: Any])
                XCTAssertEqual(acceptance["initialMediaBudgetObserved"] as? Bool, true, "Initial media allocation never reached 4Mbps")
                XCTAssertEqual(acceptance["restoreCount"] as? Int, 1, "Resolution must restore exactly once after allocation recovery")
                XCTAssertLessThanOrEqual(acceptance["maximumRendererGapMs"] as? Double ?? .infinity, 200,
                                         "Every renderer gap, including transitions and endpoint silence, must be <=200ms")
                XCTAssertLessThanOrEqual(acceptance["firstNativeRendererAfterTriggerMs"] as? Double ?? .infinity, 2000,
                                         "Full native detail must return within 2s of observed allocation recovery")
                XCTAssertLessThanOrEqual(acceptance["firstNativeRendererAfterAllocationMs"] as? Double ?? .infinity, 2000,
                                         "A 1Hz observation delay must not extend the 2s native allocation recovery deadline")
                XCTAssertGreaterThanOrEqual(acceptance["firstNativeRendererAfterAllocationMs"] as? Double ?? -.infinity, 0)
                XCTAssertEqual(acceptance["allocationPrecedesTrigger"] as? Bool, true)
                XCTAssertEqual(acceptance["staysNativeUntilEnd"] as? Bool, true)
                XCTAssertEqual(acceptance["matchedNativeRecoverySample"] as? Bool, true)
                XCTAssertEqual(acceptance["limitedEncodedScaleObserved"] as? Bool, true)
                XCTAssertEqual(acceptance["limitedRendererScaleObserved"] as? Bool, true)
            }
            for phase in result["summary"] as! [[String: Any]] {
                XCTAssertGreaterThan(phase["renderer"] as! Int, 0, "No renderer callbacks during measured phase")
                let gaps = phase["sourceGapsMs"] as! [String: Double]
                XCTAssertGreaterThanOrEqual(gaps["min"] ?? 0, 1000.0 / 120, "Source submissions must not bunch in any phase")
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
                     baseline: Bool, diagnostic: Bool, candidate: Bool, directory: URL) async throws -> [String: Any] {
        let duration = baseline ? 30.0 : 86.0
        let frameCount = Int(duration * 60)
        let trace = BudgetTrace()
        let samples = BudgetSamples(phase: "startup")
        let factory = RTCPeerConnectionFactory(encoderFactory: BudgetEncoderFactory(trace, samples: samples), decoderFactory: ScreenVideoDecoderFactory())
        let source = factory.videoSource(forScreenCast: true)
        let capturer = RTCVideoCapturer(delegate: source)
        let host = PeerTransport(factory: factory, source: source, ice: .local)
        let viewer = ViewerTransport(ice: .local)
        let firstRendered = expectation(description: "Negotiated encoder and decoder startup")
        let sink = BudgetRenderer(trace, samples: samples, maximumIndex: frameCount) { firstRendered.fulfill() }
        var track: RTCVideoTrack?
        viewer.onVideo = { track = $0; $0.add(sink) }
        defer { track?.remove(sink); host.close(); viewer.close() }
        let pc: RTCPeerConnection = try XCTUnwrap(child(host, "pc"))
        let remote: RTCPeerConnection = try XCTUnwrap(child(viewer, "peer"))
        let sender = try XCTUnwrap(pc.senders.first)
        func cap(_ bitrate: Int, scale: Double? = nil, stage: String = "cap", armRecovery: Bool = false) throws {
            let parameters = sender.parameters
            parameters.degradationPreference = NSNumber(value: preference.rawValue)
            for encoding in parameters.encodings {
                encoding.maxBitrateBps = NSNumber(value: bitrate)
                if let scale { encoding.scaleResolutionDownBy = NSNumber(value: scale) }
            }
            let requestedAt = ProcessInfo.processInfo.systemUptime
            if armRecovery { samples.armRecovery(at: requestedAt) }
            sender.parameters = parameters
            let readback = sender.parameters
            let actual = try XCTUnwrap(readback.encodings.first?.maxBitrateBps?.intValue)
            XCTAssertEqual(actual, bitrate)
            XCTAssertEqual(readback.degradationPreference?.intValue, preference.rawValue)
            var values: [String: Any] = ["requestedBps": bitrate, "readbackBps": actual,
                                        "requestedAtUptimeSeconds": requestedAt,
                                        "preference": readback.degradationPreference?.intValue ?? -1]
            if let scale {
                let actualScale = try XCTUnwrap(readback.encodings.first?.scaleResolutionDownBy?.doubleValue)
                XCTAssertEqual(actualScale, scale)
                values["requestedScale"] = scale; values["readbackScale"] = actualScale
            }
            trace.add(stage, values)
        }
        try cap(4_000_000, scale: candidate ? 1 : nil)
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
        try cap(4_000_000, scale: candidate ? 1 : nil)
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
        await fulfillment(of: [firstRendered], timeout: 7)
        warmup.stop()
        await fulfillment(of: [startupStopped], timeout: 1)
        let startupRows = trace.snapshot().map { row -> [String: Any] in
            var row = row; row["t"] = (row.removeValue(forKey: "time") as! Double) - startupStart; return row
        }
        let renderedAt = startupRows.first { ["renderer", "startup-renderer"].contains($0["stage"] as? String ?? "") }?["t"] as? Double
        let startup: [String: Any] = ["sourceRevision": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "unknown",
                                     "firstRenderedSeconds": renderedAt.map { $0 as Any } ?? NSNull(), "maximumRepeatFPS": 12,
                                     "maximumSourceSeconds": 5, "rendererTimeoutSeconds": 7,
                                     "submittedFrames": startupRows.filter { $0["stage"] as? String == "startup-source" }.count,
                                     "allocationFailures": startupRows.filter { $0["stage"] as? String == "startup-source-allocation-failed" }.count,
                                     "skippedAttempts": startupRows.filter { $0["stage"] as? String == "startup-source-skipped" }.count,
                                     "method": "Actual negotiated media path; bounded 12Hz warm-up with separate stamps 60000-60059. Hard 8-buffer limit; allocation pressure skips a paced attempt. Stop after first renderer callback, then begin the measured phase. Unused slots in the maximum 5s window are not observed dropped frames.",
                                     "rows": startupRows]
        try JSONSerialization.data(withJSONObject: startup, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + "-startup.json"))
        guard renderedAt != nil else { throw BudgetFailure.noWarmFrame }
        samples.setPhase(baseline ? "baseline" : "initial")
        let start = ProcessInfo.processInfo.systemUptime + 0.2
        let clockAnchor = ["uptimeSeconds": start,
                           "utcSeconds": Date().timeIntervalSince1970 - (ProcessInfo.processInfo.systemUptime - start)]
        var recovery = BudgetResolutionRecovery()
        var budgetPhase = "initial"
        var feedbackOpen = true
        var initialBudgetObserved = false
        defer { feedbackOpen = false }
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
            let requestedPhase = budgetPhase
            pc.statistics { report in
                let observedAt = ProcessInfo.processInfo.systemUptime
                trace.statistics(report, stage: "host-rtc", type: "outbound-rtp", counter: "framesEncoded")
                if diagnostic { trace.selectedTransport(report) }
                if candidate, let allocation = report.statistics.values.first(where: {
                    $0.type == "outbound-rtp" && $0.values["kind"] as? String == "video" && $0.values["framesEncoded"] != nil
                })?.values["targetBitrate"] as? NSNumber {
                    let bitrate = allocation.intValue
                    Task { @MainActor in
                        guard feedbackOpen, requestedPhase == budgetPhase, observedAt >= start,
                              observedAt < start + duration, ProcessInfo.processInfo.systemUptime < start + duration,
                              host.isReady else { return }
                        if budgetPhase == "initial", bitrate >= 4_000_000, !initialBudgetObserved {
                            initialBudgetObserved = true
                            trace.add("initial-media-budget", ["observedAllocationBps": bitrate], at: observedAt)
                        }
                        if budgetPhase == "recovery", recovery.observe(allocationBps: bitrate) {
                            trace.add("resolution-trigger", ["observedAllocationBps": bitrate,
                                "observedUptimeSeconds": observedAt,
                                "restoreRequestedUptimeSeconds": ProcessInfo.processInfo.systemUptime], at: observedAt)
                            do { try cap(4_000_000, scale: 1, stage: "resolution-restore") }
                            catch { XCTFail("Resolution restore failed: \(error)") }
                        }
                    }
                }
            }
            remote.statistics { trace.statistics($0, stage: "viewer-rtc", type: "inbound-rtp", counter: "framesDecoded") }
        }
        statistics()
        let timer = Timer.connectionTimer(withTimeInterval: 1, repeats: true) { _ in statistics() }
        defer { timer.invalidate() }
        if !baseline {
            try await Task.sleep(for: .seconds(10.2))
            try cap(250_000, scale: candidate ? 4 : nil)
            budgetPhase = "limited"; samples.setPhase("limited")
            try await Task.sleep(for: .seconds(15))
            try cap(4_000_000, scale: candidate ? 4 : nil, armRecovery: true)
            budgetPhase = "recovery"; samples.setPhase("recovery")
            if candidate {
                recovery.arm()
                trace.add("resolution-armed", ["requiredAllocationBps": 4_000_000])
            }
        }
        await fulfillment(of: [finished], timeout: baseline ? 35 : 66)
        feedbackOpen = false
        try await Task.sleep(for: .seconds(1))
        statistics()
        try await Task.sleep(for: .seconds(0.3))
        timer.invalidate()
        track?.remove(sink)
        // No verbose callback during source observation or drain. Only the numeric teardown
        // footer is retained; synchronous close flushes the event log and destroys the send stream.
        let dropTotals = BudgetDropTotals()
        let logger: RTCCallbackLogger? = diagnostic ? RTCCallbackLogger() : nil
        logger?.severity = .info
        logger?.start { dropTotals.capture($0) }
        defer { logger?.stop() }
        host.close(); viewer.close()
        trace.add("closed", ["hostReady": host.isReady])
        try await Task.sleep(for: .seconds(0.5))
        logger?.stop()
        let nativeDrops = dropTotals.snapshot()
        for row in nativeDrops.rows { trace.add("native-drop-totals", row.totals, at: row.time) }
        let detail = try samples.write(source: scenes, directory: directory, prefix: name, start: start)
        let rows = trace.snapshot().map { row -> [String: Any] in
            var row = row; row["t"] = (row.removeValue(forKey: "time") as! Double) - start; return row
        }
        let selectedPairs = rows.filter { $0["stage"] as? String == "host-selected-pair" }
        let pairBudgetSamples = selectedPairs.filter {
            $0["availableOutgoingBitrate"] is NSNumber && $0["currentRoundTripTime"] is NSNumber
        }.count
        let caps = rows.filter { $0["stage"] as? String == "cap" && ($0["t"] as! Double) >= 0 }
        let limitedAt = caps.first?["t"] as? Double ?? 10
        let recoveryAt = caps.last?["t"] as? Double ?? 25
        let recoveryRequestAt = (caps.last?["requestedAtUptimeSeconds"] as? Double).map { $0 - start } ?? recoveryAt
        let allSource = rows.filter { $0["stage"] as? String == "source" }
        let sourceTimes = Dictionary(uniqueKeysWithValues: allSource.map { ($0["index"] as! Int, $0["t"] as! Double) })
        let sourceGaps = zip(allSource, allSource.dropFirst()).map { before, after in
            (end: after["t"] as! Double, ms: ((after["t"] as! Double) - (before["t"] as! Double)) * 1000)
        }
        let allRendered = rows.filter { $0["stage"] as? String == "renderer" }
        let allGaps = zip(allRendered, allRendered.dropFirst()).map { before, after in
            (end: after["t"] as! Double, ms: ((after["t"] as! Double) - (before["t"] as! Double)) * 1000)
        }
        let triggers = rows.filter { $0["stage"] as? String == "resolution-trigger" }
        let triggerTime = triggers.first?["t"] as? Double
        let measuredRendered = allRendered.filter { ($0["t"] as! Double) >= 0 && ($0["t"] as! Double) < duration }
        let firstNative = triggerTime.flatMap { trigger in measuredRendered.first { row in
            let index = row["index"] as? Int ?? -1
            return (row["t"] as! Double) >= trigger && (sourceTimes[index] ?? -.infinity) >= trigger
                && (row["width"] as? NSNumber)?.intValue == 3840 && (row["height"] as? NSNumber)?.intValue == 2160
        } }
        let firstNativeTime = firstNative?["t"] as? Double
        let nativeLatency = triggerTime.flatMap { trigger in firstNativeTime.map { ($0 - trigger) * 1000 } }
        let allocationRecoveryTime = rows.first { row in
            row["stage"] as? String == "encoder-rate" && (row["t"] as! Double) >= recoveryRequestAt
                && ((row["kbps"] as? NSNumber)?.intValue ?? 0) >= 4000
        }?["t"] as? Double
        let allocationLatency = allocationRecoveryTime.flatMap { allocated in firstNativeTime.map { ($0 - allocated) * 1000 } }
        let allocationPrecedesTrigger = allocationRecoveryTime.flatMap { allocated in triggerTime.map { allocated <= $0 } } ?? false
        let staysNative = firstNativeTime.map { first in measuredRendered.filter { ($0["t"] as! Double) >= first }
            .allSatisfy { ($0["width"] as? NSNumber)?.intValue == 3840 && ($0["height"] as? NSNumber)?.intValue == 2160 } } ?? false
        let recoveryDetail = detail.first { $0["phase"] as? String == "recovery" }
        let matchedRecovery = recoveryDetail.map { sample in
            sample["missing"] == nil && sourceTimes[sample["index"] as? Int ?? -1] != nil
                && sample["width"] as? Int == 3840 && sample["height"] as? Int == 2160
                && (sample["textROIPsnr"] as? Double ?? -1) > 0
                && (sample["textEdgeMeanAbsoluteError"] as? Double ?? -1) >= 0
                && (sample["textEdgePixels"] as? Int ?? 0) > 0
        } ?? false
        let maximumGap = max(allGaps.map(\.ms).max() ?? 0,
                             max(0, measuredRendered.first?["t"] as? Double ?? duration) * 1000,
                             max(0, duration - (measuredRendered.last?["t"] as? Double ?? 0)) * 1000)
        let limitedScaled = rows.filter { row in
            (row["t"] as! Double) >= limitedAt && (row["t"] as! Double) < recoveryAt
                && (row["width"] as? NSNumber)?.intValue == 960 && (row["height"] as? NSNumber)?.intValue == 540
        }
        let candidateAcceptance: [String: Any] = [
            "initialMediaBudgetObserved": initialBudgetObserved, "triggerCount": triggers.count,
            "restoreCount": rows.filter { $0["stage"] as? String == "resolution-restore" }.count,
            "maximumRendererGapMs": maximumGap,
            "firstNativeRendererAfterTriggerMs": nativeLatency.map { $0 as Any } ?? NSNull(),
            "firstNativeRendererAfterAllocationMs": allocationLatency.map { $0 as Any } ?? NSNull(),
            "allocationPrecedesTrigger": allocationPrecedesTrigger,
            "staysNativeUntilEnd": staysNative, "matchedNativeRecoverySample": matchedRecovery,
            "limitedEncodedScaleObserved": limitedScaled.contains { $0["stage"] as? String == "encode-output" },
            "limitedRendererScaleObserved": limitedScaled.contains { $0["stage"] as? String == "renderer" },
            "allocationRecoverySeconds": allocationRecoveryTime.map { $0 as Any } ?? NSNull(),
            "triggerSeconds": triggerTime.map { $0 as Any } ?? NSNull(),
            "firstNativeRendererSeconds": firstNativeTime.map { $0 as Any } ?? NSNull(),
            "recoveryDetail": recoveryDetail ?? [:]]
        if !baseline { XCTAssertGreaterThanOrEqual(duration - recoveryAt, 60, "Recovery observation must be at least 60 seconds") }
        let phases: [(String, Double, Double)] = baseline ? [("baseline", 0, duration)]
            : [("initial", 0, limitedAt), ("limited", limitedAt, recoveryAt), ("recovery", recoveryAt, duration)]
        let summaries: [[String: Any]] = phases.map { label, begin, end in
            let selected = rows.filter { ($0["t"] as! Double) >= begin && ($0["t"] as! Double) < end }
            let rendered = selected.filter { $0["stage"] as? String == "renderer" }
            // Attribute a crossing gap to its ending frame, retaining budget-transition stalls.
            let gaps = allGaps.filter { $0.end >= begin && $0.end < end }.map(\.ms)
            let phaseSourceGaps = sourceGaps.filter { $0.end >= begin && $0.end < end }.map(\.ms)
            let ages: [Double] = rendered.compactMap { row in
                guard let index = row["index"] as? Int, let sent = sourceTimes[index] else { return nil }
                return ((row["t"] as! Double) - sent) * 1000
            }
            let qp = selected.filter { $0["stage"] as? String == "encode-output" }.compactMap { ($0["qp"] as? NSNumber)?.doubleValue }
            let reasons = Set(selected.filter { $0["stage"] as? String == "host-rtc" }.compactMap { $0["qualityLimitationReason"] as? String }).sorted()
            let lastBeforeEnd = allRendered.last { ($0["t"] as! Double) < end }?["t"] as? Double ?? begin
            let sizes = Set(rendered.map { "\($0["width"]!)x\($0["height"]!)" }).sorted()
            let pairSamples = selected.filter { $0["stage"] as? String == "host-selected-pair" && $0["resolved"] as? Int == 1
                && $0["availableOutgoingBitrate"] is NSNumber && $0["currentRoundTripTime"] is NSNumber }.count
            let count: (String) -> Int = { stage in selected.filter { $0["stage"] as? String == stage }.count }
            return ["phase": label, "startSeconds": begin, "durationSeconds": end - begin, "source": count("source"),
                    "encoderInputs": count("encode-input"), "encoderOutputs": count("encode-output"),
                    "selectedPairBudgetSamples": pairSamples,
                    "renderer": rendered.count, "sizes": sizes,
                    "sourceGapsMs": distribution(phaseSourceGaps), "sourceToRendererAgeMs": distribution(ages),
                    "encodedQP": distribution(qp), "qualityLimitationReasons": reasons,
                    "sourceAllocationFailures": count("source-allocation-failed"), "sourceSkippedAttempts": count("source-skipped"),
                    "rendererGapMaxMs": gaps.max() ?? 0, "rendererGapsOver200Ms": gaps.filter { $0 > 200 }.count,
                    "rendererTailSilenceMs": max(0, end - max(begin, lastBeforeEnd)) * 1000,
                    "readableStamps": rendered.filter { ($0["index"] as? Int ?? -1) >= 0 }.count]
        }
        let instrumentation: [String: Any] = [
            "enabled": diagnostic, "valid": diagnostic && PerformanceLog.enabled && nativeDrops.valid && summaries.allSatisfy { ($0["selectedPairBudgetSamples"] as? Int ?? 0) > 0 },
            "performanceLogEnabled": PerformanceLog.enabled, "nativeSummaryCount": nativeDrops.rows.count,
            "nativeSummaryRejectedCount": nativeDrops.rejected, "nativeSummaryOverflowCount": nativeDrops.overflow,
            "selectedPairSamples": selectedPairs.count, "selectedPairBudgetSamples": pairBudgetSamples,
            "selectedPairBudgetSamplesByPhase": Dictionary(uniqueKeysWithValues: summaries.map { ($0["phase"] as! String, $0["selectedPairBudgetSamples"] as! Int) }),
            "networkTraceValidation": "Required separately by the offline collector: both trace start records and complete BeginLog/EndLog coverage.",
            "dropTotalsScope": "Exact whole send-stream lifetime, including warm-up and drain; not per-phase drop counts.",
            "eligibleForRelease": false]
        return ["policy": name, "sourceRevision": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "unknown",
                "baseRevision": "b799faefe011d254eac491769231bb38e1087bc0", "durationSeconds": duration, "baselineOnly": baseline,
                "schemaVersion": 3, "diagnosticOnly": diagnostic, "eligibleForRelease": false,
                "correctionCandidate": candidate, "candidateAcceptance": candidateAcceptance,
                "candidateMethod": candidate ? "Preserve-both preference throughout; initial scale1, atomic250kbps+scale4, restore4Mbps cap retaining scale4, then one scale1 restore after a measured adjusted encoder allocation reaches4Mbps. No QP/min-rate/limiter override. Source and native encoder input may stay4K; encoded/renderer dimensions establish scaling. Transition gaps are included." : "none",
                "clockAnchor": clockAnchor, "diagnosticInstrumentation": instrumentation,
                "processActivity": "userInteractive across source-only admission, warm-up, measurement, drain and cleanup; matches the app's active-session option",
                "schemaSemantics": ["renderer": "BudgetRenderer callback after pixel-stamp extraction, not decoder output or display presentation; entryAtUptimeSeconds preserves callback entry time.",
                                    "renderer-entry": "Callback entry before pixel access or stamp extraction; rtp is the original frame's unsigned receiver RTP timestamp.",
                                    "decode-output": "Performance frame-timing timestamp retains raw decoder nanoseconds; detail is unsigned receiver RTP, captured before forwarding the native callback.",
                                    "sourceToRendererAgeMs": "Source submission to that renderer callback; not optical latency.",
                                    "framesDecoded": "Native RTC cumulative decoder counter, separate from renderer callback counts.",
                                    "native-drop-totals": "M153 SendStatisticsProxy exact unclamped lifetime counters, collected only during teardown."],
                "sourceSize": [3840, 2160], "requestedSourceFPS": 60,
                "method": "Local ICE and production transports/factories. Baseline: 30s at 4Mbps. Comparison mode: 4Mbps for 10s, 250kbps for 15s, 4Mbps for at least 60s. Sender cap is not network shaping or optical latency. Two pre-rendered text scenes alternate every 300 emitted frames with a moving bar and unique sequential frame stamp; this is not scrolling and must not be compared directly with the prior workload. Stamps count emitted frames, not planned 60Hz slots. Strict one-shot timer prepares before waiting and rebases on actual previous emission; missed slots are never replayed. Hard pool limit 8; allocation pressure skips a paced attempt and reduces actual source cadence. Encoder/decoder startup uses separately recorded bounded 12Hz repeats before the full measured phase. PNG/detail work happens after measurement and peer closure.",
                "sourceGapsMs": gapSummary(rows.filter { $0["stage"] as? String == "source" }.map { $0["t"] as! Double }),
                "sourceFrames": rows.filter { $0["stage"] as? String == "source" }.count,
                "sourceAllocationFailures": rows.filter { $0["stage"] as? String == "source-allocation-failed" }.count,
                "sourceSkippedAttempts": rows.filter { $0["stage"] as? String == "source-skipped" }.count,
                "rendererFrames": rows.filter { $0["stage"] as? String == "renderer" }.count,
                "readableStamps": rows.filter { $0["stage"] as? String == "renderer" && ($0["index"] as? Int ?? -1) >= 0 }.count,
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
        distribution(zip(times, times.dropFirst()).map { ($1 - $0) * 1000 })
    }
    private func distribution(_ values: [Double]) -> [String: Double] {
        let gaps = values.sorted()
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

/// Experiment-only latch; not a production bandwidth controller.
private struct BudgetResolutionRecovery {
    private var armed = false
    private var restored = false
    mutating func arm() { armed = true }
    mutating func observe(allocationBps: Int) -> Bool {
        guard armed, !restored, allocationBps >= 4_000_000 else { return false }
        restored = true
        return true
    }
}

private enum BudgetFailure: Error { case noLocalConnection, noWarmFrame, diagnosticsInitializedDisabled }

/// Only six exact numeric footer fields cross the native logging boundary; no raw log is saved.
private final class BudgetDropTotals {
    private static let prefix = "WebRTC.Video.Screenshare.DroppedFrames."
    private static let fields = ["Capturer", "BadTimestamp", "EncoderQueue", "Encoder", "Ratelimiter", "CongestionWindow"]
    private let lock = NSLock()
    private var messages: [(time: Double, lines: [String])] = []
    private var overflow = 0

    func capture(_ message: String) {
        guard Self.isTeardown(message) else { return }
        // Called under WebRTC's logging lock: no RTC calls, dispatch, disk I/O or full-log retention.
        let lines = message.split(separator: "\n").filter { $0.hasPrefix(Self.prefix) }
        let bounded = lines.count <= 8 && lines.allSatisfy { $0.utf8.count <= 128 }
            ? lines.map(String.init) : []
        let time = ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        if messages.count < 4 { messages.append((time, bounded)) } else { overflow += 1 }
    }

    func snapshot() -> (rows: [(time: Double, totals: [String: Int])], rejected: Int, overflow: Int, valid: Bool) {
        lock.lock(); let messages = self.messages, overflow = self.overflow; lock.unlock()
        let rows = messages.compactMap { message -> (time: Double, totals: [String: Int])? in
            Self.parseLines(message.lines).map { (message.time, $0) }
        }
        let rejected = messages.count - rows.count
        return (rows, rejected, overflow, rows.count == 1 && rejected == 0 && overflow == 0)
    }

    static func parse(_ message: String) -> [String: Int]? {
        guard isTeardown(message) else { return nil }
        return parseLines(message.split(separator: "\n").filter { $0.hasPrefix(prefix) }.map(String.init))
    }
    private static func isTeardown(_ message: String) -> Bool {
        message.range(of: #"\(send_statistics_proxy\.cc:[0-9]+\):"#, options: .regularExpression) != nil
            && message.contains(prefix)
    }
    private static func parseLines(_ lines: [String]) -> [String: Int]? {
        guard lines.count == fields.count else { return nil }
        var totals: [String: Int] = [:]
        for line in lines {
            guard let field = fields.first(where: { line.hasPrefix(prefix + $0 + ($0 == "BadTimestamp" ? "" : " ")) }) else { return nil }
            let number = line.dropFirst(prefix.count + field.count + (field == "BadTimestamp" ? 0 : 1))
                .drop(while: { $0 == " " })
            guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(number), totals.updateValue(value, forKey: field) == nil else { return nil }
        }
        return totals.count == fields.count ? totals : nil
    }
}

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
    func selectedTransport(_ report: RTCStatisticsReport) {
        let stats = report.statistics
        let video = stats.values.first { $0.type == "outbound-rtp" && $0.values["kind"] as? String == "video" && $0.values["framesEncoded"] != nil }
        let transport = (video?.values["transportId"] as? String).flatMap { stats[$0] }
        let pair = (transport?.values["selectedCandidatePairId"] as? String).flatMap { stats[$0] }
        let resolved = transport?.type == "transport" && pair?.type == "candidate-pair"
        let fields = ["availableOutgoingBitrate", "currentRoundTripTime", "totalRoundTripTime",
                      "bytesSent", "bytesReceived", "packetsSent", "packetsReceived",
                      "requestsSent", "responsesReceived", "consentRequestsSent",
                      "packetsDiscardedOnSend", "bytesDiscardedOnSend"]
        var values: [String: Any] = ["resolved": resolved ? 1 : 0]
        for field in fields {
            // IDs are used only for this lookup. No candidate identifiers, addresses or strings survive.
            values[field] = resolved ? (pair?.values[field] as? NSNumber).map { $0 as Any } ?? NSNull() : NSNull()
        }
        add("host-selected-pair", values)
    }
}

private final class BudgetEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let base = ScreenVideoEncoderFactory()
    private let trace: BudgetTrace
    private let samples: BudgetSamples
    init(_ trace: BudgetTrace, samples: BudgetSamples) { self.trace = trace; self.samples = samples }
    func supportedCodecs() -> [RTCVideoCodecInfo] { base.supportedCodecs() }
    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        guard let encoder = base.createEncoder(info) else { return nil }
        return BudgetEncoder(encoder, trace, samples: samples)
    }
}

private final class BudgetEncoder: NSObject, RTCVideoEncoder {
    private let base: RTCVideoEncoder
    private let trace: BudgetTrace
    private let samples: BudgetSamples
    init(_ base: RTCVideoEncoder, _ trace: BudgetTrace, samples: BudgetSamples) {
        self.base = base; self.trace = trace; self.samples = samples
    }
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
        let observedAt = ProcessInfo.processInfo.systemUptime
        trace.add("encoder-rate", ["kbps": bitrateKbit, "fps": framerate, "result": result], at: observedAt)
        samples.observeEncoderRate(kbps: bitrateKbit, result: result, at: observedAt)
        return result
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
        let enteredAt = ProcessInfo.processInfo.systemUptime
        guard let frame else { return }
        let rtp = UInt32(bitPattern: frame.timeStamp)
        trace.add("renderer-entry", ["rtp": rtp, "ns": frame.timeStampNs,
                                     "width": frame.width, "height": frame.height], at: enteredAt)
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
        trace.add(startupFrame ? "startup-renderer" : "renderer",
                  ["index": validatedIndex, "stampIndex": index, "rtp": rtp,
                   "width": frame.width, "height": frame.height, "ns": frame.timeStampNs,
                   "entryAtUptimeSeconds": enteredAt])
        samples.capture(frame, index: validatedIndex, at: enteredAt)
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
