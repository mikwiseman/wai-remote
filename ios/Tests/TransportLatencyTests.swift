import CoreVideo
import RemoteCore
import WebRTC
import XCTest
@testable import WAI_Remote

/// Opt in with WAI_IOS_TRANSPORT_BENCH=1. Synthetic video and echoed input use the
/// real iOS ViewerTransport. This measures local WebRTC, not a Mac or a WAN route.
@MainActor
final class TransportLatencyTests: XCTestCase {
    func testInputRoundTripWhileReceivingVideo() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAI_IOS_TRANSPORT_BENCH"] == "1")
        let host = EchoVideoPeer(), viewer = ViewerTransport(ice: .local), frames = DecodedFrames()
        defer { host.close(); viewer.close() }
        var track: RTCVideoTrack?
        viewer.onVideo = { track = $0; $0.add(frames) }
        defer { track?.remove(frames) }
        let ready = expectation(description: "Peer greeting arrives through the interaction channel")
        var replyExpectation: XCTestExpectation?
        var connected = false, sent: [Int: (Data, Double)] = [:], acknowledged: [Int] = [], roundTrips: [Double] = []
        var failures: [String] = []
        viewer.onMessage = { data in
            if data == Data("ready".utf8) {
                if !connected { connected = true; ready.fulfill() }
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let index = object["probe"] as? Int, let original = sent[index] else {
                XCTFail("Unexpected echo"); return
            }
            XCTAssertEqual(data, original.0)
            XCTAssertFalse(acknowledged.contains(index), "An input message must arrive exactly once")
            acknowledged.append(index)
            roundTrips.append((ProcessInfo.processInfo.systemUptime - original.1) * 1_000)
            replyExpectation?.fulfill()
        }
        viewer.offer { result in
            switch result {
            case .failure(let error): failures.append("offer: \(error)")
            case .success(let offer):
                host.answer(offer) { result in
                    switch result {
                    case .failure(let error): failures.append("answer: \(error)")
                    case .success(let answer): viewer.answer(answer) { if let error = $0 { failures.append("remote: \(error)") } }
                    }
                }
            }
        }
        // Offer and answer each allow up to 12 seconds for candidate gathering.
        // This setup deadline is separate from the measured input/video latency.
        await fulfillment(of: [ready], timeout: 35)
        guard connected else { XCTFail("Local ICE did not connect: \(failures)"); return }
        let replies = expectation(description: "Every input payload returns unchanged")
        replies.expectedFulfillmentCount = 24; replyExpectation = replies

        let pixels = try [Self.pixels(luma: 32), Self.pixels(luma: 210)]
        let played = expectation(description: "Five seconds of synthetic video submitted")
        var sourceTimes: [Double] = [], number = 0
        let timer = Timer.connectionTimer(withTimeInterval: 1.0 / 30, repeats: true) { timer in
            let now = ProcessInfo.processInfo.systemUptime
            sourceTimes.append(now)
            host.push(pixels[(number / 5) % pixels.count], at: now)
            if number >= 30 && (number - 30) % 5 == 0 {
                let index = (number - 30) / 5
                let data = try! JSONSerialization.data(withJSONObject: ["probe": index, "text": "aЯ👨‍👩‍👧‍👦é"])
                sent[index] = (data, ProcessInfo.processInfo.systemUptime)
                XCTAssertTrue(viewer.send(data), "An open transport must accept this small input message")
            }
            number += 1
            if number == 150 { timer.invalidate(); played.fulfill() }
        }
        defer { timer.invalidate() }
        await fulfillment(of: [played, replies], timeout: 15)
        try await Task.sleep(for: .milliseconds(300))
        let decoded = frames.snapshot()
        XCTAssertEqual(acknowledged, Array(0..<24), "Ordered input must stay ordered while video is active")
        XCTAssertFalse(decoded.isEmpty, "The real decoder must deliver synthetic frames")
        func gaps(_ times: [Double]) -> [Double] { zip(times, times.dropFirst()).map { ($1 - $0) * 1_000 } }
        var video: [String: Any] = ["submitted": sourceTimes.count, "decoded": decoded.count,
                                    "sourceGapMs": Self.distribution(gaps(sourceTimes)),
                                    "decodedGapMs": Self.distribution(gaps(decoded))]
        if let first = decoded.first, let start = sourceTimes.first { video["firstFrameMs"] = (first - start) * 1_000 }
        #if targetEnvironment(simulator)
        let runtime = "simulator"
        #else
        let runtime = "device"
        #endif
        let report: [String: Any] = ["scope": "same-process iOS WebRTC; synthetic pixels; no Mac input injection",
                                     "runtime": runtime, "inputRoundTripMs": Self.distribution(roundTrips),
                                     "inputSent": sent.count, "inputAcknowledged": acknowledged.count, "video": video]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "iOS transport latency"; attachment.lifetime = .keepAlways; add(attachment)
        print("WAI_IOS_TRANSPORT_BENCH " + String(decoding: json, as: UTF8.self))
    }

