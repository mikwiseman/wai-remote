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
}
