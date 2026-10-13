import AppKit
import WebRTC
import XCTest
import RemoteCore
import Combine
import AVFoundation
@testable import WAIRemote

@MainActor
final class RemoteScreenTests: XCTestCase {
    private final class InputRecorder: MacViewerModel {
        var input: [(key: String, action: String, modifiers: [String])] = []
        var operations: [WireMessage] = []
        let host = SessionMachine(surface: Surface(id: "test", width: 1920, height: 1080))
        override var canControl: Bool { true }
        override func keyEvent(_ key: String, action: String, modifiers: [String] = []) {
            input.append((key, action, modifiers))
        }
        override func send(_ type: String, edit: (inout WireMessage) -> Void = { _ in }) -> Bool {
            var message = WireMessage(type: type, state: host.state)
            message.sequence = operations.count
            edit(&message)
            operations.append(message)
            return true
        }
    }

    func testLongDictationIsDeliveredCompletelyInValidTextPackets() {
        let model = InputRecorder(identity: DeviceIdentity())
        let screen = RemoteScreenView(model: model)
        let text = String(repeating: "Надиктованный текст 👨‍👩‍👧‍👦 café.\n", count: 400)
        screen.insertText(NSAttributedString(string: text), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(model.operations.compactMap(\.text).joined(), text)
        XCTAssertGreaterThan(model.operations.count, 1)
        for (index, message) in model.operations.enumerated() {
            XCTAssertLessThanOrEqual(message.text?.utf16.count ?? 0, 4096)
            XCTAssertEqual(model.host.handle(message, now: Double(index)).input?.text, message.text)
        }
    }

    func testLocalWindowShortcutsAreNotSentToTheRemoteMac() throws {
        _ = NSApplication.shared
        let model = InputRecorder(identity: DeviceIdentity())
        let screen = RemoteScreenView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = screen
        defer { window.close() }
        window.makeFirstResponder(screen)
        for (code, character): (UInt16, String) in [(4, "h"), (46, "m"), (43, ","), (29, "0")] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
            XCTAssertFalse(screen.performKeyEquivalent(with: event))
        }
        XCTAssertTrue(model.input.isEmpty, "Hide, minimize, settings and home belong to the local app.")
    }

    func testPointerCarriesCurrentModifiersAfterAShortcut() throws {
        let model = InputRecorder(identity: DeviceIdentity())
        let screen = RemoteScreenView(model: model)
        screen.frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        for flags: NSEvent.ModifierFlags in [.shift, []] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 100, y: 100),
                modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            screen.mouseDown(with: event)
        }
        XCTAssertEqual(model.operations.map(\.modifiers), [["Shift"], []])
    }

    func testMenuShortcutDoesNotLeaveCommandHeld() {
        let model = InputRecorder(identity: DeviceIdentity())
        model.key("KeyC", modifiers: ["Meta"])
        XCTAssertEqual(model.input.map(\.modifiers), [["Meta"], []])
    }

    func testControlArrowShortcutReleasesControlBeforeTheNextClick() throws {
        let model = InputRecorder(identity: DeviceIdentity())
        let screen = RemoteScreenView(model: model)
        func event(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
        }
        screen.flagsChanged(with: try event(.flagsChanged, 59, .control))
        screen.keyDown(with: try event(.keyDown, 126, .control))
        screen.keyUp(with: try event(.keyUp, 126, .control))
        screen.flagsChanged(with: try event(.flagsChanged, 59, []))

        XCTAssertEqual(model.input.map(\.key), ["ControlLeft", "ArrowUp", "ArrowUp", "ControlLeft"])
        XCTAssertEqual(model.input.map(\.action), ["down", "down", "up", "up"])
        XCTAssertEqual(model.input.last?.modifiers, [], "A later click must not inherit Control from Mission Control.")
    }

    func testReleasingOneShiftDoesNotReleaseTheOtherShift() throws {
        let model = InputRecorder(identity: DeviceIdentity())
        let screen = RemoteScreenView(model: model)
        for (code, flags): (UInt16, NSEvent.ModifierFlags) in [(56, .shift), (60, .shift), (56, .shift), (60, [])] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: code))
            screen.flagsChanged(with: event)
        }
        XCTAssertEqual(model.input.map(\.key), ["ShiftLeft", "ShiftRight", "ShiftLeft", "ShiftRight"])
        XCTAssertEqual(model.input.map(\.action), ["down", "down", "up", "up"])
        XCTAssertEqual(model.input.map(\.modifiers), [["Shift"], ["Shift"], ["Shift"], []])
    }

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
        // the small CI display). Match its toolbar as well, since the toolbar
        // reduces the content height when the screen constrains the window.
        let reference = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 780),
                                 styleMask: window.styleMask, backing: .buffered, defer: false)
        reference.isReleasedWhenClosed = false
        defer { reference.close() }
        let referenceToolbar = ViewerToolbar(model: delegate.viewer, window: reference)
        try withExtendedLifetime(referenceToolbar) {
            reference.setContentSize(NSSize(width: 1200, height: 780))
            reference.center()
            reference.orderFront(nil)
            let expected = try XCTUnwrap(reference.contentView).bounds.size
            let content = try XCTUnwrap(window.contentView)
            XCTAssertEqual(content.bounds.width, expected.width, accuracy: 1)
            XCTAssertEqual(content.bounds.height, expected.height, accuracy: 1)
        }
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
