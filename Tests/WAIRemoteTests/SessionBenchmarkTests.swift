import AppKit
import RemoteCore
import WebRTC
import XCTest
@testable import WAIRemote

/// Opt-in end-to-end session: the app's host PeerTransport and Mac ViewerTransport
/// in one process, with short-lived relay credentials from the production gateway,
/// so media takes the real path: this Mac, its default route, the TURN relay and back.
/// Synthetic pixels only; nothing is captured, persisted in the Keychain or injected.
///
///     WAI_SESSION_BENCH=1 swift test --filter SessionBenchmarkTests
///
/// WAI_SESSION_POLICY=all compares the direct path. Results go to WAI_BENCH_DIR,
/// or .runtime/bench in this package.
@MainActor
final class SessionBenchmarkTests: XCTestCase {
    private static let gateway = URL(string: "wss://waiwai.is/remote/connect/signal")!

    func testDesktopSession() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["WAI_SESSION_BENCH"] == "1")
        let policy = environment["WAI_SESSION_POLICY"] ?? "relay"
        // As main.swift and HostModel prepare WebRTC, before any WebRTC object exists.
        _ = NSApplication.shared
        ScreenVideoPolicy.initializeWebRTC()
        RTCInitializeSSL()
        signal(SIGPIPE, SIG_IGN)
        let desktop = SyntheticDesktop()
        let hostICE = try await iceConfiguration(policy: policy), viewerICE = try await iceConfiguration(policy: policy)
        // As HostModel.connect builds a session.
        let factory = RTCPeerConnectionFactory(encoderFactory: ScreenVideoEncoderFactory(), decoderFactory: ScreenVideoDecoderFactory())
        let capture = VideoCapture(factory: factory)
        let host = PeerTransport(factory: factory, source: capture.source, ice: hostICE)
        let viewer = ViewerTransport(ice: viewerICE)
        defer { host.close(); viewer.close() }
        let screen = Screen(desktop: desktop, timeline: Timeline(), source: capture.source)
        // Like MacViewerModel, hold the track: releasing it detaches its renderers.
        var track: RTCVideoTrack?
        viewer.onVideo = { track = $0; $0.add(screen) }
        defer { track?.remove(screen) }
        var states: [String] = []
        host.onState = { states.append("host:\($0.rawValue)") }
        viewer.onState = { states.append("viewer:\($0.rawValue)") }
        let opened = expectation(description: "Interaction channel open")
        host.onOpen = { opened.fulfill() }
        viewer.offer { offer in
            guard case .success(let offer) = offer else { states.append("offer:\(offer)"); return }
            host.answer(offer: offer) { answer in
                guard case .success(let answer) = answer else { states.append("answer:\(answer)"); return }
                viewer.answer(answer) { if let error = $0 { states.append("remote answer:\(error)") } }
            }
        }
        await fulfillment(of: [opened], timeout: 45)
        guard host.isReady else { XCTFail("No \(policy) connection: \(states)"); return }

        let input = InputProbe()
        host.onMessage = { [weak host] data in
            guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = message["operationID"] as? String else { return }
            _ = host?.send(["type": "performanceAck", "id": id])
        }
        viewer.onMessage = { data in
            guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  message["type"] as? String == "performanceAck", let id = message["id"] as? String else { return }
            input.acknowledged(id)
        }
        let statistics = Statistics(host: try XCTUnwrap(child(host, "pc")), viewer: try XCTUnwrap(child(viewer, "peer")))
        // HostModel starts capture once the interaction channel opens.
        let start = ProcessInfo.processInfo.systemUptime + 0.25
        let played = expectation(description: "Desktop timeline played")
        let feeder = Thread { screen.play(from: start); played.fulfill() }
        feeder.qualityOfService = .userInteractive; feeder.start()
        statistics.sample()
        let timers = [Timer.connectionTimer(withTimeInterval: 1, repeats: true) { _ in statistics.sample() },
                      Timer.connectionTimer(withTimeInterval: 0.25, repeats: true) { _ in input.send(through: viewer) }]
        await fulfillment(of: [played], timeout: screen.timeline.duration + 60)
        try await Task.sleep(for: .seconds(1.5))
        timers.forEach { $0.invalidate() }
        statistics.sample()
        try await Task.sleep(for: .seconds(0.5))
        screen.drain()

        let (rows, summary) = summarize(screen, statistics, input, start: start, policy: policy)
        let directory = URL(fileURLWithPath: environment["WAI_BENCH_DIR"] ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".runtime/bench").path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = directory.appendingPathComponent("session-\(policy)-\(formatter.string(from: Date()))").path
        try rows.map(Bench.json).joined(separator: "\n").write(toFile: base + ".jsonl", atomically: true, encoding: .utf8)
        try Bench.json(summary).write(toFile: base + "-summary.json", atomically: true, encoding: .utf8)
        print("SESSION_BENCH " + Bench.json(summary))
        print("SESSION_BENCH_FILES \(base).jsonl \(base)-summary.json")
        XCTAssertGreaterThan(screen.snapshot().shown.filter { $0.index >= 0 }.count, 0, "No decoded frame carried a readable index.")
        XCTAssertGreaterThan(input.snapshot().roundTrips.count, 0, "No input message was acknowledged.")
    }

    /// The app's own host signaling with a throwaway in-memory identity, read once for
    /// its relay credentials, exactly as the app receives them.
    private func iceConfiguration(policy: String) async throws -> ICEConfiguration {
        let signaling = Signaling(identity: DeviceIdentity())
        defer { signaling.close() }
        let ready = expectation(description: "Gateway ready")
        ready.assertForOverFulfill = false
        var configuration: ICEConfiguration?, failure: String?
        signaling.onReady = { configuration = $0; ready.fulfill() }
        signaling.onFailure = { failure = $0; ready.fulfill() }
        signaling.connect(url: Self.gateway)
        await fulfillment(of: [ready], timeout: 20)
        let ice = try XCTUnwrap(configuration, failure ?? "The gateway sent no ready message")
        guard ice.iceTransportPolicy != policy else { return ice }
        return try ICEConfiguration.read(["ice": ["iceServers": ice.iceServers.map { ["urls": $0.urls, "username": $0.username, "credential": $0.credential] },
                                                  "iceTransportPolicy": policy, "expiresAt": ice.expiresAt]])
    }

    /// The transports keep their connections private; the benchmark only reads statistics.
    private func child<T>(_ object: Any, _ label: String) -> T? {
        Mirror(reflecting: object).children.first { $0.label == label }?.value as? T
    }

    private func summarize(_ screen: Screen, _ statistics: Statistics, _ input: InputProbe, start: Double,
                           policy: String) -> ([[String: Any]], [String: Any]) {
        let timeline = screen.timeline, frames = screen.snapshot(), samples = statistics.snapshot()
        let pushed = frames.pushed, identified = frames.shown.filter { $0.index >= 0 && pushed[$0.index].isFinite }
        func delta(_ a: [String: Any], _ b: [String: Any], _ key: String) -> Double? {
            guard let before = a[key] as? Double, let after = b[key] as? Double else { return nil }; return after - before
        }
        let rows: [[String: Any]] = zip(samples, samples.dropFirst()).map { a, b in
            let dt = b.time - a.time, interval = a.time..<b.time
            let sources = pushed.indices.filter { interval.contains(pushed[$0]) }
            let encoded = delta(a.host, b.host, "framesEncoded") ?? 0
            let buffered = delta(a.viewer, b.viewer, "jitterBufferEmittedCount") ?? 0
            return ["t": Bench.round(b.time - start, 1), "phase": sources.first.map { timeline.pushes[$0].phase } ?? "static",
                    "src": sources.count, "shown": frames.shown.filter { interval.contains($0.time) }.count,
                    "recvMbps": Bench.round(delta(a.viewer, b.viewer, "bytesReceived").map { $0 * 8 / dt / 1e6 }, 3),
                    "sentMbps": Bench.round(delta(a.host, b.host, "bytesSent").map { $0 * 8 / dt / 1e6 }, 3),
                    "targetMbps": Bench.round((b.host["targetBitrate"] as? Double).map { $0 / 1e6 }, 3),
                    "availMbps": Bench.round((b.host["availableOutgoingBitrate"] as? Double).map { $0 / 1e6 }, 3),
                    "rttMs": Bench.round((b.host["currentRoundTripTime"] as? Double).map { $0 * 1000 }, 0),
                    "encFps": Bench.round(encoded / dt, 1), "decFps": Bench.round(delta(a.viewer, b.viewer, "framesDecoded").map { $0 / dt }, 1),
                    "qp": Bench.round(encoded > 0 ? delta(a.host, b.host, "qpSum").map { $0 / encoded } : nil, 1),
                    "keyFrames": Bench.round(delta(a.host, b.host, "keyFramesEncoded"), 0),
                    "freezes": Bench.round(delta(a.viewer, b.viewer, "freezeCount"), 0),
                    "lost": Bench.round(delta(a.viewer, b.viewer, "packetsLost"), 0),
                    "nack": Bench.round(delta(a.viewer, b.viewer, "nackCount"), 0), "pli": Bench.round(delta(a.viewer, b.viewer, "pliCount"), 0),
                    "jitterBufferMs": Bench.round(buffered > 0 ? delta(a.viewer, b.viewer, "jitterBufferDelay").map { $0 / buffered * 1000 } : nil, 0),
                    "pair": "\(b.host["local"] ?? "-") > \(b.host["remote"] ?? "-")",
                    "limitation": b.host["qualityLimitationReason"] ?? NSNull()]
        }
        func values(_ key: String, _ rows: [[String: Any]] = rows) -> [Double] { rows.compactMap { ($0[key] as? NSNumber)?.doubleValue } }
        func spread(_ values: [Double], _ points: [Double], digits: Int = 2) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: points.map { ("p\(Int($0 * 100))", Bench.round(Bench.percentile(values, $0), digits)) })
        }
        // A freeze is a gap over 200 ms between displayed frames while the source kept
        // changing: no source gap of 200 ms or more lies between the two frames.
        var freezes = 0, frozen = 0.0
        for (a, b) in zip(identified, identified.dropFirst()) where b.time - a.time > 0.2 && b.index > a.index {
            if ((a.index + 1)...b.index).allSatisfy({ pushed[$0] - pushed[$0 - 1] < 0.2 }) { freezes += 1; frozen += b.time - a.time }
        }
        var firstShown: [Int: Double] = [:]
        for frame in identified where firstShown[frame.index] == nil { firstShown[frame.index] = frame.time }
        let changes: [[String: Any]] = timeline.changes.map { change in
            let pushedAt = pushed[change.final]
            let sharp = frames.quality.filter { $0.kind == "final" && $0.reference == change.final && $0.psnr >= 35 }.map(\.time).min()
            let settled = frames.quality.first { $0.kind == "settled" && $0.reference == change.final }
            return ["phase": change.phase, "final": change.final,
                    "shownMs": Bench.round(firstShown[change.final].map { ($0 - pushedAt) * 1000 }, 0),
                    "firstPSNR": Bench.round(frames.quality.filter { $0.kind == "final" && $0.reference == change.final }.min { $0.time < $1.time }?.psnr),
                    "sharpMs": Bench.round(sharp.map { ($0 - pushedAt) * 1000 }, 0),
                    "settledPSNR": Bench.round(settled?.psnr), "settledShown": settled?.shown ?? NSNull()]
        }
        let shownMs = changes.compactMap { ($0["shownMs"] as? NSNumber)?.doubleValue }, sharpMs = changes.compactMap { ($0["sharpMs"] as? NSNumber)?.doubleValue }
        let bursts = [0] + timeline.changes.dropLast().map { $0.final + 1 }
        let response = bursts.compactMap { first in identified.first { $0.index >= first }.map { ($0.time - pushed[first]) * 1000 } }
        let motion = rows.filter { ($0["src"] as? Int ?? 0) >= 30 }
        let last = samples.last, roundTrips = input.snapshot()
        let summary: [String: Any] = [
            "policy": policy, "durationS": Bench.round(timeline.duration, 0),
            "path": ["host": last?.host["local"] ?? NSNull(), "hostRemote": last?.host["remote"] ?? NSNull(), "viewer": last?.viewer["local"] ?? NSNull(),
                     "codec": last?.host["codec"] ?? NSNull(), "encoder": last?.host["encoderImplementation"] ?? NSNull(),
                     "decoder": last?.viewer["decoderImplementation"] ?? NSNull(),
                     "size": "\(Int(last?.viewer["frameWidth"] as? Double ?? 0))x\(Int(last?.viewer["frameHeight"] as? Double ?? 0))"],
            "recvMbps": spread(values("recvMbps"), [0.1, 0.5, 0.9], digits: 3),
            "decodedFps": spread(values("shown", motion), [0.1, 0.5], digits: 0), "motionSourceFps": Bench.round(Bench.percentile(values("src", motion), 0.5), 0),
            "freezes": ["count": freezes, "seconds": Bench.round(frozen)],
            "webrtcFreezes": ["count": Bench.round(last?.viewer["freezeCount"] as? Double, 0),
                              "seconds": Bench.round(last?.viewer["totalFreezesDuration"] as? Double)],
            "staleFinal": ["stale": changes.count - shownMs.filter { $0 <= 1000 }.count, "bursts": changes.count],
            "finalShownMs": spread(shownMs, [0.5, 0.9], digits: 0),
            "latencyMs": spread(firstShown.map { ($0.value - pushed[$0.key]) * 1000 }, [0.5, 0.9], digits: 0),
            "responseMs": spread(response, [0.5, 0.9], digits: 0),
            "psnrMotion": spread(frames.quality.filter { $0.kind == "motion" }.map(\.psnr), [0.1, 0.5]).merging(["n": frames.quality.filter { $0.kind == "motion" }.count]) { a, _ in a },
            "psnrSettled": spread(frames.quality.filter { $0.kind == "settled" }.map(\.psnr), [0.1, 0.5]).merging(["n": frames.quality.filter { $0.kind == "settled" }.count]) { a, _ in a },
            "sharpMs": spread(sharpMs, [0.5, 0.9], digits: 0).merging(["reached": sharpMs.count, "changes": changes.count]) { a, _ in a },
            "keyFrames": ["encoded": Bench.round(last?.host["keyFramesEncoded"] as? Double, 0),
                          "decoded": Bench.round(last?.viewer["keyFramesDecoded"] as? Double, 0)],
            "targetMbps": spread(values("targetMbps"), [0.1, 0.5], digits: 3), "availMbps": spread(values("availMbps"), [0.1, 0.5], digits: 3),
            "rttMs": spread(values("rttMs"), [0.5, 0.9], digits: 0),
            "inputMs": spread(roundTrips.roundTrips, [0.5, 0.95], digits: 0).merging(["sent": roundTrips.sent, "acked": roundTrips.roundTrips.count]) { a, _ in a },
            "frames": ["pushed": pushed.filter(\.isFinite).count, "shown": frames.shown.count,
                       "unidentified": frames.shown.count - frames.shown.filter { $0.index >= 0 }.count, "psnrSkipped": frames.skipped],
            "changes": changes]
        return (rows, summary)
    }
}

