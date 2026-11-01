import AppKit
import Darwin
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
}
