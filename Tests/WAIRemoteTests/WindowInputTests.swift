import AppKit
import Darwin
import XCTest
@testable import WAIRemote

final class WindowInputTests: XCTestCase {
    func testClickInActiveAppDoesNotDismissItsMenuWithAnOffWindowPrimer() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 250, y: 420), mouseButton: .left))
        var delivered: [CGEventType] = []
        let delivery = WindowInputTarget.Delivery(
            frame: { _ in CGRect(x: 100, y: 200, width: 800, height: 600) }, frontmostPID: { 123 },
            prepare: { _ in XCTFail("An active app must not be activated again") },
            pointer: { _, event in delivered.append(event.type); XCTAssertEqual(event.location, CGPoint(x: 250, y: 420)) },
            pause: { _ in XCTFail("Active-app clicks must not wait for a background activation") })
        target.post(event, permitted: { true }, delivery: delivery)
        XCTAssertEqual(delivered, [.leftMouseDown], "Exactly the user's down, with no synthetic off-window click.")
    }

    func testBackgroundClickUsesGeometryAfterActivationAndStillKeepsItsPrimer() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 250, y: 420), mouseButton: .left))
        var frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        var delivered: [CGEventType] = []
        var pauses = 0
        let delivery = WindowInputTarget.Delivery(frame: { _ in frame }, frontmostPID: { 999 },
            prepare: { _ in frame.origin = CGPoint(x: 120, y: 230) },
            pointer: { _, event in delivered.append(event.type) },
            pause: { _ in pauses += 1; frame.origin.x += 10 })
        target.post(event, permitted: { true }, delivery: delivery)
        XCTAssertEqual(delivered, [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDown])
        XCTAssertEqual(pauses, 3)
        typealias GetLocation = @convention(c) (CGEvent) -> CGPoint
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventGetWindowLocation"))
        XCTAssertEqual(unsafeBitCast(symbol, to: GetLocation.self)(event), CGPoint(x: 100, y: 190),
            "The real click must use the current window origin, including moves during the last wait.")
        XCTAssertEqual(event.location, CGPoint(x: 250, y: 420))
    }

    func testRevocationDuringActivationCannotDeliverTheRealClick() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 250, y: 420), mouseButton: .left))
        var allowed = true
        var delivered: [CGEventType] = []
        let delivery = WindowInputTarget.Delivery(frame: { _ in CGRect(x: 100, y: 200, width: 800, height: 600) },
            frontmostPID: { 999 }, prepare: { _ in }, pointer: { _, event in delivered.append(event.type) },
            pause: { _ in allowed = false })
        target.post(event, permitted: { allowed }, delivery: delivery)
        XCTAssertEqual(delivered, [.mouseMoved])
    }

    func testBackgroundEventAddressesOnlyTheSelectedWindow() throws {
        let target = WindowInputTarget(pid: 123, windowID: 456)
        let frame = CGRect(x: 100, y: 200, width: 800, height: 600)
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                        mouseCursorPosition: CGPoint(x: 250, y: 420), mouseButton: .left))
        let cursor = CGEvent(source: nil)?.location
        try XCTSkipUnless(WindowInputTarget.isSupported)
        event.setIntegerValueField(CGEventField(rawValue: 58)!, value: 987)
        XCTAssertTrue(target.address(event, frame: frame))
        XCTAssertEqual(event.getIntegerValueField(.eventTargetUnixProcessID), 123)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventWindowUnderMousePointer), 456)
        XCTAssertEqual(event.getIntegerValueField(CGEventField(rawValue: 51)!), 456)
        XCTAssertEqual(event.getIntegerValueField(.mouseEventSubtype), 3,
                       "Background pointer delivery must carry Chromium's accepted touch subtype.")
        XCTAssertEqual(event.getIntegerValueField(CGEventField(rawValue: 58)!), 987,
                       "The target down/up pair must keep the same gesture as its background primer.")
        XCTAssertEqual(event.getIntegerValueField(.mouseEventNumber), 3)
        typealias GetLocation = @convention(c) (CGEvent) -> CGPoint
        let symbol = try XCTUnwrap(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventGetWindowLocation"))
        let location = unsafeBitCast(symbol, to: GetLocation.self)(event)
        XCTAssertEqual(location, CGPoint(x: 150, y: 220),
                       "The target window origin must be subtracted exactly once; Chrome otherwise receives the origin twice.")
        XCTAssertEqual(event.location, CGPoint(x: 250, y: 420), "Global event location stays in screen coordinates.")
        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        key.flags = .maskCommand
        let keyLocation = unsafeBitCast(symbol, to: GetLocation.self)(key)
        XCTAssertTrue(target.address(key, frame: frame))
        XCTAssertEqual(unsafeBitCast(symbol, to: GetLocation.self)(key), keyLocation,
                       "Keyboard events are window-addressed, but must not receive mouse coordinates.")
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
