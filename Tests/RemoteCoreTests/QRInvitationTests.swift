import XCTest
@testable import RemoteCore

final class QRInvitationTests: XCTestCase {
    private func invitation() -> String {
        let host = DeviceIdentity()
        return "https://waiwai.is/remote/connect/#host=\(host.id)&key=\(host.publicKey)&secret=\(Data(repeating: 4, count: 32).base64URL)"
    }

    func testCameraAppLinkKeepsHostAndPairingProof() throws {
        let text = invitation()
        let original = try RemoteInvite(text)
        let cameraLink = try XCTUnwrap(RemoteInvite.phoneURL(for: text))
        let scanned = try RemoteInvite(cameraLink.absoluteString)
        XCTAssertEqual(scanned.hostID, original.hostID)
        XCTAssertEqual(scanned.publicKey, original.publicKey)
        XCTAssertEqual(scanned.secret, original.secret)
        XCTAssertEqual(scanned.signalingURL, original.signalingURL)
        XCTAssertNil(try RemoteInvite(scanned.savedURL.absoluteString).secret)
    }

    func testQRRejectsAmbiguousOrUnrelatedAppLinks() throws {
        let link = try XCTUnwrap(RemoteInvite.phoneURL(for: invitation()))
        XCTAssertThrowsError(try RemoteInvite(link.absoluteString + "&invite=bad"))
        XCTAssertThrowsError(try RemoteInvite(link.absoluteString + "&extra=1"))
        XCTAssertThrowsError(try RemoteInvite(link.absoluteString.replacingOccurrences(of: "wai-remote://connect", with: "wai-remote://other")))
        XCTAssertThrowsError(try RemoteInvite(link.absoluteString.replacingOccurrences(of: "wai-remote://connect", with: "wai-remote://user@connect")))
        XCTAssertThrowsError(try RemoteInvite("https://example.com/"))
        XCTAssertThrowsError(try RemoteInvite("javascript:alert(1)"))
    }
}
