import Foundation
import CoreFoundation
import CryptoKit

/// Fail closed at the disk boundary, even if a future caller passes a payload.
/// Strings must be known protocol labels, never arbitrary application content.
enum DiagnosticPrivacy {
    private enum Rule {
        case number, boolean, uuid, identifier, samples, statistics, durations
        case label(Set<String>)
    }
    private static let salt = UUID().uuidString
    private static let roles: Rule = .label(["host", "viewer"])
    private static let kinds: Rule = .label(["pointer", "text", "heartbeat", "key", "scroll"])
    private static let actions: Rule = .label(["", "down", "up", "move"])
    private static let domains: Rule = .label(["NSURLErrorDomain", "NSCocoaErrorDomain", "NSOSStatusErrorDomain",
        "kCFErrorDomainCFNetwork", "SCStreamErrorDomain", "Capture", "WebRTC", "Clipboard", "KeyStore", "SUErrorDomain"])
    private static func numbers(_ names: String) -> [String: Rule] {
        Dictionary(uniqueKeysWithValues: names.split(separator: " ").map { (String($0), .number) })
    }
    private static func flags(_ names: String) -> [String: Rule] {
        Dictionary(uniqueKeysWithValues: names.split(separator: " ").map { (String($0), .boolean) })
    }
    private static func combine(_ groups: [String: Rule]...) -> [String: Rule] {
        groups.reduce(into: [:]) { $0.merge($1) { _, next in next } }
    }
    private static let schemas: [String: [String: Rule]] = [
        "input-dispatch": numbers("queueMs"),
        "input-delivery": combine(numbers("textUnits queueMs handlingMs"), ["kind": kinds, "action": actions]),
        "input-applied": ["kind": kinds, "action": actions, "handlingMs": .number],
        "input-roundtrip": ["kind": kinds, "ms": .number],
        "input-button-lookup": combine(numbers("heldKeys heldButtons modifiers lookupMs"), flags("eligible found accessibilityTrusted")),
        "input-mode": flags("independent window supported control lab"),
        "text-submit": numbers("units"),
        "paste-request": flags("canControl concealed hasText clipboardReady"),
        "test-click": numbers("count"),
        "capture-config": combine(numbers("width height fps queueDepth"), ["format": .label(["NV12"])]),
        "capture": numbers("fps gapMaxMs sampleOffsetMs"),
        "renderer": numbers("fps gapP95Ms gapMaxMs gapsOver100Ms"),
        "display-metrics": numbers("frames dropped corrupted delaySeconds"),
        "display-skipped": [:],
        "encoder": ["implementation": .label(["WebRTC"]), "lowLatency": .boolean],
        "frame-timing": ["stage": .label(["decode-input", "decode-output", "render", "display-enqueue"]), "samples": .samples],
        "ice-policy": flags("relayOnly"),
        "ice-ready": combine(numbers("gatheringMs candidateCount"), flags("hasRelay")),
        "rtc": ["role": roles, "bufferedBytes": .number, "stats": .statistics],
        "network-trace": ["role": roles, "started": .boolean],
        "clipboard-state": combine(flags("enabled open ready"), numbers("peerWindow")),
        "clipboard": combine(numbers("bytes sentBytes receivedBytes code"), ["id": .uuid, "domain": domains,
            "operation": .label(["send", "receive-start", "ack", "receive", "timeout", "superseded", "write-failed", "decode-failed"])]),
        "capture-error": ["domain": domains, "code": .number],
        "identity-error": ["domain": domains, "code": .number],
        "updater-error": ["domain": domains, "code": .number],
        "host-signaling-ready": [:],
        "host-signaling-lost": ["closeCode": .number, "domain": domains, "code": .number],
        "viewer-signaling-lost": ["closeCode": .number, "domain": domains, "code": .number],
        "transport-state": ["role": roles, "state": .number],
        "peer-approval": ["indefinite": .boolean, "seconds": .number, "control": .boolean],
        "host-session-open": ["indefinite": .boolean, "remainingSeconds": .number],
        "host-session-close": ["seconds": .number, "cause": .label(["owner", "transport", "replaced", "negotiation", "send-failed", "peer-revoked", "approval-expired", "host-stop", "connect-timeout"])],
        "host-session-pause": ["cause": .label(["connection-stalled", "transport-disconnected", "host-drawing", "window-resizing", "permissions-changed"])],
        "host-stop": ["connected": .boolean, "cause": .label(["owner", "application-exit", "capture-start", "capture-stopped", "display-changed", "invite-randomness", "peer-save-failed", "relay-expired", "screen-permission-revoked", "session-suspended", "signaling-invalid", "window-closed", "window-resize-failed"])]
    ]
    private static let rtcSchema: [String: Rule] = combine(
        numbers("frameWidth frameHeight framesPerSecond framesEncoded framesDecoded framesDropped framesReceived framesSent bytesSent bytesReceived packetsLost packetsReceived packetsSent totalEncodeTime totalDecodeTime totalPacketSendDelay qpSum targetBitrate jitter jitterBufferDelay jitterBufferTargetDelay jitterBufferEmittedCount freezeCount totalFreezesDuration nackCount pliCount keyFramesDecoded fecPacketsReceived fecPacketsDiscarded currentRoundTripTime roundTripTime availableOutgoingBitrate availableIncomingBitrate"),
        flags("nominated powerEfficientEncoder powerEfficientDecoder"),
        ["kind": .label(["video", "audio"]),
         "mimeType": .label(["video/H264", "video/H265", "video/VP8", "video/VP9", "video/AV1", "video/rtx", "video/red", "video/ulpfec", "video/flexfec-03"]),
         "codecId": .identifier, "selectedCandidatePairId": .identifier, "localCandidateId": .identifier, "remoteCandidateId": .identifier,
         "qualityLimitationReason": .label(["none", "cpu", "bandwidth", "other"]), "qualityLimitationDurations": .durations,
         "encoderImplementation": .label(["VideoToolbox", "libvpx", "libaom", "OpenH264"]),
         "decoderImplementation": .label(["VideoToolbox", "libvpx", "libaom", "OpenH264"]),
         "state": .label(["frozen", "waiting", "in-progress", "failed", "succeeded", "new", "checking", "connected", "completed", "disconnected", "closed"]),
         "candidateType": .label(["host", "srflx", "prflx", "relay"]), "protocol": .label(["udp", "tcp", "tls"]), "relayProtocol": .label(["udp", "tcp", "tls"]),
         "networkType": .label(["ethernet", "wifi", "cellular", "vpn", "unknown", "loopback"])])

