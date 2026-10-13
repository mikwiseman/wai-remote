import SwiftUI
import AppKit
import WebRTC
import RemoteCore

enum DrawingTool: String, CaseIterable, Identifiable {
    case pen, marker, arrow, eraser, select
    var id: String { rawValue }
    var title: String { switch self { case .pen: "Перо"; case .marker: "Маркер"; case .arrow: "Стрелка"; case .eraser: "Ластик"; case .select: "Выделить" } }
    var symbol: String { switch self { case .pen: "pencil.tip"; case .marker: "highlighter"; case .arrow: "arrow.up.right"; case .eraser: "eraser"; case .select: "cursorarrow" } }
}

class MacViewerModel: ObservableObject {
    @Published var invitation = ""
    @Published var invitationDraft = ""
    @Published var status = "Подключиться к Mac"
    @Published var detail = "Откройте доступ в WAI Remote на Mac и вставьте приглашение."
    @Published var connecting = false
    @Published var connected = false
    @Published var connectionInterrupted = false
    @Published var receivedFrame = false
    @Published var pasteFailure: String?
    @Published var track: RTCVideoTrack? {
        didSet { if track !== oldValue { receivedFrame = false } }
    }
    // Packet sequence changes are not UI changes. Publishing every heartbeat
    // or mouse move repeatedly invalidates the live Metal view.
    private(set) var session = ViewerSession()
    @Published var tool: DrawingTool = .pen
    @Published var color = InkStore.colors[0]
    @Published var width = 4.0
    @Published private(set) var strokes: [InkStroke] = []
    @Published private(set) var previews: [String: InkStroke] = [:]
    @Published private(set) var hiddenIDs = Set<String>()
    @Published var selectedID: String?
    @Published var gestureRevision = 0
    @Published var resetZoomRevision = 0
    @Published private(set) var identity: DeviceIdentity?
    private var signaling: ViewerSignaling?
    private var transport: ViewerTransport?
    private var heartbeat: Timer?
    private var timeout: Timer?
    private var activity: NSObjectProtocol?
    private var attempt = UUID()
    private var snapshot: [InkStroke]?
    private var activeStroke: String?
    private var erasedIDs = Set<String>()
    private var pendingMeasurements: [String: (time: Double, kind: String)] = [:]
    private var nonce = ""
    private var answerAccepted = false
    private var offerStarted = false
    private(set) var lastCursor = InkPoint(0.5, 0.5)
    var mode: RemoteMode { session.mode }
    var canControl: Bool { connected && receivedFrame && !session.invalidated && mode == .control && session.state?.permissions.control == true }
    var canDraw: Bool { connected && receivedFrame && !session.invalidated && mode == .draw && session.state?.permissions.annotate == true }
    var visibleStrokes: [InkStroke] { strokes.filter { previews[$0.id] == nil && !hiddenIDs.contains($0.id) } + previews.values.sorted { $0.id < $1.id } }

    @Published var computerName = "Другой Mac"
    @Published var computers: [SavedComputer] = []
    private var currentInvite: RemoteInvite?

