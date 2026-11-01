import AppKit
import RemoteCore
import WebRTC
import XCTest
@testable import WAIRemote

/// Real CLI/socket/session/WebRTC/video path. Only the host's app pixels and input sink are synthetic.
@MainActor
final class AgentIntegrationTests: XCTestCase {
    private final class Viewer: AgentControlTarget {
        let transport: ViewerTransport
        let frames = AgentFrameCapture()
        var session = ViewerSession(), connected = false, connecting = false
        var status = "Fixture", invitation = "", computers: [SavedComputer] = []
        var track: RTCVideoTrack?, renderer: RTCVideoRenderer?
        var stateChanged: (() -> Void)?
        var agentState: HostState? { session.state }
        var outgoingBytes: UInt64 { transport.bufferedAmount }
        var canControl: Bool { connected && session.mode == .control && session.state?.permissions.control == true }
        init(ice: ICEConfiguration) {
            transport = ViewerTransport(ice: ice)
            transport.onVideo = { [weak self] track in
                guard let self else { return }
                self.track = track; let renderer = self.frames.beginStream(); self.renderer = renderer; track.add(renderer)
            }
            transport.onMessage = { [weak self] data in
                guard let self, let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      message["type"] as? String == "state", let state = message["state"],
                      let encoded = try? JSONSerialization.data(withJSONObject: state),
                      let decoded = try? JSONDecoder().decode(HostState.self, from: encoded) else { return }
                do { try self.session.accept(decoded); self.connected = true; self.stateChanged?() } catch { XCTFail("Invalid fixture state: \(error)") }
            }
        }
        func submit(_ type: String, edit: (inout WireMessage) -> Void) {
            guard var message = session.make(type) else { XCTFail("Viewer could not make input"); return }
            edit(&message); XCTAssertTrue(transport.send(try! JSONEncoder().encode(message)))
        }
        func pointer(_ action: String, at point: InkPoint, button: Int, dx: Double, dy: Double, modifiers: [String], clickCount: Int?) {
            submit("pointer") { $0.action = action; $0.x = point.x; $0.y = point.y; $0.button = button; $0.deltaX = dx; $0.deltaY = dy; $0.modifiers = modifiers; $0.clickCount = clickCount }
        }
        func keyEvent(_ key: String, action: String, modifiers: [String]) { submit("key") { $0.key = key; $0.action = action; $0.modifiers = modifiers } }
        func text(_ text: String) { submit("text") { $0.text = text } }
        func disconnect(message: String, cancelRecovery: Bool) {
            connected = false; if let renderer { track?.remove(renderer) }; frames.endStream(); transport.close()
        }
    }

