import AppKit
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class SessionHandoffTests: XCTestCase {
    private final class Signals {
        var messages: [[String: Any]] = []
        var viewerAtEmission: [String?] = []
        weak var host: HostModel?
    }
    private func peer(_ identity: DeviceIdentity, control: Bool = true, labOnly: Bool = false,
                      expiresAt: Date? = nil) -> TrustedPeer {
        TrustedPeer(id: identity.id, publicKey: identity.publicKey, name: identity.id,
                    permissions: .init(control: control, annotate: true), labOnly: labOnly, expiresAt: expiresAt)
    }
    private func withHost(peers: [TrustedPeer], _ check: (HostModel, Signals, URL) throws -> Void) throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-\(UUID())")
        let url = directory.appendingPathComponent("peers.json")
        let suite = "handoff-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        try KeyStore.save(peers, to: url)
        let signals = Signals()
        let host = HostModel(identity: DeviceIdentity(), defaults: defaults, peersURL: url,
                             disableBackgroundAccess: {}, signalSender: {
                                 signals.messages.append($0)
                                 signals.viewerAtEmission.append(signals.host?.connectedName)
                             })
        signals.host = host
        defer { host.stop() }
        host.sharing = true
        host.controlAllowed = true
        try check(host, signals, url)
    }
    private func request(_ host: HostModel, from identity: DeviceIdentity, replacing sessionID: String? = nil,
                         secret: Data? = nil) throws -> [String: Any] {
        var object: [String: Any] = ["hostID": host.identity.id, "peerID": identity.id, "publicKey": identity.publicKey,
            "nonce": Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URL,
            "expiresAt": Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000,
            "name": identity.id, "sdp": "invalid test SDP"]
        if let sessionID { object["replaceSessionID"] = sessionID }
        let data = try JSONSerialization.data(withJSONObject: object)
        var body = ["payload": data.base64URL, "signature": try identity.sign(data, domain: "wai-remote/offer/v1")]
        if let secret { body["proof"] = DeviceIdentity.pairingProof(secret: secret, payload: data) }
        return ["type": "offer", "from": identity.id, "body": body]
    }
    private func payload(_ message: [String: Any]) throws -> [String: Any] {
        let body = try XCTUnwrap(message["body"] as? [String: Any])
        let data = try XCTUnwrap(Data(base64URL: try XCTUnwrap(body["payload"] as? String)))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func busy(_ signals: Signals, host: HostModel, request: [String: Any]) throws -> [String: Any] {
        let message = try XCTUnwrap(signals.messages.last)
        let body = try XCTUnwrap(message["body"] as? [String: Any])
        XCTAssertEqual(message["type"] as? String, "reject")
        XCTAssertEqual(message["to"] as? String, request["from"] as? String)
        XCTAssertEqual(body["reason"] as? String, "busy")
        let data = try XCTUnwrap(Data(base64URL: try XCTUnwrap(body["payload"] as? String)))
        XCTAssertTrue(DeviceIdentity.verify(try XCTUnwrap(body["signature"] as? String), data: data,
                                           domain: "wai-remote/busy/v1", publicKey: host.identity.publicKey))
        let object = try payload(message)
        XCTAssertEqual(object["hostID"] as? String, host.identity.id)
        XCTAssertEqual(object["peerID"] as? String, request["from"] as? String)
        XCTAssertEqual(object["nonce"] as? String, try payload(request)["nonce"] as? String)
        return object
    }
    func testBusyReplyIsSignedAndBoundToTheRequestAndConsumesItsNonce() throws {
        let a = DeviceIdentity(), b = DeviceIdentity()
        try withHost(peers: [peer(a), peer(b)]) { host, signals, url in
            let before = try Data(contentsOf: url)
            host.receiveSignal(try request(host, from: a))
            let offer = try request(host, from: b)
            host.receiveSignal(offer)
            let response = try busy(signals, host: host, request: offer)
            XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(response["sessionID"] as? String)))
            XCTAssertEqual(host.connectedName, a.id)
            let count = signals.messages.count
            host.receiveSignal(offer)
            XCTAssertEqual(signals.messages.count, count, "A signed busy offer is consumed too.")
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }
    func testExplicitHandoffRequiresSignedExactSessionAndOldRetriesCannotDisplaceIt() throws {
        let a = DeviceIdentity(), b = DeviceIdentity(), c = DeviceIdentity()
        try withHost(peers: [peer(a), peer(b), peer(c)]) { host, signals, url in
            let before = try Data(contentsOf: url)
            host.receiveSignal(try request(host, from: a))
            let ordinary = try request(host, from: b)
            host.receiveSignal(ordinary)
            let first = try XCTUnwrap(busy(signals, host: host, request: ordinary)["sessionID"] as? String)
            let replace = try request(host, from: b, replacing: first)
            var tampered = replace
            var body = try XCTUnwrap(tampered["body"] as? [String: String])
            var changed = try payload(tampered)
            changed["replaceSessionID"] = UUID().uuidString
            body["payload"] = try JSONSerialization.data(withJSONObject: changed).base64URL
            tampered["body"] = body
            let count = signals.messages.count
            host.receiveSignal(tampered)
            XCTAssertEqual(host.connectedName, a.id)
            XCTAssertEqual(signals.messages.count, count, "Replacement must be covered by the viewer signature.")

            host.receiveSignal(replace)
            XCTAssertEqual(host.connectedName, b.id)
            let notification = try XCTUnwrap(signals.messages.last)
            XCTAssertEqual(notification["to"] as? String, a.id)
            XCTAssertEqual(signals.viewerAtEmission.last!, a.id, "Notify the old viewer before closing its session.")
            XCTAssertEqual((notification["body"] as? [String: Any])?["reason"] as? String, "session-replaced")
            let replacedCount = signals.messages.count
            host.receiveSignal(replace)
            XCTAssertEqual(signals.messages.count, replacedCount, "The successful handoff is not replayable.")
            host.receiveSignal(ordinary)
            XCTAssertEqual(signals.messages.count, replacedCount, "An earlier busy offer cannot later reconnect or replace.")

            let oldRetry = try request(host, from: a)
            host.receiveSignal(oldRetry)
            XCTAssertEqual(host.connectedName, b.id, "An older viewer's passive retry cannot take the session back.")
            let second = try XCTUnwrap(busy(signals, host: host, request: oldRetry)["sessionID"] as? String)
            XCTAssertNotEqual(first, second)
            let raced = try request(host, from: c, replacing: first)
            host.receiveSignal(raced)
            XCTAssertEqual(host.connectedName, b.id, "A delayed click cannot replace a different session.")
            XCTAssertEqual(try busy(signals, host: host, request: raced)["sessionID"] as? String, second)
            host.receiveSignal(try request(host, from: c, replacing: second))
            XCTAssertEqual(host.connectedName, c.id)
            XCTAssertEqual(try Data(contentsOf: url), before, "Switching devices must not change any grant or expiry.")
            XCTAssertNil(host.pending)
        }
    }
    func testSameDeviceExplicitHandoffDoesNotRejectItsNewSignalingConnection() throws {
        let a = DeviceIdentity(), b = DeviceIdentity()
        try withHost(peers: [peer(a), peer(b)]) { host, signals, _ in
            host.receiveSignal(try request(host, from: a))
            let observer = try request(host, from: b)
            host.receiveSignal(observer)
            let sessionID = try XCTUnwrap(busy(signals, host: host, request: observer)["sessionID"] as? String)
            let count = signals.messages.count
            host.receiveSignal(try request(host, from: a, replacing: sessionID))
            XCTAssertEqual(host.connectedName, a.id)
            XCTAssertEqual(signals.messages.count, count,
                           "The gateway routes by device ID: a reject to this ID would close the new viewer too.")
            let next = try request(host, from: b)
            host.receiveSignal(next)
            XCTAssertNotEqual(try busy(signals, host: host, request: next)["sessionID"] as? String, sessionID)
        }
    }
    func testNoSwitchCapabilityForReadOnlyExpiredLabOnlyOrNewInvite() throws {
        let a = DeviceIdentity(), b = DeviceIdentity(), c = DeviceIdentity()
        let grants: [TrustedPeer?] = [peer(b, control: false), peer(b, expiresAt: .distantPast), peer(b, labOnly: true), nil]
        for grant in grants {
            try withHost(peers: [peer(a), peer(c)] + [grant].compactMap { $0 }) { host, signals, url in
                let before = try Data(contentsOf: url)
                host.receiveSignal(try request(host, from: a))
                let controller = try request(host, from: c)
                host.receiveSignal(controller)
                let sessionID = try XCTUnwrap(busy(signals, host: host, request: controller)["sessionID"] as? String)
                host.newInvite()
                let secret = try XCTUnwrap(try RemoteInvite(host.invite).secret)
                let offer = try request(host, from: b, secret: secret)
                host.receiveSignal(offer)
                XCTAssertNil(try busy(signals, host: host, request: offer)["sessionID"])
                let guessed = try request(host, from: b, replacing: sessionID, secret: secret)
                host.receiveSignal(guessed)
                XCTAssertNil(try busy(signals, host: host, request: guessed)["sessionID"],
                             "Knowing the current session ID cannot create a control grant.")
                XCTAssertEqual(host.connectedName, a.id)
                XCTAssertNil(host.pending)
                XCTAssertEqual(try Data(contentsOf: url), before)
            }
        }
    }
    func testPendingApprovalAndMissingSystemPermissionNeverOfferOrAllowHandoff() throws {
        let a = DeviceIdentity(), b = DeviceIdentity(), newcomer = DeviceIdentity()
        try withHost(peers: [peer(a), peer(b)]) { host, signals, url in
            let before = try Data(contentsOf: url)
            host.receiveSignal(try request(host, from: a))
            let initial = try request(host, from: b)
            host.receiveSignal(initial)
            let sessionID = try XCTUnwrap(busy(signals, host: host, request: initial)["sessionID"] as? String)
            host.controlAllowed = false
            let denied = try request(host, from: b, replacing: sessionID)
            host.receiveSignal(denied)
            XCTAssertNil(try busy(signals, host: host, request: denied)["sessionID"])
            XCTAssertEqual(host.connectedName, a.id)
            host.controlAllowed = true
            let incoming = try request(host, from: newcomer)
            let body = try XCTUnwrap(incoming["body"] as? [String: String])
            host.pending = PendingPeer(offer: try JSONDecoder().decode(Offer.self, from: XCTUnwrap(Data(base64URL: XCTUnwrap(body["payload"])))))
            let pending = try request(host, from: b, replacing: sessionID)
            host.receiveSignal(pending)
            XCTAssertNil(try busy(signals, host: host, request: pending)["sessionID"])
            XCTAssertEqual(host.pending?.id, newcomer.id)
            XCTAssertEqual(host.connectedName, a.id)
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }
    func testHandoffCannotInterruptTheHostsLocalDrawing() throws {
        let a = DeviceIdentity(), b = DeviceIdentity()
        try withHost(peers: [peer(a), peer(b)]) { host, signals, _ in
            host.receiveSignal(try request(host, from: a))
            let offer = try request(host, from: b)
            host.receiveSignal(offer)
            let sessionID = try XCTUnwrap(busy(signals, host: host, request: offer)["sessionID"] as? String)
            host.localDrawing = true
            let takeover = try request(host, from: b, replacing: sessionID)
            host.receiveSignal(takeover)
            XCTAssertEqual(host.connectedName, a.id)
            XCTAssertTrue(host.localDrawing)
            XCTAssertNil(try busy(signals, host: host, request: takeover)["sessionID"])
        }
    }
    func testExplicitSwitchConnectsNormallyIfTheOldViewerAlreadyDisconnected() throws {
        let a = DeviceIdentity(), b = DeviceIdentity()
        try withHost(peers: [peer(a), peer(b)]) { host, signals, url in
            let before = try Data(contentsOf: url)
            host.receiveSignal(try request(host, from: a))
            let offer = try request(host, from: b)
            host.receiveSignal(offer)
            let sessionID = try XCTUnwrap(busy(signals, host: host, request: offer)["sessionID"] as? String)
            host.disconnectViewer()
            let count = signals.messages.count
            host.receiveSignal(try request(host, from: b, replacing: sessionID))
            XCTAssertEqual(host.connectedName, b.id, "An explicit switch can join an already vacant slot.")
            XCTAssertEqual(signals.messages.count, count, "A free Mac must not reply busy.")
            XCTAssertNil(host.pending)
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }
    func testRevokedGrantCannotUsePreviouslyOfferedSessionID() throws {
        let a = DeviceIdentity(), b = DeviceIdentity()
        try withHost(peers: [peer(a), peer(b)]) { host, signals, _ in
            host.receiveSignal(try request(host, from: a))
            let offer = try request(host, from: b)
            host.receiveSignal(offer)
            let sessionID = try XCTUnwrap(busy(signals, host: host, request: offer)["sessionID"] as? String)
            host.forget(b.id)
            host.receiveSignal(try request(host, from: b, replacing: sessionID))
            XCTAssertEqual(host.connectedName, a.id)
            XCTAssertEqual((signals.messages.last?["body"] as? [String: Any])?["reason"] as? String, "new-invite-required")
            XCTAssertEqual(host.peers.map(\.id), [a.id])
        }
    }
}