    func testPacedScrollRoundTripAndDecodedResponseAt60And120Hz() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAI_IOS_TRANSPORT_BENCH"] == "1")
        let host = EchoVideoPeer(), viewer = ViewerTransport(ice: .local), frames = DecodedFrames(readCounter: true)
        defer { host.close(); viewer.close() }
        var track: RTCVideoTrack?
        viewer.onVideo = { track = $0; $0.add(frames) }
        defer { track?.remove(frames) }
        let machine = SessionMachine(surface: .init(id: "synthetic-scroll", width: 320, height: 180))
        var session = ViewerSession(); try session.accept(machine.state)
        var sent: [(message: WireMessage, data: Data, time: Double, group: String)] = []
        var received: [WireMessage] = [], echoed: [Int] = [], receivedTimes: [Int: Double] = [:]
        var roundTrips: [Int: Double] = [:], buffered: [UInt64] = [], lastReceived = 0
        var connected = false, failures: [String] = []
        let ready = expectation(description: "Scroll transport connected")
        viewer.onMessage = { data in
            if data == Data("ready".utf8) {
                if !connected { connected = true; ready.fulfill() }; return
            }
            guard let message = try? JSONDecoder().decode(WireMessage.self, from: data),
                  sent.indices.contains(message.sequence) else { XCTFail("Unexpected scroll echo"); return }
            XCTAssertEqual(data, sent[message.sequence].data)
            XCTAssertEqual(message.sequence, echoed.count, "Echoes must be ordered and exactly once")
            echoed.append(message.sequence)
            roundTrips[message.sequence] = (ProcessInfo.processInfo.systemUptime - sent[message.sequence].time) * 1_000
        }
        host.onInput = { data in
            guard let message = try? JSONDecoder().decode(WireMessage.self, from: data) else { XCTFail("Invalid wire input"); return }
            let now = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(message.sequence, received.count, "The receiver must observe every ordered operation")
            XCTAssertTrue(machine.handle(message, now: now).accepted, "The production protocol must accept phased scrolling")
            received.append(message); receivedTimes[message.sequence] = now
            lastReceived = message.sequence + 1 // Zero means no input received yet.
        }
        viewer.offer { result in
            switch result {
            case .failure(let error): failures.append("offer: \(error)")
            case .success(let offer):
                host.answer(offer) { result in
                    switch result {
                    case .failure(let error): failures.append("answer: \(error)")
                    case .success(let answer): viewer.answer(answer) { if let error = $0 { failures.append("remote: \(error)") } }
                    }
                }
            }
        }
        await fulfillment(of: [ready], timeout: 35)
        guard connected else { XCTFail("Local ICE did not connect: \(failures)"); return }
        var sourceFrames: [(time: Double, received: Int)] = []
        let video = Timer.connectionTimer(withTimeInterval: 1.0 / 30, repeats: true) { timer in
            do {
                let now = ProcessInfo.processInfo.systemUptime
                let counter = sourceFrames.count
                guard counter < 4096 else { failures.append("Visual frame counter exhausted"); timer.invalidate(); return }
                let pixels = try Self.counterPixels(counter)
                sourceFrames.append((now, lastReceived))
                host.push(pixels, at: now)
            } catch { failures.append("pixels: \(error)"); timer.invalidate() }
        }
        defer { video.invalidate() }
        try await Task.sleep(for: .milliseconds(300))
        func transmit(_ type: String, group: String, edit: (inout WireMessage) -> Void) {
            guard var message = session.make(type) else { XCTFail("The synthetic session must remain valid"); return }
            edit(&message)
            let data = try! JSONEncoder().encode(message)
            sent.append((message, data, ProcessInfo.processInfo.systemUptime, group))
            buffered.append(viewer.bufferedAmount)
            XCTAssertTrue(viewer.send(data), "An open transport must accept paced scroll input")
        }
        var expected: [String: CGPoint] = [:], tickTimes: [Int: [Double]] = [:], barriers: [[Int]] = []
        for hz in [60, 120] {
            var group = "\(hz)-drag"
            let stream = PhoneScrollStream { output in
                transmit("pointer", group: group) {
                    $0.action = "scroll"; $0.x = 0.5; $0.y = 0.5
                    $0.deltaX = Double(output.delta.x); $0.deltaY = Double(output.delta.y)
                    $0.scrollPhase = output.scrollPhase; $0.momentumPhase = output.momentumPhase
                }
            }
            stream.begin(at: ProcessInfo.processInfo.systemUptime)
            let played = expectation(description: "\(hz) Hz scroll completed")
            var ticks = 0
            let input = Timer.connectionTimer(withTimeInterval: 1 / Double(hz), repeats: true) { timer in
                let now = ProcessInfo.processInfo.systemUptime
                tickTimes[hz, default: []].append(now)
                // Two fractional samples per display tick exercise accumulation.
                stream.move(by: CGPoint(x: 0.125, y: -0.25), at: now)
                stream.move(by: CGPoint(x: 0.125, y: -0.25), at: now)
                stream.tick(at: now)
                ticks += 1
                if ticks == hz * 2 { timer.invalidate(); played.fulfill() }
            }
            await fulfillment(of: [played], timeout: 10); input.invalidate()
            expected[group] = CGPoint(x: Double(hz * 2) * 0.25, y: Double(hz * 2) * -0.5)
            try await Task.sleep(for: .milliseconds(100)) // Release after velocity expires: exact drag distance, no coast.
            stream.end(at: ProcessInfo.processInfo.systemUptime)
            XCTAssertFalse(stream.isActive)

            group = "\(hz)-cancel"
            stream.begin(at: ProcessInfo.processInfo.systemUptime)
            stream.move(by: CGPoint(x: 3, y: -5), at: ProcessInfo.processInfo.systemUptime)
            stream.tick(at: ProcessInfo.processInfo.systemUptime)
            stream.move(by: CGPoint(x: 91, y: -127), at: ProcessInfo.processInfo.systemUptime)
            stream.cancel() // These last pending samples must never be delivered.
            expected[group] = CGPoint(x: 3, y: -5)
            let cancelled = sent.count - 1
            transmit("key", group: "\(hz)-barrier") { $0.key = "ArrowDown"; $0.action = "down" }
            transmit("key", group: "\(hz)-barrier") { $0.key = "ArrowDown"; $0.action = "up" }
            let beforeIdleTick = sent.count
            stream.tick(at: ProcessInfo.processInfo.systemUptime + 1)
            XCTAssertEqual(sent.count, beforeIdleTick, "No cancelled movement may cross a key barrier")

            group = "\(hz)-fresh"
            stream.begin(at: ProcessInfo.processInfo.systemUptime)
            stream.move(by: CGPoint(x: 0.75, y: -1.5), at: ProcessInfo.processInfo.systemUptime)
            stream.tick(at: ProcessInfo.processInfo.systemUptime)
            barriers.append([cancelled, cancelled + 1, cancelled + 2, beforeIdleTick])
            expected[group] = CGPoint(x: 0.75, y: -1.5)
            try await Task.sleep(for: .milliseconds(100))
            stream.end(at: ProcessInfo.processInfo.systemUptime)
            XCTAssertFalse(stream.isActive)
        }
        XCTAssertLessThan(sent.count, 4096, "The visual counter must never wrap")
        func visibleReceipt() -> Int? {
            guard let counter = frames.counterSnapshot().last?.value, sourceFrames.indices.contains(counter) else { return nil }
            return sourceFrames[counter].received
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while (echoed.count != sent.count || visibleReceipt() != sent.count),
              ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(20)) }
        video.invalidate()
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(echoed, Array(sent.indices))
        XCTAssertEqual(received.map(\.sequence), Array(sent.indices))
        var distances: [[String: Any]] = []
        for (group, expectedDelta) in expected.sorted(by: { $0.key < $1.key }) {
            let messages = received.filter { sent.indices.contains($0.sequence) && sent[$0.sequence].group == group }
            let x = messages.reduce(0) { $0 + ($1.deltaX ?? 0) }, y = messages.reduce(0) { $0 + ($1.deltaY ?? 0) }
            XCTAssertEqual(x, Double(expectedDelta.x), accuracy: 0.000001, group)
            XCTAssertEqual(y, Double(expectedDelta.y), accuracy: 0.000001, group)
            XCTAssertEqual(messages.filter { $0.scrollPhase == "began" }.count, 1, group)
            let terminal = group.hasSuffix("cancel") ? "cancelled" : "ended"
            XCTAssertEqual(messages.last?.scrollPhase, terminal, group)
            XCTAssertEqual(messages.filter { $0.scrollPhase == terminal }.count, 1, group)
            XCTAssertTrue(messages.allSatisfy { $0.momentumPhase == nil }, "Idle release/cancel must not add momentum")
            distances.append(["gesture": group, "expectedX": expectedDelta.x, "expectedY": expectedDelta.y,
                              "receivedX": x, "receivedY": y, "messages": messages.count])
        }
        for barrier in barriers where received.count > barrier[3] {
            XCTAssertEqual(received[barrier[0]].scrollPhase, "cancelled")
            XCTAssertEqual(received[barrier[1]].type, "key"); XCTAssertEqual(received[barrier[1]].action, "down")
            XCTAssertEqual(received[barrier[2]].type, "key"); XCTAssertEqual(received[barrier[2]].action, "up")
            XCTAssertEqual(received[barrier[3]].scrollPhase, "began")
        }
        let decoded = frames.snapshot(), counters = frames.counterSnapshot()
        XCTAssertGreaterThan(counters.count, 2, "Read the watermark from actual decoded pixels")
        XCTAssertEqual(visibleReceipt(), sent.count)
        XCTAssertTrue(zip(counters, counters.dropFirst()).allSatisfy { $0.value <= $1.value }, "Decoded frame counters must stay ordered")
        var sourceToDecoded: [Double] = []
        for frame in counters {
            guard sourceFrames.indices.contains(frame.value) else { XCTFail("Unknown decoded frame counter"); continue }
            let source = sourceFrames[frame.value]
            XCTAssertGreaterThanOrEqual(frame.time, source.time, "A decoded frame cannot precede its source pixels")
            sourceToDecoded.append((frame.time - source.time) * 1_000)
            if source.received > 0 {
                let receivedAt = try XCTUnwrap(receivedTimes[source.received - 1], "The frame watermark must refer to received input")
                XCTAssertGreaterThanOrEqual(source.time, receivedAt, "A response frame cannot precede peer receipt")
            }
        }
        var visible: [Int: Double] = [:]
        for item in sent {
            // Many inputs can be acknowledged by one video frame. Its unique
            // pixel counter identifies the exact source time and receipt state.
            if let frame = counters.first(where: {
                sourceFrames.indices.contains($0.value) && sourceFrames[$0.value].received > item.message.sequence
            }) {
                visible[item.message.sequence] = (frame.time - item.time) * 1_000
            }
        }
        XCTAssertEqual(visible.count, sent.count)
        let measured = expectation(description: "Negotiated video codec measured")
        var codec: String?
        host.videoCodec { codec = $0; measured.fulfill() }
        await fulfillment(of: [measured], timeout: 3)
        XCTAssertEqual(codec?.lowercased(), "video/h264", "Validate the visual watermark through the preferred production codec")
        func gaps(_ times: [Double]) -> [Double] { zip(times, times.dropFirst()).map { ($1 - $0) * 1_000 } }
        let runs: [[String: Any]] = [60, 120].map { hz in
            let operations = sent.filter { $0.group.hasPrefix("\(hz)-") }
            let movement = operations.filter { $0.group == "\(hz)-drag" && ($0.message.deltaX != 0 || $0.message.deltaY != 0) }
            return ["requestedTickHz": hz, "samplesPerTick": 2, "ticks": tickTimes[hz]?.count ?? 0,
                    "emittedMessages": operations.count, "dragEmittedGapMs": Self.distribution(gaps(movement.map(\.time))),
                    "actualTickGapMs": Self.distribution(gaps(tickTimes[hz] ?? [])),
                    "inputRoundTripMs": Self.distribution(operations.compactMap { roundTrips[$0.message.sequence] }),
                    "inputToDecodedResponseMs": Self.distribution(operations.compactMap { visible[$0.message.sequence] }),
                    "inputToPeerReceiptMs": Self.distribution(operations.compactMap { item in receivedTimes[item.message.sequence].map { ($0 - item.time) * 1_000 } })]
        }
        #if targetEnvironment(simulator)
        let runtime = "simulator"
        #else
        let runtime = "device"
        #endif
        let report: [String: Any] = ["scope": "same-process iOS WebRTC; synthetic visual frame ID mapped to peer receipt; no Mac input delivery or physical touch latency",
            "runtime": runtime, "runs": runs, "distanceChecks": distances, "sent": sent.count, "received": received.count,
            "echoed": echoed.count, "maxBufferedBytes": buffered.max() ?? 0, "barrierSequences": barriers,
            "video": ["requestedFPS": 30, "codec": codec ?? "unknown", "submitted": sourceFrames.count,
                      "decoded": decoded.count, "validCounterFrames": counters.count,
                      "sourceToDecodedMs": Self.distribution(sourceToDecoded),
                      "sourceGapMs": Self.distribution(gaps(sourceFrames.map(\.time))), "decodedGapMs": Self.distribution(gaps(decoded))]]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = "iOS paced scroll transport"; attachment.lifetime = .keepAlways; add(attachment)
        print("WAI_IOS_SCROLL_BENCH " + String(decoding: json, as: UTF8.self))
    }

    private static func distribution(_ samples: [Double]) -> [String: Any] {
        guard !samples.isEmpty else { return ["count": 0] }
        let values = samples.sorted()
        return ["count": values.count, "p50": values[Int(Double(values.count - 1) * 0.5)],
                "p95": values[Int(Double(values.count - 1) * 0.95)], "max": values.last!]
    }
    private static func pixels(luma: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, plane))
            memset(base, Int32(plane == 0 ? luma : 128),
                   CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane))
        }
        return pixels
    }
    /// Twelve data bits plus black/white markers, each mirrored below with the
    /// inverse luma. Large flat tiles survive the real video encoder/decoder.
    private static func counterPixels(_ counter: Int) throws -> CVPixelBuffer {
        precondition((0..<4096).contains(counter))
        let pixels = try pixels(luma: 32)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(pixels, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, 0))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        for column in 0..<14 {
            let high = column == 1 || column >= 2 && counter & (1 << (column - 2)) != 0
            let left = column * width / 14, right = (column + 1) * width / 14
            for y in 0..<height {
                let luma: Int32 = (y < height / 2) == high ? 210 : 32
                memset(base.advanced(by: y * stride + left), luma, right - left)
            }
        }
        return pixels
    }
}

