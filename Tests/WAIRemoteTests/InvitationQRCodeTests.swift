import XCTest
import RemoteCore
@testable import WAIRemote

final class InvitationQRCodeTests: XCTestCase {
    func testDisplayedCodeCanBeReadBackWithPairingSecretIntact() throws {
        let identity = DeviceIdentity()
        let text = "https://waiwai.is/remote/connect/#host=\(identity.id)&key=\(identity.publicKey)&secret=\(Data(repeating: 6, count: 32).base64URL)"
        let image = try XCTUnwrap(InvitationQRCode.image(for: text))
        let read = try XCTUnwrap(InvitationQRCode.invitation(in: image))
        XCTAssertEqual(read, text)
        XCTAssertEqual(try RemoteInvite(read).secret, try RemoteInvite(text).secret)
        XCTAssertNil(InvitationQRCode.image(for: "https://example.com"))
    }
}
