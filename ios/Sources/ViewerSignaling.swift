import Foundation
import RemoteCore

final class ViewerSignaling {
    private var socket: URLSessionWebSocketTask?
    private var ping: Timer?
    private let identity: DeviceIdentity
    private let invite: RemoteInvite
    var onReady: ((ICEConfiguration) -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    var onFailure: (() -> Void)?
    init(identity: DeviceIdentity, invite: RemoteInvite) { self.identity = identity; self.invite = invite }
    func connect() {
        let task = URLSession.shared.webSocketTask(with: invite.signalingURL)
        socket = task; task.maximumMessageSize = 131_072; task.resume(); receive(task)
        ping = Timer.connectionTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.send(["type": "ping"]) }
    }
    func send(_ object: [String: Any]) {
        guard let task = socket, let data = try? JSONSerialization.data(withJSONObject: object),
              data.count <= 131_072, let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self, weak task] error in
            if error != nil { DispatchQueue.main.async { guard let self, self.socket === task else { return }; self.onFailure?() } }
        }
    }
    private func receive(_ current: URLSessionWebSocketTask) {
        current.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.socket === current else { return }
                switch result {
                case .failure: self.onFailure?()
                case .success(let message):
                    let data: Data
                    switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: return }
                    guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { self.onFailure?(); return }
                    if object["type"] as? String == "challenge", let nonce = object["nonce"] as? String, nonce.count <= 100 {
                        let payload = Data("viewer\n\(self.invite.hostID)\n\(self.identity.id)\n\(nonce)".utf8)
                        guard let signature = try? self.identity.sign(payload, domain: "wai-remote/signal/v1") else { self.onFailure?(); return }
                        self.send(["type": "hello", "role": "viewer", "hostID": self.invite.hostID, "peerID": self.identity.id, "publicKey": self.identity.publicKey, "signature": signature])
                    } else if object["type"] as? String == "ready" {
                        do { self.onReady?(try ICEConfiguration.read(object)) }
                        catch { self.onFailure?(); self.close(); return }
                    }
                    else { self.onMessage?(object) }
                    if self.socket === current { self.receive(current) }
                }
            }
        }
    }
    func close() { ping?.invalidate(); ping = nil; let task = socket; socket = nil; task?.cancel(with: .goingAway, reason: nil) }
}