/// About 77 s of desktop use: a page opens, scrolls, takes typing, switches window,
/// with six static seconds after every burst. Frames exist only on change.
private struct Timeline {
    struct Push { let time: Double; let state: SyntheticDesktop.State; let phase: String }
    /// The last frame of a burst; the screen then stays static until `end`.
    struct Change { let final: Int; let end: Double; let phase: String }
    private(set) var pushes: [Push] = [], changes: [Change] = []
    private(set) var duration = 0.0
    init() {
        var state = SyntheticDesktop.State(), time = 0.0
        func push(_ phase: String) { pushes.append(Push(time: time, state: state, phase: phase)) }
        func hold() { time += 6; changes.append(Change(final: pushes.count - 1, end: time, phase: pushes[pushes.count - 1].phase)) }
        func scroll(by distance: Int, seconds: Double, _ phase: String) {
            let base = time, from = state.offsets[state.window], count = Int(seconds * 60)
            for frame in 1...count {
                let x = Double(frame) / Double(count), offset = from + Int(Double(distance) * x * x * (3 - 2 * x)) / 2 * 2
                guard offset != state.offsets[state.window] else { continue }
                state.offsets[state.window] = offset; time = base + Double(frame) / 60; push(phase)
            }
            time = base + seconds
        }
        func type(_ count: Int) { for _ in 0..<count { time += 0.125; state.typed += 1; push("typing") } }
        func show(_ window: Int) { state.window = window; push("switch") }
        push("open"); hold()
        scroll(by: 2160, seconds: 3, "scroll"); hold()
        type(64); hold()
        show(1); hold()
        scroll(by: 1440, seconds: 2, "scroll"); hold()
        show(0); hold()
        scroll(by: 720, seconds: 6, "slow-scroll"); hold()
        type(32); hold()
        show(1); hold()
        duration = time
    }
}

