import XCTest
@testable import RemoteCore

final class ClickSequenceTests: XCTestCase {
    func testDoubleClickUsesSameButtonLocationAndSystemInterval() {
        var clicks = ClickSequence()
        XCTAssertEqual(clicks.down(x: 100, y: 100, button: 0, now: 1, interval: 0.5), 1)
        XCTAssertEqual(clicks.down(x: 101, y: 100, button: 0, now: 1.2, interval: 0.5), 2)
        XCTAssertEqual(clicks.down(x: 101, y: 100, button: 2, now: 1.3, interval: 0.5), 1)
        XCTAssertEqual(clicks.down(x: 150, y: 100, button: 2, now: 1.4, interval: 0.5), 1)
        XCTAssertEqual(clicks.down(x: 150, y: 100, button: 2, now: 2.1, interval: 0.5), 1)
        clicks.reset()
        XCTAssertEqual(clicks.down(x: 150, y: 100, button: 2, now: 2.2, interval: 0.5), 1)
    }

    func testTheViewersCountWinsOverHostArrivalTimes() {
        var clicks = ClickSequence()
        XCTAssertEqual(clicks.down(x: 100, y: 100, button: 0, now: 1, interval: 0.5, reported: 1), 1)
        XCTAssertEqual(clicks.down(x: 100, y: 100, button: 0, now: 1.05, interval: 0.5, reported: 1), 1,
                       "Two single clicks bunched together by the network stay single clicks.")
        XCTAssertEqual(clicks.down(x: 100, y: 100, button: 0, now: 1.85, interval: 0.5, reported: 2), 2,
                       "A double-click delayed in transit stays a double-click.")
        XCTAssertEqual(clicks.down(x: 100, y: 100, button: 0, now: 2, interval: 0.5, reported: 7), 3)
        XCTAssertEqual(clicks.down(x: 100, y: 100, button: 0, now: 2.1, interval: 0.5, reported: 0), 1)
        XCTAssertEqual(clicks.down(x: 100, y: 100, button: 0, now: 2.2, interval: 0.5), 2, "Older viewers keep the host's grouping.")
    }

    func testTouchTapsGroupWithinAFingerSizedRadius() {
        var taps = ClickSequence()
        XCTAssertEqual(taps.down(x: 200, y: 300, button: 0, now: 1, interval: 0.5, radius: 22), 1)
        XCTAssertEqual(taps.down(x: 206, y: 300, button: 0, now: 1.3, interval: 0.5, radius: 22), 2)
        XCTAssertEqual(taps.down(x: 240, y: 300, button: 0, now: 1.5, interval: 0.5, radius: 22), 1)
        var clicks = ClickSequence()
        _ = clicks.down(x: 200, y: 300, button: 0, now: 1, interval: 0.5)
        XCTAssertEqual(clicks.down(x: 206, y: 300, button: 0, now: 1.3, interval: 0.5), 1)
    }
}
