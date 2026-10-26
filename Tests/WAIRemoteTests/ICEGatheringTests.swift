import AppKit
import RemoteCore
import XCTest
import WebRTC
@testable import WAIRemote

@MainActor
final class ICEGatheringTests: XCTestCase {
    private func unreachableRelay() throws -> ICEConfiguration {
        try JSONDecoder().decode(ICEConfiguration.self, from: Data(#"{"iceServers":[{"urls":["turn:127.0.0.1:9?transport=tcp"],"username":"test","credential":"test"}],"iceTransportPolicy":"relay","expiresAt":0}"#.utf8))
    }
    func testMissingRelayCannotProduceAnUnusableOffer() throws {
        _ = NSApplication.shared
        let viewer = ViewerTransport(ice: try unreachableRelay())
        defer { viewer.close() }
        let rejected = expectation(description: "No route is reported as a connection failure")
        viewer.offer { result in
            if case .success = result { XCTFail("An offer without a usable relay must not start a connection") }
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 14)
    }
    func testMissingRelayCannotProduceAnUnusableAnswer() throws {
        _ = NSApplication.shared
        let factory = RTCPeerConnectionFactory()
        let host = PeerTransport(factory: factory, source: factory.videoSource(forScreenCast: true), ice: try unreachableRelay())
        let viewer = ViewerTransport(ice: .local)
        defer { host.close(); viewer.close() }
        let rejected = expectation(description: "Host without a route rejects the attempt")
        viewer.offer { offer in
            guard case .success(let sdp) = offer else { XCTFail("Local offer failed"); rejected.fulfill(); return }
            host.answer(offer: sdp) { result in
                if case .success = result { XCTFail("An answer without a usable relay must not start a connection") }
                rejected.fulfill()
            }
        }
        wait(for: [rejected], timeout: 14)
    }
    func testDirectRoutesSkipLoopbackAndTunnelsButKeepTheRelay() throws {
        let sdp = ["v=0", "m=application 9 UDP/DTLS/SCTP webrtc-datachannel",
            "a=candidate:1 1 udp 2122260223 192.168.1.66 50000 typ host generation 0",
            "a=candidate:2 1 udp 2122194687 127.0.0.1 50001 typ host generation 0",
            "a=candidate:3 1 udp 2122129151 172.19.0.1 50002 typ host generation 0",
            "a=candidate:4 1 udp 1686052607 212.80.205.91 50003 typ srflx raddr 172.19.0.1 rport 50002 generation 0",
            "a=candidate:5 1 udp 41885439 65.108.215.2 49200 typ relay raddr 172.19.0.1 rport 50002 generation 0",
            "a=candidate:6 1 tcp 1518280447 ::1 9 typ host tcptype active generation 0",
            "a=end-of-candidates", ""].joined(separator: "\r\n")
        let kept = try ICEGatheringDeadline.result(for: sdp, tunnels: ["172.19.0.1"]).get()
        XCTAssertEqual(kept.components(separatedBy: "\r\n").filter { $0.hasPrefix("a=candidate:") }.map { $0.prefix(13) },
                       ["a=candidate:1", "a=candidate:5"])
        XCTAssertTrue(kept.hasPrefix("v=0\r\n") && kept.hasSuffix("a=end-of-candidates\r\n"))
        let unusable = ["v=0", "a=candidate:2 1 udp 2122194687 127.0.0.1 50001 typ host generation 0", ""].joined(separator: "\r\n")
        XCTAssertThrowsError(try ICEGatheringDeadline.result(for: unusable, tunnels: []).get())
    }
    func testAnUnresponsiveInterfaceDoesNotDiscardAvailableCandidates() throws {
        _ = NSApplication.shared
        // TEST-NET never answers STUN. Local candidates are still useful on a LAN.
        let ice = try JSONDecoder().decode(ICEConfiguration.self, from: Data(#"{"iceServers":[{"urls":["stun:192.0.2.1:3478"],"username":"test","credential":"test"}],"iceTransportPolicy":"all","expiresAt":0}"#.utf8))
        let viewer = ViewerTransport(ice: ice)
        defer { viewer.close() }
        let ready = expectation(description: "Offer contains the candidates already gathered")
        viewer.offer { result in
            switch result {
            case .success(let sdp): XCTAssertTrue(sdp.contains("a=candidate:"))
            case .failure(let error): XCTFail("Discarded available routes: \(error)")
            }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 4)
    }
}
