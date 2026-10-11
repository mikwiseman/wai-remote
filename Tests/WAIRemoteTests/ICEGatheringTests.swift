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
