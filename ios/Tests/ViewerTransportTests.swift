import XCTest
import RemoteCore
@testable import WAI_Remote

@MainActor
final class ViewerTransportTests: XCTestCase {
    func testCompletedGatheringRejectsAnOfferWithoutAUsableRoute() throws {
        // No servers plus relay-only completes immediately with no candidates.
        // This exercises WebRTC's completed callback, before the 12-second deadline.
        let ice = try JSONDecoder().decode(ICEConfiguration.self, from: Data(
            #"{"iceServers":[],"iceTransportPolicy":"relay","expiresAt":0}"#.utf8))
        let viewer = ViewerTransport(ice: ice)
        defer { viewer.close() }
        let finished = expectation(description: "Completed gathering reports the missing route")
        viewer.offer { result in
            if case .success = result { XCTFail("An SDP without a route cannot connect") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }
}