/// A test-only answering peer: no host permissions, state machine or desktop input.
private final class EchoVideoPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    var onInput: ((Data) -> Void)?
    private let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    private var peer: RTCPeerConnection!
    private var source: RTCVideoSource!
    private var capturer: RTCVideoCapturer!
    private var channel: RTCDataChannel?
    private let gathering = ICEGatheringDeadline(ice: .local)
    private var completion: ((Result<String, Error>) -> Void)?
    private var greeted = false, closed = false
    override init() {
        super.init()
        let configuration = RTCConfiguration(); configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle; configuration.rtcpMuxPolicy = .require
        peer = factory.peerConnection(with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        source = factory.videoSource(forScreenCast: true); capturer = RTCVideoCapturer(delegate: source)
        _ = peer.add(factory.videoTrack(with: source, trackId: "synthetic-screen"), streamIds: ["test"])
    }
    func push(_ pixels: CVPixelBuffer, at time: Double) {
        source.capturer(capturer, didCapture: RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels),
                                                         rotation: ._0, timeStampNs: Int64(time * 1e9)))
    }
    func videoCodec(_ completion: @escaping (String?) -> Void) {
        peer.statistics { report in
            let sender = report.statistics.values.first { $0.type == "outbound-rtp" && $0.values["kind"] as? String == "video" }
            let codec = (sender?.values["codecId"] as? String).flatMap { report.statistics[$0]?.values["mimeType"] as? String }
            DispatchQueue.main.async { completion(codec) }
        }
    }
    func answer(_ offer: String, completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        gathering.start(description: { [weak self] in self?.peer.localDescription?.sdp }) { [weak self] in self?.finish($0) }
        peer.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer)) { [weak self] error in
            guard let self else { return }
            if let error { DispatchQueue.main.async { self.finish(.failure(error)) }; return }
            self.peer.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                guard let answer else { if let error { DispatchQueue.main.async { self.finish(.failure(error)) } }; return }
                self.peer.setLocalDescription(answer) { error in
                    DispatchQueue.main.async {
                        if let error { self.finish(.failure(error)) }
                        else if self.peer.iceGatheringState == .complete { self.gathered() }
                    }
                }
            }
        }
    }
    private func gathered() { if let sdp = peer.localDescription?.sdp { finish(ICEGatheringDeadline.result(for: sdp)) } }
    private func finish(_ result: Result<String, Error>) {
        guard !closed else { return }; gathering.cancel()
        let callback = completion; completion = nil; callback?(result)
    }
    private func greet() {
        guard !closed, !greeted, let channel, channel.readyState == .open else { return }
        greeted = channel.sendData(RTCDataBuffer(data: Data("ready".utf8), isBinary: false))
    }
    func close() { closed = true; gathering.cancel(); completion = nil; channel?.delegate = nil; channel?.close(); peer.delegate = nil; peer.close() }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { DispatchQueue.main.async { [weak self] in self?.gathered() } }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, self.channel == nil, dataChannel.label == "interaction" else { dataChannel.close(); return }
            self.channel = dataChannel; dataChannel.delegate = self; self.greet()
        }
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in self?.greet() }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            self.onInput?(buffer.data)
            XCTAssertTrue(dataChannel.sendData(buffer), "The peer must echo accepted input")
        }
    }
}

