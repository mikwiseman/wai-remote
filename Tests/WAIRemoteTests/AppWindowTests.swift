import AppKit
import XCTest
import RemoteCore
@testable import WAIRemote

@MainActor
final class AppWindowTests: XCTestCase {
    private func windows() -> AppDelegate {
        _ = NSApplication.shared
        let delegate = AppDelegate()
        delegate.viewer = MacViewerModel(identity: DeviceIdentity())
        for isViewer in [false, true] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            if isViewer { delegate.viewerWindow = window } else { delegate.window = window }
        }
        return delegate
    }

    func testReopenReturnsToTheExistingConnection() {
        let delegate = windows()
        defer { delegate.window.close(); delegate.viewerWindow?.close() }
        delegate.viewer.connected = true
        let existing = delegate.viewerWindow

        let letAppKitReopenOtherWindows = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)

        XCTAssertTrue(delegate.viewerWindow === existing)
        XCTAssertTrue(delegate.viewerWindow?.isVisible == true)
        XCTAssertFalse(delegate.window.isVisible)
        XCTAssertTrue(delegate.viewer.connected)
        XCTAssertFalse(letAppKitReopenOtherWindows)
    }

    func testReopenDuringConnectionShowsItsProgress() {
        let delegate = windows()
        defer { delegate.window.close(); delegate.viewerWindow?.close() }
        delegate.viewer.connecting = true
        delegate.showWindow()
        XCTAssertTrue(delegate.viewerWindow?.isVisible == true)
        XCTAssertFalse(delegate.window.isVisible)
        XCTAssertTrue(delegate.viewer.connecting)
    }

    func testReopenWithoutConnectionShowsHome() {
        let delegate = windows()
        defer { delegate.window.close(); delegate.viewerWindow?.close() }
        delegate.showWindow()
        XCTAssertTrue(delegate.window.isVisible)
        XCTAssertFalse(delegate.viewerWindow?.isVisible == true)
    }

    func testMainMenuOffersHideAndHomeWithoutDisconnecting() throws {
        let delegate = windows()
        let oldMenu = NSApp.mainMenu, oldWindowsMenu = NSApp.windowsMenu
        defer {
            delegate.window.close(); delegate.viewerWindow?.close()
            if let status = delegate.statusItem { NSStatusBar.system.removeStatusItem(status) }
            NSApp.mainMenu = oldMenu; NSApp.windowsMenu = oldWindowsMenu
        }
        delegate.viewer.connected = true
        delegate.makeMenus()
        let appMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        let hide = try XCTUnwrap(appMenu.items.first { $0.keyEquivalent == "h" && $0.keyEquivalentModifierMask == .command })
        XCTAssertEqual(hide.action, #selector(NSApplication.hide(_:)))
        XCTAssertTrue(hide.target === NSApp)
        XCTAssertEqual(appMenu.items.first { $0.keyEquivalent == "," }?.action, #selector(AppDelegate.diagnostics))
        let home = try XCTUnwrap(NSApp.windowsMenu?.items.first { $0.keyEquivalent == "0" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(home.action), to: home.target, from: home))
        XCTAssertTrue(delegate.window.isVisible)
        XCTAssertTrue(delegate.viewer.connected)
    }

    func testReopenRestoresMinimizedViewer() {
        let delegate = windows()
        defer { delegate.window.close(); delegate.viewerWindow?.close() }
        delegate.viewer.connected = true
        delegate.viewerWindow?.makeKeyAndOrderFront(nil)
        delegate.viewerWindow?.miniaturize(nil)
        delegate.showWindow()
        XCTAssertFalse(delegate.viewerWindow?.isMiniaturized == true)
        XCTAssertTrue(delegate.viewerWindow?.isVisible == true)
    }
}
