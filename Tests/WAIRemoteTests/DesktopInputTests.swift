import AppKit
import XCTest
@testable import WAIRemote

final class DesktopInputTests: XCTestCase {
    private let first = WindowInputTarget(pid: 101, windowID: 11)
    private let second = WindowInputTarget(pid: 202, windowID: 22)
    private let point = CGPoint(x: 240, y: 180)
    private func window(_ target: WindowInputTarget, alpha: Double = 1) -> [String: Any] {
        [kCGWindowNumber as String: target.windowID, kCGWindowOwnerPID as String: target.pid,
         kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: CGRect(x: 100, y: 100, width: 400, height: 300).dictionaryRepresentation]
    }

    func testTheHitWindowReceivesInputEvenWithAFullScreenTransparentDockAboveIt() {
        let windows = [window(first), window(second)]
        XCTAssertEqual(DesktopInputTarget.target(windowID: 22, windows: windows), second)
        XCTAssertNil(DesktopInputTarget.target(windowID: 11, windows: windows, excluding: [11]))
        XCTAssertNil(DesktopInputTarget.target(windowID: 0, windows: windows))
        XCTAssertNil(DesktopInputTarget.target(windowID: 33, windows: windows))
    }

    func testUnaddressableTopWindowBlocksClicksInsteadOfClickingThrough() {
        var overlay = window(first); overlay[kCGWindowOwnerPID as String] = 0
        XCTAssertNil(DesktopInputTarget.target(windowID: 11, windows: [overlay, window(second)]))
    }

    func testDragAndReleaseStayWithTheOriginalAppAfterCrossingAnotherWindow() {
        var routing = DesktopInputTarget()
        XCTAssertEqual(routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in self.first }), first)
        XCTAssertEqual(routing.pointer(action: "move", button: 0, at: point, hitTest: { _ in self.second }), first)
        XCTAssertEqual(routing.pointer(action: "up", button: 0, at: point, hitTest: { _ in self.second }), first)
        XCTAssertEqual(routing.pointer(action: "move", button: 0, at: point, hitTest: { _ in self.second }), second)
        XCTAssertEqual(routing.keyboardTarget, first, "Hovering must not redirect typing.")
        XCTAssertEqual(routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in self.second }), second)
        XCTAssertEqual(routing.keyboardTarget, second)
    }

    func testASecondHeldButtonDoesNotEndTheFirstGesture() {
        var routing = DesktopInputTarget()
        _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in self.first })
        _ = routing.pointer(action: "down", button: 2, at: point, hitTest: { _ in self.second })
        _ = routing.pointer(action: "up", button: 0, at: point, hitTest: { _ in self.second })
        XCTAssertEqual(routing.pointer(action: "move", button: 2, at: point, hitTest: { _ in self.second }), first)
        XCTAssertEqual(routing.pointer(action: "up", button: 2, at: point, hitTest: { _ in self.second }), first)
    }

    func testPressingEmptySpaceDoesNotStartADragInAnAppEnteredLater() {
        var routing = DesktopInputTarget()
        _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in nil })
        XCTAssertNil(routing.pointer(action: "move", button: 0, at: point, hitTest: { _ in self.first }))
        XCTAssertNil(routing.pointer(action: "up", button: 0, at: point, hitTest: { _ in self.first }))
        XCTAssertNil(routing.keyboardTarget)
    }

    func testReleaseClearsTypingDestinationAndAnyHeldGesture() {
        var routing = DesktopInputTarget()
        _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in self.first })
        routing.reset()
        XCTAssertNil(routing.keyboardTarget)
        XCTAssertEqual(routing.pointer(action: "move", button: 0, at: point, hitTest: { _ in self.second }), second)
    }
}
