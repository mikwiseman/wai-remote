import AppKit
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class ICEGatheringTests: XCTestCase {
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
