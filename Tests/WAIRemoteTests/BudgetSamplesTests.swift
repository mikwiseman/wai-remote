import WebRTC
import XCTest

final class BudgetSamplesTests: XCTestCase {
    private let phases = ["recovery-0.5s", "recovery-1s", "recovery-2s"]

    private func frame(_ rtp: UInt32) throws -> RTCVideoFrame {
        let frame = try AgentFrameCaptureTests.frame(luma: 100)
        frame.timeStamp = Int32(bitPattern: rtp)
        return frame
    }

    private func row(_ samples: BudgetSamples, _ phase: String, start: Double = 0) throws -> BudgetSamples.Snapshot {
        try XCTUnwrap(samples.snapshot(start: start).first { $0.metadata["phase"] as? String == phase })
    }

    func testOnlySuccessfulAllocationAfterArmingStartsDeadlineClock() throws {
        let samples = BudgetSamples(phase: "recovery")
        samples.observeEncoderRate(kbps: 4_000, result: 0, at: 9)
        samples.armRecovery(at: 10)
        samples.observeEncoderRate(kbps: 4_000, result: 0, at: 9.9)
        samples.observeEncoderRate(kbps: 3_999, result: 0, at: 10.1)
        samples.observeEncoderRate(kbps: 4_000, result: -1, at: 10.2)
        samples.capture(try frame(1), index: 1, at: 10.3)
        for phase in phases {
            let value = try row(samples, phase).metadata
            XCTAssertTrue(value["allocationAtSeconds"] is NSNull)
            XCTAssertTrue(value["deadlineAtSeconds"] is NSNull)
            XCTAssertTrue(value["decodedAtSeconds"] is NSNull)
            XCTAssertNotNil(value["missing"])
        }
        samples.observeEncoderRate(kbps: 4_000, result: 0, at: 11)
        for (phase, deadline) in zip(phases, [11.5, 12, 13]) {
            let value = try row(samples, phase).metadata
            XCTAssertEqual(value["allocationAtSeconds"] as? Double, 11)
            XCTAssertEqual(value["deadlineAtSeconds"] as? Double, deadline)
            XCTAssertTrue(value["decodedAtSeconds"] is NSNull)
        }
    }

    func testRecoveryAllocationLatchesOnceEvenIfRearmed() throws {
        let samples = BudgetSamples(phase: "recovery")
        samples.armRecovery(at: 10)
        samples.observeEncoderRate(kbps: 4_100, result: 0, at: 11)
        samples.observeEncoderRate(kbps: 5_000, result: 0, at: 12)
        samples.armRecovery(at: 20)
        samples.observeEncoderRate(kbps: 4_000, result: 0, at: 21)
        let value = try row(samples, "recovery-2s", start: 5).metadata
        XCTAssertEqual(value["allocationAtSeconds"] as? Double, 6)
        XCTAssertEqual(value["deadlineAtSeconds"] as? Double, 8)
    }

    func testExactDeadlineAllowedAndLaterFrameCannotReplaceIt() throws {
        let samples = BudgetSamples(phase: "recovery")
        samples.armRecovery(at: 10)
        samples.observeEncoderRate(kbps: 4_000, result: 0, at: 11)
        let entries: [(Int, Double)] = [(1, 11.499), (2, 11.5), (3, 11.5001),
                                       (4, 12), (5, 12.0001), (6, 13), (7, 13.0001)]
        for (index, time) in entries {
            samples.capture(try frame(UInt32(index)), index: index, at: time)
        }
        for (phase, expected) in zip(phases, [(2, 11.5), (4, 12.0), (6, 13.0)]) {
            let value = try row(samples, phase).metadata
            XCTAssertEqual(value["index"] as? Int, expected.0)
            XCTAssertEqual(value["decodedAtSeconds"] as? Double, expected.1)
            XCTAssertEqual(value["rtp"] as? UInt32, UInt32(expected.0))
        }
        XCTAssertEqual(try row(samples, "recovery").metadata["index"] as? Int, 7)
    }

    func testPreAllocationAndLateOnlyFramesLeaveMissingSlots() throws {
        let samples = BudgetSamples(phase: "recovery")
        samples.armRecovery(at: 10)
        samples.observeEncoderRate(kbps: 4_000, result: 0, at: 11)
        samples.capture(try frame(1), index: 1, at: 10.99)
        samples.capture(try frame(2), index: 2, at: 13.01)
        for phase in phases {
            let value = try row(samples, phase)
            XCTAssertNil(value.frame)
            for key in ["decodedAtSeconds", "index", "width", "height", "rtp"] {
                XCTAssertTrue(value.metadata[key] is NSNull, key)
            }
            XCTAssertNotNil(value.metadata["missing"])
        }
    }

    func testLatestInvalidSmallFrameReplacesEarlierReadableFrame() throws {
        let samples = BudgetSamples(phase: "recovery")
        samples.armRecovery(at: 10)
        samples.observeEncoderRate(kbps: 4_000, result: 0, at: 11)
        samples.capture(try frame(1), index: 1, at: 12.9)
        let invalid = try frame(0xffff_fffe)
        samples.capture(invalid, index: -1, at: 12.99)
        let value = try row(samples, "recovery-2s", start: 10)
        XCTAssertTrue(value.frame === invalid)
        XCTAssertEqual(value.metadata["index"] as? Int, -1)
        XCTAssertEqual(value.metadata["width"] as? Int, 16)
        XCTAssertEqual(value.metadata["height"] as? Int, 8)
        XCTAssertEqual(value.metadata["rtp"] as? UInt32, 0xffff_fffe)
        XCTAssertEqual(try XCTUnwrap(value.metadata["decodedAtSeconds"] as? Double), 2.99, accuracy: 0.000_001)
        XCTAssertEqual(value.metadata["deadlineAtSeconds"] as? Double, 3)
        XCTAssertNotNil(value.metadata["missing"])
    }

    func testOutOfOrderProcessingKeepsLatestEligibleRendererEntry() throws {
        let samples = BudgetSamples(phase: "recovery")
        samples.armRecovery(at: 10)
        samples.observeEncoderRate(kbps: 4_000, result: 0, at: 11)
        samples.capture(try frame(2), index: 2, at: 12.9)
        samples.capture(try frame(3), index: 3, at: 13.1)
        samples.capture(try frame(1), index: 1, at: 12.8)
        samples.capture(try frame(4), index: 4, at: 12.95)
        let value = try row(samples, "recovery-2s").metadata
        XCTAssertEqual(value["index"] as? Int, 4)
        XCTAssertEqual(value["decodedAtSeconds"] as? Double, 12.95)
    }
}
