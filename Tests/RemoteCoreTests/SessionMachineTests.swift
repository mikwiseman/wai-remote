import XCTest
@testable import RemoteCore

final class SessionMachineTests: XCTestCase {
    func testTransportRecoveryNeedsNewEpochAndPreservesLocalPause() {
        let host = machine()
        let old = pointer(host.state)
        XCTAssertTrue(host.transportInterrupted().releaseInput)
        XCTAssertEqual(host.state.mode, .paused)
        XCTAssertFalse(host.handle(pointer(host.state), now: 1).accepted)
        XCTAssertTrue(host.transportRestored().releaseInput)
        XCTAssertEqual(host.state.mode, .control)
        XCTAssertFalse(host.handle(old, now: 2).accepted)
        XCTAssertTrue(host.handle(pointer(host.state), now: 2.1).accepted)
        _ = host.pause(reason: "host-drawing")
        _ = host.transportInterrupted(); _ = host.transportRestored()
        XCTAssertEqual(host.state.mode, .paused)
        XCTAssertFalse(host.handle(pointer(host.state), now: 3).accepted)
    }
    private func machine(_ permissions: Permissions = .init()) -> SessionMachine {
        SessionMachine(surface: .init(id: "display-1", width: 1920, height: 1080), permissions: permissions)
    }
    private func pointer(_ s: HostState) -> WireMessage {
        var m = WireMessage(type: "pointer", state: s); m.action = "down"; m.button = 0; m.x = 0.5; m.y = 0.5
        return m
    }
    func testDrawingCannotClickUnderlyingApplication() {
        let host = machine()
        var draw = WireMessage(type: "mode", state: host.state); draw.mode = .draw; draw.modeGeneration += 1
        let change = host.handle(draw, now: 1)
        XCTAssertTrue(change.releaseInput)
        XCTAssertEqual(host.state.mode, .draw)
        XCTAssertNil(host.handle(pointer(host.state), now: 1.01).input)
    }
    func testAnnotateOnlyDeviceCannotInjectInput() {
        let host = machine(.init(control: false, annotate: true))
        XCTAssertNil(host.handle(pointer(host.state), now: 1).input)
    }
    func testDeadManInvalidatesQueuedInputAndHeartbeat() {
        let host = machine()
        let oldState = host.state
        XCTAssertNotNil(host.handle(pointer(oldState), now: 1).input)
        let timeout = host.tick(now: 3.01)
        XCTAssertTrue(timeout.releaseInput)
        XCTAssertGreaterThan(host.state.inputEpoch, oldState.inputEpoch)
        XCTAssertNil(host.handle(pointer(oldState), now: 3.1).input)
        XCTAssertFalse(host.handle(WireMessage(type: "heartbeat", state: oldState), now: 3.2).accepted)
    }
    func testLocalDrawingCannotBeOverriddenByRemoteModeChange() {
        let host = machine()
        _ = host.pause(reason: "local-drawing")
        var resume = WireMessage(type: "mode", state: host.state); resume.mode = .control; resume.modeGeneration += 1
        XCTAssertFalse(host.handle(resume, now: 1).accepted)
        XCTAssertEqual(host.state.mode, .paused)
    }
    func testStoppedSessionRejectsEveryPacket() {
        let host = machine(); let packet = pointer(host.state); host.stop()
        XCTAssertFalse(host.handle(packet, now: 1).accepted)
    }
    func testWrongGeometryAndReplayAreRejected() {
        let host = machine()
        var bad = pointer(host.state); bad.geometryRevision += 1
        XCTAssertFalse(host.handle(bad, now: 1).accepted)
        let valid = pointer(host.state)
        XCTAssertTrue(host.handle(valid, now: 1).accepted)
        XCTAssertFalse(host.handle(valid, now: 1.1).accepted)
    }
    func testOutOfBoundsAndNonFinitePointsAreRejected() {
        let host = machine()
        var bad = pointer(host.state); bad.x = 1.1
        XCTAssertNil(host.handle(bad, now: 1).input)
        bad.x = .nan; XCTAssertNil(host.handle(bad, now: 1).input)
    }
}