/// Plays the timeline into the host's video source and identifies every frame the
/// viewer's track delivers, measuring a sample against the regenerated source.
private final class Screen: NSObject, RTCVideoRenderer, @unchecked Sendable {
    struct Shown { let time: Double; let index: Int }
    struct Quality { let kind: String; let reference: Int; let shown: Int; let time: Double; let psnr: Double }
    let desktop: SyntheticDesktop, timeline: Timeline
    private let source: RTCVideoSource
    private let finals: Set<Int>
    private let lock = NSLock()
    private var pushed: [Double], shown: [Shown] = [], quality: [Quality] = []
    private var latest: RTCVideoFrame?
    private var pending = 0, motion = 0, skipped = 0
    private let queue = DispatchQueue(label: "is.wai.remote.bench.psnr", qos: .utility)
    init(desktop: SyntheticDesktop, timeline: Timeline, source: RTCVideoSource) {
        self.desktop = desktop; self.timeline = timeline; self.source = source
        finals = Set(timeline.changes.map(\.final)); pushed = Array(repeating: .nan, count: timeline.pushes.count)
    }
    func snapshot() -> (pushed: [Double], shown: [Shown], quality: [Quality], skipped: Int) {
        lock.lock(); defer { lock.unlock() }; return (pushed, shown, quality, skipped)
    }
    func drain() { queue.sync {} }

    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let now = ProcessInfo.processInfo.systemUptime, index = SyntheticDesktop.index(in: frame.buffer) ?? -1
        lock.lock()
        shown.append(Shown(time: now, index: index)); latest = frame
        if index >= 0, !finals.contains(index) { motion += 1 }
        let kind = finals.contains(index) ? "final" : index >= 0 && motion % 6 == 0 ? "motion" : nil
        lock.unlock()
        if let kind { measure(frame, index: index, against: index, kind: kind, time: now) }
    }
    private func measure(_ frame: RTCVideoFrame, index: Int, against reference: Int, kind: String, time: Double) {
        lock.lock()
        // Final and settled frames decide time-to-sharp; motion samples yield under load.
        guard pending < (kind == "motion" ? 4 : 64) else { skipped += 1; lock.unlock(); return }
        pending += 1; lock.unlock()
        let luma = SyntheticDesktop.luma(of: frame.buffer)
        queue.async { [self] in
            let psnr = SyntheticDesktop.psnr(reference: desktop.luma(timeline.pushes[reference].state, index: reference),
                                             decoded: luma.pixels, decodedFullRange: luma.fullRange)
            lock.lock(); pending -= 1
            if let psnr { quality.append(Quality(kind: kind, reference: reference, shown: index, time: time, psnr: psnr)) }
            lock.unlock()
        }
    }
    /// Like VideoCapture: ScreenCaptureKit delivers frames only when pixels change.
    func play(from start: Double) {
        let capturer = RTCVideoCapturer(delegate: source), pool = SyntheticDesktop.pool()
        func wait(until deadline: Double) {
            let delay = deadline - ProcessInfo.processInfo.systemUptime
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        }
        var next = 0
        func settle(before time: Double) {
            // What the viewer shows at the end of each static period, against what it should show.
            while next < timeline.changes.count, timeline.changes[next].end <= time {
                let change = timeline.changes[next]; next += 1
                wait(until: start + change.end - 0.05)
                lock.lock(); let frame = latest; lock.unlock()
                guard let frame else { continue }
                measure(frame, index: SyntheticDesktop.index(in: frame.buffer) ?? -1, against: change.final, kind: "settled",
                        time: ProcessInfo.processInfo.systemUptime)
            }
        }
        for (index, push) in timeline.pushes.enumerated() {
            settle(before: push.time)
            wait(until: start + push.time)
            guard let buffer = desktop.frame(push.state, index: index, pool: pool) else { continue }
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock(); pushed[index] = now; lock.unlock()
            source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0,
                                                                timeStampNs: Int64(now * 1_000_000_000)))
        }
        settle(before: .infinity)
    }
}

