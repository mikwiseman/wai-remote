import XCTest
import CoreImage
import CoreVideo
import RemoteCore
#if os(macOS)
@testable import WAIRemote
#else
@testable import WAI_Remote
#endif

final class InvitationQRCodeTests: XCTestCase {
    func testCameraFrameCanBeReadWithoutMetadataSupport() throws {
        let identity = DeviceIdentity()
        let text = "https://waiwai.is/remote/connect/#host=\(identity.id)&key=\(identity.publicKey)&secret=\(Data(repeating: 7, count: 32).base64URL)"
        let image = try XCTUnwrap(InvitationQRCode.image(for: text))
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
            kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CIContext().render(CIImage(cgImage: image), to: frame)
        XCTAssertEqual(try InvitationQRCode.invitation(in: frame), text)
        CIContext().render(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0,
            width: image.width, height: image.height)), to: frame)
        XCTAssertNil(try InvitationQRCode.invitation(in: frame))
    }

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
