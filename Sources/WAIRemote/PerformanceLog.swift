import Foundation
import WebRTC

/// Opt-in, local measurements. Never record SDP, addresses, device names, or input contents.
enum PerformanceLog {
    static let enabled = UserDefaults.standard.bool(forKey: "performanceDiagnostics")
    private static let queue = DispatchQueue(label: "is.wai.remote.performance", qos: .utility)
    private static let url = FileManager.default.temporaryDirectory.appendingPathComponent("wai-remote-performance-\(ProcessInfo.processInfo.processIdentifier).jsonl")
    private static var written = 0
    static let fields: Set<String> = [
        "kind", "mimeType", "codecId", "frameWidth", "frameHeight", "framesPerSecond",
        "framesEncoded", "framesDecoded", "framesDropped", "framesReceived", "framesSent",
        "bytesSent", "bytesReceived", "packetsLost", "packetsReceived", "packetsSent",
        "totalEncodeTime", "totalDecodeTime", "totalPacketSendDelay", "qpSum",
        "qualityLimitationReason", "qualityLimitationDurations", "encoderImplementation", "decoderImplementation",
        "jitter", "jitterBufferDelay", "jitterBufferTargetDelay", "jitterBufferEmittedCount",
        "freezeCount", "totalFreezesDuration", "nackCount", "pliCount", "keyFramesDecoded",
        "currentRoundTripTime", "roundTripTime", "availableOutgoingBitrate", "availableIncomingBitrate",
        "state", "nominated", "candidateType", "protocol", "relayProtocol", "networkType",
        "selectedCandidatePairId", "localCandidateId", "remoteCandidateId", "powerEfficientEncoder", "powerEfficientDecoder"
    ]
    static func record(_ event: String, _ values: [String: Any] = [:]) {
        guard enabled else { return }
        let row = values.merging(["event": event, "time": Date().timeIntervalSince1970]) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        queue.async {
            // Bound a diagnostic run to 20 MB. Restarting the app starts a new file.
            guard written < 20_000_000 else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let file = try? FileHandle(forWritingTo: url) else { return }
            defer { try? file.close() }
            do { try file.seekToEnd(); try file.write(contentsOf: data + Data([10])); written += data.count + 1 } catch {}
        }
    }
    static func record(_ report: RTCStatisticsReport, role: String, buffered: UInt64) {
        let stats = report.statistics.values.filter {
            ["inbound-rtp", "outbound-rtp", "remote-inbound-rtp", "candidate-pair", "local-candidate", "remote-candidate", "codec", "transport"].contains($0.type)
        }.map { stat -> [String: Any] in
            ["id": stat.id, "type": stat.type, "values": stat.values.filter { fields.contains($0.key) }]
        }
        record("rtc", ["role": role, "bufferedBytes": buffered, "stats": stats])
    }
}
