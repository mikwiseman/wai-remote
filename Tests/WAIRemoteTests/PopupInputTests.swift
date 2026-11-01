import AppKit
import Darwin
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class PopupInputTests: XCTestCase {
    @MainActor private final class MenuState: NSObject, NSMenuDelegate {
        var opened = 0
        var tracking = false
        var selections = 0
        func menuWillOpen(_ menu: NSMenu) { opened += 1; tracking = true }
        func menuDidClose(_ menu: NSMenu) { tracking = false }
        @objc func selected(_ sender: NSPopUpButton) { selections += 1 }
    }
    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.02)
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success ? raw : nil
    }
    private func find(in roots: [AXUIElement], matching: (AXUIElement) -> Bool) -> AXUIElement? {
        var pending = roots, visited = 0
        while let element = pending.popLast(), visited < 64 {
            visited += 1
            if matching(element) { return element }
            pending += (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return nil
    }
    private func center(_ element: AXUIElement) -> CGPoint? {
        guard let rawPosition = value(element, kAXPositionAttribute), let rawSize = value(element, kAXSizeAttribute),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &point),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
    }
    private func click(_ point: CGPoint, injector: InputInjector) {
        for action in ["down", "up"] {
            var event = WireMessage(type: "pointer", state: SessionMachine(surface: .init(id: "popup-test", width: 800, height: 600)).state)
            event.action = action; event.button = 0
            event.x = (point.x - injector.bounds.minX) / max(1, injector.bounds.width - 1)
            event.y = (point.y - injector.bounds.minY) / max(1, injector.bounds.height - 1)
            injector.apply(event)
        }
    }
    func testDesktopClickOpensNativePopupAndSelectsItsItemWithoutMovingThePhysicalPointer() throws {
        try XCTSkipUnless(CGPreflightPostEventAccess(), "Native input requires existing post-event permission; this test never requests it.")
        let previous = NSWorkspace.shared.frontmostApplication
        NSApplication.shared.setActivationPolicy(.regular); NSApp.finishLaunching()
        let window = NSWindow(contentRect: CGRect(x: 100, y: 120, width: 350, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "WAI Remote popup test"; window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let state = MenuState()
        let popup = NSPopUpButton(frame: CGRect(x: 30, y: 70, width: 250, height: 30), pullsDown: false)
        popup.identifier = .init("wai-popup-fixture"); popup.addItems(withTitles: ["First fixture choice", "Second fixture choice"])
        popup.target = state; popup.action = #selector(MenuState.selected)
        popup.menu?.delegate = state; popup.autoenablesItems = false
        window.contentView?.addSubview(popup); window.orderFrontRegardless()
        defer {
            popup.menu?.cancelTrackingWithoutAnimation(); window.orderOut(nil); window.close()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), previous?.processIdentifier != getpid() {
                _ = previous?.activate(options: [])
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let windows = try XCTUnwrap(value(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute) as? [AXUIElement])
        let element = try XCTUnwrap(find(in: windows) { value($0, kAXIdentifierAttribute) as? String == "wai-popup-fixture" })
        XCTAssertEqual(value(element, kAXRoleAttribute) as? String, kAXPopUpButtonRole)
        let point = try XCTUnwrap(center(element))
        XCTAssertEqual(DesktopInputTarget.target(at: point, excluding: [])?.windowID, CGWindowID(window.windowNumber))
        let pointer = try XCTUnwrap(CGEvent(source: nil)).location
        let injector = InputInjector(); injector.setIndependentPointer(true)
        defer { injector.resetSession() }
        var selected = false
        let choose = Timer(timeInterval: 0.05, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                guard state.tracking, !selected,
                      let item = find(in: [element], matching: { value($0, kAXRoleAttribute) as? String == kAXMenuItemRole &&
                          value($0, kAXTitleAttribute) as? String == "Second fixture choice" }), let point = center(item) else { return }
                guard let target = DesktopInputTarget.target(at: point, excluding: []) else {
                    XCTFail("The menu item must have a window target"); selected = true; return
                }
                XCTAssertEqual(target.pid, getpid())
                XCTAssertEqual(target.windowID, CGWindowID(window.windowNumber))
                let action = target.button(at: point)
                XCTAssertNotNil(action, "The exact hit menu item must use its native Press action")
                XCTAssertFalse(action?.press(if: { false }) ?? true)
                XCTAssertTrue(state.tracking, "Canceled input must leave the menu untouched")
                selected = true; click(point, injector: injector)
            }
        }
        let cancel = Timer(timeInterval: 1.8, repeats: false) { _ in MainActor.assumeIsolated { popup.menu?.cancelTrackingWithoutAnimation() } }
        let stop = Timer(timeInterval: 2, repeats: false) { _ in
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        for timer in [choose, cancel, stop] { RunLoop.main.add(timer, forMode: .common) }
        defer { for timer in [choose, cancel, stop] { timer.invalidate() } }
        click(point, injector: injector); NSApp.run()
        XCTAssertEqual(state.opened, 1)
        XCTAssertTrue(selected, "The open menu must expose its actual item before the bounded cleanup.")
        XCTAssertEqual(popup.indexOfSelectedItem, 1)
        XCTAssertEqual(state.selections, 1)
        XCTAssertEqual(try XCTUnwrap(CGEvent(source: nil)).location, pointer)
    }
}
