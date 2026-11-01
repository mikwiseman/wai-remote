import AppKit
import Darwin
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class ModalInputTests: XCTestCase {
    private static var launched = false
    @MainActor private struct Fixture {
        let window: NSWindow
        let alert: NSAlert
        let target: WindowInputTarget
        let sheetTarget: WindowInputTarget
        let elements: [String: AXUIElement]
        func close() {
            window.endSheet(alert.window, returnCode: .cancel)
            alert.window.orderOut(nil); window.orderOut(nil); window.close()
        }
    }
    private func fixture() throws -> Fixture {
        if !Self.launched { NSApplication.shared.finishLaunching(); Self.launched = true }
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        let button = NSButton(title: "Covered parent action", target: nil, action: nil)
        button.identifier = .init("parent-action"); button.frame = CGRect(x: 20, y: 20, width: 200, height: 40)
        window.contentView?.addSubview(button)
        window.orderFrontRegardless()
        let alert = NSAlert(); alert.messageText = "WAI Remote modal fixture"
        alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].identifier = .init("sheet-discard"); alert.buttons[1].identifier = .init("sheet-cancel")
        alert.window.animationBehavior = .none
        alert.beginSheetModal(for: window) { _ in }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(window.attachedSheet === alert.window)
        XCTAssertTrue(alert.window.sheetParent === window)
        var windows: CFTypeRef?
        XCTAssertEqual(AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute as CFString, &windows), .success)
        var pending = (windows as? [AXUIElement]) ?? [], elements: [String: AXUIElement] = [:], count = 0
        while let element = pending.popLast(), count < 200 {
            count += 1
            var identifier: CFTypeRef?, children: CFTypeRef?, title: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
            if let title = title as? String, ["Cancel", "Discard"].contains(title) { elements["sheet-" + title.lowercased()] = element }
            if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier) == .success,
               let id = identifier as? String { elements[id] = element }
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success {
                pending += (children as? [AXUIElement]) ?? []
            }
        }
        return Fixture(window: window, alert: alert,
                       target: WindowInputTarget(pid: getpid(), windowID: CGWindowID(window.windowNumber)),
                       sheetTarget: WindowInputTarget(pid: getpid(), windowID: CGWindowID(alert.window.windowNumber)), elements: elements)
    }
    private func center(_ element: AXUIElement) throws -> CGPoint {
        var position: CFTypeRef?, size: CFTypeRef?, point = CGPoint.zero, extent = CGSize.zero
        XCTAssertEqual(AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position), .success)
        XCTAssertEqual(AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size), .success)
        XCTAssertTrue(AXValueGetValue(try XCTUnwrap(position) as! AXValue, .cgPoint, &point))
        XCTAssertTrue(AXValueGetValue(try XCTUnwrap(size) as! AXValue, .cgSize, &extent))
        return CGPoint(x: point.x + extent.width / 2, y: point.y + extent.height / 2)
    }
    func testAttachedSheetButtonRemainsPressableInsideItsOwnTarget() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let button = try XCTUnwrap(fixture.elements["sheet-cancel"])
        let point = try center(button)
        // AXWindow is the document; AXTopLevelUIElement is the sheet. The
        // document's identity must not authorize a button in its child window.
        XCTAssertNil(fixture.target.button(climbingFrom: button, at: point))
        let press = try XCTUnwrap(fixture.sheetTarget.button(climbingFrom: button, at: point))
        XCTAssertFalse(press.press(if: { false }))
        XCTAssertNotNil(fixture.window.attachedSheet)
        XCTAssertTrue(press.press(if: { true }))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(fixture.window.attachedSheet)
    }
    func testKeyboardDestinationFollowsOnlyAnAttachedModalSheet() throws {
        let fixture = try fixture(); defer { fixture.close() }
        let unrelated = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 100, height: 100),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false; unrelated.orderFrontRegardless()
        defer { unrelated.orderOut(nil); unrelated.close() }
        let unrelatedTarget = WindowInputTarget(pid: getpid(), windowID: CGWindowID(unrelated.windowNumber))
        XCTAssertEqual(unrelatedTarget.keyboardDestination(), unrelatedTarget)
        XCTAssertEqual(fixture.target.keyboardDestination(), fixture.sheetTarget)
        XCTAssertEqual(fixture.sheetTarget.keyboardDestination(), fixture.sheetTarget)
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { XCTAssertEqual(fixture.target.keyboardDestination(), fixture.sheetTarget) }
        print("Modal routing: \((ProcessInfo.processInfo.systemUptime - started) * 10) ms/call (same-process AppKit, 100 calls)")
        fixture.window.endSheet(fixture.alert.window, returnCode: .cancel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(fixture.target.keyboardDestination(), fixture.target)
    }

    private func runApplication(for duration: TimeInterval) {
        let stop = Timer(timeInterval: duration, repeats: false) { _ in
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        RunLoop.main.add(stop, forMode: .common)
        NSApp.run(); stop.invalidate()
    }
    private func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
    @MainActor private final class SaveResponse: NSObject {
        var response: NSApplication.ModalResponse?
        var completions = 0
        var coveredPresses = 0
        @objc func coveredPress() { coveredPresses += 1 }
    }
    @MainActor private struct SaveFixture {
        let window: NSWindow
        let panel: NSSavePanel
        let target: WindowInputTarget
        let cancel: AXUIElement
        let filename: AXUIElement
        let response: SaveResponse
        let previousFrontmost: NSRunningApplication?
        func close() {
            if response.response == nil, window.attachedSheet != nil { panel.cancel(nil) }
            panel.orderOut(nil); window.orderOut(nil); window.close()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), previousFrontmost?.processIdentifier != getpid() {
                _ = previousFrontmost?.activate(options: [])
            }
        }
    }
    private func saveFixture() throws -> SaveFixture {
        let previous = NSWorkspace.shared.frontmostApplication
        NSApplication.shared.setActivationPolicy(.regular)
        if !Self.launched { NSApplication.shared.finishLaunching(); Self.launched = true }
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 700, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WAI Remote SavePanel test"
        window.isReleasedWhenClosed = false; window.animationBehavior = .none
        let response = SaveResponse()
        let covered = NSButton(frame: window.contentView!.bounds)
        covered.title = "Covered document action"; covered.target = response; covered.action = #selector(SaveResponse.coveredPress)
        window.contentView?.addSubview(covered); window.orderFrontRegardless()
        let panel = NSSavePanel()
        panel.directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        panel.nameFieldStringValue = "WAI Remote routing fixture.txt"
        panel.title = "WAI Remote SavePanel test"
        panel.canCreateDirectories = false; panel.animationBehavior = .none
        panel.beginSheetModal(for: window) { response.response = $0; response.completions += 1 }
        runApplication(for: 0.5)
        panel.orderFrontRegardless()
        typealias Number = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        let number = unsafeBitCast(try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")), to: Number.self)
        let windows = try XCTUnwrap(axValue(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute) as? [AXUIElement])
        let parent = try XCTUnwrap(windows.first { var id: CGWindowID = 0; return number($0, &id) == .success && id == CGWindowID(window.windowNumber) })
        var pending = [parent], cancel: AXUIElement?, filename: AXUIElement?, count = 0
        while let element = pending.popLast(), count < 128 {
            count += 1
            if axValue(element, kAXIdentifierAttribute) as? String == "CancelButton" { cancel = element }
            if axValue(element, kAXRoleAttribute) as? String == kAXTextFieldRole,
               (axValue(element, kAXValueAttribute) as? String)?.contains("WAI Remote routing fixture") == true { filename = element }
            pending += (axValue(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        guard let cancel, let filename else {
            panel.cancel(nil); panel.orderOut(nil); window.orderOut(nil); window.close()
            throw NSError(domain: "SavePanelFixture", code: 1)
        }
        return SaveFixture(window: window, panel: panel,
                           target: WindowInputTarget(pid: getpid(), windowID: CGWindowID(panel.windowNumber)),
                           cancel: cancel, filename: filename, response: response, previousFrontmost: previous)
    }
    private func message(_ type: String) -> WireMessage {
        WireMessage(type: type, state: SessionMachine(surface: .init(id: "fixture", width: 700, height: 500)).state)
    }
    private func click(_ element: AXUIElement, fixture: SaveFixture, injector: InputInjector) throws {
        let point = try center(element), frame = try XCTUnwrap(fixture.target.frame)
        for action in ["down", "up"] {
            var click = message("pointer"); click.action = action; click.button = 0
            click.x = (point.x - frame.minX) / max(1, frame.width - 1)
            click.y = (point.y - frame.minY) / max(1, frame.height - 1)
            injector.apply(click)
        }
        runApplication(for: 0.5)
    }
    private func key(_ key: String, injector: InputInjector) {
        for action in ["down", "up"] { var event = message("key"); event.key = key; event.action = action; injector.apply(event) }
        runApplication(for: 1.5)
    }
    /// Failure-only diagnostics for this test's own panel. Never print AX titles
    /// or values; identities distinguish an OS topology change from a timeout.
    private func diagnoseReceiver(_ fixture: SaveFixture) {
        print("SavePanel receiver: OS=\(ProcessInfo.processInfo.operatingSystemVersionString) outer=\(fixture.target.pid):\(fixture.target.windowID)")
        for budget in [0.01, 0.05, 0.25] {
            let started = ProcessInfo.processInfo.systemUptime
            let target = fixture.target.keyboardDestination(budget: budget)
            print("SavePanel resolution: budget=\(budget) elapsed=\(ProcessInfo.processInfo.systemUptime - started) receiver=\(String(describing: target?.keyboardReceiver))")
        }
        typealias Number = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return }
        let number = unsafeBitCast(symbol, to: Number.self)
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        func prepare(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(0.02, remaining))); return true
        }
        func windowID(_ element: AXUIElement) -> CGWindowID {
            var id: CGWindowID = 0
            if prepare(element) { _ = number(element, &id) }; return id
        }
        let app = AXUIElementCreateApplication(getpid())
        guard prepare(app), let windows = axValue(app, kAXWindowsAttribute) as? [AXUIElement],
              let parent = windows.first(where: { windowID($0) == CGWindowID(fixture.window.windowNumber) }) else { return }
        var pending = [(parent, 0)], count = 0
        while let (element, depth) = pending.popLast(), count < 64, prepare(element) {
            count += 1
            var raw: CFArray?, owner: pid_t = 0
            let names = [kAXRoleAttribute, kAXChildrenAttribute, kAXTopLevelUIElementAttribute]
            let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw)
            guard let values = raw as? [AnyObject], values.count == 3 else {
                print("SavePanel AX: depth=\(depth) error=\(error.rawValue)"); continue
            }
            _ = AXUIElementGetPid(element, &owner)
            var topOwner: pid_t = 0, topID: CGWindowID = 0
            if CFGetTypeID(values[2]) == AXUIElementGetTypeID() {
                let top = values[2] as! AXUIElement
                _ = AXUIElementGetPid(top, &topOwner); topID = windowID(top)
            }
            print("SavePanel AX: depth=\(depth) role=\(values[0] as? String ?? "?") owner=\(owner) window=\(windowID(element)) top=\(topOwner):\(topID)")
            if depth < 8 { pending += ((values[1] as? [AXUIElement]) ?? []).reversed().map { ($0, depth + 1) } }
        }
        print("SavePanel AX: nodes=\(count) truncated=\(!pending.isEmpty)")
    }
    func testActualSavePanelCancelUsesItsWindowServerTarget() throws {
        try XCTSkipUnless(CGPreflightPostEventAccess(), "Native input requires existing post-event permission; this test never requests it.")
        let fixture = try saveFixture(); defer { fixture.close() }
        let point = try center(fixture.cancel)
        XCTAssertEqual(DesktopInputTarget.target(at: point, excluding: []), fixture.target)
        let parent = WindowInputTarget(pid: getpid(), windowID: CGWindowID(fixture.window.windowNumber))
        XCTAssertNil(parent.button(climbingFrom: fixture.cancel, at: point))
        let injector = InputInjector(); injector.setWindowTarget(fixture.target)
        defer { injector.resetSession() }
        try click(fixture.cancel, fixture: fixture, injector: injector)
        XCTAssertEqual(fixture.response.response, .cancel)
        XCTAssertEqual(fixture.response.completions, 1)
        XCTAssertEqual(fixture.response.coveredPresses, 0)
    }
    func testActualSavePanelEscapeUsesItsLinkedKeyboardReceiver() throws {
        try XCTSkipUnless(CGPreflightPostEventAccess(), "Native input requires existing post-event permission; this test never requests it.")
        let fixture = try saveFixture(); defer { fixture.close() }
        let resolved = try XCTUnwrap(fixture.target.keyboardDestination())
        if resolved.keyboardReceiver == nil { diagnoseReceiver(fixture) }
        let receiver = try XCTUnwrap(resolved.keyboardReceiver)
        XCTAssertEqual(resolved.pid, fixture.target.pid)
        XCTAssertEqual(resolved.windowID, fixture.target.windowID)
        XCTAssertEqual(resolved.frame, fixture.target.frame)
        XCTAssertNotEqual(receiver.pid, resolved.pid)
        XCTAssertNotEqual(receiver.windowID, resolved.windowID)
        XCTAssertNil(fixture.target.keyboardDestination(budget: 0)?.keyboardReceiver)
        let injector = InputInjector(); injector.setWindowTarget(fixture.target)
        defer { injector.resetSession() }
        key("Escape", injector: injector)
        XCTAssertEqual(fixture.response.response, .cancel)
        XCTAssertEqual(fixture.response.completions, 1)
        XCTAssertEqual(fixture.response.coveredPresses, 0)
        let unrelated = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 100, height: 100),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false; unrelated.orderFrontRegardless()
        defer { unrelated.orderOut(nil); unrelated.close() }
        XCTAssertNil(WindowInputTarget(pid: getpid(), windowID: CGWindowID(unrelated.windowNumber)).keyboardDestination()?.keyboardReceiver)
        // The old virtual receiver must not outlive its validated outer sheet.
        fixture.panel.orderOut(nil); runApplication(for: 0.1)
        var posts = 0, delivery = WindowInputTarget.Delivery.system
        delivery.key = { _, _ in posts += 1 }
        _ = resolved.post(try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 7, keyDown: true)), permitted: { true }, delivery: delivery)
        XCTAssertEqual(posts, 0)
    }
    func testActualSavePanelUnicodeAndPhysicalKeyReachItsFilename() throws {
        try XCTSkipUnless(CGPreflightPostEventAccess(), "Native input requires existing post-event permission; this test never requests it.")
        let fixture = try saveFixture(); defer { fixture.close() }
        let injector = InputInjector(); injector.setWindowTarget(fixture.target)
        defer { injector.resetSession() }
        try click(fixture.filename, fixture: fixture, injector: injector)
        let unicode = "Привет é 🦊"
        var text = message("text"); text.text = unicode; injector.apply(text)
        runApplication(for: 0.5)
        let typed = try XCTUnwrap(axValue(fixture.filename, kAXValueAttribute) as? String)
        if !typed.contains(unicode) { diagnoseReceiver(fixture) }
        XCTAssertTrue(typed.contains(unicode), typed)
        key("KeyX", injector: injector)
        let physical = try XCTUnwrap(axValue(fixture.filename, kAXValueAttribute) as? String)
        XCTAssertNotEqual(physical, typed)
        XCTAssertTrue(physical.contains(unicode), physical)
        XCTAssertNil(fixture.response.response)
        XCTAssertEqual(fixture.response.coveredPresses, 0)
    }
}
