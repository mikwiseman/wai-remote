import Foundation
import RemoteCore

final class Signaling {
    private let identity: DeviceIdentity
    private var socket: URLSessionWebSocketTask?
    private var ping: Timer?
    var onReady: ((ICEConfiguration) -> Void)?
    var onRelayRefresh: ((ICEConfiguration) -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    var onFailure: ((String) -> Void)?
    init(identity: DeviceIdentity) { self.identity = identity }
    func connect(url: URL) {
        let socket = URLSession.shared.webSocketTask(with: url); self.socket = socket
        socket.maximumMessageSize = 131_072; socket.resume(); receive(socket)
        ping = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.send(["type": "ping"]) }
    }
    private func receive(_ current: URLSessionWebSocketTask) {
        current.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.socket === current else { return }
                switch result {
                case .failure: self.onFailure?("Сервер подключения недоступен"); self.close()
                case .success(let message):
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: return }
                    if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] { self.handle(object) }
                    if self.socket === current { self.receive(current) }
                }
            }
        }
    }
    private func handle(_ object: [String: Any]) {
        if object["type"] as? String == "challenge", let nonce = object["nonce"] as? String, nonce.utf8.count <= 100 {
            let payload = Data("host\n\(identity.id)\n\(identity.id)\n\(nonce)".utf8)
            guard let sig = try? identity.sign(payload, domain: "wai-remote/signal/v1") else { return }
            send(["type":"hello","role":"host","hostID":identity.id,"peerID":identity.id,"publicKey":identity.publicKey,"signature":sig])
        } else if ["ready", "relay"].contains(object["type"] as? String ?? "") {
            do {
                let configuration = try ICEConfiguration.read(object)
                if object["type"] as? String == "relay" { onRelayRefresh?(configuration) }
                else { onReady?(configuration) }
            }
            catch { onFailure?("Сервер передал недействительные параметры подключения"); close() }
        }
        else { onMessage?(object) }
    }
    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let string = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(string)) { _ in }
    }
    func close() { ping?.invalidate(); ping = nil; socket?.cancel(with: .goingAway, reason: nil); socket = nil }
}
