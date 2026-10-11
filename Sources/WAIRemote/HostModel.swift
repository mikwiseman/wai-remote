import AppKit
import SwiftUI
import ScreenCaptureKit
import CryptoKit
import RemoteCore
import WebRTC

struct Offer: Codable {
    let hostID: String
    let peerID: String
    let publicKey: String
    let nonce: String
    let expiresAt: Double
    let name: String
    let sdp: String
}
struct PendingPeer: Identifiable {
    var id: String { offer.peerID }
    let offer: Offer
}

final class HostModel: ObservableObject {
    @Published var status = "Доступ закрыт"
    @Published var detail = "Откройте доступ, когда будете готовы."
    @Published var sharing = false
    @Published var starting = false
    @Published var isLab = false
    @Published var connectedName: String?
    @Published var pending: PendingPeer?
    @Published var invite = ""
    @Published var localDrawing = false
    @Published var screenAllowed = CGPreflightScreenCaptureAccess()
    @Published var controlAllowed = CGPreflightPostEventAccess()
    @Published var gateway = UserDefaults.standard.string(forKey: "signalingGateway") ?? "https://waiwai.is/remote/connect/"
    @Published var peers = KeyStore.peers()
    let identity: DeviceIdentity
    private let factory: RTCPeerConnectionFactory
    private var capture: VideoCapture?
    private var captureStartTask: Task<Void, Never>?
    private var capturedDisplay: SCDisplay?
    private var signaling: Signaling?
    private var transport: PeerTransport?
    private var iceConfiguration = ICEConfiguration.local
    private var machine: SessionMachine?
    private let injector = InputInjector()
    private var overlay: InkOverlay?
    private var labWindow: NSWindow?
    private var inputTestWindow: NSWindow?
    private var labImage: NSImageView?
    private var labInk: InkView?
    private var secret: Data?
    private var secretExpiry = Date.distantPast
    private var seenNonces: [String: Date] = [:]
    private var tick: Timer?
    private var observers: [NSObjectProtocol] = []
    private var localStrokeID: String?
    private var activity: NSObjectProtocol?
    private var connectionDeadline: TimeInterval?
    private var connectionGeneration = UUID()
    private var capturedScreenFrame: CGRect?
    @Published var permissionRequested = false
    private var surface = Surface(id: "lab", width: 1280, height: 800)