    func testCLIInputChangesSubsequentDecodedPNGAndRejectsStaleAuthority() async throws {
        _ = NSApplication.shared
        RTCInitializeSSL(); signal(SIGPIPE, SIG_IGN)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let id = String(UUID().uuidString.prefix(8))
        let directory = URL(fileURLWithPath: "/private/tmp/wai-int-" + id)
        let artifacts = root.appendingPathComponent(".runtime/agent-integration-" + id)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let factory = RTCPeerConnectionFactory(encoderFactory: ScreenVideoEncoderFactory(), decoderFactory: ScreenVideoDecoderFactory())
        let source = factory.videoSource(forScreenCast: true), capturer = RTCVideoCapturer(delegate: source)
        let hostICE = try await iceConfiguration(), viewerICE = try await iceConfiguration()
        let host = PeerTransport(factory: factory, source: source, ice: hostICE), viewer = Viewer(ice: viewerICE)
        defer { host.close(); viewer.disconnect(message: "", cancelRecovery: true) }
        let machine = SessionMachine(surface: .init(id: "synthetic", width: 320, height: 160))
        let control = AgentControl(target: viewer, frames: viewer.frames, connect: { XCTFail("Fixture must not connect to a saved computer") })
        viewer.stateChanged = { control.synchronize() }
        let socket = try AgentSocket(path: directory.appendingPathComponent("Library/Caches/is.wai.remote.agent/control.sock")) { control.handle($0) }
        defer { socket.stop() }
        var accepted: [WireMessage] = [], pressed = false, clicked = false, typed = ""
        var states: [String] = [], pushed = 0
        host.onState = { states.append("host:\($0.rawValue)") }; viewer.transport.onState = { states.append("viewer:\($0.rawValue)") }
        defer { print("AGENT_INTEGRATION_TRANSPORT states=\(states) hostReady=\(host.isReady) connected=\(viewer.connected) track=\(viewer.track != nil) pushed=\(pushed) decoded=\(viewer.frames.latest() != nil)") }
        let text = "Exact — Привет! 👨‍👩‍👧‍👦"
        host.onMessage = { data in
            guard let message = try? JSONDecoder().decode(WireMessage.self, from: data) else { XCTFail("Invalid wire input"); return }
            let effect = machine.handle(message, now: ProcessInfo.processInfo.systemUptime)
            guard let input = effect.input else { XCTFail("Host rejected input: \(effect.rejected ?? "unknown")"); return }
            accepted.append(input)
            if input.type == "pointer", input.x == 0.25, input.y == 0.5 {
                if input.action == "down" { pressed = true }
                if input.action == "up", pressed { clicked = true; pressed = false }
            }
            if input.type == "text" { typed += input.text ?? "" }
        }
        host.onOpen = { XCTAssertTrue(host.send(["type":"state", "state":machine.state.jsonObject()])) }
        viewer.transport.offer { offer in
            guard case .success(let sdp) = offer else { XCTFail("Offer failed: \(offer)"); return }
            host.answer(offer: sdp) { answer in
                guard case .success(let sdp) = answer else { XCTFail("Answer failed: \(answer)"); return }
                viewer.transport.answer(sdp) { if let error = $0 { XCTFail("Remote answer failed: \(error)") } }
            }
        }
        let feeder = Timer.connectionTimer(withTimeInterval: 0.05, repeats: true) { _ in
            guard host.isReady else { return }; pushed += 1
            source.capturer(capturer, didCapture: Self.frame(clicked: clicked, typed: typed == text))
        }
        defer { feeder.invalidate() }
        try await eventually("Connected and decoded first frame", timeout: 45) { viewer.canControl && viewer.frames.latest() != nil }
        let before = try await cli(directory, ["screenshot", "--output", artifacts.appendingPathComponent("before.png").path])
        let snapshot = try XCTUnwrap(before["snapshotID"] as? String, String(describing: before))
        XCTAssertLessThan(try brightness(artifacts, "before.png", x: 80), 0.25)
        XCTAssertLessThan(try brightness(artifacts, "before.png", x: 240), 0.25)
        let clickReply = try await cli(directory, ["click", "--snapshot", snapshot, "--x", "0.25", "--y", "0.5"])
        XCTAssertEqual(clickReply["status"] as? String, "submitted")
        try await eventually("Click changed decoded pixels") { clicked && Self.luma(viewer.frames, x: 80) > 150 }
        let clickedReply = try await cli(directory, ["screenshot", "--output", artifacts.appendingPathComponent("clicked.png").path])
        XCTAssertEqual(accepted.map(\.action), ["down", "up"]); XCTAssertFalse(pressed)
        XCTAssertGreaterThan(try brightness(artifacts, "clicked.png", x: 80), 0.65)
        XCTAssertLessThan(try brightness(artifacts, "clicked.png", x: 240), 0.25)
        let secondSnapshot = try XCTUnwrap(clickedReply["snapshotID"] as? String)
        let textReply = try await cli(directory, ["text", "--snapshot", secondSnapshot, text])
        XCTAssertEqual(textReply["status"] as? String, "submitted")
        try await eventually("Exact text changed decoded pixels") { typed == text && Self.luma(viewer.frames, x: 240) > 100 }
        let after = try await cli(directory, ["screenshot", "--output", artifacts.appendingPathComponent("typed.png").path])
        XCTAssertGreaterThan(try brightness(artifacts, "typed.png", x: 80), 0.65)
        XCTAssertGreaterThan(try brightness(artifacts, "typed.png", x: 240), 0.4)
        XCTAssertGreaterThan(try XCTUnwrap(after["frameNumber"] as? UInt64), try XCTUnwrap(before["frameNumber"] as? UInt64))
        XCTAssertEqual(accepted.last?.text, text)
        let oldSnapshot = try XCTUnwrap(after["snapshotID"] as? String), count = accepted.count
        machine.reconnect(); XCTAssertTrue(host.send(["type":"state", "state":machine.state.jsonObject()]))
        try await eventually("New epoch reached viewer") { viewer.agentState?.inputEpoch == machine.state.inputEpoch }
        let stale = try await cli(directory, ["click", "--snapshot", oldSnapshot, "--x", "0.25", "--y", "0.5"])
        XCTAssertEqual(stale["error"] as? String, "stale_snapshot")
        machine.setPermissions(.init(control: false)); XCTAssertTrue(host.send(["type":"state", "state":machine.state.jsonObject()]))
        try await eventually("Permission revocation reached viewer") { viewer.agentState?.permissions.control == false }
        let revoked = try await cli(directory, ["text", "--snapshot", oldSnapshot, "must not arrive"])
        XCTAssertEqual(revoked["error"] as? String, "control_unavailable")
        try await Task.sleep(for: .milliseconds(100)); XCTAssertEqual(accepted.count, count); XCTAssertEqual(typed, text)
        print("AGENT_INTEGRATION_ARTIFACTS \(artifacts.path)")
    }

