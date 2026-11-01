import XCTest
import UIKit
@testable import WAI_Remote

@MainActor
final class PhoneScrollStreamTests: XCTestCase {
    func testDisplayCadenceChangesPacketCountButNotDistance() {
        for rate in [60, 120] {
            var output: [PhoneScrollStream.Output] = []
            let stream = PhoneScrollStream { output.append($0) }
            stream.begin(at: 100, scale: CGPoint(x: 4, y: 4))
            for sample in 1...240 {
                let time = 100 + Double(sample) / 240
                stream.move(by: CGPoint(x: 0.25, y: -1), at: time)
                if sample.isMultiple(of: 240 / rate) { stream.tick(at: time) }
            }
            stream.end(at: 101.2)
            XCTAssertEqual(output.filter { $0.delta != .zero }.count, rate)
            XCTAssertEqual(output.reduce(0) { $0 + $1.delta.x }, 240, accuracy: 0.00001)
            XCTAssertEqual(output.reduce(0) { $0 + $1.delta.y }, -960, accuracy: 0.00001)
            XCTAssertEqual(output.first?.scrollPhase, "began")
            XCTAssertEqual(output.last?.scrollPhase, "ended")
            XCTAssertFalse(stream.isActive)
        }
    }

    func testBackpressurePreservesLargeDistanceAndOrderedEnd() {
        var ready = false
        var output: [PhoneScrollStream.Output] = []
        let stream = PhoneScrollStream(canSend: { ready }) { output.append($0) }
        stream.begin(at: 100, scale: CGPoint(x: 4, y: 4))
        stream.move(by: CGPoint(x: 1500, y: -3000), at: 100.02)
        stream.tick(at: 100.03); stream.end(at: 100.3)
        XCTAssertTrue(output.isEmpty)
        ready = true
        for frame in 1...7 { stream.tick(at: 100.4 + Double(frame) / 60) }
        XCTAssertEqual(output.reduce(0) { $0 + $1.delta.x }, 6000, accuracy: 0.00001)
        XCTAssertEqual(output.reduce(0) { $0 + $1.delta.y }, -12000, accuracy: 0.00001)
        XCTAssertTrue(output.allSatisfy { abs($0.delta.x) <= 2000 && abs($0.delta.y) <= 2000 })
        XCTAssertEqual(output.compactMap(\.scrollPhase), ["began", "changed", "changed", "changed", "changed", "changed", "ended"])
        XCTAssertFalse(output.contains { $0.momentumPhase != nil }, "A delayed queue must not replay a stale fling.")
        XCTAssertFalse(stream.isActive)
    }

    func testCancellationDropsPendingMovementEvenWhenChannelIsBlocked() {
        var ready = true
        var output: [PhoneScrollStream.Output] = []
        let stream = PhoneScrollStream(canSend: { ready }) { output.append($0) }
        stream.begin(at: 100)
        stream.move(by: CGPoint(x: 0, y: 10), at: 100.01); stream.tick(at: 100.02)
        ready = false
        stream.move(by: CGPoint(x: 0, y: 999), at: 100.03); stream.end(at: 100.04)
        stream.cancel(); ready = true; stream.tick(at: 100.05)
        XCTAssertEqual(output.map(\.scrollPhase), ["began", "cancelled"])
        XCTAssertEqual(output.reduce(0) { $0 + $1.delta.y }, 10)
        XCTAssertFalse(stream.isActive)
    }

    func testMomentumDistanceAndDurationAreIndependentOfDisplayCadence() throws {
        var distances: [CGFloat] = [], durations: [Double] = []
        for rate in [60, 120] {
            var output: [PhoneScrollStream.Output] = []
            let stream = PhoneScrollStream { output.append($0) }
            stream.begin(at: 100)
            for sample in 1...12 {
                let time = 100 + Double(sample) / 120
                stream.move(by: CGPoint(x: 0, y: 5), at: time); stream.tick(at: time)
            }
            stream.end(at: 100.1)
            var frames = 0
            while stream.isActive && frames < rate * 5 {
                frames += 1; stream.tick(at: 100.1 + Double(frames) / Double(rate))
            }
            let momentum = output.filter { $0.momentumPhase != nil }
            distances.append(momentum.reduce(0) { $0 + $1.delta.y }); durations.append(Double(frames) / Double(rate))
            XCTAssertEqual(momentum.first?.momentumPhase, "began")
            XCTAssertEqual(momentum.last?.momentumPhase, "ended")
            XCTAssertTrue(output.allSatisfy { $0.scrollPhase == nil || $0.momentumPhase == nil })
            let decay = -log(Double(UIScrollView.DecelerationRate.normal.rawValue)) * 1000
            XCTAssertEqual(Double(try XCTUnwrap(distances.last)), (600 - 5) / decay, accuracy: 0.00001)
            XCTAssertFalse(stream.isActive)
        }
        XCTAssertEqual(distances[0], distances[1], accuracy: 0.00001)
        XCTAssertEqual(durations[0], durations[1], accuracy: 1.0 / 60)
    }

    func testMomentumStopsOnNewGestureAndOnAStalledDisplay() {
        for restart in [false, true] {
            var output: [PhoneScrollStream.Output] = []
            let stream = PhoneScrollStream { output.append($0) }
            stream.begin(at: 100)
            stream.move(by: CGPoint(x: 0, y: 20), at: 100.02); stream.end(at: 100.02)
            stream.tick(at: 100.04)
            XCTAssertEqual(output.last?.momentumPhase, "began")
            if restart { stream.begin(at: 100.05) } else { stream.tick(at: 101) }
            XCTAssertEqual(output.last?.momentumPhase, "ended")
            let count = output.count
            stream.tick(at: 101.02)
            XCTAssertEqual(output.count, count)
            stream.cancel()
        }
    }

    func testReleaseVelocityIsBoundedAndMomentumStopsUnderBackpressure() {
        var ready = true
        var output: [PhoneScrollStream.Output] = []
        let stream = PhoneScrollStream(canSend: { ready }) { output.append($0) }
        stream.begin(at: 100)
        stream.move(by: CGPoint(x: 0, y: 1000), at: 100.001); stream.end(at: 100.001)
        stream.tick(at: 100.001 + 1.0 / 60)
        let firstMomentum = output.last!
        XCTAssertEqual(firstMomentum.momentumPhase, "began")
        XCTAssertLessThanOrEqual(firstMomentum.delta.y, 2500.0 / 60)
        ready = false; stream.tick(at: 100.05)
        XCTAssertEqual(output.last?.momentumPhase, "ended")
        XCTAssertFalse(stream.isActive)
    }

    func testDelayedEndDoesNotStartMomentumBeforeTheTouchEnded() throws {
        var ready = false
        var output: [PhoneScrollStream.Output] = []
        let stream = PhoneScrollStream(canSend: { ready }) { output.append($0) }
        stream.begin(at: 100)
        stream.move(by: CGPoint(x: 0, y: 20), at: 100.02)
        stream.end(at: 100.03)
        ready = true
        // The display timestamp can precede a touch delivered in the same frame.
        stream.tick(at: 100.025)
        stream.tick(at: 100.04)
        let first = try XCTUnwrap(output.first { $0.momentumPhase == "began" })
        let decay = -log(Double(UIScrollView.DecelerationRate.normal.rawValue)) * 1000
        XCTAssertEqual(Double(first.delta.y), 1000 * (1 - exp(-decay * 0.01)) / decay, accuracy: 0.00001)
        let count = output.count
        stream.tick(at: 100.035)
        XCTAssertEqual(output.count, count, "An older display timestamp must not integrate motion twice.")
        stream.cancel()
    }
}
