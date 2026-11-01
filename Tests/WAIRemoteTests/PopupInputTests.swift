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
        var onSelect: (() -> Void)?
        func menuWillOpen(_ menu: NSMenu) { opened += 1; tracking = true }
        func menuDidClose(_ menu: NSMenu) { tracking = false }
        @objc func selected(_ sender: NSPopUpButton) { selections += 1; onSelect?() }
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
    private func click(_ point: CGPoint, injector: InputInjector, modifiers: [String] = []) {
        for action in ["down", "up"] {
            var event = WireMessage(type: "pointer", state: SessionMachine(surface: .init(id: "popup-test", width: 800, height: 600)).state)
            event.action = action; event.button = 0; event.modifiers = modifiers
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
        popup.addItem(withTitle: "Disabled fixture choice"); popup.lastItem?.isEnabled = false
        popup.target = state; popup.action = #selector(MenuState.selected)
        popup.menu?.delegate = state; popup.autoenablesItems = false
        let unrelated = NSWindow(contentRect: CGRect(x: -30_000, y: -30_000, width: 250, height: 100),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        unrelated.isReleasedWhenClosed = false; unrelated.level = .popUpMenu; unrelated.orderFrontRegardless()
        let unrelatedTarget = WindowInputTarget(pid: getpid(), windowID: CGWindowID(unrelated.windowNumber))
        defer { unrelated.orderOut(nil); unrelated.close() }
        let field = NSTextField(frame: CGRect(x: 30, y: 20, width: 250, height: 24))
        window.contentView?.addSubview(field); window.contentView?.addSubview(popup)
        window.orderFrontRegardless(); window.makeFirstResponder(field)
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
        let remotePointer = RemotePointer()
        injector.excludedWindows = [remotePointer.windowID]
        defer { remotePointer.hide(); injector.resetSession() }
        state.onSelect = {
            var text = WireMessage(type: "text", state: SessionMachine(surface: .init(id: "popup-test", width: 800, height: 600)).state)
            text.text = "after-menu"; injector.apply(text)
        }
        var selected = false, positionedComparison = false, checkedComparison = false, clickedDisabled = false, clickedModifiedDisabled = false, displayedPointer = false
        var menuTarget: WindowInputTarget?
        let choose = Timer(timeInterval: 0.05, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                guard state.tracking, !selected,
                      let item = find(in: [element], matching: { value($0, kAXRoleAttribute) as? String == kAXMenuItemRole &&
                          value($0, kAXTitleAttribute) as? String == "Second fixture choice" }), let point = center(item) else { return }
                guard var target = DesktopInputTarget.target(at: point, excluding: injector.excludedWindows) else {
                    XCTFail("The menu item must have a window target"); selected = true; return
                }
                // menuWillOpen precedes the transient WindowServer window. Wait
                // for that actual window before making the one selection attempt.
                guard target.windowID != CGWindowID(window.windowNumber) else { return }
                XCTAssertEqual(target.pid, getpid())
                let menuFrame = target.frame!
                if !positionedComparison {
                    positionedComparison = true; menuTarget = target
                    let cocoaFrame = CGRect(x: menuFrame.minX, y: CGDisplayBounds(CGMainDisplayID()).maxY - menuFrame.maxY,
                                            width: menuFrame.width, height: menuFrame.height)
                    unrelated.setFrame(cocoaFrame, display: true)
                    unrelated.order(.below, relativeTo: Int(target.windowID))
                    return
                }
                if !checkedComparison {
                    guard unrelatedTarget.frame == menuTarget?.frame else { return }
                    XCTAssertNil(unrelatedTarget.button(climbingFrom: item, at: point), "An overlapping window cannot authorize a stale menu item")
                    checkedComparison = true
                    unrelated.setFrameOrigin(CGPoint(x: -30_000, y: -30_000))
                    return
                }
                guard unrelatedTarget.frame?.maxX ?? 0 < 0 else { return }
                // Moving the comparison window and hit-testing it are separate
                // WindowServer observations. Wait only for that owned window.
                guard let freshTarget = DesktopInputTarget.target(at: point, excluding: injector.excludedWindows) else {
                    XCTFail("The open menu must remain addressable"); selected = true; return
                }
                if freshTarget == unrelatedTarget { return }
                target = freshTarget
                if target != menuTarget {
                    print("POPUP_TARGET_MISMATCH hit=\(target) expected=\(String(describing: menuTarget)) comparison=\(unrelatedTarget) document=\(window.windowNumber) pointer=\(remotePointer.windowID)")
                }
                XCTAssertEqual(target, menuTarget)
                guard target == menuTarget else { selected = true; return }
                if !displayedPointer {
                    displayedPointer = true
                    let cursorX = Double((point.x - injector.bounds.minX) / (injector.bounds.width - 1))
                    let cursorY = Double((point.y - injector.bounds.minY) / (injector.bounds.height - 1))
                    remotePointer.show(InkPoint(cursorX, cursorY), on: injector.bounds)
                    return
                }
                let overlay = NSApp.windows.first { CGWindowID($0.windowNumber) == remotePointer.windowID }
                XCTAssertTrue(overlay?.isVisible ?? false)
                XCTAssertTrue(overlay?.ignoresMouseEvents ?? false)
                let action = target.button(at: point, excluding: injector.excludedWindows)
                XCTAssertNotNil(action, "The exact hit menu item must use its native Press action")
                XCTAssertTrue(action?.isMenuItem ?? false)
                XCTAssertEqual(action?.menuDocumentWindowID, CGWindowID(window.windowNumber))
                XCTAssertFalse(action?.press(if: { false }) ?? true)
                XCTAssertTrue(state.tracking, "Canceled input must leave the menu untouched")
                if let disabled = find(in: [element], matching: { value($0, kAXTitleAttribute) as? String == "Disabled fixture choice" }), let disabledPoint = center(disabled) {
                    XCTAssertNil(target.button(at: disabledPoint, excluding: injector.excludedWindows), "A disabled item cannot be pressed")
                    if !clickedDisabled {
                        clickedDisabled = true; click(disabledPoint, injector: injector)
                        return
                    }
                    if !clickedModifiedDisabled {
                        clickedModifiedDisabled = true; click(disabledPoint, injector: injector, modifiers: ["Shift"])
                        return
                    }
                    XCTAssertEqual(state.selections, 0, "Tapping the disabled item must not select it")
                } else { XCTFail("The native menu must expose its disabled item") }
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
        XCTAssertEqual(field.stringValue, "after-menu", "Typing after menu selection must return to the document without another click")
        XCTAssertEqual(try XCTUnwrap(CGEvent(source: nil)).location, pointer)
    }
}