private final class DecodedFrames: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private let readCounter: Bool
    private var times: [Double] = []
    private var counters: [(value: Int, time: Double)] = []
    init(readCounter: Bool = false) { self.readCounter = readCounter; super.init() }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, frame.width > 0, frame.height > 0 else { return }
        let time = ProcessInfo.processInfo.systemUptime
        let counter = readCounter ? Self.counter(frame) : nil
        lock.lock(); times.append(time)
        if let counter { counters.append((counter, time)) }
        lock.unlock()
    }
    func snapshot() -> [Double] { lock.lock(); defer { lock.unlock() }; return times }
    func counterSnapshot() -> [(value: Int, time: Double)] { lock.lock(); defer { lock.unlock() }; return counters }
    private static func counter(_ frame: RTCVideoFrame) -> Int? {
        let pixels = frame.buffer.toI420(), width = Int(frame.width), height = Int(frame.height)
        guard width >= 56, height >= 16 else { return nil }
        let stride = Int(pixels.strideY)
        func luma(_ x: Int, _ y: Int) -> Double {
            var total = 0
            for dy in -1...1 { for dx in -1...1 { total += Int(pixels.dataY[(y + dy) * stride + x + dx]) } }
            return Double(total) / 9
        }
        var value = 0
        for column in 0..<14 {
            let x = (column * 2 + 1) * width / 28
            let top = luma(x, height / 4), bottom = luma(x, height * 3 / 4)
            guard abs(top - bottom) > 80 else { return nil }
            let high = top > bottom
            if column < 2 { guard high == (column == 1) else { return nil } }
            else if high { value |= 1 << (column - 2) }
        }
        return value
    }
}
