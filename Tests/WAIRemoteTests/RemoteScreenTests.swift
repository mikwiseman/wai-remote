import AppKit
import WebRTC
import XCTest
import RemoteCore
import Combine
@testable import WAIRemote

@MainActor
final class RemoteScreenTests: XCTestCase {
    func testViewerOpensAtReadableSizeInsteadOfItsMinimum() throws {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.viewer = MacViewerModel(identity: DeviceIdentity())
        delegate.viewer.connecting = true

        delegate.connect()
        let window = try XCTUnwrap(delegate.viewerWindow)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.bounds.width, 1200, accuracy: 1)
        XCTAssertEqual(content.bounds.height, 780, accuracy: 1)
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

    func testUnchangedScreenDoesNotScheduleAnotherMetalLayout() {
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
        let previous = try XCTUnwrap(screen.subviews.first { $0 is RTCMTLNSVideoView })

        model.disconnect()
        screen.update()

        XCTAssertFalse(screen.subviews.contains { $0 === previous }, "The disconnected Mac's last frame must leave the view hierarchy.")
        XCTAssertFalse(screen.subviews.contains { $0 is RTCMTLNSVideoView })
    }

    func testAnotherTrackGetsAFreshVideoSurface() throws {
        let model = MacViewerModel(identity: DeviceIdentity())
        let factory = RTCPeerConnectionFactory()
        model.track = factory.videoTrack(with: factory.videoSource(), trackId: "first")
        let screen = RemoteScreenView(model: model)
        screen.update()
        let previous = try XCTUnwrap(screen.subviews.first { $0 is RTCMTLNSVideoView })

        model.track = factory.videoTrack(with: factory.videoSource(), trackId: "second")
        screen.update()
        let current = try XCTUnwrap(screen.subviews.first { $0 is RTCMTLNSVideoView })

        XCTAssertFalse(current === previous, "A new Mac must not inherit a Metal surface with the previous Mac's frame.")
        XCTAssertEqual(screen.subviews.filter { $0 is RTCMTLNSVideoView }.count, 1)
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
