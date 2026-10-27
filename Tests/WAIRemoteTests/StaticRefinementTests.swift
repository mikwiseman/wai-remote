import CoreVideo
import XCTest
@testable import WAIRemote

final class StaticRefinementTests: XCTestCase {
    private let queue = DispatchQueue(label: "is.wai.remote.test.refinement")
    private let lock = NSLock()
    private var sent: [(buffer: CVPixelBuffer, time: Double)] = []
    // Binary-exact steps: ticks at k/64 s against a 8/64 s window.
    private let step = 1.0 / 64, window = 8.0 / 64
    private var now = 100.0
    /// Ticks are driven by hand on a fake clock, so CI scheduling cannot change the result.
    private func refinement() -> StaticRefinement {
        StaticRefinement(queue: queue, interval: 3600, window: window, clock: { [unowned self] in now }) { [unowned self] buffer, time in
            lock.lock(); sent.append((buffer, time)); lock.unlock()
        }
    }
    private func tick(_ refinement: StaticRefinement, _ count: Int = 1) {
        for _ in 0..<count { now += step; queue.sync { refinement.repeatLast() } }
    }
    private func snapshot() -> [(buffer: CVPixelBuffer, time: Double)] { lock.lock(); defer { lock.unlock() }; return sent }
    private func buffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    func testStaticFrameIsResentBrieflyThenTheHostGoesIdle() throws {
        let refinement = refinement(), frame = try buffer()
        queue.sync { refinement.frame(frame, at: now) }
        tick(refinement, 12)
        let frames = snapshot()
        XCTAssertTrue(frames.allSatisfy { $0.buffer === frame })
        XCTAssertEqual(frames.count, 8, "The frame itself, then a repeat on every tick inside the window")
        XCTAssertEqual(frames.map(\.time), (0..<8).map { 100 + Double($0) * step }, "Fresh, increasing timestamps")
        tick(refinement, 4)
        XCTAssertEqual(snapshot().count, 8, "Idle after the window")
    }

    func testIdleRefinementReleasesTheCaptureSurface() throws {
        // This sink keeps no buffers, so only the refinement can hold the surface.
        let refinement = StaticRefinement(queue: queue, interval: 3600, window: window, clock: { [unowned self] in now }) { _, _ in }
        weak var released: CVPixelBuffer?
        try autoreleasepool {
            let frame = try buffer(); released = frame
            queue.sync { refinement.frame(frame, at: now) }
        }
        tick(refinement, 3)
        XCTAssertNotNil(released, "Held while it may still refine")
        tick(refinement, 6)
        XCTAssertNil(released, "Released once refinement ends")
    }

    func testNewFrameCancelsRefinementOfTheOldOneImmediately() throws {
        let refinement = refinement(), old = try buffer(), new = try buffer()
        queue.sync { refinement.frame(old, at: now) }
        tick(refinement, 3)
        queue.sync { refinement.frame(new, at: now) }
        tick(refinement, 12)
        let frames = snapshot(), first = try XCTUnwrap(frames.firstIndex { $0.buffer === new })
        XCTAssertEqual(first, 4, "The old frame was refined while static")
        XCTAssertTrue(frames[first...].allSatisfy { $0.buffer === new })
        XCTAssertEqual(frames.count - first, 8, "The new frame gets its own full window")
    }

    func testContinuousChangesAreNotRepeated() throws {
        let refinement = refinement()
        let frames = try (0..<20).map { _ in try buffer() }
        for frame in frames { now += step / 2; queue.sync { refinement.frame(frame, at: now) } }
        queue.sync { refinement.stop() }
        tick(refinement, 4)
        XCTAssertEqual(snapshot().map { ObjectIdentifier($0.buffer) }, frames.map(ObjectIdentifier.init))
    }

    func testTheRealTimerRepeatsAndThenStops() throws {
        // Real scheduling with generous margins: CI may coalesce timers heavily.
        var count = 0
        let refinement = StaticRefinement(queue: queue, interval: 0.02, window: 0.3) { _, _ in count += 1 }
        let frame = try buffer()
        queue.sync { refinement.frame(frame, at: 1) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, queue.sync(execute: { count }) < 3 { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertGreaterThanOrEqual(queue.sync { count }, 3, "The frame and at least two repeats")
        Thread.sleep(forTimeInterval: 0.6)
        let settled = queue.sync { count }
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(queue.sync { count }, settled, "Idle after the window")
    }
}
