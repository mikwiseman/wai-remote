import XCTest
@testable import RemoteCore

final class SessionMachineTests: XCTestCase {
    func testWindowResizeRejectsQueuedCoordinatesAndKeepsTheSession() {
        let host = machine()
        let queued = pointer(host.state), session = host.state.sessionID
        let effects = host.resizeSurface(width: 800, height: 600)
        XCTAssertTrue(effects.releaseInput)
        XCTAssertEqual(host.state.surface.width, 800)
        XCTAssertEqual(host.state.surface.height, 600)
        XCTAssertEqual(host.state.sessionID, session)
        XCTAssertNil(host.handle(queued, now: 1).input)
        XCTAssertNotNil(host.handle(pointer(host.state), now: 2).input)
        XCTAssertFalse(host.resizeSurface(width: 800, height: 600).stateChanged)
    }
    func testSystemPermissionCanReturnWithoutLosingTheOwnersGrant() {
        let host = machine()
        let queued = pointer(host.state)
        XCTAssertTrue(host.setSystemControlAllowed(false).releaseInput)
        XCTAssertFalse(host.state.permissions.control)
        XCTAssertNil(host.handle(queued, now: 1).input)
        XCTAssertTrue(host.setSystemControlAllowed(true).stateChanged)
        XCTAssertTrue(host.state.permissions.control)
        XCTAssertNotNil(host.handle(pointer(host.state), now: 2).input)
        XCTAssertFalse(host.setSystemControlAllowed(true).stateChanged)
    }
    func testSystemGrantNeverPromotesAViewOnlyConnection() {
        let host = machine(.init(control: false, annotate: true))
        _ = host.setSystemControlAllowed(false)
        _ = host.setSystemControlAllowed(true)
        XCTAssertFalse(host.state.permissions.control)
        XCTAssertNil(host.handle(pointer(host.state), now: 1).input)
        _ = host.setPermissions(.init(control: true, annotate: true))
        _ = host.setSystemControlAllowed(false)
        _ = host.setPermissions(.init(control: false, annotate: true))
        _ = host.setSystemControlAllowed(true)
        XCTAssertFalse(host.state.permissions.control, "A revoked owner grant must stay revoked after macOS permission returns.")
    }
    func testTransportInterruptionLiftsHeldInputAndKeepsLateInputAndLocalPause() {
        let host = machine()
        let queued = pointer(host.state), epoch = host.state.inputEpoch
        let interrupted = host.transportInterrupted()
        XCTAssertTrue(interrupted.releaseInput)
        XCTAssertTrue(interrupted.stateChanged)
        XCTAssertTrue(host.stalled)
        XCTAssertEqual(host.state.inputEpoch, epoch, "The ordered channel may still deliver input sent before the interruption.")
        XCTAssertEqual(host.state.mode, .control)
        XCTAssertFalse(host.transportInterrupted().releaseInput)
        let late = host.handle(queued, now: 1)
        XCTAssertEqual(late.input?.action, "down", "Input that arrives after the path recovers is delivered, in order.")
        XCTAssertTrue(late.stateChanged)
        XCTAssertFalse(host.stalled)
        _ = host.pause(reason: "host-drawing")
        _ = host.transportInterrupted()
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
    func testStallLiftsHeldInputButDeliversLateInputInOrder() {
        let host = machine()
        let oldState = host.state
        XCTAssertNotNil(host.handle(pointer(oldState), now: 1).input)
        var heartbeat = WireMessage(type: "heartbeat", state: oldState); heartbeat.sequence = 1
        var up = pointer(oldState); up.sequence = 2; up.action = "up"
        let stall = host.tick(now: 3.01)
        XCTAssertTrue(stall.releaseInput, "A silent viewer must not leave a button or key held.")
        XCTAssertTrue(stall.stateChanged)
        XCTAssertTrue(host.stalled)
        XCTAssertEqual(host.state.inputEpoch, oldState.inputEpoch)
        XCTAssertEqual(host.state.nextSequence, 1)
        XCTAssertFalse(host.tick(now: 4).releaseInput)
        let resumed = host.handle(heartbeat, now: 5.3)
        XCTAssertTrue(resumed.accepted)
        XCTAssertTrue(resumed.stateChanged)
        XCTAssertFalse(host.stalled)
        XCTAssertEqual(host.handle(up, now: 5.4).input?.action, "up", "A click sent before the uplink stalled must arrive, not vanish.")
        XCTAssertFalse(host.handle(up, now: 5.5).accepted, "Replays stay rejected.")
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
