import Foundation
import WebRTC

/// Opt-in, local measurements. Never record SDP, addresses, device names, or input contents.
enum PerformanceLog {
    static let enabled = UserDefaults.standard.bool(forKey: "performanceDiagnostics")
    static func startNetworkTrace(_ connection: RTCPeerConnection, role: String) {
        guard enabled, UserDefaults.standard.bool(forKey: "performanceNetworkTrace") else { return }
        // This extra opt-in contains network metadata. Keep it private and separate
        // from the content-free JSONL diagnostics; never upload it with a report.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("wai-remote-network-\(ProcessInfo.processInfo.processIdentifier)-\(role).rtc")
        FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let started = connection.startRtcEventLog(withFilePath: path.path, maxSizeInBytes: 20_000_000)
        record("network-trace", ["started": started, "role": role])
    }
    private static let queue = DispatchQueue(label: "is.wai.remote.performance", qos: .utility)
    private static let url = FileManager.default.temporaryDirectory.appendingPathComponent("wai-remote-performance-\(ProcessInfo.processInfo.processIdentifier).jsonl")
    private static var written = 0
    static let fields: Set<String> = [
        "kind", "mimeType", "codecId", "frameWidth", "frameHeight", "framesPerSecond",
        "framesEncoded", "framesDecoded", "framesDropped", "framesReceived", "framesSent",
        "bytesSent", "bytesReceived", "packetsLost", "packetsReceived", "packetsSent",
        "totalEncodeTime", "totalDecodeTime", "totalPacketSendDelay", "qpSum", "targetBitrate",
        "qualityLimitationReason", "qualityLimitationDurations", "encoderImplementation", "decoderImplementation",
        "jitter", "jitterBufferDelay", "jitterBufferTargetDelay", "jitterBufferEmittedCount",
        "freezeCount", "totalFreezesDuration", "nackCount", "pliCount", "keyFramesDecoded",
        "fecPacketsReceived", "fecPacketsDiscarded",
        "currentRoundTripTime", "roundTripTime", "availableOutgoingBitrate", "availableIncomingBitrate",
        "state", "nominated", "candidateType", "protocol", "relayProtocol", "networkType",
        "selectedCandidatePairId", "localCandidateId", "remoteCandidateId", "powerEfficientEncoder", "powerEfficientDecoder"
    ]
    static func record(_ event: String, _ values: [String: Any] = [:]) {
        guard enabled else { return }
        guard let safe = DiagnosticPrivacy.sanitize(event, values: values) else { return }
        let row = safe.merging(["event": event, "time": Date().timeIntervalSince1970]) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        queue.async {
            // Keep recent evidence for long-lived hosts without growing forever.
            // Both files contain only this process's opt-in diagnostics.
            if written + data.count + 1 > 20_000_000 {
                let previous = url.deletingPathExtension().appendingPathExtension("previous.jsonl")
                do {
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    try FileManager.default.moveItem(at: url, to: previous)
                    written = 0
                } catch { return }
            }
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

/// Batch frame timestamps once a second, without retaining pixels or touching disk per frame.
final class FrameTimingLog {
    private let stage: String
    private let lock = NSLock()
    private var started: UInt64 = 0
    private var samples: [[Int64]] = []
    init(_ stage: String) { self.stage = stage }
    func frame(_ timestamp: Int64, detail: Int64 = 0) {
        guard PerformanceLog.enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if started == 0 { started = now }
        samples.append([Int64(now / 1_000), timestamp, detail])
        if now - started >= 1_000_000_000 || samples.count >= 120 {
            let batch = samples
            samples.removeAll(keepingCapacity: true); started = now
            lock.unlock()
            PerformanceLog.record("frame-timing", ["stage": stage, "samples": batch])
        } else { lock.unlock() }
    }
}
