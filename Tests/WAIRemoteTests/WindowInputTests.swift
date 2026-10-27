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
        XCTAssertEqual(target.post(event, permitted: { true }, delivery: delivery), .window)
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
        XCTAssertEqual(target.post(event, permitted: { true }, delivery: delivery), .primer)
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
        XCTAssertEqual(target.post(event, permitted: { allowed }, delivery: delivery), .cancelled)
        XCTAssertEqual(delivered, [.mouseMoved])
        var open = true
        let closing = WindowInputTarget.Delivery(frame: { _ in open ? CGRect(x: 100, y: 200, width: 800, height: 600) : nil },
            frontmostPID: { 999 }, transient: { _, _ in false }, prepare: { _ in open = false },
            pointer: { _, _ in XCTFail("A closed window receives nothing") }, pause: { _ in })
        XCTAssertEqual(target.post(event, permitted: { true }, delivery: closing), .frameGone)
    }

    private func key(_ code: CGKeyCode, _ flags: CGEventFlags, down: Bool = true) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = flags
        return event
    }
    private func keyDelivery(frontmost: pid_t, posted: @escaping (CGEvent) -> Void,
                             menu: @escaping (CGEvent) -> WindowInputTarget.Button?) -> WindowInputTarget.Delivery {
        WindowInputTarget.Delivery(frame: { _ in CGRect(x: 100, y: 200, width: 800, height: 600) }, frontmostPID: { frontmost },
            transient: { _, _ in false }, prepare: { _ in }, pointer: { _, _ in XCTFail("Keys never use the pointer path") },
            pause: { _ in }, menuItem: { _, event in menu(event) }, key: { _, event in posted(event) })
    }

    func testCommandShortcutInABackgroundAppPressesItsMenuItemInsteadOfPostingTheKey() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        var presses = 0, asked: [CGKeyCode] = []
        let item = WindowInputTarget.Button(frame: .zero, requiresMainThread: false, action: { presses += 1; return true })
        let delivery = keyDelivery(frontmost: 999, posted: { _ in XCTFail("A background app ignores a posted key equivalent") },
            menu: { asked.append(CGKeyCode($0.getIntegerValueField(.keyboardEventKeycode))); return item })
        XCTAssertEqual(target.post(try key(9, .maskCommand), permitted: { true }, delivery: delivery), .menu)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(asked, [9])
    }

    func testShortcutWithoutAMenuItemOrForTheActiveAppIsPostedAsBefore() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        var posted: [CGKeyCode] = []
        let record: (CGEvent) -> Void = { posted.append(CGKeyCode($0.getIntegerValueField(.keyboardEventKeycode))) }
        XCTAssertEqual(target.post(try key(123, .maskCommand), permitted: { true },
            delivery: keyDelivery(frontmost: 999, posted: record, menu: { _ in nil })), .window)
        let active = keyDelivery(frontmost: 123, posted: record, menu: { _ in XCTFail("The active app performs its own shortcuts"); return nil })
        XCTAssertEqual(target.post(try key(9, .maskCommand), permitted: { true }, delivery: active), .window)
        let background = keyDelivery(frontmost: 999, posted: record, menu: { _ in XCTFail("Only a Command key-down is a menu shortcut"); return nil })
        target.post(try key(0, []), permitted: { true }, delivery: background)
        target.post(try key(9, .maskCommand, down: false), permitted: { true }, delivery: background)
        let failing = WindowInputTarget.Button(frame: .zero, requiresMainThread: false, action: { false })
        XCTAssertEqual(target.post(try key(8, .maskCommand), permitted: { true },
            delivery: keyDelivery(frontmost: 999, posted: record, menu: { _ in failing })), .window, "A failed press falls back to the key.")
        XCTAssertEqual(posted, [123, 9, 0, 9, 8])
    }

    func testRevocationDuringTheMenuLookupPressesNothing() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        var allowed = true
        let item = WindowInputTarget.Button(frame: .zero, requiresMainThread: false, action: { XCTFail("Cancelled input must not press"); return true })
        let delivery = keyDelivery(frontmost: 999, posted: { _ in XCTFail("Cancelled input must not post") },
            menu: { _ in allowed = false; return item })
        XCTAssertEqual(target.post(try key(9, .maskCommand), permitted: { allowed }, delivery: delivery), .cancelled)
    }

    func testNonLatinLayoutFindsShortcutsByTheUSLatinKey() throws {
        for (name, code) in InputInjector.keyCodes where name.hasPrefix("Key") || name.hasPrefix("Digit") {
            let event = try key(code, .maskCommand)
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x0436]) // Cyrillic "ж"
            XCTAssertEqual(WindowInputTarget.shortcutCharacter(event), String(name.last!), name)
        }
        let latin = try key(8, .maskCommand)
        latin.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x0079]) // "y" on a QWERTZ layout
        XCTAssertEqual(WindowInputTarget.shortcutCharacter(latin), "Y", "A Latin layout keeps its own characters.")
        XCTAssertNil(WindowInputTarget.shortcutCharacter(try key(123, .maskCommand)), "Arrows are not menu characters.")
    }

    private final class MenuRecorder: NSObject {
        var fired: [String] = []
        @objc func fire(_ sender: NSMenuItem) { fired.append(sender.title) }
    }
    /// The app's own AppKit menus, read through accessibility like a foreign
    /// app's. Lookups only; every item's target is the recorder.
    @MainActor
    func testMenuShortcutLookupMatchesTheCharacterAndExactModifiers() throws {
        if !Self.launched { NSApplication.shared.finishLaunching(); Self.launched = true }
        let recorder = MenuRecorder()
        let previous = NSApp.mainMenu
        defer { NSApp.mainMenu = previous }
        func item(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(MenuRecorder.fire(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers; item.target = recorder; item.isEnabled = enabled
            return item
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title); menu.autoenablesItems = false
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: ""); holder.submenu = menu
            return holder
        }
        let main = NSMenu(title: "Main")
        main.addItem(menu("Fixture", [item("Fixture Settings", ",")]))
        main.addItem(menu("Edit", [item("Undo", "z"), item("Redo", "z", [.command, .shift]), item("Copy", "c"),
            item("Select All", "a"), item("Duplicate", "d", enabled: false),
            menu("Find", [item("Find…", "f")])]))
        NSApp.mainMenu = main
        let target = WindowInputTarget(pid: getpid(), windowID: 1)
        var bar: CFTypeRef?
        try XCTSkipIf(AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXMenuBarAttribute as CFString, &bar) != .success,
                      "This process exposes no accessibility menu bar.")
        func press(_ code: CGKeyCode, _ flags: CGEventFlags) throws -> String? {
            guard let found = target.menuItem(for: try key(code, flags)) else { return nil }
            XCTAssertTrue(found.press(if: { true }))
            // AppKit performs a pressed menu item on the app's next run loop turn.
            let deadline = Date().addingTimeInterval(1)
            while recorder.fired.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            return recorder.fired.popLast()
        }
        XCTAssertEqual(try press(6, .maskCommand), "Undo")
        XCTAssertEqual(try press(6, [.maskCommand, .maskShift]), "Redo", "Shift selects a different item, not the same one.")
        XCTAssertEqual(try press(0, .maskCommand), "Select All")
        XCTAssertEqual(try press(3, .maskCommand), "Find…", "Submenu shortcuts count too.")
        XCTAssertEqual(try press(43, .maskCommand), "Fixture Settings")
        XCTAssertNil(target.menuItem(for: try key(0, [.maskCommand, .maskAlternate])), "Modifier sets must match exactly.")
        XCTAssertNil(target.menuItem(for: try key(2, .maskCommand)), "A disabled item falls back to the key.")
        XCTAssertNil(target.menuItem(for: try key(12, [.maskCommand, .maskControl])),
                     "Never the system's Apple menu: Lock Screen and Log Out are not the app's shortcuts.")
        let cyrillic = try key(8, .maskCommand)
        cyrillic.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x0441]) // "с" on a Russian layout
        XCTAssertNotNil(target.menuItem(for: cyrillic), "Like AppKit, a non-Latin layout uses the Latin command layout.")
        XCTAssertTrue(recorder.fired.isEmpty)
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

    /// The host's own window is a target in independent mode. Delivery runs on the
    /// input queue, and same-process AX calls run AppKit on the caller's thread.
    @MainActor
    func testOwnWindowTransientCheckRunsAppKitOnTheMainThread() throws {
        if !Self.launched { NSApplication.shared.finishLaunching(); Self.launched = true }
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let target = WindowInputTarget(pid: getpid(), windowID: CGWindowID(window.windowNumber))
        let selector = #selector(NSApplication.accessibilityHitTest(_:))
        let method = try XCTUnwrap(class_getInstanceMethod(NSApplication.self, selector))
        typealias HitTest = @convention(c) (NSApplication, Selector, NSPoint) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: HitTest.self)
        let lock = NSLock()
        var onMain: [Bool] = []
        let recording: @convention(block) (NSApplication, NSPoint) -> AnyObject? = { app, point in
            lock.withLock { onMain.append(Thread.isMainThread) }
            return original(app, selector, point)
        }
        let previous = method_setImplementation(method, imp_implementationWithBlock(recording))
        defer { method_setImplementation(method, previous) }
        let checked = expectation(description: "transient check")
        DispatchQueue(label: "is.wai.remote.input", qos: .userInteractive).async {
            _ = target.isTransient(at: CGPoint(x: 100, y: 100)); checked.fulfill()
        }
        wait(for: [checked], timeout: 5)
        let threads = lock.withLock { onMain }
        XCTAssertFalse(threads.isEmpty, "The check must reach AppKit's own hit test.")
        XCTAssertEqual(threads, threads.map { _ in true }, "AppKit accessibility of our own views runs on their main thread.")
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
