import CoreVideo
import XCTest
@testable import WAIRemote

final class StaticRefinementTests: XCTestCase {
    private let queue = DispatchQueue(label: "is.wai.remote.test.refinement")
    private let lock = NSLock()
    private var sent: [(buffer: CVPixelBuffer, time: Double)] = []
    private func refinement() -> StaticRefinement {
        StaticRefinement(queue: queue, interval: 0.02, window: 0.2) { [unowned self] buffer, time in
            lock.lock(); sent.append((buffer, time)); lock.unlock()
        }
    }
    private func snapshot() -> [(buffer: CVPixelBuffer, time: Double)] { lock.lock(); defer { lock.unlock() }; return sent }
    private func buffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    func testStaticFrameIsResentBrieflyThenTheHostGoesIdle() throws {
        let refinement = refinement(), frame = try buffer()
        queue.sync { refinement.frame(frame, at: 1) }
        Thread.sleep(forTimeInterval: 0.4)
        let frames = snapshot()
        XCTAssertTrue(frames.allSatisfy { $0.buffer === frame })
        // The frame itself, then repeats every 20 ms for 200 ms; timer slack may cost a tick or two.
        XCTAssertTrue((6...10).contains(frames.count), "\(frames.count) frames")
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $0.time < $1.time }, "Fresh, increasing timestamps")
        let last = try XCTUnwrap(frames.last), firstRepeat = try XCTUnwrap(frames.dropFirst().first)
        XCTAssertLessThan(last.time - firstRepeat.time, 0.2)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(snapshot().count, frames.count, "Idle after the window")
    }

    func testIdleRefinementReleasesTheCaptureSurface() throws {
        var count = 0
        let refinement = StaticRefinement(queue: queue, interval: 0.02, window: 0.1) { _, _ in count += 1 }
        weak var released: CVPixelBuffer?
        try autoreleasepool {
            let frame = try buffer(); released = frame
            queue.sync { refinement.frame(frame, at: 1) }
        }
        XCTAssertNotNil(released, "Held while it may still refine")
        Thread.sleep(forTimeInterval: 0.3)
        queue.sync { XCTAssertGreaterThan(count, 1) }
        XCTAssertNil(released, "Released once refinement ends")
    }

    func testNewFrameCancelsRefinementOfTheOldOneImmediately() throws {
        let refinement = refinement(), old = try buffer(), new = try buffer()
        queue.sync { refinement.frame(old, at: 1) }
        Thread.sleep(forTimeInterval: 0.07)
        queue.sync { refinement.frame(new, at: 2) }
        Thread.sleep(forTimeInterval: 0.3)
        let frames = snapshot(), first = try XCTUnwrap(frames.firstIndex { $0.buffer === new })
        XCTAssertGreaterThan(first, 1, "The old frame was refined while static")
        XCTAssertTrue(frames[first...].allSatisfy { $0.buffer === new })
    }

    func testContinuousChangesAreNotRepeated() throws {
        let refinement = refinement()
        let frames = try (0..<20).map { _ in try buffer() }
        for (index, frame) in frames.enumerated() {
            queue.sync { refinement.frame(frame, at: Double(index)) }
            Thread.sleep(forTimeInterval: 0.008)
        }
        queue.sync { refinement.stop() }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(snapshot().map { ObjectIdentifier($0.buffer) }, frames.map(ObjectIdentifier.init))
    }
}
