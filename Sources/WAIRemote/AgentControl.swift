import Foundation
import RemoteCore
import Combine
import WebRTC

protocol AgentControlTarget: AnyObject {
    var connected: Bool { get }
    var connecting: Bool { get }
    var canControl: Bool { get }
    var outgoingBytes: UInt64 { get }
    var status: String { get }
    var invitation: String { get set }
    var computers: [SavedComputer] { get }
    var agentState: HostState? { get }
    func disconnect(message: String, cancelRecovery: Bool)
    func pointer(_ action: String, at point: InkPoint, button: Int, dx: Double, dy: Double, modifiers: [String], clickCount: Int?)
    func keyEvent(_ key: String, action: String, modifiers: [String])
    func text(_ text: String)
}
extension MacViewerModel: AgentControlTarget {
    var agentState: HostState? { session.state }
}
struct AgentReply {
    var body: [String: Any]
    var frame: AgentFrameCapture.Captured?
    static func failure(_ code: String) -> AgentReply { AgentReply(body: ["ok":false, "error":code]) }
    func encoded() throws -> Data {
        var values = body
        if let frame {
            let png = try frame.png()
            values["image"] = ["mimeType":"image/png", "width":png.width, "height":png.height, "base64":png.data.base64EncodedString()]
        }
        return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    }
}

/// All model access runs on the main run loop. Transport and PNG work stay off it.
final class AgentControl {
    private struct Context: Equatable {
        let sessionID: String
        let controllerEpoch: Int, inputEpoch: Int, modeGeneration: Int, layerEpoch: Int
        let mode: RemoteMode, permissions: Permissions, surface: Surface
        init(_ state: HostState) {
            sessionID = state.sessionID; controllerEpoch = state.controllerEpoch; inputEpoch = state.inputEpoch
            modeGeneration = state.modeGeneration; layerEpoch = state.layerEpoch; mode = state.mode
            permissions = state.permissions; surface = state.surface
        }
    }
    private struct Snapshot { let id: String; let context: Context; let stream: UInt64 }
    private struct Request: Decodable {
        let command: String
        var computerID: String?, snapshotID: String?, key: String?, text: String?, modifiers: [String]?
        var x: Double?, y: Double?, deltaX: Double?, deltaY: Double?
        var button: Int?, clickCount: Int?
    }
    private let target: AgentControlTarget, frames: AgentFrameCapture, connect: () -> Void
    private var observed: Context?
    private var snapshot: Snapshot?
    init(target: AgentControlTarget, frames: AgentFrameCapture, connect: @escaping () -> Void) {
        self.target = target; self.frames = frames; self.connect = connect
        observed = target.agentState.map(Context.init)
    }
    func synchronize() {
        let context = target.connected ? target.agentState.map(Context.init) : nil
        if context != observed { observed = context; snapshot = nil; frames.clearFrame() }
        if !target.connected { snapshot = nil; frames.clearFrame() }
    }
    func handle(_ data: Data) -> AgentReply {
        precondition(Thread.isMainThread)
        guard data.count <= 65_536,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let request = try? JSONDecoder().decode(Request.self, from: data) else { return .failure("invalid_request") }
        let allowed: Set<String>
        switch request.command {
        case "status", "screenshot", "disconnect": allowed = ["command"]
        case "connect": allowed = ["command", "computerID"]
        case "click": allowed = ["command", "snapshotID", "x", "y", "button", "clickCount", "modifiers"]
        case "scroll": allowed = ["command", "snapshotID", "x", "y", "deltaX", "deltaY"]
        case "key": allowed = ["command", "snapshotID", "key", "modifiers"]
        case "text": allowed = ["command", "snapshotID", "text"]
        default: return .failure("unknown_command")
        }
        guard Set(fields.keys).isSubset(of: allowed) else { return .failure("invalid_request") }
        synchronize()
        switch request.command {
        case "status":
            return AgentReply(body: ["ok":true, "connected":target.connected, "connecting":target.connecting,
                "canControl":target.canControl, "status":target.status,
                "computers":target.computers.map { ["id":$0.id, "name":$0.name] }])
        case "connect":
            guard !target.connected, !target.connecting else { return .failure("connection_active") }
            guard let id = request.computerID, let computer = target.computers.first(where: { $0.id == id }) else { return .failure("unknown_computer") }
            target.invitation = computer.invitation; connect()
            return AgentReply(body: ["ok":true, "status":"connecting"])
        case "disconnect":
            target.disconnect(message: "Вы отключились", cancelRecovery: true); snapshot = nil; frames.clearFrame()
            return AgentReply(body: ["ok":true, "status":"disconnected"])
        case "screenshot":
            guard target.connected, let state = target.agentState else { return .failure("not_connected") }
            guard let frame = frames.latest() else { return .failure("frame_pending") }
            let id = UUID().uuidString
            snapshot = Snapshot(id: id, context: Context(state), stream: frame.generation)
            return AgentReply(body: ["ok":true, "snapshotID":id, "frameNumber":frame.sequence,
                "decodedAtUptimeSeconds":frame.receivedAt,
                "frameAgeMs":max(0, (ProcessInfo.processInfo.systemUptime - frame.receivedAt) * 1000),
                "surface":["width":state.surface.width, "height":state.surface.height, "revision":state.surface.revision],
                "coordinates":"normalized-top-left"], frame: frame)
        default: break
        }
        guard target.connected, target.canControl else { return .failure("control_unavailable") }
        guard let snapshot, request.snapshotID == snapshot.id, let state = target.agentState,
              snapshot.context == Context(state), snapshot.stream == frames.generation else { return .failure("stale_snapshot") }
        guard target.outgoingBytes <= 16_384 else { return .failure("congested") }
        let modifiers = request.modifiers ?? []
        guard modifiers.count <= 4, Set(modifiers).count == modifiers.count,
              modifiers.allSatisfy({ ["Meta", "Control", "Alt", "Shift"].contains($0) }) else { return .failure("invalid_request") }
        switch request.command {
        case "click", "scroll":
            guard let x = request.x, let y = request.y, InkPoint(x, y).isValid else { return .failure("invalid_coordinates") }
            let point = InkPoint(x, y)
            if request.command == "click" {
                let button = request.button ?? 0, count = request.clickCount ?? 1
                guard (0...2).contains(button), (1...2).contains(count) else { return .failure("invalid_request") }
                for index in 1...count {
                    target.pointer("down", at: point, button: button, dx: 0, dy: 0, modifiers: modifiers, clickCount: index)
                    target.pointer("up", at: point, button: button, dx: 0, dy: 0, modifiers: modifiers, clickCount: index)
                    if !target.canControl { break }
                }
            } else {
                let dx = request.deltaX ?? 0, dy = request.deltaY ?? 0
                guard dx.isFinite, dy.isFinite, abs(dx) <= 2000, abs(dy) <= 2000, dx != 0 || dy != 0 else { return .failure("invalid_delta") }
                target.pointer("scroll", at: point, button: 0, dx: dx, dy: dy, modifiers: [], clickCount: nil)
            }
        case "key":
            guard let key = request.key, InputInjector.keyCodes[key] != nil else { return .failure("invalid_key") }
            target.keyEvent(key, action: "down", modifiers: modifiers)
            target.keyEvent(key, action: "up", modifiers: [])
        case "text":
            guard let text = request.text, !text.isEmpty, text.utf8.count <= 16_384, !text.contains("\0") else { return .failure("invalid_text") }
            target.text(text)
        default: return .failure("unknown_command")
        }
        guard target.connected, target.canControl, target.agentState.map(Context.init) == snapshot.context else { return .failure("connection_changed") }
        return AgentReply(body: ["ok":true, "status":"submitted", "snapshotID":snapshot.id])
    }
}

