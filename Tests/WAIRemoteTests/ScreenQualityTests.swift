import XCTest
@testable import WAIRemote

final class ScreenQualityTests: XCTestCase {
    func testSeverelyCompressedThirtyHzScreenGetsMoreBitsPerFrameImmediately() {
        var quality = ScreenQualityController()
        XCTAssertEqual(quality.observe(qp: 45, framesPerSecond: 30), 20)
        XCTAssertEqual(quality.observe(qp: 45, framesPerSecond: 20), 15)
        XCTAssertEqual(quality.observe(qp: 45, framesPerSecond: 15), 10)
        XCTAssertNil(quality.observe(qp: 45, framesPerSecond: 10))
    }

    func testSingleSceneChangeDoesNotReduceCadenceAndRecoveryNeedsSustainedClarity() {
        var quality = ScreenQualityController()
        XCTAssertNil(quality.observe(qp: 36, framesPerSecond: 60))
        XCTAssertNil(quality.observe(qp: 26, framesPerSecond: 60))
        XCTAssertEqual(quality.frameRate, 60)
        XCTAssertNil(quality.observe(qp: 36, framesPerSecond: 60))
        XCTAssertEqual(quality.observe(qp: 36, framesPerSecond: 60), 45)
        for _ in 0..<7 { XCTAssertNil(quality.observe(qp: 26, framesPerSecond: 45)) }
        XCTAssertEqual(quality.observe(qp: 26, framesPerSecond: 45), 60)
    }

    func testSparseOrInvalidMeasurementsCannotPretendTheConnectionRecovered() {
        var quality = ScreenQualityController()
        XCTAssertEqual(quality.observe(qp: 50, framesPerSecond: 15), 10)
        for _ in 0..<20 { XCTAssertNil(quality.observe(qp: 0, framesPerSecond: 1)) }
        for qp in [Double.nan, .infinity, -1, 52] { XCTAssertNil(quality.observe(qp: qp, framesPerSecond: 30)) }
        XCTAssertEqual(quality.frameRate, 10)
    }
}
