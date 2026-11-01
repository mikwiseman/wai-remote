import AppKit
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class ScrollInjectionTests: XCTestCase {
    private func native(_ event: CGEvent?) throws -> NSEvent { try XCTUnwrap(NSEvent(cgEvent: XCTUnwrap(event))) }
    private func message(_ dx: Double, _ dy: Double, phase: String? = "changed", momentum: String? = nil) -> WireMessage {
        var message = WireMessage(type: "pointer", state: SessionMachine(surface: .init(id: "display", width: 800, height: 600)).state)
        message.sessionID = "same-session"
        message.action = "scroll"; message.x = 0.5; message.y = 0.5
        message.deltaX = dx; message.deltaY = dy; message.scrollPhase = phase; message.momentumPhase = momentum
        return message
    }
    private func message(_ dy: Double, phase: String? = "changed", momentum: String? = nil) -> WireMessage {
        message(0, dy, phase: phase, momentum: momentum)
    }
    func testNativePhasesIncludeZeroDistanceBeginEndAndCancel() throws {
        var builder = ScrollEventBuilder()
        let begin = try native(builder.event(deltaX: 0, deltaY: 0, scrollPhase: "began"))
        XCTAssertTrue(begin.hasPreciseScrollingDeltas)
        XCTAssertEqual(begin.phase, .began)
        XCTAssertEqual(begin.scrollingDeltaY, 0)
        let changed = try native(builder.event(deltaX: 2, deltaY: -3, scrollPhase: "changed"))
        XCTAssertEqual(changed.phase, .changed)
        XCTAssertEqual(changed.scrollingDeltaX, -2); XCTAssertEqual(changed.scrollingDeltaY, 3)
        XCTAssertEqual(try native(builder.event(deltaX: 0, deltaY: 0, scrollPhase: "ended")).phase, .ended)
        _ = builder.event(deltaX: 0, deltaY: 0, scrollPhase: "began")
        XCTAssertEqual(try native(builder.event(deltaX: 0, deltaY: 0, scrollPhase: "cancelled")).phase, .cancelled)
    }
    func testNativeMomentumUsesItsOwnPhaseValuesAndZeroDistanceEnd() throws {
        var builder = ScrollEventBuilder()
        _ = builder.event(deltaX: 0, deltaY: 0, scrollPhase: "began")
        _ = builder.event(deltaX: 0, deltaY: 0, scrollPhase: "ended")
        for (phase, expected): (String, NSEvent.Phase) in [("began", .began), ("changed", .changed), ("ended", .ended)] {
            let event = try native(builder.event(deltaX: 0, deltaY: phase == "ended" ? 0 : 2, momentumPhase: phase))
            XCTAssertEqual(event.phase, [])
            XCTAssertEqual(event.momentumPhase, expected)
        }
    }
    func testFractionalDistanceSurvivesSamplesAndTheTouchToMomentumTransition() throws {
        var builder = ScrollEventBuilder()
        _ = builder.event(deltaX: 0, deltaY: 0, scrollPhase: "began")
        var x = 0.0, y = 0.0
        for _ in 0..<100 {
            if let event = builder.event(deltaX: 0.25, deltaY: -0.125, scrollPhase: "changed") {
                let native = try native(event); x += native.scrollingDeltaX; y += native.scrollingDeltaY
            }
        }
        _ = builder.event(deltaX: 0, deltaY: 0, scrollPhase: "ended")
        let tail = try native(builder.event(deltaX: 0, deltaY: -0.5, momentumPhase: "began"))
        y += tail.scrollingDeltaY
        XCTAssertEqual(x, -25); XCTAssertEqual(y, 13)
        _ = builder.event(deltaX: 0, deltaY: 0, momentumPhase: "ended")
        _ = builder.event(deltaX: 0, deltaY: 0, scrollPhase: "began")
        XCTAssertNil(builder.event(deltaX: 0, deltaY: -0.5, scrollPhase: "changed"), "The next gesture starts with no old remainder.")
    }
    func testReleaseTerminatesTheActiveNativeGestureOnlyOnce() throws {
        var builder = ScrollEventBuilder()
        _ = builder.event(deltaX: 0, deltaY: 1, scrollPhase: "began")
        XCTAssertEqual(try native(builder.finish()).phase, .cancelled)
        XCTAssertNil(builder.finish())
        _ = builder.event(deltaX: 0, deltaY: 1, momentumPhase: "began")
        XCTAssertEqual(try native(builder.finish()).momentumPhase, .ended)
        XCTAssertNil(builder.finish())
    }
    func testLegacyPixelScrollKeepsItsExistingNativeSemantics() throws {
        var builder = ScrollEventBuilder()
        let event = try native(builder.event(deltaX: -3, deltaY: 2))
        XCTAssertTrue(event.hasPreciseScrollingDeltas)
        XCTAssertEqual(event.scrollingDeltaX, 3); XCTAssertEqual(event.scrollingDeltaY, -2)
        XCTAssertEqual(event.phase, []); XCTAssertEqual(event.momentumPhase, [])
        XCTAssertNil(builder.event(deltaX: 0, deltaY: 0))
        XCTAssertNil(builder.finish())
    }
    func testIndependentScrollKeepsItsWindowThroughMomentumAndNeverFallsThrough() {
        var routing = DesktopInputTarget()
        let a = WindowInputTarget(pid: 101, windowID: 11), b = WindowInputTarget(pid: 202, windowID: 22)
        let point = CGPoint(x: 40, y: 40)
        XCTAssertEqual(routing.scroll(at: point, phase: "began", momentum: nil, hitTest: { _ in a }), a)
        for (phase, momentum): (String?, String?) in [("changed", nil), ("ended", nil), (nil, "began"), (nil, "changed"), (nil, "ended")] {
            XCTAssertEqual(routing.scroll(at: point, phase: phase, momentum: momentum, hitTest: { _ in
                XCTFail("A live gesture must not select a new window."); return b
            }), a)
        }
        XCTAssertEqual(routing.scroll(at: point, phase: "began", momentum: nil, hitTest: { _ in b }), b)
        routing.liftHeld()
        XCTAssertNil(routing.scroll(at: point, phase: "changed", momentum: nil, hitTest: { _ in a }))
        XCTAssertNil(routing.scroll(at: point, phase: "began", momentum: nil, hitTest: { _ in nil }))
        XCTAssertNil(routing.scroll(at: point, phase: "changed", momentum: nil, hitTest: { _ in a }))
        XCTAssertEqual(routing.scroll(at: point, phase: nil, momentum: nil, hitTest: { _ in a }), a)
    }
    func testBlockedScrollBurstPreservesDistanceWithBoundedDeliveryBeforeAKey() async {
        let delivery = InputDeliveryQueue(), entered = expectation(description: "Input blocked")
        let finished = expectation(description: "Key delivered"), resume = DispatchSemaphore(value: 0)
        delivery.submit { _ in entered.fulfill(); _ = resume.wait(timeout: .now() + 2) }
        await fulfillment(of: [entered], timeout: 1)
        var deltas: [(Double, Double)] = [], order: [String] = []
        for _ in 0..<100 {
            delivery.submitScroll(message(0.25, -0.125)) { message, _ in
                deltas.append((message.deltaX!, message.deltaY!)); order.append("scroll")
            }
        }
        delivery.submit { _ in order.append("key"); finished.fulfill() }
        resume.signal()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(deltas.count, 1, "Pending updates must not retain one delivery closure per packet.")
        XCTAssertEqual(deltas.reduce(0) { $0 + $1.0 }, 25)
        XCTAssertEqual(deltas.reduce(0) { $0 + $1.1 }, -12.5)
        XCTAssertEqual(order, ["scroll", "key"])
    }
    func testScrollMergingPreservesDirectionPhaseAndSessionBoundaries() async {
        let delivery = InputDeliveryQueue(), entered = expectation(description: "Input blocked")
        let finished = expectation(description: "Input delivered"), resume = DispatchSemaphore(value: 0)
        delivery.submit { _ in entered.fulfill(); _ = resume.wait(timeout: .now() + 2) }
        await fulfillment(of: [entered], timeout: 1)
        var batch: [WireMessage] = []
        var messages = [message(1), message(1), message(-1), message(-1), message(0, phase: "ended"), message(0, phase: "began"), message(1)]
        var newEpoch = message(1); newEpoch.inputEpoch += 1
        var newSession = message(1); newSession.sessionID = "new-session"
        var newTarget = message(1); newTarget.x = 0.7
        var newModifiers = message(1); newModifiers.modifiers = ["Shift"]
        messages += [newEpoch, newSession, newTarget, newModifiers]
        for message in messages { delivery.submitScroll(message) { message, _ in batch.append(message) } }
        delivery.submit { _ in finished.fulfill() }; resume.signal()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(batch.compactMap(\.deltaY), [2, -2, 0, 0, 1, 1, 1, 1, 1])
    }
    func testCancellationDiscardsThePendingScrollBatchBeforeNewSessionInput() async {
        let delivery = InputDeliveryQueue(), entered = expectation(description: "Input blocked")
        let finished = expectation(description: "New session"), resume = DispatchSemaphore(value: 0)
        delivery.submit { _ in entered.fulfill(); _ = resume.wait(timeout: .now() + 2) }
        await fulfillment(of: [entered], timeout: 1)
        var order: [String] = []
        for _ in 0..<100 { delivery.submitScroll(message(0.25)) { _, _ in order.append("stale") } }
        delivery.cancel { order.append("release") }
        delivery.submitScroll(message(1, phase: "began")) { _, _ in order.append("new"); finished.fulfill() }
        resume.signal(); await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(order, ["release", "new"])
    }
}