    static func sanitize(_ event: String, values: [String: Any]) -> [String: Any]? {
        guard let schema = schemas[event] else { return nil }
        return filter(values, schema: schema)
    }
    private static func filter(_ values: [String: Any], schema: [String: Rule]) -> [String: Any] {
        values.reduce(into: [:]) { result, entry in
            if let rule = schema[entry.key], let safe = sanitize(entry.value, rule: rule) { result[entry.key] = safe }
        }
    }
    private static func sanitize(_ value: Any, rule: Rule) -> Any? {
        switch rule {
        case .number:
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number
        case .boolean:
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number
        case .label(let labels):
            guard let text = value as? String, labels.contains(text) else { return nil }; return text
        case .uuid:
            guard let text = value as? String, let uuid = UUID(uuidString: text) else { return nil }; return uuid.uuidString
        case .identifier:
            guard let text = value as? String, !text.isEmpty, text.utf8.count <= 1024 else { return nil }
            return SHA256.hash(data: Data((salt + text).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        case .samples:
            guard let rows = value as? [[Int64]], rows.count <= 120, rows.allSatisfy({ $0.count == 3 }) else { return nil }; return rows
        case .durations:
            guard let values = value as? [String: Any] else { return nil }
            return filter(values, schema: numbers("none cpu bandwidth other"))
        case .statistics:
            guard let rows = value as? [[String: Any]], rows.count <= 256 else { return nil }
            let types: Set<String> = ["inbound-rtp", "outbound-rtp", "remote-inbound-rtp", "candidate-pair", "local-candidate", "remote-candidate", "codec", "transport"]
            return rows.compactMap { row -> [String: Any]? in
                guard let type = row["type"] as? String, types.contains(type),
                      let id = row["id"].flatMap({ sanitize($0, rule: .identifier) }), let values = row["values"] as? [String: Any] else { return nil }
                return ["id": id, "type": type, "values": filter(values, schema: rtcSchema)]
            }
        }
    }
}