/// The bridge owns no remote permissions or connection; the ordinary viewer does.
final class AgentBridge {
    private let frames = AgentFrameCapture()
    private var track: RTCVideoTrack?
    private var renderer: RTCVideoRenderer?
    private var subscriptions = Set<AnyCancellable>()
    private let control: AgentControl
    private var socket: AgentSocket?
    init(viewer: MacViewerModel, connect: @escaping () -> Void) throws {
        control = AgentControl(target: viewer, frames: frames, connect: connect)
        socket = try AgentSocket(path: AgentSocket.defaultPath) { [weak self] data in
            self?.control.handle(data) ?? .failure("unavailable")
        }
        viewer.$track.sink { [weak self] track in self?.attach(track) }.store(in: &subscriptions)
        viewer.objectWillChange.sink { [weak self] in
            // Published emits before assignment; read the resulting state on the next common-mode turn.
            RunLoop.main.perform(inModes: [.common]) { [weak self] in self?.control.synchronize() }
        }.store(in: &subscriptions)
    }
    private func attach(_ next: RTCVideoTrack?) {
        guard track !== next else { return }
        if let renderer { track?.remove(renderer) }
        frames.endStream(); track = next; renderer = nil
        if let next { let sink = frames.beginStream(); renderer = sink; next.add(sink) }
    }
    deinit { socket?.stop(); if let renderer { track?.remove(renderer) }; frames.endStream() }
}
