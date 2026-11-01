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

    func testVisualPointerAndInkAreSkippedWithoutSkippingAnotherApplicationsWindow() {
        var queries: [CGWindowID] = []
        let hit = DesktopInputTarget.hitWindow(excluding: [90, 91]) { below in
            queries.append(below)
            return [0: 90, 90: 91, 91: 22][below]
        }
        XCTAssertEqual(hit, 22)
        XCTAssertEqual(queries, [0, 90, 91], "Look below our visual overlays using WindowServer's actual input regions.")
        queries = []
        XCTAssertEqual(DesktopInputTarget.hitWindow(excluding: [90]) { below in
            queries.append(below); return 11
        }, 11)
        XCTAssertEqual(queries, [0], "An unrelated window must block the hit even if it cannot receive remote input.")
    }

    func testRepeatedOrMissingOverlayHitCannotLoopOrInventATarget() {
        var queries = 0
        XCTAssertNil(DesktopInputTarget.hitWindow(excluding: [90]) { _ in queries += 1; return 90 })
        XCTAssertLessThanOrEqual(queries, 2)
        XCTAssertNil(DesktopInputTarget.hitWindow(excluding: []) { _ in nil })
        XCTAssertNil(DesktopInputTarget.hitWindow(excluding: []) { _ in 0 })
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

    func testLiftingHeldInputKeepsTypingDestinationAndOnlyResetForgetsIt() {
        var routing = DesktopInputTarget()
        _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in self.first })
        routing.liftHeld()
        XCTAssertEqual(routing.keyboardTarget, first, "A stall or focus change must not drop the next paste.")
        XCTAssertEqual(routing.pointer(action: "move", button: 0, at: point, hitTest: { _ in self.second }), second)
        routing.reset()
        XCTAssertNil(routing.keyboardTarget)
    }

    func testMenuSelectionPreservesItsProvenDocumentWhileItsGestureStaysPinned() {
        var routing = DesktopInputTarget()
        let menu = WindowInputTarget(pid: first.pid, windowID: 33)
        _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in self.first })
        _ = routing.pointer(action: "up", button: 0, at: point, hitTest: { _ in self.first })
        _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in menu })
        routing.preserveKeyboardTargetForMenu(document: first)
        XCTAssertEqual(routing.keyboardTarget, first)
        XCTAssertEqual(routing.pointer(action: "move", button: 0, at: point, hitTest: { _ in self.second }), menu)
        XCTAssertEqual(routing.pointer(action: "up", button: 0, at: point, hitTest: { _ in self.second }), menu)
        XCTAssertEqual(routing.keyboardTarget, first, "Closing the menu must not strand subsequent typing on its transient window.")
    }

    func testForeignServiceMenuKeepsTypingInItsProvenOriginalDocument() {
        var routing = DesktopInputTarget()
        let serviceMenu = WindowInputTarget(pid: 303, windowID: 33)
        _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in self.first })
        _ = routing.pointer(action: "up", button: 0, at: point, hitTest: { _ in self.first })
        _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in serviceMenu })
        routing.preserveKeyboardTargetForMenu(document: first)
        XCTAssertEqual(routing.keyboardTarget, first, "The menu service PID must not replace the proven document owner")
        XCTAssertEqual(routing.pointer(action: "move", button: 0, at: point, hitTest: { _ in self.second }), serviceMenu)
        XCTAssertEqual(routing.pointer(action: "up", button: 0, at: point, hitTest: { _ in self.second }), serviceMenu)
        XCTAssertEqual(routing.keyboardTarget, first)
    }

    func testMenuCannotReuseAnUnrelatedOrUnprovenKeyboardTarget() {
        let cases: [WindowInputTarget?] = [WindowInputTarget(pid: first.pid, windowID: 99),
            WindowInputTarget(pid: second.pid, windowID: first.windowID), nil]
        for document in cases {
            var routing = DesktopInputTarget()
            _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in self.first })
            _ = routing.pointer(action: "up", button: 0, at: point, hitTest: { _ in self.first })
            _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in WindowInputTarget(pid: 303, windowID: 33) })
            routing.preserveKeyboardTargetForMenu(document: document)
            XCTAssertNil(routing.keyboardTarget, "A same-app different document, foreign app, or missing parent proof cannot redirect typing.")
        }
    }

    func testMenuOnlySessionAndResetCannotInventADocumentTarget() {
        var routing = DesktopInputTarget()
        let menu = WindowInputTarget(pid: first.pid, windowID: 33)
        _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in menu })
        routing.preserveKeyboardTargetForMenu(document: first)
        XCTAssertNil(routing.keyboardTarget)
        _ = routing.pointer(action: "up", button: 0, at: point, hitTest: { _ in menu })
        _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in self.first })
        routing.reset()
        _ = routing.pointer(action: "down", button: 0, at: point, hitTest: { _ in menu })
        routing.preserveKeyboardTargetForMenu(document: first)
        XCTAssertNil(routing.keyboardTarget)
    }
}
