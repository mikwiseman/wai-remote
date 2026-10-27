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
    /// A tunnel's own address is private to this device (both Macs on one VPN share
    /// it, and pairs through it stalled SCTP input), and loopback reaches nobody.
    /// Reflexive and relay addresses stay: under a VPN that captures every route,
    /// the reflexive address on the tunnel is this device's public one.
    static func result(for sdp: String, tunnels: Set<String> = tunnelAddresses()) -> Result<String, Error> {
        let lines = sdp.components(separatedBy: "\r\n").filter { line in
            guard line.hasPrefix("a=candidate:") else { return true }
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count > 7, fields[7] == "host" else { return true }
            return !(fields[4].hasPrefix("127.") || fields[4] == "::1" || tunnels.contains(fields[4]))
        }
        guard lines.contains(where: { $0.hasPrefix("a=candidate:") }) else {
            return .failure(NSError(domain: "WebRTC", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не найден сетевой маршрут"]))
        }
        return .success(lines.joined(separator: "\r\n"))
    }
    static func tunnelAddresses() -> Set<String> {
        var addresses = Set<String>(), list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var next = list
        while let entry = next?.pointee {
            next = entry.ifa_next
            let name = String(cString: entry.ifa_name)
            guard ["utun", "ipsec", "ppp", "tun", "tap"].contains(where: name.hasPrefix), let address = entry.ifa_addr,
                  [AF_INET, AF_INET6].contains(Int32(address.pointee.sa_family)) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            addresses.insert(String(cString: host).components(separatedBy: "%")[0])
        }
        return addresses
    }
    func cancel() { timer?.invalidate(); timer = nil }
    deinit { cancel() }
}