    private func iceConfiguration() async throws -> ICEConfiguration {
        guard ProcessInfo.processInfo.environment["WAI_SESSION_POLICY"] == "relay" else { return .local }
        let signaling = Signaling(identity: DeviceIdentity())
        defer { signaling.close() }
        let ready = expectation(description: "Ephemeral relay credentials"); ready.assertForOverFulfill = false
        var configuration: ICEConfiguration?, failure: String?
        signaling.onReady = { configuration = $0; ready.fulfill() }
        signaling.onFailure = { failure = $0; ready.fulfill() }
        signaling.connect(url: URL(string: "wss://waiwai.is/remote/connect/signal")!)
        await fulfillment(of: [ready], timeout: 20)
        let ice = try XCTUnwrap(configuration, failure ?? "No gateway configuration")
        return try ICEConfiguration.read(["ice": ["iceServers":ice.iceServers.map {
            ["urls":$0.urls, "username":$0.username, "credential":$0.credential] as [String:Any]
        }, "iceTransportPolicy":"relay", "expiresAt":ice.expiresAt]])
    }
    private func eventually(_ message: String, timeout: TimeInterval = 12, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard condition() else { XCTFail(message); throw NSError(domain: "AgentIntegrationTimeout", code: 1) }
    }
    private static func luma(_ capture: AgentFrameCapture, x: Int) -> Int {
        guard let frame = capture.latest()?.frame, frame.width == 320, frame.height == 160 else { return 0 }
        let pixels = frame.buffer.toI420(); return Int(pixels.dataY[80 * Int(pixels.strideY) + x])
    }
    private func brightness(_ directory: URL, _ name: String, x: Int) throws -> CGFloat {
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: directory.appendingPathComponent(name))))
        XCTAssertEqual(image.pixelsWide, 320); XCTAssertEqual(image.pixelsHigh, 160)
        return try XCTUnwrap(image.colorAt(x: x, y: 80)?.usingColorSpace(.sRGB)).redComponent
    }
    private static func frame(clicked: Bool, typed: Bool) -> RTCVideoFrame {
        var optional: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 320, 160, kCVPixelFormatType_32BGRA, nil, &optional) == kCVReturnSuccess)
        let pixel = optional!; CVPixelBufferLockBaseAddress(pixel, [])
        let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<160 { for x in 0..<320 {
            let offset = y * CVPixelBufferGetBytesPerRow(pixel) + x * 4
            let value: UInt8 = x < 160 ? (clicked ? 220 : 32) : (typed ? 160 : 32)
            base[offset] = value; base[offset + 1] = value; base[offset + 2] = value; base[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixel), rotation: ._0,
                             timeStampNs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000))
    }
    private func cli(_ directory: URL, _ arguments: [String]) async throws -> [String: Any] {
        let data = try await Task.detached { try Self.runCLI(directory.path, arguments) }.value
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    nonisolated private static func runCLI(_ directory: String, _ arguments: [String]) throws -> Data {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/wai-remote-agent.py")
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import pathlib,runpy,sys,signal\nfrom unittest.mock import patch\nsignal.alarm(15)\nscript=sys.argv.pop(1); home=sys.argv.pop(1); sys.argv[0]=script\nwith patch.object(pathlib.Path,'home',return_value=pathlib.Path(home)):\n runpy.run_path(script,run_name='__main__')", script.path, directory] + arguments
        process.standardOutput = output
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else { throw NSError(domain: "AgentCLI", code: Int(process.terminationStatus)) }
        return data
    }
}
