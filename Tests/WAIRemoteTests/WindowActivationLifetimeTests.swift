import AppKit
import XCTest
@testable import WAIRemote

@MainActor
final class WindowActivationLifetimeTests: XCTestCase {
    private final class NumberedWindow: NSWindow {
        let number: Int
        override var windowNumber: Int { number }
        init(_ number: Int) {
            self.number = number
            super.init(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
            isReleasedWhenClosed = false
        }
    }

    func testUnallocatedWindowDoesNotHideTheSelectedWindowOrTrap() throws {
        _ = NSApplication.shared
        let deferred = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        deferred.isReleasedWhenClosed = false
        let selected = NumberedWindow(77)
        XCTAssertEqual(deferred.windowNumber, -1, "An allocated NSWindow need not have a WindowServer ID")
        XCTAssertFalse(deferred.isVisible)
        XCTAssertTrue(WindowInputTarget.ownWindow(matching: 77, in: [deferred, selected]) === selected)
    }

    func testInvalidNumbersCannotAliasAnotherWindow() {
        _ = NSApplication.shared
        let negative = NumberedWindow(-1), zero = NumberedWindow(0), oversized = NumberedWindow(Int.max)
        let largest = NumberedWindow(Int(CGWindowID.max))
        XCTAssertTrue(WindowInputTarget.ownWindow(matching: .max, in: [oversized, negative, zero, largest]) === largest)
        XCTAssertNil(WindowInputTarget.ownWindow(matching: 17, in: [negative, zero, oversized]))
    }
}
