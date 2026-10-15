import CoreMedia
import CoreVideo
import XCTest
@testable import WAIRemote

final class CaptureConfigurationTests: XCTestCase {
    func testWindowCaptureKeepsRetinaDetailWhenTheFilterReportsNominalScale() {
        // The Mini's desktop-independent filter reported 1x on its 2x display.
        let config = VideoCapture.windowConfiguration(size: CGSize(width: 680, height: 608), pixelScale: 1)
        XCTAssertEqual(config.width, 1360)
        XCTAssertEqual(config.height, 1216)
        XCTAssertEqual(config.captureResolution, .best)
        XCTAssertFalse(config.showsCursor)
        XCTAssertTrue(config.ignoreShadowsSingleWindow)
    }
    func testRetinaTextKeepsItsNativePixels() {
        let config = VideoCapture.configuration(size: CGSize(width: 1920, height: 1080), pixelScale: 2)
        XCTAssertEqual(config.width, 3840)
        XCTAssertEqual(config.height, 2160)
    }
    func testNonRetinaCaptureIsNotUpscaled() {
        let config = VideoCapture.configuration(size: CGSize(width: 1920, height: 1080), pixelScale: 1)
        XCTAssertEqual(config.width, 1920)
        XCTAssertEqual(config.height, 1080)
    }
    func testCaptureFeedsTheEncoderAtSixtyFramesWithoutRGBConversion() {
        let config = VideoCapture.configuration(size: CGSize(width: 1920, height: 1080), pixelScale: 1)
        XCTAssertEqual(config.minimumFrameInterval.seconds, 1.0 / 60, accuracy: 0.00001)
        XCTAssertEqual(config.pixelFormat, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(config.queueDepth, 8, "Keep the surface pool within Apple's limit while asynchronous hardware encoding retains frames.")
    }
}
