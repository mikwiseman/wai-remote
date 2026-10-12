import AppKit
import XCTest
@testable import WAIRemote

final class WindowInputTests: XCTestCase {
    func testBackgroundEventAddressesOnlyTheSelectedWindow() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                        mouseCursorPosition: CGPoint(x: 250, y: 420), mouseButton: .left))
        let cursor = CGEvent(source: nil)?.location
        try XCTSkipUnless(WindowInputTarget.isSupported)
        XCTAssertTrue(target.address(event, frame: frame))
        XCTAssertEqual(event.getIntegerValueField(.eventTargetUnixProcessID), 123)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointer), 456)
        XCTAssertEqual(event.getIntegerValueField(CGEventField(rawValue: 51)!), 456)
        XCTAssertEqual(CGEvent(source: nil)?.location, cursor, "Addressing a background event must not warp the desktop cursor.")
    }

    func testAReusedWindowNumberDoesNotGrantAccessToAnotherProcess() {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let frame = CGRect(x: 10, y: 20, width: 800, height: 600)
        let window: [String: Any] = [kCGWindowNumber as String: 456, kCGWindowOwnerPID as String: 999,
                                   kCGWindowBounds as String: frame.dictionaryRepresentation]
        XCTAssertNil(target.frame(in: [window]))
        var owned = window; owned[kCGWindowOwnerPID as String] = 123
        XCTAssertEqual(target.frame(in: [owned]), frame)
    }
}
