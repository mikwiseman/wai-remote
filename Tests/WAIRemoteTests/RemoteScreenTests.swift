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
        var operations: [WireMessage] = []
        var input: [(key: String, action: String, modifiers: [String])] {
            operations.filter { $0.type == "key" }.map { ($0.key ?? "", $0.action ?? "", $0.modifiers ?? []) }
        }
        var releases = 0
        var outgoing: UInt64 = 0
        override var outgoingBytes: UInt64 { outgoing }
        let host = SessionMachine(surface: Surface(id: "test", width: 1920, height: 1080))
        override var canControl: Bool { true }
        override func releaseInput() { releases += 1; super.releaseInput() }
        var pastes = 0
        override func paste() { pastes += 1 }
        var sent: [String] { operations.map { "\($0.type) \($0.key ?? String($0.button ?? -1)) \($0.action ?? "")" } }
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

    private func focusedScreen(_ model: InputRecorder) -> (RemoteScreenView, NSWindow) {
        _ = NSApplication.shared
        let screen = RemoteScreenView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = screen
        window.makeFirstResponder(screen)
        return (screen, window)
    }
    private func holdShiftAndButton(on screen: RemoteScreenView, in window: NSWindow) throws {
        screen.flagsChanged(with: try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 56)))
        screen.mouseDown(with: try click(in: window))
    }
    private func click(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 320, y: 240), modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    func testLosingFocusLiftsHeldInputAndTheNextClickNeedsNoHostRoundTrip() throws {
        let model = InputRecorder(identity: DeviceIdentity())
        let (screen, window) = focusedScreen(model)
        defer { window.close() }
        try holdShiftAndButton(on: screen, in: window)
        XCTAssertEqual(model.sent, ["key ShiftLeft down", "pointer 0 down"])
        window.makeFirstResponder(nil)
        XCTAssertEqual(model.sent.dropFirst(2), ["pointer 0 up", "key ShiftLeft up"])
        XCTAssertEqual(model.releases, 0, "A release blocks all input until the host answers with a new epoch.")
        window.makeFirstResponder(screen)
        screen.mouseDown(with: try click(in: window))
        XCTAssertEqual(model.sent.last, "pointer 0 down")
    }

    func testViewerWindowLosingKeyLiftsHeldInputWithoutReleasingTheSession() throws {
        let model = InputRecorder(identity: DeviceIdentity())
        let (screen, window) = focusedScreen(model)
        defer { window.close() }
        let delegate = AppDelegate()
        delegate.viewer = model; delegate.viewerWindow = window
        try holdShiftAndButton(on: screen, in: window)
        delegate.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        XCTAssertEqual(model.sent.dropFirst(2), ["pointer 0 up", "key ShiftLeft up"])
        XCTAssertEqual(model.releases, 0)
    }

    func testLocalWindowShortcutsLiftHeldInputButOnlyTheEscapeShortcutReleases() throws {
        let model = InputRecorder(identity: DeviceIdentity())
        let (screen, window) = focusedScreen(model)
        defer { window.close() }
        func shortcut(_ code: UInt16, _ character: String, _ flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        }
        try holdShiftAndButton(on: screen, in: window)
        XCTAssertFalse(screen.performKeyEquivalent(with: try shortcut(4, "h")))
        XCTAssertEqual(model.sent.dropFirst(2), ["pointer 0 up", "key ShiftLeft up"])
        XCTAssertEqual(model.releases, 0)
        XCTAssertTrue(screen.performKeyEquivalent(with: try shortcut(53, "\u{1b}", [.command, .option])))
        XCTAssertEqual(model.releases, 1, "Command-Option-Escape is the explicit release.")
    }

    func testOnlyExactLocalShortcutsStayOnThisMac() throws {
        let model = InputRecorder(identity: DeviceIdentity())
        let (screen, window) = focusedScreen(model)
        defer { window.close() }
        func shortcut(_ code: UInt16, _ character: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        }
        for flags: NSEvent.ModifierFlags in [[.command, .shift], [.command, .option], [.command, .control]] {
            XCTAssertTrue(screen.performKeyEquivalent(with: try shortcut(12, "q", flags)), "Only plain Command-Q quits the viewer.")
        }
        for flags: NSEvent.ModifierFlags in [[.command, .option], [.command, .control]] {
            XCTAssertTrue(screen.performKeyEquivalent(with: try shortcut(9, "v", flags)))
        }
        XCTAssertTrue(screen.performKeyEquivalent(with: try shortcut(53, "\u{1b}", [.command, .option, .control])))
        XCTAssertEqual(model.releases, 0, "Only exact Command-Option-Escape and Command-Q release input.")
        XCTAssertEqual(model.pastes, 0, "Option-Command-V and Control-Command-V are the remote app's shortcuts, not a paste.")
        XCTAssertEqual(model.input.filter { $0.action == "down" }.map(\.key), ["KeyQ", "KeyQ", "KeyQ", "KeyV", "KeyV", "Escape"])
        XCTAssertEqual(model.input.filter { $0.action == "down" }.map(\.modifiers),
                       [["Meta", "Shift"], ["Meta", "Alt"], ["Meta", "Control"], ["Meta", "Alt"], ["Meta", "Control"], ["Meta", "Control", "Alt"]])
        XCTAssertTrue(screen.performKeyEquivalent(with: try shortcut(9, "v", .command)))
        XCTAssertEqual(model.pastes, 1, "Plain Command-V keeps the explicit paste path.")
        XCTAssertFalse(screen.performKeyEquivalent(with: try shortcut(12, "q", .command)))
        XCTAssertEqual(model.releases, 1, "Plain Command-Q stays local and releases input first.")
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

    func testDoubleClickCarriesTheViewersClickCount() throws {
        let model = InputRecorder(identity: DeviceIdentity())
        let screen = RemoteScreenView(model: model)
        screen.frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        for count in [1, 2] {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 100), modifierFlags: [],
                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
                if type == .leftMouseDown { screen.mouseDown(with: event) } else { screen.mouseUp(with: event) }
            }
        }
        XCTAssertEqual(model.operations.map(\.clickCount), [1, nil, 2, nil])
        XCTAssertEqual(model.operations.map(\.action), ["down", "up", "down", "up"])
    }

    func testCongestedChannelDropsHoverMovesButNeverClicksOrKeys() {
        let model = InputRecorder(identity: DeviceIdentity())
        model.outgoing = 20_000
        model.pointer("move", at: InkPoint(0.2, 0.2))
        model.pointer("down", at: InkPoint(0.3, 0.3))
        model.pointer("move", at: InkPoint(0.4, 0.4))
        model.pointer("up", at: InkPoint(0.5, 0.5))
        model.key("KeyA")
        XCTAssertEqual(model.sent, ["pointer 0 down", "pointer 0 up", "key KeyA down", "key KeyA up"],
                       "A queued backlog of positions must not delay the click or force a reconnect.")
        XCTAssertEqual(model.lastCursor, InkPoint(0.5, 0.5))
        model.outgoing = 8_000
        model.pointer("move", at: InkPoint(0.6, 0.6))
        XCTAssertEqual(model.sent.last, "pointer 0 move")
    }

    func testCommandEquivalentReleasesItsKeyWithoutWaitingForKeyUp() throws {
        _ = NSApplication.shared
        let model = InputRecorder(identity: DeviceIdentity())
        let screen = RemoteScreenView(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = screen
        defer { window.close() }
        window.makeFirstResponder(screen)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        }
        XCTAssertTrue(screen.performKeyEquivalent(with: try event(.keyDown)))
        XCTAssertEqual(model.input.map(\.key), ["KeyA", "KeyA"])
        XCTAssertEqual(model.input.map(\.action), ["down", "up"],
                       "AppKit may consume the key-up for a handled key equivalent; the remote shortcut must still finish.")
        XCTAssertEqual(model.input.map(\.modifiers), [["Meta"], []])
        screen.keyUp(with: try event(.keyUp))
        XCTAssertEqual(model.input.count, 2, "A later key-up must not duplicate the completed command.")
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

    func testVideoReappearsWhenTheSameTrackResumesAfterInterruption() async throws {
        let model = MacViewerModel(identity: DeviceIdentity())
        let factory = RTCPeerConnectionFactory()
        model.track = factory.videoTrack(with: factory.videoSource(), trackId: "screen")
        let screen = RemoteScreenView(model: model)
        screen.update()
        let renderer = try XCTUnwrap(screen.renderer)
        let first = expectation(description: "First frame appears")
        let resumed = expectation(description: "Resumed frame removes the waiting overlay")
        var appearances = 0
        let observation = model.$receivedFrame.dropFirst().filter { $0 }.sink { _ in
            appearances += 1
            if appearances == 1 { first.fulfill() } else { resumed.fulfill() }
        }
        defer { observation.cancel(); screen.detach() }
        let buffer = RTCCVPixelBuffer(pixelBuffer: try pixels())
        // A busy native display may intentionally drop a frame. Feed a real
        // sequence so the test measures recovery rather than one enqueue slot.
        let frames = Task { @MainActor in
            var timestamp: Int64 = 1
            while !Task.isCancelled {
                renderer.renderFrame(RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timestamp))
                timestamp += 66_666_667
                do { try await Task.sleep(for: .milliseconds(67)) } catch { return }
            }
        }
        defer { frames.cancel() }
        await fulfillment(of: [first], timeout: 2)

        model.receivedFrame = false // Temporary ICE interruption; the track survives.
        screen.update()
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertTrue(model.receivedFrame)
    }
}
