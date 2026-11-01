import AppKit
import RemoteCore
import WebRTC
import XCTest
@testable import WAIRemote

@MainActor
final class AgentControlTests: XCTestCase {
    private final class Target: AgentControlTarget {
        var connected = true, connecting = false, canControl = true
        var status = "Connected", invitation = ""
        var computers: [SavedComputer] = []
        var agentState: HostState? = SessionMachine(surface: .init(id: "screen", width: 1440, height: 900)).state
        var events: [String] = [], points: [InkPoint] = [], receivedText = ""
        var outgoingBytes: UInt64 = 0
        func disconnect(message: String, cancelRecovery: Bool) { connected = false; events.append("disconnect") }
        func pointer(_ action: String, at point: InkPoint, button: Int, dx: Double, dy: Double, modifiers: [String], clickCount: Int?) {
            events.append("pointer:\(action):\(button):\(clickCount ?? 0):\(dx):\(dy)"); points.append(point)
        }
        func keyEvent(_ key: String, action: String, modifiers: [String]) { events.append("key:\(key):\(action):\(modifiers.joined(separator: "+"))") }
        func text(_ text: String) { receivedText += text; events.append("text") }
    }
    private func make() throws -> (Target, AgentControl, AgentFrameCapture, String) {
        let target = Target(), frames = AgentFrameCapture()
        let renderer = frames.beginStream()
        renderer.renderFrame(try AgentFrameCaptureTests.frame(luma: 80))
        let control = AgentControl(target: target, frames: frames, connect: { target.events.append("connect") })
        let screenshot = control.handle(Data(#"{"command":"screenshot"}"#.utf8))
        return (target, control, frames, try XCTUnwrap(screenshot.body["snapshotID"] as? String))
    }
    private func perform(_ control: AgentControl, _ values: [String: Any]) -> AgentReply {
        control.handle(try! JSONSerialization.data(withJSONObject: values))
    }

    func testCapturedCoordinatesAndCompleteClicksKeysAndUnicodeReachExistingInputPath() throws {
        let (target, control, _, snapshot) = try make()
        XCTAssertEqual(perform(control, ["command":"click", "snapshotID":snapshot, "x":0.25, "y":0.75, "clickCount":2]).body["status"] as? String, "submitted")
        XCTAssertEqual(target.points, Array(repeating: InkPoint(0.25, 0.75), count: 4))
        XCTAssertEqual(target.events, ["pointer:down:0:1:0.0:0.0", "pointer:up:0:1:0.0:0.0", "pointer:down:0:2:0.0:0.0", "pointer:up:0:2:0.0:0.0"])
        _ = perform(control, ["command":"key", "snapshotID":snapshot, "key":"KeyA", "modifiers":["Meta"]])
        XCTAssertEqual(Array(target.events.suffix(2)), ["key:KeyA:down:Meta", "key:KeyA:up:"])
        let text = "xcrun — Привет! 👨‍👩‍👧‍👦\n"
        _ = perform(control, ["command":"text", "snapshotID":snapshot, "text":text])
        XCTAssertEqual(target.receivedText, text)
    }

    func testNewVideoFramesDoNotInvalidateAnUnchangedSessionSnapshot() throws {
        let target = Target(), frames = AgentFrameCapture(), renderer = frames.beginStream()
        renderer.renderFrame(try AgentFrameCaptureTests.frame(luma: 40))
        let control = AgentControl(target: target, frames: frames, connect: {})
        let reply = control.handle(Data(#"{"command":"screenshot"}"#.utf8))
        let snapshot = try XCTUnwrap(reply.body["snapshotID"] as? String)
        let previous = try XCTUnwrap(frames.latest()).sequence
        renderer.renderFrame(try AgentFrameCaptureTests.frame(luma: 200))
        XCTAssertGreaterThan(try XCTUnwrap(frames.latest()).sequence, previous)
        XCTAssertEqual(perform(control, ["command":"scroll", "snapshotID":snapshot, "x":0.5, "y":0.5, "deltaY":80]).body["status"] as? String, "submitted")
        XCTAssertEqual(target.events.last, "pointer:scroll:0:0:0.0:80.0")
        XCTAssertNotNil(frames.latest())
    }

    func testGeometryChangeRequiresPixelsReceivedAfterTheNewContextWasObserved() throws {
        let target = Target(), frames = AgentFrameCapture(), renderer = frames.beginStream()
        let control = AgentControl(target: target, frames: frames, connect: {})
        renderer.renderFrame(try AgentFrameCaptureTests.frame(luma: 40))
        _ = perform(control, ["command":"screenshot"])
        target.agentState?.surface.revision += 1
        XCTAssertEqual(perform(control, ["command":"screenshot"]).body["error"] as? String, "frame_pending")
        renderer.renderFrame(try AgentFrameCaptureTests.frame(luma: 200))
        XCTAssertEqual(perform(control, ["command":"screenshot"]).body["ok"] as? Bool, true)
    }

    func testChangedContextPermissionAndTrackRejectOldCoordinates() throws {
        for change in ["session", "input", "controller", "mode", "surface", "geometry", "permission", "track", "disconnect"] {
            let (target, control, frames, snapshot) = try make()
            switch change {
            case "session": target.agentState?.sessionID = "replacement"
            case "input": target.agentState?.inputEpoch += 1
            case "controller": target.agentState?.controllerEpoch += 1
            case "mode": target.agentState?.modeGeneration += 1
            case "surface": target.agentState?.surface.id = "other"
            case "geometry": target.agentState?.surface.revision += 1
            case "permission": target.canControl = false
            case "track": _ = frames.beginStream()
            default: target.connected = false
            }
            let result = perform(control, ["command":"click", "snapshotID":snapshot, "x":0.5, "y":0.5])
            XCTAssertEqual(result.body["ok"] as? Bool, false, change)
            XCTAssertTrue(target.events.isEmpty, change)
        }
    }

    func testInvalidRequestsAndCongestionNeverSubmitPartialInput() throws {
        let (target, control, _, snapshot) = try make()
        for fields: [String: Any] in [
            ["command":"click", "x":-0.1, "y":0.5],
            ["command":"click", "x":true, "y":0.5],
            ["command":"scroll", "x":0.5, "y":0.5, "deltaY":2001],
            ["command":"key", "key":"ShellCommand"],
            ["command":"key", "key":"KeyA", "modifiers":["Hyper"]],
            ["command":"text", "text":"a\0b"],
            ["command":"text", "text":String(repeating:"x", count:16_385)],
            ["command":"click", "x":0.5, "y":0.5, "secret":"never accepted"]
        ] {
            var values = fields; values["snapshotID"] = snapshot
            XCTAssertEqual(perform(control, values).body["ok"] as? Bool, false)
        }
        target.outgoingBytes = 16_385
        XCTAssertEqual(perform(control, ["command":"click", "snapshotID":snapshot, "x":0.5, "y":0.5]).body["error"] as? String, "congested")
        XCTAssertTrue(target.events.isEmpty)
    }

    func testConnectUsesOnlySavedComputerAndNeverReplacesAnActiveSession() throws {
        let (target, control, _, _) = try make()
        let identity = DeviceIdentity()
        let saved = try SavedComputer(invitation: "https://example.test/#host=\(identity.id)&key=\(identity.publicKey)", name: "Mini")
        target.computers = [saved]
        XCTAssertEqual(perform(control, ["command":"connect", "computerID":saved.id]).body["error"] as? String, "connection_active")
        target.connected = false
        XCTAssertEqual(perform(control, ["command":"connect", "computerID":"unknown"]).body["error"] as? String, "unknown_computer")
        XCTAssertEqual(perform(control, ["command":"connect", "computerID":saved.id]).body["status"] as? String, "connecting")
        XCTAssertEqual(target.invitation, saved.invitation)
        XCTAssertEqual(target.events, ["connect"])
        let status = perform(control, ["command":"status"])
        let json = String(decoding: try status.encoded(), as: UTF8.self)
        XCTAssertFalse(json.contains("invitation")); XCTAssertFalse(json.contains("publicKey"))
    }
}
