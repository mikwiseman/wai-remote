import AppKit
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class PeerAuthorizationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }
    private func withHost(peers: [TrustedPeer] = [], _ check: (HostModel, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("peer-expiry-\(UUID())")
        let url = directory.appendingPathComponent("peers.json")
        let suite = "peer-expiry-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        try KeyStore.save(peers, to: url)
        let host = HostModel(identity: DeviceIdentity(), defaults: defaults, peersURL: url, disableBackgroundAccess: {})
        defer { host.stop() }
        host.sharing = true
        try check(host, url)
    }
    private func offer(to host: HostModel, from identity: DeviceIdentity) -> Offer {
        Offer(hostID: host.identity.id, peerID: identity.id, publicKey: identity.publicKey,
              nonce: Data(repeating: 3, count: 32).base64URL,
              expiresAt: Date().addingTimeInterval(60).timeIntervalSince1970 * 1_000,
              name: "Test viewer", sdp: "invalid test SDP")
    }
    private func signal(_ offer: Offer, identity: DeviceIdentity, secret: Data? = nil) throws -> [String: Any] {
        let data = try JSONEncoder().encode(offer)
        var body = ["payload": data.base64URL, "signature": try identity.sign(data, domain: "wai-remote/offer/v1")]
        if let secret { body["proof"] = DeviceIdentity.pairingProof(secret: secret, payload: data) }
        return ["type": "offer", "from": identity.id, "body": body]
    }

    func testLegacyPeerWithoutExpiryRemainsIndefinite() throws {
        let data = Data(#"{"id":"old","publicKey":"key","name":"Old Mac","permissions":{"control":true,"annotate":true},"labOnly":false}"#.utf8)
        let peer = try JSONDecoder().decode(TrustedPeer.self, from: data)
        XCTAssertNil(peer.expiresAt)
        XCTAssertTrue(peer.isAuthorized(at: .distantFuture))
        var temporary = peer
        temporary.expiresAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(temporary.isAuthorized(at: Date(timeIntervalSince1970: 999)))
        XCTAssertFalse(temporary.isAuthorized(at: Date(timeIntervalSince1970: 1_000)))
    }

    func testApprovalPersistsDeadlineAndHousekeepingClosesTheActiveAttempt() throws {
        try withHost { host, url in
            let expiry = Date().addingTimeInterval(3_600), identity = DeviceIdentity()
            host.pending = PendingPeer(offer: offer(to: host, from: identity))
            host.approve(control: false, expiresAt: expiry)
            XCTAssertEqual(KeyStore.peers(at: url).first?.expiresAt, expiry)
            XCTAssertEqual(host.connectedName, "Test viewer")
            host.housekeeping(now: expiry)
            XCTAssertNil(host.connectedName)
            XCTAssertTrue(host.sharing, "Another authorized device may still connect.")
            XCTAssertEqual(host.status, "Срок доступа устройства истёк")
            XCTAssertFalse(try XCTUnwrap(host.peers.first).isAuthorized(at: expiry))
        }
    }

    func testExpiredPeerNeedsFreshInvitationAndFreshApproval() throws {
        let identity = DeviceIdentity()
        let peer = TrustedPeer(id: identity.id, publicKey: identity.publicKey, name: "Expired", permissions: .init(), labOnly: false, expiresAt: .distantPast)
        try withHost(peers: [peer]) { host, _ in
            let offer = offer(to: host, from: identity)
            host.receiveSignal(try signal(offer, identity: identity))
            XCTAssertNil(host.pending)
            XCTAssertNil(host.connectedName)
            host.newInvite()
            let secret = try XCTUnwrap(try RemoteInvite(host.invite).secret)
            host.receiveSignal(try signal(offer, identity: identity, secret: secret))
            XCTAssertEqual(host.pending?.id, identity.id)
            XCTAssertNil(host.connectedName, "A valid invitation must not silently renew an expired grant.")
        }
    }

    func testIndefinitePeerReconnectsWithoutInvitationAndCanBeRevoked() throws {
        let identity = DeviceIdentity()
        let peer = TrustedPeer(id: identity.id, publicKey: identity.publicKey, name: "Trusted", permissions: .init(), labOnly: false)
        try withHost(peers: [peer]) { host, url in
            host.receiveSignal(try signal(offer(to: host, from: identity), identity: identity))
            XCTAssertEqual(host.connectedName, "Test viewer")
            host.forget(identity.id)
            XCTAssertNil(host.connectedName)
            XCTAssertTrue(KeyStore.peers(at: url).isEmpty)
            XCTAssertTrue(host.peers.isEmpty)
        }
    }

    func testInvalidApprovalDoesNotSaveOrConnect() throws {
        try withHost { host, url in
            host.pending = PendingPeer(offer: offer(to: host, from: DeviceIdentity()))
            host.approve(control: true, expiresAt: .distantPast)
            XCTAssertTrue(KeyStore.peers(at: url).isEmpty)
            XCTAssertNotNil(host.pending)
            XCTAssertNil(host.connectedName)
        }
    }
}
