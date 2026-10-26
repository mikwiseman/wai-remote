import SwiftUI
import WebRTC
import RemoteCore

enum DrawingTool: String, CaseIterable, Identifiable {
    case pen, marker, arrow, eraser, select
    var id: String { rawValue }
    var title: String { switch self { case .pen: "Перо"; case .marker: "Маркер"; case .arrow: "Стрелка"; case .eraser: "Ластик"; case .select: "Выделить" } }
    var symbol: String { switch self { case .pen: "pencil.tip"; case .marker: "highlighter"; case .arrow: "arrow.up.right"; case .eraser: "eraser"; case .select: "cursorarrow" } }
}

final class PhoneModel: ObservableObject {
    @Published var computerName = "Mac"
    @Published var computers: [SavedComputer] = []
    @Published var invitation = UserDefaults.standard.string(forKey: "lastMac") ?? ""
    @Published var status = "Ваш Mac. Под рукой."
    @Published var detail = "Откройте доступ в WAI Remote на Mac и вставьте приглашение."
    @Published var connecting = false
    @Published var connected = false
    @Published var connectionInterrupted = false
    @Published var receivedFrame = false
    @Published var track: RTCVideoTrack? { didSet { if track !== oldValue { receivedFrame = false } } }
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
    private var retryTimer: Timer?
    private var interruptionTimer: Timer?
    private var retryDelay: TimeInterval = 1
    private var recoveryInvitation: String?
    private var heartbeatAcknowledged = false
    private var lastReply = ProcessInfo.processInfo.systemUptime
    private var currentInvite: RemoteInvite?
    private var resumeInvitation: String?
    private var attempt = UUID()
    private var snapshot: [InkStroke]?
    private var activeStroke: String?
    private var erasedIDs = Set<String>()
    private var nonce = ""
    private var answerAccepted = false
    private var offerStarted = false
    private(set) var lastCursor = InkPoint(0.5, 0.5)
    private var heldButtons = Set<Int>()
    var mode: RemoteMode { session.mode }
    var canControl: Bool { connected && receivedFrame && !connectionInterrupted && !session.invalidated && mode == .control && session.state?.permissions.control == true }
    var canDraw: Bool { connected && receivedFrame && !connectionInterrupted && !session.invalidated && mode == .draw && session.state?.permissions.annotate == true }
    var visibleStrokes: [InkStroke] { strokes.filter { previews[$0.id] == nil && !hiddenIDs.contains($0.id) } + previews.values.sorted { $0.id < $1.id } }

