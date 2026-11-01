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
        let replies = expectation(description: "Every input payload returns unchanged")
        replies.expectedFulfillmentCount = 24
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
            replies.fulfill()
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
        await fulfillment(of: [ready], timeout: 15)
        guard connected else { XCTFail("Local ICE did not connect: \(failures)"); return }

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
}

/// A test-only answering peer: no host permissions, state machine or desktop input.
private final class EchoVideoPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
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
            XCTAssertTrue(dataChannel.sendData(buffer), "The peer must echo accepted input")
        }
    }
}

private final class DecodedFrames: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var times: [Double] = []
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, frame.width > 0, frame.height > 0 else { return }
        let time = ProcessInfo.processInfo.systemUptime
        lock.lock(); times.append(time); lock.unlock()
    }
    func snapshot() -> [Double] { lock.lock(); defer { lock.unlock() }; return times }
}