    init(identity: DeviceIdentity) {
        self.identity = identity
        RTCInitializeSSL()
        if let data = UserDefaults.standard.data(forKey: "savedComputers"),
           let saved = try? JSONDecoder().decode([SavedComputer].self, from: data) {
            computers = saved.compactMap { try? SavedComputer(invitation: $0.invitation, name: $0.name) }
        }
    }
    func forget(_ id: String) { computers.removeAll { $0.id == id }; saveComputers() }
    func rename(_ id: String, name: String) {
        guard let index = computers.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        computers[index].name = String(name.prefix(60)); saveComputers()
    }
    private func saveComputers() {
        if let data = try? JSONEncoder().encode(computers) { UserDefaults.standard.set(data, forKey: "savedComputers") }
    }
    private func remember() {
        guard let invite = currentInvite,
              let computer = try? SavedComputer(invitation: invite.savedURL.absoluteString, name: computerName) else { return }
        if let index = computers.firstIndex(where: { $0.id == computer.id }) { computers[index] = computer }
        else { computers.append(computer) }
        saveComputers()
        invitation = computer.invitation
        UserDefaults.standard.set(invitation, forKey: "lastMac")
    }
    func open(_ url: URL) {
        guard url.scheme == "wai-remote", url.host == "connect",
              let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "invite" })?.value,
              (try? RemoteInvite(text)) != nil else { return }
        if connected || connecting { return }
        invitationDraft = text
        // Opening a link prepares the invitation; the visible Connect button starts the session.
    }
    func connect() {
        guard !connecting, !connected, let identity else { return }
        do {
            let invite = try RemoteInvite(invitation)
            guard invite.hostID != identity.id else { status = "Это приглашение с этого Mac"; detail = "Откройте WAI Remote на другом Mac и скопируйте его приглашение."; return }
            disconnect(message: "")
            invitationDraft = ""
            currentInvite = invite
            computerName = computers.first(where: { $0.id == invite.hostID })?.name ?? "Другой Mac"
            connecting = true; status = "Подключаемся…"; detail = "На другом Mac должны быть включены интернет и доступ к экрану."
            let token = attempt
            let signal = ViewerSignaling(identity: identity, invite: invite); signaling = signal
            signal.onReady = { [weak self] configuration in guard let self, self.attempt == token, !self.offerStarted else { return }; self.offerStarted = true; self.createOffer(invite, token: token, ice: configuration) }
            signal.onMessage = { [weak self] message in guard let self, self.attempt == token else { return }; self.signal(message, invite: invite, token: token) }
            signal.onFailure = { [weak self] in
                guard let self, self.attempt == token else { return }
                if !self.connected { self.disconnect(message: "Не удалось связаться с Mac. Проверьте интернет и убедитесь, что на нём открыт доступ.") }
            }
            timeout = Timer.connectionTimer(withTimeInterval: 110, repeats: false) { [weak self] _ in
                guard let self, self.attempt == token else { return }; self.disconnect(message: "Время подключения истекло. Проверьте доступ на другом Mac и попробуйте снова.")
            }
            signal.connect()
        } catch { status = "Нужно приглашение с Mac"; detail = "Скопируйте ссылку целиком из WAI Remote. Для первого подключения нужна новая ссылка." }
    }
    private func createOffer(_ invite: RemoteInvite, token: UUID, ice: ICEConfiguration) {
        guard let identity else { return }
        let peer = ViewerTransport(ice: ice); transport = peer
        peer.onVideo = { [weak self] track in guard let self, self.attempt == token else { return }; self.track = track }
        peer.onMessage = { [weak self] data in guard let self, self.attempt == token else { return }; self.receive(data) }
        peer.onState = { [weak self] state in
            guard let self, self.attempt == token else { return }
            if state == .failed || state == .closed { self.disconnect(message: "Соединение закрыто. Доступ на Mac можно открыть снова.") }
            if state == .disconnected { self.transport?.clipboard.setEnabled(false); self.cancelGesture(notify: false); self.session.interrupt(); self.connectionInterrupted = true; self.status = "Соединение прервано" }
        }
        peer.offer { [weak self] result in
            guard let self, self.attempt == token else { return }
            do {
                let sdp = try result.get()
                var random = Data(count: 32)
                guard random.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else { throw RemoteInvite.Invalid.invitation }
                self.nonce = random.base64URL
                let payload = try JSONSerialization.data(withJSONObject: ["hostID": invite.hostID, "peerID": identity.id, "publicKey": identity.publicKey,
                    "nonce": self.nonce, "expiresAt": (Date().timeIntervalSince1970 + 100) * 1000,
                    "name": String((Host.current().localizedName ?? "Mac").prefix(40)), "sdp": sdp])
                var body = ["payload": payload.base64URL, "signature": try identity.sign(payload, domain: "wai-remote/offer/v1")]
                if let secret = invite.secret { body["proof"] = DeviceIdentity.pairingProof(secret: secret, payload: payload) }
                self.signaling?.send(["type": "offer", "body": body])
                self.status = invite.secret == nil ? "Подключаемся к Mac…" : "Подтвердите на другом Mac"; self.detail = "При первом подключении владелец Mac разрешает просмотр или управление."
            } catch { self.disconnect(message: "Не удалось подготовить соединение. Проверьте интернет и попробуйте снова.") }
        }
    }
    private func signal(_ message: [String: Any], invite: RemoteInvite, token: UUID) {
        if message["type"] as? String == "answer" {
            guard !answerAccepted, message["from"] as? String == invite.hostID,
                  let body = message["body"] as? [String: Any], let encoded = body["payload"] as? String,
                  let data = Data(base64URL: encoded), let signature = body["signature"] as? String,
                  DeviceIdentity.verify(signature, data: data, domain: "wai-remote/answer/v1", publicKey: invite.publicKey),
                  let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  payload["hostID"] as? String == invite.hostID, payload["peerID"] as? String == identity?.id,
                  payload["nonce"] as? String == nonce, let sdp = payload["sdp"] as? String, sdp.utf8.count <= 80_000 else {
                disconnect(message: "Подлинность Mac не подтверждена. Откройте новое приглашение."); return
            }
            answerAccepted = true
            status = "Подключаем экран…"
            transport?.answer(sdp) { [weak self] error in
                guard let self, self.attempt == token else { return }
                if error != nil { self.disconnect(message: "Не удалось подключить изображение Mac.") }
            }
            if let name = payload["name"] as? String, !name.isEmpty, name.utf8.count <= 200,
               !computers.contains(where: { $0.id == invite.hostID }) { computerName = String(name.prefix(60)) }
        } else if message["type"] as? String == "unavailable" { disconnect(message: "Mac недоступен. Откройте доступ в WAI Remote на Mac.") }
        else if message["type"] as? String == "reject" {
            let reason = (message["body"] as? [String: Any])?["reason"] as? String
            disconnect(message: reason == "busy" ? "К Mac уже подключено другое устройство." : reason == "network" ? "Не удалось установить соединение через интернет. Попробуйте подключиться снова." : reason == "new-invite-required" ? "Откройте доступ к экрану Mac и создайте новое приглашение." : "Подключение отклонено на Mac.")
        }
    }
    func disconnect(message: String = "Вы отключились") {
        if connected, let release = session.release(), let data = try? JSONEncoder().encode(release) { _ = transport?.send(data) }
        attempt = UUID(); heartbeat?.invalidate(); heartbeat = nil; timeout?.invalidate(); timeout = nil
        signaling?.close(); signaling = nil; transport?.close(); transport = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        connecting = false; connected = false; connectionInterrupted = false; receivedFrame = false; track = nil; session = ViewerSession()
        strokes = []; previews = [:]; snapshot = nil; hiddenIDs = []; erasedIDs = []; activeStroke = nil; selectedID = nil
        answerAccepted = false; offerStarted = false; gestureRevision += 1
        currentInvite = nil; pendingMeasurements.removeAll(); pasteFailure = nil
        if !message.isEmpty { status = message; detail = "" }
    }
    func releaseInput() { cancelGesture(notify: true); _ = transmit(session.release()) }
    @discardableResult private func transmit(_ operation: WireMessage?) -> Bool {
        guard let operation, let data = try? JSONEncoder().encode(operation) else { return false }
        if PerformanceLog.enabled && (operation.type == "heartbeat" || operation.type == "pointer" && operation.action != "move") {
            let now = ProcessInfo.processInfo.systemUptime
            pendingMeasurements = pendingMeasurements.filter { now - $0.value.time < 30 }
            pendingMeasurements[operation.operationID] = (now, operation.action ?? operation.type)
        }
        guard transport?.send(data) == true else { disconnect(message: "Соединение прервано"); return false }
        return true
    }
    @discardableResult func send(_ type: String, edit: (inout WireMessage) -> Void = { _ in }) -> Bool {
        guard var operation = session.make(type) else { return false }; edit(&operation); return transmit(operation)
    }
    private func decode<T: Decodable>(_ object: Any, as: T.Type) throws -> T { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object)) }
    private func receive(_ data: Data) {
        do {
            guard let m = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            switch m["type"] as? String {
            case "performanceAck":
                if let id = m["id"] as? String, let sent = pendingMeasurements.removeValue(forKey: id) {
                    PerformanceLog.record("input-roundtrip", ["kind": sent.kind, "ms": (ProcessInfo.processInfo.systemUptime - sent.time) * 1000])
                }
            case "state":
                let state = try decode(m["state"] ?? [:], as: HostState.self)
                objectWillChange.send()
                if try session.accept(state) { cancelGesture(notify: false) }
                connectionInterrupted = false
                if !connected {
                    connected = true; connecting = false; timeout?.invalidate(); timeout = nil
                    activity = ProcessInfo.processInfo.beginActivity(options: .userInteractive, reason: "WAI Remote live screen")
                    remember()
                    heartbeat = Timer.connectionTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in _ = self?.send("heartbeat") }
                }
                status = mode == .paused ? "Владелец Mac приостановил управление" : m["lab"] as? Bool == true ? "Проверочный экран" : "Подключено"
                transport?.clipboard.onPasteFailure = { [weak self] message in self?.pasteFailure = message }
                transport?.clipboard.setEnabled(state.permissions.control && state.mode != .paused && m["lab"] as? Bool != true)
            case "ink":
                let op = try decode(m["op"] ?? [:], as: WireMessage.self)
                guard let id = op.strokeID else { return }
                if op.type == "strokeBegin", let tool = op.tool, let color = op.color, let width = op.width, let points = op.points, let author = m["author"] as? String {
                    strokes.removeAll { $0.id == id }; strokes.append(InkStroke(id: id, author: author, tool: tool, color: color, width: width, points: points))
                } else if op.type == "strokeAppend", let index = strokes.firstIndex(where: { $0.id == id }), let points = op.points {
                    if strokes[index].tool == .arrow, let first = strokes[index].points.first, let last = points.last { strokes[index].points = [first, last] }
                    else { strokes[index].points.append(contentsOf: points) }
                } else if op.type == "strokeEnd", let index = strokes.firstIndex(where: { $0.id == id }) {
                    strokes[index].complete = true; previews.removeValue(forKey: id)
                } else if op.type == "strokeCancel" { strokes.removeAll { $0.id == id }; previews.removeValue(forKey: id) }
            case "snapshotBegin": snapshot = []
            case "snapshotStroke":
                let stroke = try decode(m["stroke"] ?? [:], as: InkStroke.self)
                guard (snapshot?.count ?? 0) < 500 else { throw RemoteInvite.Invalid.invitation }; snapshot?.append(stroke)
            case "snapshotPoints":
                guard let id = m["id"] as? String, let index = snapshot?.firstIndex(where: { $0.id == id }) else { return }
                let points = try decode(m["points"] ?? [], as: [InkPoint].self)
                guard points.count <= 128, points.allSatisfy(\.isValid), (snapshot?[index].points.count ?? 0) + points.count <= 32768 else { throw RemoteInvite.Invalid.invitation }
                snapshot?[index].points.append(contentsOf: points)
            case "snapshotEnd":
                if let snapshot { strokes = snapshot.map { var stroke = $0; stroke.complete = true; return stroke } }
                snapshot = nil; hiddenIDs = []; previews = [:]
                if !strokes.contains(where: { $0.id == selectedID }) { selectedID = nil }
            default: break
            }
        } catch { disconnect(message: "Не удалось продолжить соединение. Подключитесь снова.") }
    }
    func changeMode(_ mode: RemoteMode) { cancelGesture(notify: true); _ = transmit(session.changeMode(mode)); selectedID = nil }
    func changeTool(_ value: DrawingTool) { cancelGesture(notify: true); tool = value; selectedID = nil }
    func pointer(_ action: String, at point: InkPoint, button: Int = 0, dx: Double = 0, dy: Double = 0, modifiers: [String] = []) {
        guard canControl else { return }; lastCursor = point
        send("pointer") { $0.action = action; $0.x = point.x; $0.y = point.y; $0.button = button; $0.deltaX = min(2000, max(-2000, dx)); $0.deltaY = min(2000, max(-2000, dy)); $0.modifiers = modifiers }
    }
    func rightClick() { pointer("down", at: lastCursor, button: 2); pointer("up", at: lastCursor, button: 2) }
    func keyEvent(_ key: String, action: String, modifiers: [String] = []) {
        guard canControl else { return }
        send("key") { $0.key = key; $0.action = action; $0.modifiers = modifiers }
    }
    func key(_ key: String, modifiers: [String] = []) {
        guard canControl else { return }
        keyEvent(key, action: "down", modifiers: modifiers)
        keyEvent(key, action: "up")
    }
    func text(_ text: String) {
        guard canControl, !text.isEmpty, !text.contains("\0") else { return }
        PerformanceLog.record("text-submit", ["units": text.utf16.count])
        var chunk = "", units = 0
        for scalar in text.unicodeScalars {
            let count = scalar.utf16.count
            if units + count > 4096 {
                guard send("text", edit: { $0.text = chunk }) else { return }
                chunk = ""; units = 0
            }
            chunk.unicodeScalars.append(scalar); units += count
        }
        if !chunk.isEmpty { send("text") { $0.text = chunk } }
    }
    func paste() {
        PerformanceLog.record("paste-request", ["canControl": canControl,
            "concealed": (NSPasteboard.general.types ?? []).contains(ClipboardContent.concealed),
            "hasText": (NSPasteboard.general.types ?? []).contains(.string),
            "clipboardReady": transport?.clipboard.available == true])
        guard canControl else { return }
        if let text = ClipboardContent.textForExplicitInsertion(from: .general) {
            self.text(text)
        } else if let clipboard = transport?.clipboard, clipboard.available {
            let epoch = session.state?.inputEpoch
            clipboard.pushCurrent { [weak self] in
                guard let self, self.canControl, self.session.state?.inputEpoch == epoch else { return }
                self.key("KeyV", modifiers: ["Meta"])
            }
        } else if let text = NSPasteboard.general.string(forType: .string) { self.text(text) }
    }
    func beginStroke(at point: InkPoint) {
        guard canDraw, let identity, let inkTool = InkTool(rawValue: tool.rawValue) else { return }
        let id = UUID().uuidString
        if send("strokeBegin", edit: { $0.strokeID = id; $0.tool = inkTool; $0.color = color; $0.width = width; $0.points = [point] }) {
            activeStroke = id; previews[id] = InkStroke(id: id, author: identity.id, tool: inkTool, color: color, width: width, points: [point])
        }
    }
    func appendStroke(at point: InkPoint) {
        guard let id = activeStroke, var stroke = previews[id] else { return }
        if send("strokeAppend", edit: { $0.strokeID = id; $0.points = [point] }) {
            if stroke.tool == .arrow { stroke.points = [stroke.points[0], point] } else { stroke.points.append(point) }
            previews[id] = stroke
        }
    }
    func endStroke() {
        guard let id = activeStroke else { return }; activeStroke = nil
        _ = send("strokeEnd") { $0.strokeID = id }
    }
    func markErased(_ id: String) { guard canDraw, erasedIDs.count < 50 else { return }; erasedIDs.insert(id); hiddenIDs.insert(id) }
    func finishErase() {
        guard !erasedIDs.isEmpty else { return }; let ids = Array(erasedIDs); erasedIDs = []
        _ = send("erase") { $0.strokeIDs = ids }
    }
    func deleteSelected() { guard let id = selectedID else { return }; selectedID = nil; markErased(id); finishErase() }
    func editInk(_ action: String) { guard canDraw else { return }; cancelGesture(notify: true); _ = send(action) }
    func cancelGesture(notify: Bool) {
        if let id = activeStroke { if notify { _ = send("strokeCancel") { $0.strokeID = id } }; previews.removeValue(forKey: id); activeStroke = nil }
        hiddenIDs.subtract(erasedIDs); erasedIDs = []; gestureRevision += 1
    }
}
