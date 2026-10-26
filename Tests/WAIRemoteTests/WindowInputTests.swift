import AppKit
import Darwin
import XCTest
@testable import WAIRemote

final class WindowInputTests: XCTestCase {
    func testClickInActiveAppDoesNotDismissItsMenuWithAnOffWindowPrimer() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 250, y: 420), mouseButton: .left))
        var delivered: [CGEventType] = []
        let delivery = WindowInputTarget.Delivery(
            frame: { _ in CGRect(x: 100, y: 200, width: 800, height: 600) }, frontmostPID: { 123 }, transient: { _, _ in false },
            prepare: { _ in XCTFail("An active app must not be activated again") },
            pointer: { _, event in delivered.append(event.type); XCTAssertEqual(event.location, CGPoint(x: 250, y: 420)) },
            pause: { _ in XCTFail("Active-app clicks must not wait for a background activation") })
        target.post(event, permitted: { true }, delivery: delivery)
        XCTAssertEqual(delivered, [.leftMouseDown], "Exactly the user's down, with no synthetic off-window click.")
    }

    func testBackgroundClickKeepsTheWindowPointItWasAimedAtAndItsPrimer() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 250, y: 420), mouseButton: .left))
        var frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        var delivered: [CGEventType] = []
        var pauses = 0
        let delivery = WindowInputTarget.Delivery(frame: { _ in frame }, frontmostPID: { 999 }, transient: { _, _ in false },
            prepare: { _ in frame.origin = CGPoint(x: 120, y: 230) },
            pointer: { _, event in delivered.append(event.type) },
            pause: { _ in pauses += 1; frame.origin.x += 10 })
        target.post(event, permitted: { true }, delivery: delivery)
        XCTAssertEqual(delivered, [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDown])
        XCTAssertEqual(pauses, 3)
        XCTAssertEqual(windowLocation(event), CGPoint(x: 150, y: 220),
            "A point inside a window does not move with the window; the user aimed at the original geometry.")
        XCTAssertEqual(event.location, CGPoint(x: 250, y: 420))
    }

    func testClickIntoABackgroundMenuOrPopoverIsNotPrecededByAnOffWindowPrimer() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 250, y: 420), mouseButton: .left))
        var delivered: [CGEventType] = [], asked: [CGPoint] = [], prepared = 0
        let delivery = WindowInputTarget.Delivery(frame: { _ in CGRect(x: 100, y: 200, width: 800, height: 600) },
            frontmostPID: { 999 }, transient: { _, point in asked.append(point); return true }, prepare: { _ in prepared += 1 },
            pointer: { _, event in delivered.append(event.type) },
            pause: { _ in XCTFail("An open menu needs no activation wait") })
        target.post(event, permitted: { true }, delivery: delivery)
        XCTAssertEqual(delivered, [.leftMouseDown], "The primer would close the menu and the click would hit what lay beneath.")
        XCTAssertEqual(asked, [CGPoint(x: 250, y: 420)])
        XCTAssertEqual(prepared, 1, "Only the primer is skipped; the target-only focus record stays.")
    }

    func testATapWithoutHoverMovesThePointerOverTheTargetBeforePressing() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 250, y: 420), mouseButton: .left))
        var delivered: [(CGEventType, CGPoint)] = []
        let delivery = WindowInputTarget.Delivery(frame: { _ in CGRect(x: 100, y: 200, width: 800, height: 600) },
            frontmostPID: { 123 }, transient: { _, _ in false }, prepare: { _ in XCTFail("The app is already active") },
            pointer: { _, event in delivered.append((event.type, self.windowLocation(event))) },
            pause: { _ in })
        target.post(event, permitted: { true }, hover: true, delivery: delivery)
        XCTAssertEqual(delivered.map(\.0), [.mouseMoved, .leftMouseDown], "Hover-armed controls need the pointer over them first.")
        XCTAssertEqual(delivered.map(\.1), [CGPoint(x: 150, y: 220), CGPoint(x: 150, y: 220)])
    }

    func testRevocationDuringActivationCannotDeliverTheRealClick() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 250, y: 420), mouseButton: .left))
        var allowed = true
        var delivered: [CGEventType] = []
        let delivery = WindowInputTarget.Delivery(frame: { _ in CGRect(x: 100, y: 200, width: 800, height: 600) },
            frontmostPID: { 999 }, transient: { _, _ in false }, prepare: { _ in },
            pointer: { _, event in delivered.append(event.type) }, pause: { _ in allowed = false })
        target.post(event, permitted: { allowed }, delivery: delivery)
        XCTAssertEqual(delivered, [.mouseMoved])
    }

    func testBackgroundEventAddressesOnlyTheSelectedWindow() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                        mouseCursorPosition: CGPoint(x: 250, y: 420), mouseButton: .left))
        let cursor = CGEvent(source: nil)?.location
        try XCTSkipUnless(WindowInputTarget.isSupported)
        event.setIntegerValueField(CGEventField(rawValue: 58)!, value: 987)
        XCTAssertTrue(target.address(event, frame: frame))
        XCTAssertEqual(event.getIntegerValueField(.eventTargetUnixProcessID), 123)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointer), 456)
        XCTAssertEqual(event.getIntegerValueField(CGEventField(rawValue: 51)!), 456)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventSubtype), 3,
                       "Background pointer delivery must carry Chromium's accepted touch subtype.")
        XCTAssertEqual(event.getIntegerValueField(CGEventField(rawValue: 58)!), 987,
                       "The target down/up pair must keep the same gesture as its background primer.")
        XCTAssertEqual(event.getIntegerValueField(.mouseEventNumber), 3)
        typealias GetLocation = @convention(c) (CGEvent) -> CGPoint
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventGetWindowLocation"))
        let location = unsafeBitCast(symbol, to: GetLocation.self)(event)
        XCTAssertEqual(location, CGPoint(x: 150, y: 220),
                       "The target window origin must be subtracted exactly once; Chrome otherwise receives the origin twice.")
        XCTAssertEqual(event.location, CGPoint(x: 250, y: 420), "Global event location stays in screen coordinates.")
        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        key.flags = .maskCommand
        let keyLocation = unsafeBitCast(symbol, to: GetLocation.self)(key)
        XCTAssertTrue(target.address(key, frame: frame))
        XCTAssertEqual(unsafeBitCast(symbol, to: GetLocation.self)(key), keyLocation,
                       "Keyboard events are window-addressed, but must not receive mouse coordinates.")
        XCTAssertEqual(CGEvent(source: nil)?.location, cursor, "Addressing a background event must not warp the desktop cursor.")
    }

    private func windowLocation(_ event: CGEvent) -> CGPoint {
        typealias GetLocation = @convention(c) (CGEvent) -> CGPoint
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventGetWindowLocation") else { return .zero }
        return unsafeBitCast(symbol, to: GetLocation.self)(event)
    }

    private final class PressableView: NSView {
        var pressed: () -> Void = {}
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func isAccessibilityEnabled() -> Bool { true }
        override func accessibilityPerformPress() -> Bool { pressed(); return true }
    }
    /// A real AppKit window far outside every display: nothing appears on screen.
    /// AX hit-testing needs a visible window, so tests start from a known element.
    @MainActor private func accessible(_ build: (NSView) -> Void) throws -> (NSWindow, WindowInputTarget, [String: AXUIElement]) {
        if !Self.launched { NSApplication.shared.finishLaunching(); Self.launched = true }
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        build(content); window.contentView = content
        window.orderFrontRegardless(); RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        var windows: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &windows)
        var elements: [String: AXUIElement] = [:], pending = (windows as? [AXUIElement]) ?? []
        while let element = pending.popLast() {
            var id: CFTypeRef?, children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &id) == .success, let id = id as? String { elements[id] = element }
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success { pending += (children as? [AXUIElement]) ?? [] }
        }
        try XCTSkipIf(elements.isEmpty, "This process exposes no accessibility tree.")
        return (window, WindowInputTarget(pid: getpid(), windowID: CGWindowID(window.windowNumber)), elements)
    }
    private static var launched = false
    private func center(_ element: AXUIElement) throws -> CGPoint {
        var position: CFTypeRef?, size: CFTypeRef?
        var origin = CGPoint.zero, extent = CGSize.zero
        XCTAssertEqual(AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position), .success)
        XCTAssertEqual(AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size), .success)
        XCTAssertTrue(AXValueGetValue(try XCTUnwrap(position) as! AXValue, .cgPoint, &origin))
        XCTAssertTrue(AXValueGetValue(try XCTUnwrap(size) as! AXValue, .cgSize, &extent))
        return CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
    }

    @MainActor
    func testAccessibilityPressClimbsFromTheHitLabelToItsButtonInThisWindow() throws {
        var presses = 0
        let (window, target, elements) = try accessible { content in
            let button = PressableView(frame: NSRect(x: 50, y: 50, width: 200, height: 100))
            button.identifier = .init("button"); button.pressed = { presses += 1 }
            let label = NSTextField(labelWithString: "Send"); label.frame = NSRect(x: 60, y: 30, width: 80, height: 30)
            label.identifier = .init("label"); button.addSubview(label); content.addSubview(button)
        }
        defer { window.orderOut(nil); window.close() }
        let label = try XCTUnwrap(elements["label"]), point = try center(label)
        let button = try XCTUnwrap(target.button(climbingFrom: label, at: point), "A click on a button's title presses the button.")
        XCTAssertTrue(button.frame.contains(try center(try XCTUnwrap(elements["button"]))))
        XCTAssertTrue(button.press(if: { true }))
        XCTAssertEqual(presses, 1)
        XCTAssertNil(WindowInputTarget(pid: getpid(), windowID: target.windowID + 1).button(climbingFrom: label, at: point),
                     "A button of another window must never be pressed for this one.")
    }

    @MainActor
    func testAccessibilityPressNeverReachesAButtonCoveredByTheHitOverlay() throws {
        let (window, target, elements) = try accessible { content in
            let button = NSButton(frame: NSRect(x: 50, y: 50, width: 200, height: 100)); button.identifier = .init("button")
            let overlay = NSTextField(labelWithString: "Overlay"); overlay.frame = button.frame; overlay.identifier = .init("overlay")
            content.addSubview(button); content.addSubview(overlay)
        }
        defer { window.orderOut(nil); window.close() }
        let overlay = try XCTUnwrap(elements["overlay"]), button = try XCTUnwrap(elements["button"])
        XCTAssertNil(target.button(climbingFrom: overlay, at: try center(overlay)), "Events must reach the overlay the user sees.")
        XCTAssertNotNil(target.button(climbingFrom: button, at: try center(button)))
    }

    func testAReusedWindowNumberDoesNotGrantAccessToAnotherProcess() {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let window: [String: Any] = [kCGWindowNumber as String: 456, kCGWindowOwnerPID as String: 999,
                                   kCGWindowBounds as String: frame.dictionaryRepresentation]
        XCTAssertNil(target.frame(in: [window]))
        var owned = window; owned[kCGWindowOwnerPID as String] = 123
        XCTAssertEqual(target.frame(in: [owned]), frame)
    }
}