private final class Statistics: @unchecked Sendable {
    struct Sample { let time: Double; var host: [String: Any] = [:], viewer: [String: Any] = [:] }
    private let host: RTCPeerConnection, viewer: RTCPeerConnection
    private let lock = NSLock()
    private var samples: [Sample] = []
    init(host: RTCPeerConnection, viewer: RTCPeerConnection) { self.host = host; self.viewer = viewer }
    func snapshot() -> [Sample] { lock.lock(); defer { lock.unlock() }; return samples }
    func sample() {
        lock.lock()
        let index = samples.count
        samples.append(Sample(time: ProcessInfo.processInfo.systemUptime))
        lock.unlock()
        host.statistics { [self] report in let values = Self.values(report, "outbound-rtp"); lock.lock(); samples[index].host = values; lock.unlock() }
        viewer.statistics { [self] report in let values = Self.values(report, "inbound-rtp"); lock.lock(); samples[index].viewer = values; lock.unlock() }
    }
    private static func values(_ report: RTCStatisticsReport, _ type: String) -> [String: Any] {
        let stats = report.statistics
        var values: [String: Any] = [:]
        func copy(_ stat: RTCStatistics?, _ keys: [String]) {
            for key in keys {
                if let number = stat?.values[key] as? NSNumber { values[key] = number.doubleValue }
                else if let text = stat?.values[key] as? String { values[key] = text }
            }
        }
        if let rtp = stats.values.first(where: { $0.type == type && $0.values["kind"] as? String == "video" }) {
            copy(rtp, ["bytesSent", "bytesReceived", "framesEncoded", "framesDecoded", "qpSum", "keyFramesEncoded", "keyFramesDecoded",
                       "targetBitrate", "qualityLimitationReason", "encoderImplementation", "decoderImplementation", "frameWidth", "frameHeight",
                       "freezeCount", "totalFreezesDuration", "packetsLost", "nackCount", "pliCount", "jitterBufferDelay", "jitterBufferEmittedCount"])
            if let codec = rtp.values["codecId"] as? String { values["codec"] = stats[codec]?.values["mimeType"] as? String }
        }
        if let transport = stats.values.first(where: { $0.type == "transport" }),
           let pair = (transport.values["selectedCandidatePairId"] as? String).flatMap({ stats[$0] }) {
            copy(pair, ["currentRoundTripTime", "availableOutgoingBitrate"])
            func describe(_ id: String) -> String? {
                guard let candidate = (pair.values[id] as? String).flatMap({ stats[$0] }) else { return nil }
                return ["candidateType", "protocol", "relayProtocol", "networkType"].compactMap { candidate.values[$0] as? String }.joined(separator: "/")
            }
            values["local"] = describe("localCandidateId"); values["remote"] = describe("remoteCandidateId")
        }
        return values
    }
}

/// Viewer-to-host messages on the real interaction channel, acknowledged by the host.
private final class InputProbe: @unchecked Sendable {
    private let lock = NSLock(), session = UUID().uuidString
    private var sentAt: [String: Double] = [:], roundTrips: [Double] = [], sent = 0
    func send(through viewer: ViewerTransport) {
        lock.lock(); sent += 1; let id = String(sent); sentAt[id] = ProcessInfo.processInfo.systemUptime; lock.unlock()
        let message: [String: Any] = ["v": 1, "type": "heartbeat", "sessionID": session, "operationID": id, "sequence": Int(id)!]
        _ = viewer.send(try! JSONSerialization.data(withJSONObject: message))
    }
    func acknowledged(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        if let time = sentAt.removeValue(forKey: id) { roundTrips.append((ProcessInfo.processInfo.systemUptime - time) * 1000) }
    }
    func snapshot() -> (roundTrips: [Double], sent: Int) { lock.lock(); defer { lock.unlock() }; return (roundTrips, sent) }
}
