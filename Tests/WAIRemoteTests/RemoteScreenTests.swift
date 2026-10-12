import AppKit
import WebRTC
import XCTest
import RemoteCore
import Combine
import AVFoundation
@testable import WAIRemote

@MainActor
final class RemoteScreenTests: XCTestCase {
    func testDecodedVideoUsesTheNativePixelBufferDisplay() throws {
        let model = MacViewerModel(identity: DeviceIdentity())
        let factory = RTCPeerConnectionFactory()
        model.track = factory.videoTrack(with: factory.videoSource(), trackId: "screen")
        let screen = RemoteScreenView(model: model)
        screen.update()

        XCTAssertTrue(screen.subviews.contains { $0.layer is AVSampleBufferDisplayLayer },
                      "4K hardware-decoded buffers must reach native display without I420 conversion and three CPU texture uploads.")
    }

    func testRemoteViewOffersTheStandardSelectAllMenuAction() {
        let screen = RemoteScreenView(model: MacViewerModel(identity: DeviceIdentity()))
        XCTAssertTrue(screen.responds(to: #selector(NSText.selectAll(_:))),
                      "Edit > Select All must reach the remote field like Copy, Cut and Paste.")
    }

    func testHardwareFrameReusesPixelsAndDisplaysImmediately() throws {
        let pixel = try pixels()
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixel), rotation: ._0, timeStampNs: 123456789)
        let sample = try XCTUnwrap(VideoSampleBuffer.make(frame))
        XCTAssertTrue(CMSampleBufferGetImageBuffer(sample) === pixel, "The decoder's IOSurface must not be copied.")
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: 123456789, timescale: 1_000_000_000))
        let properties = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]])
        XCTAssertEqual(properties.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool, true)
    }

    func testSoftwareDecodedFramePreservesAllThreeColorPlanes() throws {
        let planar = RTCCVPixelBuffer(pixelBuffer: try pixels()).toI420()
        let frame = RTCVideoFrame(buffer: planar, rotation: ._0, timeStampNs: 1)
        let sample = try XCTUnwrap(VideoSampleBuffer.make(frame))
        let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        XCTAssertEqual(CVPixelBufferGetWidth(pixel), 8)
        XCTAssertEqual(CVPixelBufferGetHeight(pixel), 6)
        let received = RTCCVPixelBuffer(pixelBuffer: pixel).toI420()
        for row in 0..<6 {
            for column in 0..<8 { XCTAssertEqual(received.dataY[row * Int(received.strideY) + column], 72) }
        }
        for row in 0..<3 {
            for column in 0..<4 {
                XCTAssertEqual(received.dataU[row * Int(received.strideU) + column], 96)
                XCTAssertEqual(received.dataV[row * Int(received.strideV) + column], 180)
            }
        }
    }

    private func pixels() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 6, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let pixel = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        memset(CVPixelBufferGetBaseAddressOfPlane(pixel, 0), 72, CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) * 6)
        let uv = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, 1)?.assumingMemoryBound(to: UInt8.self))
        for row in 0..<3 {
            for column in 0..<4 {
                uv[row * CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) + column * 2] = 96
                uv[row * CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) + column * 2 + 1] = 180
            }
        }
        return pixel
    }

    func testViewerOpensAtReadableSizeInsteadOfItsMinimum() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.viewer = MacViewerModel(identity: DeviceIdentity())
        delegate.viewer.connecting = true

        delegate.connect()
        let window = try XCTUnwrap(delegate.viewerWindow)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()

        // AppKit constrains large windows to the available display (including
        // the small CI display). A plain window supplies that native size
        // without allowing the hosting controller to shrink it to its minimum.
        let reference = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                                 styleMask: window.styleMask, backing: .buffered, defer: false)
        reference.isReleasedWhenClosed = false
        defer { reference.close() }
        reference.center()
        reference.orderFront(nil)
        let expected = try XCTUnwrap(reference.contentView).bounds.size
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.bounds.width, expected.width, accuracy: 1)
        XCTAssertEqual(content.bounds.height, expected.height, accuracy: 1)
    }

    func testHeartbeatDoesNotInvalidateTheVideoView() {
        let model = MacViewerModel(identity: DeviceIdentity())
        var invalidations = 0
        let observation = model.objectWillChange.sink { invalidations += 1 }
        defer { observation.cancel() }

        // A mutating protocol call must not publish UI changes, including
        // when a heartbeat races with disconnect and no session remains.
        XCTAssertFalse(model.send("heartbeat"))
        XCTAssertEqual(invalidations, 0)
    }

    func testUnchangedScreenDoesNotScheduleAnotherVideoLayout() {
        let model = MacViewerModel(identity: DeviceIdentity())
        let factory = RTCPeerConnectionFactory()
        model.track = factory.videoTrack(with: factory.videoSource(), trackId: "screen")
        let screen = RemoteScreenView(model: model)
        screen.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        screen.update(); screen.layoutSubtreeIfNeeded()
        XCTAssertFalse(screen.needsLayout)

        screen.update()

        XCTAssertFalse(screen.needsLayout)
    }

    func testDisconnectRemovesThePreviousVideoSurface() throws {
        let model = MacViewerModel(identity: DeviceIdentity())
        let factory = RTCPeerConnectionFactory()
        model.track = factory.videoTrack(with: factory.videoSource(), trackId: "previous")
        let screen = RemoteScreenView(model: model)
        screen.update()
        let previous = try XCTUnwrap(screen.subviews.first { $0 is DecodedVideoView })

        model.disconnect()
        screen.update()

        XCTAssertFalse(screen.subviews.contains { $0 === previous }, "The disconnected Mac's last frame must leave the view hierarchy.")
        XCTAssertFalse(screen.subviews.contains { $0 is DecodedVideoView })
    }

    func testAnotherTrackGetsAFreshVideoSurface() throws {
        let model = MacViewerModel(identity: DeviceIdentity())
        let factory = RTCPeerConnectionFactory()
        model.track = factory.videoTrack(with: factory.videoSource(), trackId: "first")
        let screen = RemoteScreenView(model: model)
        screen.update()
        let previous = try XCTUnwrap(screen.subviews.first { $0 is DecodedVideoView })

        model.track = factory.videoTrack(with: factory.videoSource(), trackId: "second")
        screen.update()
        let current = try XCTUnwrap(screen.subviews.first { $0 is DecodedVideoView })

        XCTAssertFalse(current === previous, "A new Mac must not inherit a surface with the previous Mac's frame.")
        XCTAssertEqual(screen.subviews.filter { $0 is DecodedVideoView }.count, 1)
    }

    func testAnotherTrackWaitsForItsOwnFirstFrame() {
        let model = MacViewerModel(identity: DeviceIdentity())
        let factory = RTCPeerConnectionFactory()
        model.track = factory.videoTrack(with: factory.videoSource(), trackId: "first")
        model.receivedFrame = true

        model.track = factory.videoTrack(with: factory.videoSource(), trackId: "second")

        XCTAssertFalse(model.receivedFrame, "Readiness must belong to the current video track.")
    }
}
