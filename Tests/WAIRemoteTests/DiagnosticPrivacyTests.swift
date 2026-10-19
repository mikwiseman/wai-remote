import XCTest
@testable import WAIRemote

final class DiagnosticPrivacyTests: XCTestCase {
    func testInputAndClipboardPayloadsCannotReachTheLog() throws {
        let privateText = "private password and clipboard text"
        let input = try XCTUnwrap(DiagnosticPrivacy.sanitize("input-delivery", values: [
            "kind": "text", "textUnits": 12, "queueMs": 0.75, "handlingMs": 1.25,
            "text": privateText, "key": "A", "keyCode": 12, "x": 0.4, "y": 0.8,
            "windowTitle": privateText, "payload": ["text": privateText], "time": privateText]))
        XCTAssertEqual(Set(input.keys), ["kind", "textUnits", "queueMs", "handlingMs"])
        XCTAssertEqual(input["queueMs"] as? Double, 0.75)
        let clipboard = try XCTUnwrap(DiagnosticPrivacy.sanitize("clipboard", values: [
            "operation": "receive", "id": privateText, "bytes": 42, "text": privateText,
            "path": "/Users/private/Documents/secret.txt", "domain": privateText]))
        XCTAssertEqual(Set(clipboard.keys), ["operation", "bytes"])
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: [input, clipboard]), as: UTF8.self).contains(privateText))
    }

    func testUnexpectedEventsStringsAndValueTypesFailClosed() throws {
        XCTAssertNil(DiagnosticPrivacy.sanitize("a private value used as event", values: [:]))
        let filtered = try XCTUnwrap(DiagnosticPrivacy.sanitize("input-delivery", values: [
            "kind": "password", "action": "secret", "queueMs": "7 secret", "handlingMs": Double.infinity,
            "textUnits": ["text": "secret"]]))
        XCTAssertTrue(filtered.isEmpty)
        XCTAssertTrue(try XCTUnwrap(DiagnosticPrivacy.sanitize("input-mode", values: ["independent": "secret", "control": 1])).isEmpty)
    }

    func testRTCAddressesAreRemovedAndOpaqueReferencesStillJoin() throws {
        let sensitiveID = "candidate-192.0.2.10-secret"
        let rows: [[String: Any]] = [
            ["id": sensitiveID, "type": "local-candidate", "values": ["address": "192.0.2.10", "ip": "192.0.2.10",
                "port": 12345, "usernameFragment": "secret", "candidateType": "relay", "protocol": "udp", "networkType": "vpn"]],
            ["id": "pair", "type": "candidate-pair", "values": ["localCandidateId": sensitiveID, "currentRoundTripTime": 0.12,
                "state": "succeeded", "qualityLimitationDurations": ["none": 5, "private": "secret"]]]]
        let result = try XCTUnwrap(DiagnosticPrivacy.sanitize("rtc", values: ["role": "host", "stats": rows]))
        let safe = try XCTUnwrap(result["stats"] as? [[String: Any]])
        let values = try XCTUnwrap(safe[1]["values"] as? [String: Any])
        XCTAssertEqual(safe[0]["id"] as? String, values["localCandidateId"] as? String)
        XCTAssertEqual(values["currentRoundTripTime"] as? Double, 0.12)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        for forbidden in ["192.0.2.10", "secret", "usernameFragment", "address", "port", "private"] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
    }

    func testDisconnectAndExpiryEvidenceContainsOnlyKnownReasonsAndTimes() throws {
        let expiry = try XCTUnwrap(DiagnosticPrivacy.sanitize("host-session-close", values: [
            "cause": "approval-expired", "seconds": 3600, "peerName": "private", "peerID": "private"]))
        XCTAssertEqual(Set(expiry.keys), ["cause", "seconds"])
        XCTAssertEqual(expiry["cause"] as? String, "approval-expired")
        let transport = try XCTUnwrap(DiagnosticPrivacy.sanitize("host-signaling-lost", values: [
            "closeCode": 0, "domain": "NSURLErrorDomain", "code": -1005, "description": "private URL"] ))
        XCTAssertEqual(Set(transport.keys), ["closeCode", "domain", "code"])
    }
}
