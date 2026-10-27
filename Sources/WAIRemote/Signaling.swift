import Foundation
import RemoteCore

final class Signaling {
    private let identity: DeviceIdentity
    private var socket: URLSessionWebSocketTask?
    private var ping: Timer?
    private var endpoint: URL?
    private var retry: Timer?
    private var retryDelay: TimeInterval = 1
    private var lastReply = ProcessInfo.processInfo.systemUptime
    private let heartbeatInterval: TimeInterval
    private let responseTimeout: TimeInterval
    var onReady: ((ICEConfiguration) -> Void)?
    var onRelayRefresh: ((ICEConfiguration) -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    var onReconnecting: (() -> Void)?
    init(identity: DeviceIdentity, heartbeatInterval: TimeInterval = 20, responseTimeout: TimeInterval = 45) {
        self.identity = identity; self.heartbeatInterval = heartbeatInterval; self.responseTimeout = responseTimeout
    }
    func connect(url: URL) {
        close(); endpoint = url; openSocket()
    }
    private func openSocket() {
        guard let url = endpoint else { return }
        let socket = URLSession.shared.webSocketTask(with: url); self.socket = socket
        socket.maximumMessageSize = 131_072; socket.resume(); receive(socket)
        lastReply = ProcessInfo.processInfo.systemUptime
        ping = Timer.connectionTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self, weak socket] _ in
            guard let self, let socket, self.socket === socket else { return }
            if ProcessInfo.processInfo.systemUptime - self.lastReply > self.responseTimeout { self.reconnect(after: socket) }
            else { self.send(["type": "ping"]) }
        }
    }
    private func receive(_ current: URLSessionWebSocketTask) {
        current.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.socket === current else { return }
                switch result {
                case .failure(let error): self.reconnect(after: current, error: error)
                case .success(let message):
                    self.lastReply = ProcessInfo.processInfo.systemUptime
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: return }
                    if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { self.handle(object) }
                    if self.socket === current { self.receive(current) }
                }
            }
        }
    }
    private func reconnect(after current: URLSessionWebSocketTask, error: Error? = nil) {
        guard socket === current else { return }
        // A duplicate registration may remain on the gateway until its old socket
        // times out. Retry that rejection too; only explicit authentication failure
        // is terminal. Never tear down an established WebRTC session here.
        let authenticationFailed = current.closeCode == .policyViolation &&
            current.closeReason.flatMap { String(data: $0, encoding: .utf8) } == "authentication failed"
        var diagnostic: [String: Any] = ["closeCode": current.closeCode.rawValue]
        if let error = error as NSError? { diagnostic["domain"] = error.domain; diagnostic["code"] = error.code }
        PerformanceLog.record("host-signaling-lost", diagnostic)
        socket = nil; ping?.invalidate(); ping = nil
        current.cancel(with: .goingAway, reason: nil)
        if authenticationFailed {
            close(); onFailure?("Сервер не подтвердил устройство"); return
        }
        guard endpoint != nil else { return }
        retry = Timer.connectionTimer(withTimeInterval: retryDelay, repeats: false) { [weak self] _ in
            self?.retry = nil; self?.openSocket()
        }
        retryDelay = min(retryDelay * 2, 8)
        onReconnecting?()
    }
    private func handle(_ object: [String: Any]) {
        if object["type"] as? String == "challenge", let nonce = object["nonce"] as? String, nonce.utf8.count <= 100 {
            let payload = Data("host\n\(identity.id)\n\(identity.id)\n\(nonce)".utf8)
            guard let sig = try? identity.sign(payload, domain: "wai-remote/signal/v1") else { return }
            send(["type":"hello","role":"host","hostID":identity.id,"peerID":identity.id,"publicKey":identity.publicKey,"signature":sig,"iceVersion":4])
        } else if ["ready", "relay"].contains(object["type"] as? String ?? "") {
            do {
                let configuration = try ICEConfiguration.read(object)
                if object["type"] as? String == "relay" { onRelayRefresh?(configuration) }
                else {
                    retryDelay = 1
                    PerformanceLog.record("host-signaling-ready")
                    onReady?(configuration)
                }
            }
            catch { close(); onFailure?("Сервер передал недействительные параметры подключения") }
        }
        else { onMessage?(object) }
    }
    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let string = String(data: data, encoding: .utf8) else { return }
        guard let current = socket else { return }
        current.send(.string(string)) { [weak self, weak current] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                guard let self, let current, self.socket === current else { return }
                self.reconnect(after: current, error: error)
            }
        }
    }
    func close() {
        endpoint = nil; retry?.invalidate(); retry = nil; retryDelay = 1
        ping?.invalidate(); ping = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }
}
