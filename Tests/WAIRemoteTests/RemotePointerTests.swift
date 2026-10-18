import AppKit
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class RemotePointerTests: XCTestCase {
    func testMovingTheSecondPointerDoesNotMoveItsWindowOrTheOwnersCursor() throws {
        _ = NSApplication.shared
        let pointer = RemotePointer()
        let cursor = CGEvent(source: nil)?.location
        let keyWindow = NSApp.keyWindow
        let display = CGRect(x: 80, y: 100, width: 640, height: 480)
        pointer.show(InkPoint(0.1, 0.2), on: display)
        defer { pointer.hide() }
        let panel = try XCTUnwrap(NSApp.window(withWindowNumber: Int(pointer.windowID)))
        let initialFrame = panel.frame
        let layer = try XCTUnwrap(panel.contentView?.layer?.sublayers?.first as? CAShapeLayer)
        let initialPoint = layer.position
        pointer.show(InkPoint(0.9, 0.8), on: display)

        XCTAssertEqual(panel.frame, initialFrame, "Hover packets must not move or resize an AppKit backing store.")
        XCTAssertNotEqual(layer.position, initialPoint)
        XCTAssertEqual(layer.position.x + 3, 0.9 * 639, accuracy: 0.001)
        XCTAssertEqual(layer.position.y + 2, 0.8 * 479, accuracy: 0.001)
        XCTAssertTrue(layer.animationKeys()?.isEmpty ?? true, "The second pointer must not animate behind input.")
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
        XCTAssertEqual(CGEvent(source: nil)?.location, cursor)
    }

    func testPointerOverlayDoesNotBecomeAnInputDestination() async throws {
        _ = NSApplication.shared
        let window = NSPanel(contentRect: NSRect(x: 120, y: 180, width: 360, height: 260),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        let target = WindowInputTarget(pid: ProcessInfo.processInfo.processIdentifier, windowID: CGWindowID(window.windowNumber))
        // AppKit commits a newly ordered window to WindowServer at the end of
        // the run-loop pass; the geometric lookup must observe that commit.
        try await Task.sleep(for: .milliseconds(40))
        let frame = try XCTUnwrap(target.frame)
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let pointer = RemotePointer()
        pointer.show(InkPoint(0.5, 0.5), on: frame)
        defer { pointer.hide() }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(DesktopInputTarget.target(at: point, excluding: [pointer.windowID]), target)
    }
}
