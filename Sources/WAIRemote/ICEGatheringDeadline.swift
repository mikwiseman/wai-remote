import Foundation
import RemoteCore

/// Non-trickle signaling sends one signed SDP. A stalled interface must not discard
/// working candidates gathered on another interface (common with VPN adapters).
final class ICEGatheringDeadline {
    private var timer: Timer?
    private let relayConfigured: Bool
    init(ice: ICEConfiguration) {
        relayConfigured = ice.iceServers.flatMap(\.urls).contains { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
    }
    func start(description: @escaping () -> String?, completion: @escaping (Result<String, Error>) -> Void) {
        cancel()
        let started = ProcessInfo.processInfo.systemUptime
        timer = Timer.connectionTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            let sdp = description() ?? ""
            let candidates = sdp.components(separatedBy: .newlines).filter { $0.hasPrefix("a=candidate:") }
            let hasRelay = candidates.contains { $0.contains(" typ relay") }
            // Allow both UDP and TCP relays time to arrive. If the relay is
            // unreachable, retain direct candidates at the final deadline.
            guard elapsed >= 12 || elapsed >= 2 && !candidates.isEmpty && (hasRelay || !self.relayConfigured) else { return }
            self.cancel()
            if !candidates.isEmpty {
                PerformanceLog.record("ice-ready", ["gatheringMs": elapsed * 1000, "candidateCount": candidates.count, "hasRelay": hasRelay])
            }
            completion(Self.result(for: sdp))
        }
    }
    static func result(for sdp: String) -> Result<String, Error> {
        guard sdp.components(separatedBy: .newlines).contains(where: { $0.hasPrefix("a=candidate:") }) else {
            return .failure(NSError(domain: "WebRTC", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не найден сетевой маршрут"]))
        }
        return .success(sdp)
    }
    func cancel() { timer?.invalidate(); timer = nil }
    deinit { cancel() }
}
