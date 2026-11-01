import AppKit
import XCTest
@testable import WAIRemote

@MainActor
final class InputTrackingTests: XCTestCase {
    func testOwnAccessibilityPressCanArriveBeforeMenuTrackingEnds() {
        _ = NSApplication.shared
        let delivery = InputDeliveryQueue()
        let entered = DispatchSemaphore(value: 0)
        let finished = expectation(description: "Input returned")
        let tracked = expectation(description: "Tracking ended")
        var tracking = false
        var pressedDuringTracking = false
        var pressCount = 0
        let button = WindowInputTarget.Button(frame: .zero, requiresMainThread: true, action: {
            XCTAssertTrue(Thread.isMainThread, "Our AppKit and SwiftUI actions must stay on the main thread.")
            pressCount += 1
            pressedDuringTracking = tracking
            return true
        })

        // A menu may enter its nested loop from a main-queue callback. The
        // next remote action must reach it before that menu can finish tracking.
        DispatchQueue.main.async {
            tracking = true
            delivery.submit { current in
                entered.signal()
                XCTAssertTrue(button.press(if: current))
                finished.fulfill()
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            let deadline = Date().addingTimeInterval(0.3)
            while !pressedDuringTracking && Date() < deadline {
                RunLoop.main.run(mode: .eventTracking, before: deadline)
            }
            tracking = false
            tracked.fulfill()
        }
        wait(for: [tracked, finished], timeout: 3)
        XCTAssertEqual(pressCount, 1)
        XCTAssertTrue(pressedDuringTracking,
                      "A queued remote press must not wait for the menu it needs to control to close.")
    }
    func testCancellationWhileWaitingForTrackingDiscardsTheOldPressAndPreservesOrder() {
        _ = NSApplication.shared
        let delivery = InputDeliveryQueue()
        let entered = DispatchSemaphore(value: 0)
        let staleReturned = expectation(description: "Cancelled press returned")
        let freshReturned = expectation(description: "New press returned")
        let tracked = expectation(description: "Tracking ended")
        let lock = NSLock()
        var order: [String] = []
        var tracking = false
        var freshDuringTracking = false
        let stale = WindowInputTarget.Button(frame: .zero, requiresMainThread: true, action: {
            lock.withLock { order.append("stale") }
            XCTFail("Cancellation during the main-thread wait must still prevent the action.")
            return true
        })
        let fresh = WindowInputTarget.Button(frame: .zero, requiresMainThread: true, action: {
            XCTAssertTrue(Thread.isMainThread)
            lock.withLock { order.append("fresh") }
            freshDuringTracking = tracking
            return true
        })
        DispatchQueue.main.async {
            tracking = true
            delivery.submit { current in
                entered.signal()
                XCTAssertFalse(stale.press(if: current))
                staleReturned.fulfill()
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            // The main callback has not pumped tracking yet: the old press is
            // waiting for main, while the session is revoked on this thread.
            delivery.cancel { lock.withLock { order.append("release") } }
            delivery.submit { current in
                XCTAssertTrue(fresh.press(if: current))
                freshReturned.fulfill()
            }
            let deadline = Date().addingTimeInterval(0.3)
            while !freshDuringTracking && Date() < deadline {
                RunLoop.main.run(mode: .eventTracking, before: deadline)
            }
            tracking = false
            tracked.fulfill()
        }
        wait(for: [tracked, staleReturned, freshReturned], timeout: 3)
        XCTAssertEqual(lock.withLock { order }, ["release", "fresh"])
        XCTAssertTrue(freshDuringTracking, "The new session must not wait for the old menu loop to close.")
    }
}
