import AppKit
import WebRTC
import XCTest
@testable import WAIRemote

final class AgentFrameCaptureTests: XCTestCase {
    static func frame(luma: UInt8, rotation: RTCVideoRotation = ._0, cornerPattern: Bool = false) throws -> RTCVideoFrame {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 8, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<8 { for x in 0..<16 {
            let index = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            bytes[index] = luma; bytes[index + 1] = luma; bytes[index + 2] = luma; bytes[index + 3] = 255
            if cornerPattern {
                // Top left red, top right green, bottom left blue, bottom right yellow.
                bytes[index] = y >= 4 && x < 8 ? 255 : 0
                bytes[index + 1] = x >= 8 ? 255 : 0
                bytes[index + 2] = x < 8 && y < 4 || x >= 8 && y >= 4 ? 255 : 0
            }
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: rotation, timeStampNs: 1)
    }
    func testOnlyNewestFrameIsRetainedAndOldTrackCannotRepopulateAfterDetach() throws {
        let capture = AgentFrameCapture(), old = capture.beginStream()
        old.renderFrame(try Self.frame(luma: 32))
        let first = try XCTUnwrap(capture.latest())
        old.renderFrame(try Self.frame(luma: 210))
        let second = try XCTUnwrap(capture.latest())
        XCTAssertGreaterThan(second.sequence, first.sequence)
        let png = try second.png()
        let image = try XCTUnwrap(NSBitmapImageRep(data: png.data))
        XCTAssertEqual(image.pixelsWide, 16); XCTAssertEqual(image.pixelsHigh, 8)
        XCTAssertGreaterThan(try XCTUnwrap(image.colorAt(x: 4, y: 4)).redComponent, 0.7)
        capture.endStream()
        old.renderFrame(try Self.frame(luma: 32))
        XCTAssertNil(capture.latest())
        let fresh = capture.beginStream()
        old.renderFrame(try Self.frame(luma: 32))
        XCTAssertNil(capture.latest())
        fresh.renderFrame(try Self.frame(luma: 100, rotation: ._90))
        let rotated = try XCTUnwrap(capture.latest()).png()
        XCTAssertEqual(rotated.width, 8); XCTAssertEqual(rotated.height, 16)
    }
    func testPNGKeepsTopLeftCoordinatesAndClockwiseRotation() throws {
        let capture = AgentFrameCapture(), renderer = capture.beginStream()
        func channels(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> [Int] {
            let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            // Classify the four corner markers without depending on a display ICC profile.
            return [color.redComponent, color.greenComponent, color.blueComponent].map { $0 > 0.5 ? 255 : 0 }
        }
        renderer.renderFrame(try Self.frame(luma: 0, cornerPattern: true))
        var image = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(capture.latest()).png().data))
        XCTAssertEqual(try channels(image, 2, 2), [255, 0, 0])
        XCTAssertEqual(try channels(image, 13, 2), [0, 255, 0])
        XCTAssertEqual(try channels(image, 2, 6), [0, 0, 255])
        renderer.renderFrame(try Self.frame(luma: 0, rotation: ._90, cornerPattern: true))
        image = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(capture.latest()).png().data))
        XCTAssertEqual(try channels(image, 2, 2), [0, 0, 255])
        XCTAssertEqual(try channels(image, 6, 2), [255, 0, 0])
        XCTAssertEqual(try channels(image, 2, 13), [255, 255, 0])
    }
}
