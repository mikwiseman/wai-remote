import AppKit
import XCTest
@testable import WAIRemote

@MainActor
final class HostedInputTests: XCTestCase {
    private func pump(_ duration: TimeInterval) {
        let stop = Timer(timeInterval: duration, repeats: false) { _ in
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        RunLoop.main.add(stop, forMode: .common); NSApp.run(); stop.invalidate()
    }
    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.05)
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success ? raw : nil
    }
    private func cancel(in app: AXUIElement, identifier: String = "CancelButton") -> AXUIElement? {
        var pending = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [], count = 0
        while let element = pending.popLast(), count < 128 {
            count += 1
            if value(element, kAXIdentifierAttribute) as? String == identifier { return element }
            pending += (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return nil
    }
    private func center(_ element: AXUIElement) throws -> CGPoint {
        let position = try XCTUnwrap(value(element, kAXPositionAttribute))
        let size = try XCTUnwrap(value(element, kAXSizeAttribute))
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent), extent.width > 0, extent.height > 0 else {
            throw NSError(domain: "HostedFixtureNotLaidOut", code: 1)
        }
        return CGPoint(x: point.x + extent.width / 2, y: point.y + extent.height / 2)
    }
    func testAmbiguousContainingRemoteBranchesAreRejected() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "Requires existing Accessibility permission")
        let app = NSApplication.shared, previousPolicy = NSApplication.shared.activationPolicy()
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: 300, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close(); app.setActivationPolicy(previousPolicy) }
        for name in ["hosted-first", "hosted-overlay"] {
            let button = NSButton(frame: CGRect(x: 20, y: 20, width: 180, height: 40))
            button.title = name; button.setAccessibilityIdentifier(name)
            window.contentView?.addSubview(button)
        }
        window.orderFrontRegardless(); pump(0.05)
        let element = AXUIElementCreateApplication(getpid())
        let first = try XCTUnwrap(cancel(in: element, identifier: "hosted-first"))
        let overlay = try XCTUnwrap(cancel(in: element, identifier: "hosted-overlay"))
        let point = try center(first)
        XCTAssertNil(WindowInputTarget.singleContainingChild([first, overlay], at: point,
                                                             deadline: ProcessInfo.processInfo.systemUptime + 0.05))
        let single = try XCTUnwrap(WindowInputTarget.singleContainingChild([first], at: point,
                                                                          deadline: ProcessInfo.processInfo.systemUptime + 0.05))
        XCTAssertTrue(CFEqual(first, single))
    }
    func testStandaloneSavePanelResolvesAndPressesItsHostedCancelControl() throws {
        try XCTSkipUnless(AXIsProcessTrusted(), "Requires existing Accessibility permission; never requests access")
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy(), previous = NSWorkspace.shared.frontmostApplication
        app.setActivationPolicy(.regular); pump(0.01)
        let panel = NSSavePanel()
        panel.directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        panel.nameFieldStringValue = "WAI owned hosted control test.txt"
        panel.canCreateDirectories = false; panel.animationBehavior = .none
        var response: NSApplication.ModalResponse?, completions = 0
        panel.begin { response = $0; completions += 1 }
        panel.center(); panel.orderFrontRegardless()
        defer {
            if response == nil { panel.cancel(nil) }; panel.orderOut(nil)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), previous?.processIdentifier != getpid() {
                _ = previous?.activate(options: [])
            }
            app.setActivationPolicy(previousPolicy)
        }
        let element = AXUIElementCreateApplication(getpid())
        let target = WindowInputTarget(pid: getpid(), windowID: CGWindowID(panel.windowNumber))
        let ready = Date().addingTimeInterval(5)
        var control: AXUIElement?
        repeat {
            pump(0.05)
            if let candidate = cancel(in: element), let point = try? center(candidate),
               target.frame?.contains(point) == true, CGDisplayBounds(CGMainDisplayID()).contains(point) {
                control = candidate
            }
        } while control == nil && Date() < ready
        let cancel = try XCTUnwrap(control)
        let point = try center(cancel)
        var hit: AXUIElement?
        XCTAssertEqual(AXUIElementCopyElementAtPosition(element, Float(point.x), Float(point.y), &hit), .success)
        let actualHit = try XCTUnwrap(hit)
        XCTAssertEqual(value(actualHit, kAXRoleAttribute) as? String, kAXWindowRole)
        XCTAssertEqual(WindowInputTarget.axWindowID(actualHit, deadline: ProcessInfo.processInfo.systemUptime + 0.05), target.windowID)
        let unrelated = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false; unrelated.orderFrontRegardless()
        unrelated.order(.below, relativeTo: panel.windowNumber); pump(0.05)
        defer { unrelated.orderOut(nil); unrelated.close() }
        let otherTarget = WindowInputTarget(pid: getpid(), windowID: CGWindowID(unrelated.windowNumber))
        XCTAssertTrue(try XCTUnwrap(otherTarget.frame).contains(point))
        XCTAssertNil(otherTarget.button(at: point), "A different selected window cannot borrow this remote control")
        let action = try XCTUnwrap(target.button(at: point), "A real hosted control must be reachable from the app-scoped point hit")
        XCTAssertFalse(action.press(if: { false }))
        XCTAssertNil(response); XCTAssertEqual(completions, 0)
        XCTAssertTrue(action.press(if: { true }))
        pump(0.1)
        XCTAssertEqual(response, .cancel)
        XCTAssertEqual(completions, 1)
        XCTAssertNil(target.button(at: point), "A closed host cannot authorize its former remote control")
        print("HOSTED_PROOF standaloneXPC=true cancelledInputRejected=true unrelatedWindowRejected=true completions=\(completions)")
    }
}