    init(identity: DeviceIdentity) {
        self.identity = identity
        RTCInitializeSSL()
        factory = RTCPeerConnectionFactory(encoderFactory: ScreenVideoEncoderFactory(), decoderFactory: ScreenVideoDecoderFactory())
        for event in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in self?.stop(reason: "Сеанс Mac завершён или заблокирован") })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.sharing, !self.isLab else { return }
            // AppKit posts this for unrelated display/settings changes too.
            let screen = NSScreen.screens.first { String(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) ?? 0) == self.surface.id }
            guard let screen, screen.frame == self.capturedScreenFrame else {
                self.stop(reason: "Общий экран изменился. Откройте доступ для нового размера."); return
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshPermissions()
        })
        // Extra defense on current macOS, not a documented security API. Physical lock verification remains a release gate.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenLocked), name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        tick = Timer.connectionTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.housekeeping() }
    }
    @objc private func screenLocked() { DispatchQueue.main.async { [weak self] in self?.stop(reason: "Mac заблокирован") } }
    func refreshPermissions() {
        let screen = CGPreflightScreenCaptureAccess(), control = CGPreflightPostEventAccess()
        if screenAllowed != screen { screenAllowed = screen }
        if controlAllowed != control { controlAllowed = control }
        if sharing, let machine { apply(machine.setSystemControlAllowed(isLab || control)) }
    }
    func showInputTest() {
        if inputTestWindow == nil {
            let window = NSWindow(contentRect: NSRect(x:0,y:0,width:760,height:620), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
            window.contentMinSize = NSSize(width: 680, height: 580)
            window.title = "Проверка ввода — WAI Remote"; window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentViewController = NSHostingController(rootView: InputTestView())
            inputTestWindow = window
        }
        inputTestWindow?.center(); inputTestWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func requestScreen() {
        permissionRequested = true
        _ = CGRequestScreenCaptureAccess(); refreshPermissions()
        if !screenAllowed { openPermissionSettings("Privacy_ScreenCapture") }
    }
    func requestControl() {
        permissionRequested = true
        _ = CGRequestPostEventAccess(); refreshPermissions()
        if !controlAllowed { openPermissionSettings("Privacy_Accessibility") }
    }
    private func openPermissionSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
    func restartForPermissions() {
        let resumeKey = "continueSharingAfterPermissionRestart"
        UserDefaults.standard.set(true, forKey: resumeKey)
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"$2\"", "wai-remote-relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do { try helper.run(); NSApp.terminate(nil) }
        catch { UserDefaults.standard.removeObject(forKey: resumeKey); status = "Не удалось перезапустить. Закройте WAI Remote и откройте снова." }
    }
    func start(lab: Bool) {
        guard !sharing, !starting else { return }
        refreshPermissions()
        if !lab && !screenAllowed { status = "Нужно разрешение на запись экрана"; return }
        guard let base = URL(string: gateway), RemoteInvite.isAllowedGateway(base) else {
            status = "Укажите HTTPS-сервер или адрес в локальной сети"; return
        }
        starting = true; isLab = lab; status = "Подготовка…"; connectionGeneration = UUID()
        let generation = connectionGeneration
        let video = makeCapture(); capture = video
        Task { @MainActor in
            do {
                if lab {
                    surface = Surface(id: "lab", width: 1280, height: 800); showLab()
                    video.onLabImage = { [weak self] image in self?.labImage?.image = image }; video.startLab()
                } else {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }), let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == display.displayID }) else { throw NSError(domain: "Capture", code: 1) }
                    guard connectionGeneration == generation else { return }
                    overlay = InkOverlay(screen: screen); overlay?.view.onDraw = { [weak self] type, point in self?.drawLocally(type, point) }
                    overlay?.onFinish = { [weak self] in if self?.localDrawing == true { self?.toggleLocalDraw() } }
                    overlay?.onClear = { [weak self] in self?.clearInk() }
                    surface = Surface(id: String(display.displayID), width: Int(screen.frame.width), height: Int(screen.frame.height))
                    capturedScreenFrame = screen.frame
                    capturedDisplay = display
                    injector.bounds = CGDisplayBounds(display.displayID)
                    try await video.startDisplay(display, excluding: [CGWindowID(overlay!.panel.windowNumber)])
                }
                guard connectionGeneration == generation else { video.stop(); return }
                // Validate screen permission while the owner is here, then idle
                // until a viewer connects. Each session gets a fresh SCStream.
                if !lab { video.stop(); capture = nil }
                sharing = true; starting = false; status = "Подключаем сервер…"
                let signal = Signaling(identity: identity); signaling = signal
                signal.onRelayRefresh = { [weak self] configuration in self?.iceConfiguration = configuration }
                signal.onReady = { [weak self] configuration in
                    guard let self else { return }
                    self.iceConfiguration = configuration
                    UserDefaults.standard.set(self.gateway, forKey: "signalingGateway")
                    self.status = "Доступ открыт"; self.detail = "Подключение нового устройства потребует вашего подтверждения."; self.newInvite()
                }
                signal.onMessage = { [weak self] object in self?.receiveSignal(object) }
                signal.onFailure = { [weak self] error in self?.stop(reason: error) }
                var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                components.scheme = base.scheme == "https" ? "wss" : "ws"
                components.path = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "/signal" : "/" + base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/signal"
                signal.connect(url: components.url!)
            } catch {
                guard connectionGeneration == generation else { video.stop(); return }
                stop(reason: "Не удалось начать захват: \(error.localizedDescription)")
            }
        }
    }
    func newInvite() {
        guard sharing else { return }
        var data = Data(count: 32); let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard result == errSecSuccess else { stop(reason: "Не удалось создать ключ приглашения"); return }
        secret = data; secretExpiry = Date().addingTimeInterval(600)
        var url = URLComponents(string: gateway)!
        if !url.path.hasSuffix("/") { url.path += "/" }; url.query = nil
        var fragment = URLComponents(); fragment.queryItems = [URLQueryItem(name: "host", value: identity.id), URLQueryItem(name: "key", value: identity.publicKey), URLQueryItem(name: "secret", value: data.base64URL)]
        url.percentEncodedFragment = fragment.percentEncodedQuery; invite = url.url!.absoluteString
    }
    func copyInvite() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(invite, forType: .string) }
    func openViewer() { if let url = URL(string: gateway) { NSWorkspace.shared.open(url) } }
    private func receiveSignal(_ object: [String: Any]) {
        guard sharing, object["type"] as? String == "offer", let from = object["from"] as? String,
              let body = object["body"] as? [String: Any], let payloadString = body["payload"] as? String,
              let payload = Data(base64URL: payloadString), let signature = body["signature"] as? String,
              let offer = try? JSONDecoder().decode(Offer.self, from: payload), offer.peerID == from,
              offer.hostID == identity.id, offer.name.utf8.count <= 100, !offer.name.isEmpty,
              offer.sdp.utf8.count <= 80_000, offer.nonce.count == 43,
              offer.expiresAt >= Date().timeIntervalSince1970 * 1000,
              offer.expiresAt <= (Date().timeIntervalSince1970 + 120) * 1000,
              let pub = Data(base64URL: offer.publicKey), DeviceIdentity.id(publicKeyData: pub) == from,
              DeviceIdentity.verify(signature, data: payload, domain: "wai-remote/offer/v1", publicKey: offer.publicKey),
              seenNonces[offer.nonce] == nil else { return }
        let trusted = peers.first { $0.id == from && $0.publicKey == offer.publicKey }
        let proofValid = secret != nil && secretExpiry > Date() && DeviceIdentity.verifyPairingProof(body["proof"] as? String ?? "", secret: secret!, payload: payload)
        guard trusted != nil || proofValid else { return }
        // A signed retry from the same device can replace its unfinished attempt.
        // An established session or another device still owns the connection.
        if transport != nil, transport?.isReady == false, machine?.author == from { disconnectViewer() }
        guard transport == nil, pending == nil else { signaling?.send(["type":"reject","to":from,"body":["reason":"busy"]]); return }
        seenNonces[offer.nonce] = Date()
        if let trusted, isLab || !trusted.labOnly { connect(offer, permissions: trusted.permissions) }
        else if proofValid { pending = PendingPeer(offer: offer); NSApp.activate(ignoringOtherApps: true) }
        else { signaling?.send(["type":"reject","to":from,"body":["reason":"new-invite-required"]]) }
    }
    func approve(control: Bool) {
        guard let offer = pending?.offer, sharing else { return }
        pending = nil
        guard offer.expiresAt >= Date().timeIntervalSince1970 * 1000 else { return }
        let permission = Permissions(control: control && (isLab || controlAllowed), annotate: true)
        let peer = TrustedPeer(id: offer.peerID, publicKey: offer.publicKey, name: offer.name, permissions: permission, labOnly: isLab)
        var updated = peers.filter { $0.id != peer.id }; updated.append(peer)
        do { try KeyStore.save(updated); peers = updated }
        catch { status = "Не удалось сохранить устройство"; return }
        secret = nil; invite = ""; connect(offer, permissions: permission)
    }
    func reject() { if let pending { signaling?.send(["type":"reject","to":pending.id,"body":["reason":"declined"]]) }; pending = nil }
    private func connect(_ offer: Offer, permissions: Permissions) {
        guard sharing else { return }
        if !isLab { capture = makeCapture() }
        guard let capture, sharing else { return }
        if let machine, machine.author == offer.peerID, machine.state.surface == surface {
            machine.reconnect(); _ = machine.setPermissions(permissions)
        } else { machine = SessionMachine(surface: surface, permissions: permissions, author: offer.peerID) }
        _ = machine?.setSystemControlAllowed(isLab || controlAllowed)
        if !iceConfiguration.iceServers.isEmpty && iceConfiguration.expiresAt <= Date().timeIntervalSince1970 {
            stop(reason: "Параметры подключения истекли. Откройте доступ заново."); return
        }
        let peer = PeerTransport(factory: factory, source: capture.source, ice: iceConfiguration); transport = peer
        connectedName = offer.name; status = "Соединяемся…"
        connectionDeadline = ProcessInfo.processInfo.systemUptime + 20
        let generation = connectionGeneration
        peer.onOpen = { [weak self, weak peer] in
            guard let self, self.transport === peer else { return }
            self.connectionDeadline = nil
            self.status = "Устройство подключено"; self.sendState(); self.sendSnapshot()
            guard self.transport === peer, self.capture === capture, self.sharing else { return }
            self.activity = ProcessInfo.processInfo.beginActivity(options: .userInteractive, reason: "WAI Remote active session")
            if !self.isLab, let display = self.capturedDisplay {
                let excluded = self.overlay.map { [CGWindowID($0.panel.windowNumber)] } ?? []
                self.captureStartTask = Task { @MainActor [weak self, weak peer] in
                    do {
                        try Task.checkCancellation()
                        try await capture.startDisplay(display, excluding: excluded)
                    } catch {
                        guard let self, self.capture === capture, self.transport === peer else { return }
                        self.stop(reason: "Не удалось начать захват: \(error.localizedDescription)")
                    }
                }
            }
        }
        peer.onMessage = { [weak self, weak peer] data in guard let self, self.transport === peer else { return }; self.receiveInteraction(data) }
        peer.onState = { [weak self, weak peer] state in
            guard let self, self.transport === peer else { return }
            if state == .failed || state == .closed { self.disconnectViewer() }
            if state == .disconnected { if let machine = self.machine { self.apply(machine.transportInterrupted()) } }
            if state == .connected { if let machine = self.machine { self.apply(machine.transportRestored()) } }
        }
        peer.answer(offer: offer.sdp) { [weak self, weak peer] result in
            guard let self, self.connectionGeneration == generation, self.transport === peer else { return }
            switch result {
            case .failure:
                self.signaling?.send(["type":"reject","to":offer.peerID,"body":["reason":"network"]])
                self.disconnectViewer(); self.status = "Не удалось установить соединение. Можно попробовать снова."
            case .success(let sdp):
                let answer: [String: Any] = ["hostID":self.identity.id,"peerID":offer.peerID,"nonce":offer.nonce,"sdp":sdp,"lab":self.isLab,"name":String((Host.current().localizedName ?? "Mac").prefix(60))]
                guard let data = try? JSONSerialization.data(withJSONObject: answer), let sig = try? self.identity.sign(data, domain: "wai-remote/answer/v1") else { return }
                self.signaling?.send(["type":"answer","to":offer.peerID,"body":["payload":data.base64URL,"signature":sig]])
            }
        }
    }
    private func receiveInteraction(_ data: Data) {
        guard sharing, let machine, let m = try? JSONDecoder().decode(WireMessage.self, from: data) else { return }
        let handlingStart = ProcessInfo.processInfo.systemUptime
        let effects = machine.handle(m, now: ProcessInfo.processInfo.systemUptime)
        if effects.accepted {
            if m.type.hasPrefix("stroke") { if transport?.send(["type":"ink","author":machine.author,"op":m.jsonObject()]) != true { disconnectViewer(); return } }
            apply(effects)
            if PerformanceLog.enabled && (m.type == "heartbeat" || m.type == "pointer" && m.action != "move") {
                PerformanceLog.record("input-applied", ["kind": m.type, "action": m.action ?? "", "handlingMs": (ProcessInfo.processInfo.systemUptime - handlingStart) * 1000])
                _ = transport?.send(["type": "performanceAck", "id": m.operationID])
            }
        } else if m.type != "heartbeat" { sendState(); sendSnapshot() }
    }
    private func apply(_ e: SessionEffects) {
        if e.releaseInput { injector.releaseAll() }
        if machine?.stalled == true, let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        if e.accepted, machine?.connected == true, machine?.stalled == false, transport?.isReady == true, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInteractive, reason: "WAI Remote active session")
        }
        if let input = e.input { if isLab { capture?.applyLab(input) } else { injector.apply(input) } }
        if let point = e.laser {
            overlay?.view.showLaser(point); labInk?.showLaser(point)
            _ = transport?.send(["type":"laser", "point":point.jsonObject()])
        }
        if e.inkChanged { refreshInk() }
        if e.stateChanged { sendState() }
        if e.snapshot { sendSnapshot() }
    }
    private func sendState() { if let machine { _ = transport?.send(["type":"state","state":machine.state.jsonObject(),"lab":isLab]) } }
    private func sendSnapshot() {
        guard let machine, let transport else { return }
        guard transport.send(["type":"snapshotBegin","layerEpoch":machine.ink.epoch]) else { disconnectViewer(); return }
        for stroke in machine.ink.committed {
            var metadata = stroke; metadata.points = []; metadata.complete = false
            guard transport.send(["type":"snapshotStroke","stroke":metadata.jsonObject()]) else { disconnectViewer(); return }
            for start in stride(from: 0, to: stroke.points.count, by: 128) {
                let points = Array(stroke.points[start..<min(start+128,stroke.points.count)])
                guard transport.send(["type":"snapshotPoints","id":stroke.id,"points":points.jsonObject()]) else { disconnectViewer(); return }
            }
        }
        guard transport.send(["type":"snapshotEnd"]) else { disconnectViewer(); return }
    }
    private func refreshInk() { let strokes = machine?.ink.visible ?? []; overlay?.view.strokes = strokes; labInk?.strokes = strokes }
    func toggleLocalDraw() {
        guard let machine else { return }
        localDrawing.toggle(); localStrokeID = nil
        if localDrawing { apply(machine.pause(reason: "host-drawing")) } else { apply(machine.resume()) }
        overlay?.drawing = localDrawing; labInk?.onDraw = localDrawing ? { [weak self] type, point in self?.drawLocally(type, point) } : nil
    }
    private func drawLocally(_ type: String, _ point: InkPoint) {
        guard localDrawing, let machine else { return }
        if type == "strokeBegin" { localStrokeID = UUID().uuidString }
        guard let id = localStrokeID else { return }
        var message = WireMessage(type: type, state: machine.state); message.strokeID = id
        message.tool = .pen; message.color = "#2B77D1"; message.width = 4; message.points = [point]
        if machine.ink.apply(message, author: "host") { refreshInk(); _ = transport?.send(["type":"ink","author":"host","op":message.jsonObject()]) }
        if type == "strokeEnd" { localStrokeID = nil }
    }
    func clearInk() { if let machine { apply(machine.clearAllLocally()) } }
    private func makeCapture() -> VideoCapture {
        let video = VideoCapture(factory: factory)
        video.onError = { [weak self, weak video] _ in
            guard let self, self.capture === video else { return }
            self.stop(reason: "Захват экрана остановлен системой")
        }
        return video
    }
    private func stopCapture() {
        let video = capture, start = captureStartTask
        capture = nil; captureStartTask = nil
        start?.cancel()
        // A disconnect can arrive while ScreenCaptureKit is starting. Wait for
        // that start to finish before stopping its stream, even after reconnect.
        Task { @MainActor in
            await start?.value
            video?.stop()
        }
    }
    func disconnectViewer() {
        connectionDeadline = nil
        injector.releaseAll(); machine?.disconnect(); transport?.close(); transport = nil; connectedName = nil
        if !isLab { stopCapture() }
        localDrawing = false; overlay?.drawing = false; localStrokeID = nil; refreshInk()
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        if sharing { status = "Доступ открыт"; detail = "Устройство отключено. Новое подключение возможно до закрытия доступа." }
    }
    func forget(_ id: String) {
        if machine?.author == id { disconnectViewer() }
        let updated = peers.filter { $0.id != id }
        do { try KeyStore.save(updated); peers = updated } catch { status = "Не удалось удалить устройство" }
    }
    func stop(reason: String = "Доступ закрыт") {
        connectionGeneration = UUID(); sharing = false; starting = false
        disconnectViewer(); machine?.stop(); machine = nil
        stopCapture(); capturedDisplay = nil; capturedScreenFrame = nil; overlay?.close(); overlay = nil; labWindow?.orderOut(nil)
        signaling?.close(); signaling = nil; pending = nil; secret = nil; invite = ""; status = reason
        detail = "Чтобы подключиться снова, откройте доступ на этом Mac."
    }
    private func housekeeping() {
        refreshPermissions()
        if sharing && !isLab && !screenAllowed { stop(reason: "Разрешение на экран отозвано"); return }
        if let deadline = connectionDeadline, ProcessInfo.processInfo.systemUptime >= deadline {
            if let author = machine?.author { signaling?.send(["type":"reject","to":author,"body":["reason":"network"]]) }
            disconnectViewer(); status = "Не удалось установить соединение. Можно попробовать снова."
        }
        if let machine { apply(machine.tick(now: ProcessInfo.processInfo.systemUptime)) }
        if let pending, pending.offer.expiresAt < Date().timeIntervalSince1970 * 1000 { reject() }
        if secretExpiry < Date() { secret = nil; invite = "" }
        seenNonces = seenNonces.filter { Date().timeIntervalSince($0.value) < 150 }
    }
    func showLab() {
        if labWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
            window.title = "WAI Remote — проверочный экран"; window.isReleasedWhenClosed = false
            window.contentAspectRatio = NSSize(width: 1280,height:800)
            let root = NSView(frame: NSRect(x:0,y:0,width:960,height:600))
            let image = NSImageView(frame: root.bounds); image.imageScaling = .scaleAxesIndependently; image.autoresizingMask = [.width,.height]
            let ink = InkView(frame: root.bounds); ink.autoresizingMask = [.width,.height]
            root.addSubview(image); root.addSubview(ink); window.contentView = root
            labWindow = window; labImage = image; labInk = ink
        }
        labWindow?.center(); labWindow?.makeKeyAndOrderFront(nil)
    }
}
