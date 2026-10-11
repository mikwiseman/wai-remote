import XCTest
@testable import RemoteCore

final class SavedComputerTests: XCTestCase {
    func testRememberingComputerNeverKeepsInvitationSecret() throws {
        let identity = DeviceIdentity()
        let invite = "https://remote.waiwai.is/#host=\(identity.id)&key=\(identity.publicKey)&secret=\(Data(repeating: 1, count: 32).base64URL)"
        let computer = try SavedComputer(invitation: invite, name: "  Mac mini  ")
        XCTAssertEqual(computer.id, identity.id)
        XCTAssertEqual(computer.name, "Mac mini")
        XCTAssertNil(try RemoteInvite(computer.invitation).secret)
        XCTAssertFalse(String(data: try JSONEncoder().encode(computer), encoding: .utf8)!.contains("secret"))
        XCTAssertThrowsError(try SavedComputer(invitation: "https://example.com", name: "Mac"))
    }

    func testAspectFitInputExcludesLetterboxAndKeepsCorners() {
        let fit = RemoteViewport(width: 1000, height: 800, sourceWidth: 1920, sourceHeight: 1080)
        XCTAssertEqual(fit.height, 562.5)
        XCTAssertNil(fit.point(x: 100, y: 50))
        XCTAssertEqual(fit.point(x: 0, y: 118.75), InkPoint(0, 0))
        XCTAssertEqual(fit.point(x: 1000, y: 681.25), InkPoint(1, 1))
        XCTAssertEqual(fit.point(x: 500, y: 400), InkPoint(0.5, 0.5))
        XCTAssertNil(RemoteViewport(width: 0, height: 0, sourceWidth: 0, sourceHeight: 0).point(x: 0, y: 0))
    }
}