    init() {
        RTCInitializeSSL()
        prepareIdentity()
        if let data = UserDefaults.standard.data(forKey: "savedComputers"),
           let saved = try? JSONDecoder().decode([SavedComputer].self, from: data) {
            computers = saved.compactMap { try? SavedComputer(invitation: $0.invitation, name: $0.name) }
        }
    }
    func forget(_ id: String) {
        computers.removeAll { $0.id == id }
        saveComputers()
    }
    private func saveComputers() {
        if let data = try? JSONEncoder().encode(computers) { UserDefaults.standard.set(data, forKey: "savedComputers") }
    }
    private func remember() {
        guard let invite = currentInvite,
              let computer = try? SavedComputer(invitation: invite.savedURL.absoluteString, name: computerName) else { return }
        computers.removeAll { $0.id == computer.id }; computers.append(computer)
        saveComputers()
        invitation = computer.invitation
        UserDefaults.standard.set(invitation, forKey: "lastMac")
    }
    func suspend() {
        let target = connected ? currentInvite?.savedURL.absoluteString : recoveryInvitation
        disconnect(message: "Сеанс приостановлен")
        resumeInvitation = target
    }
    func resume() {
        prepareIdentity()
        guard let target = resumeInvitation else { return }
        resumeInvitation = nil; invitation = target; connect()
    }
    func prepareIdentity() {
        guard identity == nil else { return }
        do { identity = try PhoneIdentity.load(); status = "Ваш Mac. Под рукой."; detail = "Откройте доступ в WAI Remote на Mac и вставьте приглашение." }
        catch {
            status = "Не удалось открыть ключ устройства"
            detail = (error as NSError).code == Int(errSecInteractionNotAllowed) ? "Разблокируйте iPhone и вернитесь в приложение." : "Перезапустите приложение. Если ошибка повторится, понадобится проверить подпись сборки."
        }
    }
    func open(_ url: URL) {
        guard let invite = try? RemoteInvite(url.absoluteString) else { return }
        if connected || connecting { return }
        invitation = invite.invitationURL.absoluteString
        // Opening a link prepares the invitation; the visible Connect button starts the session.
    }
    func connect() {
        guard !connecting, !connected, let identity else { return }
        do {
            let invite = try RemoteInvite(invitation)
            disconnect(message: "", cancelRecovery: false)
            currentInvite = invite
            computerName = computers.first(where: { $0.id == invite.hostID })?.name ?? "Mac"
            connecting = true; status = "Подключаемся…"; detail = "Подключение через интернет. Ждём ответ Mac."
            let token = attempt
            let signal = ViewerSignaling(identity: identity, invite: invite); signaling = signal
            signal.onReady = { [weak self] configuration in guard let self, self.attempt == token, !self.offerStarted else { return }; self.offerStarted = true; self.createOffer(invite, token: token, ice: configuration) }
            signal.onMessage = { [weak self] message in guard let self, self.attempt == token else { return }; self.signal(message, invite: invite, token: token) }
            signal.onFailure = { [weak self] in
                guard let self, self.attempt == token else { return }
                if !self.connected { self.recover(message: "Ожидаем Mac…") }
            }
            timeout = Timer.connectionTimer(withTimeInterval: 110, repeats: false) { [weak self] _ in
                guard let self, self.attempt == token else { return }; self.recover(message: "Mac пока не отвечает…")
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
            if state == .failed || state == .closed { self.recover(message: "Восстанавливаем соединение…") }
            if state == .disconnected {
                self.liftHeldInput(); self.session.interrupt()
                self.connectionInterrupted = true; self.receivedFrame = false
                self.status = "Восстанавливаем соединение…"
                if self.interruptionTimer == nil {
                    self.interruptionTimer = Timer.connectionTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                        guard let self, self.attempt == token, self.connectionInterrupted else { return }
                        self.recover(message: "Восстанавливаем соединение…")
                    }
                }
            }
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
                    "name": String(UIDevice.current.name.prefix(40)), "sdp": sdp])
                var body = ["payload": payload.base64URL, "signature": try identity.sign(payload, domain: "wai-remote/offer/v1")]
                if let secret = invite.secret { body["proof"] = DeviceIdentity.pairingProof(secret: secret, payload: payload) }
                self.signaling?.send(["type": "offer", "body": body])
                self.status = invite.secret == nil ? "Подключаемся к Mac…" : "Подтвердите на Mac"; self.detail = "Первое подключение требует разрешения владельца Mac."
            } catch { self.recover(message: "Ищем сетевой маршрут…") }
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
                if error != nil { self.recover(message: "Восстанавливаем изображение…") }
            }
            if let name = payload["name"] as? String, !name.isEmpty, name.utf8.count <= 200 {
                computerName = String(name.prefix(60))
            }
        } else if message["type"] as? String == "unavailable" { recover(message: "Ожидаем Mac…") }
        else if message["type"] as? String == "reject" {
            let reason = (message["body"] as? [String: Any])?["reason"] as? String
            if reason == "network" || reason == "busy" { recover(message: reason == "busy" ? "Mac занят. Ожидаем освобождения…" : "Восстанавливаем соединение…"); return }
            disconnect(message: reason == "busy" ? "К Mac уже подключено другое устройство." : reason == "new-invite-required" ? "Нужно новое приглашение для настоящего экрана Mac." : "Подключение отклонено на Mac.")
        }
    }
    func recover(message: String) {
        let target = currentInvite.flatMap { invite in
            invite.secret == nil || connected || answerAccepted ? invite.savedURL.absoluteString : nil
        } ?? recoveryInvitation
        guard let target else { disconnect(message: message + " Попробуйте подключиться снова."); return }
        let delay = retryDelay
        disconnect(message: message, cancelRecovery: false)
        recoveryInvitation = target
        retryDelay = min(delay * 2, 15)
        connecting = true; connectionInterrupted = true
        detail = "Соединение восстановится автоматически. Можно отменить ожидание."
        retryTimer = Timer.connectionTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.recoveryInvitation == target else { return }
            self.retryTimer = nil; self.connecting = false; self.invitation = target; self.connect()
        }
    }
    func disconnect(message: String = "Вы отключились", cancelRecovery: Bool = true) {
        retryTimer?.invalidate(); retryTimer = nil
        interruptionTimer?.invalidate(); interruptionTimer = nil
        if cancelRecovery { recoveryInvitation = nil; retryDelay = 1 }
        heartbeatAcknowledged = false
        resumeInvitation = nil
        if connected, let release = session.release(), let data = try? JSONEncoder().encode(release) { _ = transport?.send(data) }
        attempt = UUID(); heartbeat?.invalidate(); heartbeat = nil; timeout?.invalidate(); timeout = nil
        signaling?.close(); signaling = nil; transport?.close(); transport = nil
        currentInvite = nil
        connecting = false; connected = false; connectionInterrupted = false; receivedFrame = false; track = nil; session = ViewerSession()
        strokes = []; previews = [:]; snapshot = nil; hiddenIDs = []; erasedIDs = []; activeStroke = nil; selectedID = nil
        answerAccepted = false; offerStarted = false; gestureRevision += 1; heldButtons = []
        UIApplication.shared.isIdleTimerDisabled = false
        if !message.isEmpty { status = message; detail = "Подключитесь снова, когда доступ на Mac открыт." }
    }
    /// Leaving the app ends only what this viewer holds and keeps the session
    /// valid, so the first tap after returning needs no round trip to the host.
    func liftHeldInput() {
        cancelGesture(notify: true)
        for button in heldButtons.sorted() { pointer("up", at: lastCursor, button: button) }
    }
    @discardableResult private func transmit(_ operation: WireMessage?) -> Bool {
        guard let operation, let data = try? JSONEncoder().encode(operation) else { return false }
        guard transport?.send(data) == true else { recover(message: "Восстанавливаем соединение…"); return false }
        return true
    }
    @discardableResult private func send(_ type: String, edit: (inout WireMessage) -> Void = { _ in }) -> Bool {
        guard var operation = session.make(type) else { return false }; edit(&operation); return transmit(operation)
    }
    private func decode<T: Decodable>(_ object: Any, as: T.Type) throws -> T { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object)) }
    private func receive(_ data: Data) {
        do {
            guard let m = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            lastReply = ProcessInfo.processInfo.systemUptime
            switch m["type"] as? String {
            case "heartbeatAck": heartbeatAcknowledged = true
            case "state":
                let state = try decode(m["state"] ?? [:], as: HostState.self)
                objectWillChange.send()
                if try session.accept(state) { cancelGesture(notify: false) }
                connectionInterrupted = false; interruptionTimer?.invalidate(); interruptionTimer = nil
                retryDelay = 1; recoveryInvitation = currentInvite?.savedURL.absoluteString
                if !connected {
                    connected = true; connecting = false; timeout?.invalidate(); timeout = nil
                    remember()
                    UIApplication.shared.isIdleTimerDisabled = true
                    heartbeat = Timer.connectionTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                        guard let self else { return }
                        if self.heartbeatAcknowledged && ProcessInfo.processInfo.systemUptime - self.lastReply > 8 {
                            self.recover(message: "Восстанавливаем соединение…")
                        } else { _ = self.send("heartbeat") }
                    }
                }
                status = mode == .paused ? "Владелец Mac приостановил управление" : m["lab"] as? Bool == true ? "Проверочный экран" : "Ваш Mac · защищённое соединение"
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
        } catch { disconnect(message: "Mac прислал некорректное состояние. Подключение остановлено.") }
    }
    func changeMode(_ mode: RemoteMode) { liftHeldInput(); _ = transmit(session.changeMode(mode)); selectedID = nil }
    func changeTool(_ value: DrawingTool) { cancelGesture(notify: true); tool = value; selectedID = nil }
    func pointer(_ action: String, at point: InkPoint, button: Int = 0, dx: Double = 0, dy: Double = 0) {
        // Ending a held button needs no control: it can only release.
        guard action == "up" ? heldButtons.remove(button) != nil : canControl else { return }; lastCursor = point
        if send("pointer", edit: { $0.action = action; $0.x = point.x; $0.y = point.y; $0.button = button; $0.deltaX = min(2000, max(-2000, dx)); $0.deltaY = min(2000, max(-2000, dy)) }),
           action == "down" { heldButtons.insert(button) }
    }
    func rightClick() { pointer("down", at: lastCursor, button: 2); pointer("up", at: lastCursor, button: 2) }
    func key(_ key: String, modifiers: [String] = []) {
        guard canControl else { return }
        for action in ["down", "up"] { send("key") { $0.key = key; $0.action = action; $0.modifiers = action == "down" ? modifiers : [] } }
    }
    func text(_ text: String) {
        guard canControl, !text.isEmpty, text.utf16.count <= 4096, !text.contains("\0") else { return }
        send("text") { $0.text = text }
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
