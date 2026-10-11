import WebRTC
import XCTest
import RemoteCore
import CoreVideo
@testable import WAIRemote

@MainActor
final class ScreenVideoPolicyTests: XCTestCase {
    func testNativeH264CanEncodeARetinaScreenFrame() throws {
        let factory = ScreenVideoEncoderFactory()
        let codec = try XCTUnwrap(factory.supportedCodecs().first { $0.name == "H264" })
        let encoder = try XCTUnwrap(factory.createEncoder(codec))
        defer { _ = encoder.release() }
        let settings = RTCVideoEncoderSettings()
        settings.name = "H264"; settings.width = 3840; settings.height = 2160
        settings.startBitrate = 4000; settings.maxBitrate = 32000; settings.maxFramerate = 60
        settings.mode = .screensharing
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 4), 0)
        let encoded = expectation(description: "Hardware encoded 4K frame")
        encoder.setCallback { frame, _ in
            XCTAssertEqual(frame.encodedWidth, 3840)
            XCTAssertEqual(frame.encodedHeight, 2160)
            encoded.fulfill(); return true
        }
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 3840, 2160, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: 1_000_000_000)
        XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [3]), 0)
        wait(for: [encoded], timeout: 3)
    }
    func testHostAnswerKeepsHardwareH264First() {
        let factory = RTCPeerConnectionFactory(encoderFactory: ScreenVideoEncoderFactory(), decoderFactory: ScreenVideoDecoderFactory())
        let host = PeerTransport(factory: factory, source: factory.videoSource(forScreenCast: true), ice: .local)
        let viewer = ViewerTransport(ice: .local)
        defer { host.close(); viewer.close() }
        let ready = expectation(description: "H264 answer")
        viewer.offer { offer in
            guard case .success(let sdp) = offer else { XCTFail("Offer failed"); ready.fulfill(); return }
            host.answer(offer: sdp) { result in
                guard case .success(let answer) = result else { XCTFail("Answer failed"); ready.fulfill(); return }
                let lines = answer.components(separatedBy: .newlines)
                let payload = lines.first { $0.hasPrefix("m=video ") }?.split(separator: " ").dropFirst(3).first
                XCTAssertTrue(lines.contains("a=rtpmap:\(payload ?? "") H264/90000"), "Host must retain the hardware codec after matching the remote transceiver.")
                ready.fulfill()
            }
        }
        wait(for: [ready], timeout: 7)
    }
    func testOfferActuallyPrefersHardwareH264() throws {
        let factory = RTCPeerConnectionFactory(encoderFactory: ScreenVideoEncoderFactory(), decoderFactory: ScreenVideoDecoderFactory())
        let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
        let pc = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil)!
        defer { pc.close() }
        let direction = RTCRtpTransceiverInit(); direction.direction = .recvOnly
        let video = try XCTUnwrap(pc.addTransceiver(of: .video, init: direction))
        video.setCodecPreferences(ScreenVideoPolicy.codecs(factory.rtpReceiverCapabilities(forKind: "video").codecs))
        let ready = expectation(description: "SDP offer")
        pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, error in
            XCTAssertNil(error)
            let lines = (sdp?.sdp ?? "").components(separatedBy: .newlines)
            let payload = lines.first { $0.hasPrefix("m=video ") }?.split(separator: " ").dropFirst(3).first
            XCTAssertNotNil(payload)
            XCTAssertTrue(lines.contains("a=rtpmap:\(payload ?? "") H264/90000"), "Hardware preference must be reflected in the actual negotiated offer.")
            ready.fulfill()
        }
        wait(for: [ready], timeout: 3)
    }
    func testHardwareCodecIsPreferredWithoutRemovingCompatibility() {
        let factory = RTCPeerConnectionFactory(encoderFactory: ScreenVideoEncoderFactory(), decoderFactory: ScreenVideoDecoderFactory())
        let supported = factory.rtpReceiverCapabilities(forKind: "video").codecs
        let codecs = ScreenVideoPolicy.codecs(supported)
        XCTAssertEqual(codecs.first?.name, "H264")
        XCTAssertEqual(codecs.count, supported.count)
        XCTAssertTrue(codecs.contains { $0.name == "VP8" })
    }
    func testSenderPreservesTextAndAllowsSixtyFPSWithinABoundedBitrate() throws {
        let factory = RTCPeerConnectionFactory()
        let pc = factory.peerConnection(with: RTCConfiguration(), constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil)!
        defer { pc.close() }
        let sender = try XCTUnwrap(pc.add(factory.videoTrack(with: factory.videoSource(forScreenCast: true), trackId: "screen"), streamIds: ["screen"]))
        ScreenVideoPolicy.configure(sender)
        let parameters = sender.parameters
        XCTAssertEqual(parameters.degradationPreference?.intValue, RTCDegradationPreference.maintainResolution.rawValue)
        XCTAssertEqual(parameters.encodings.first?.maxFramerate?.intValue, 60)
        XCTAssertEqual(parameters.encodings.first?.maxBitrateBps?.intValue, 32_000_000)
    }
}
