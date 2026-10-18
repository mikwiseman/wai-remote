import AppKit
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class InvitationTests: XCTestCase {
    private func host() -> HostModel {
        _ = NSApplication.shared
        let suite = "invitation-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = HostModel(identity: DeviceIdentity(), defaults: defaults,
                              peersURL: FileManager.default.temporaryDirectory.appendingPathComponent("no-peers-\(UUID()).json"),
                              disableBackgroundAccess: {})
        model.isLab = true
        model.sharing = true
        model.newInvite()
        return model
    }

    private func request(_ invitation: String, from viewer: DeviceIdentity = DeviceIdentity()) throws -> [String: Any] {
        let invite = try RemoteInvite(invitation)
        let offer = Offer(hostID: invite.hostID, peerID: viewer.id, publicKey: viewer.publicKey,
                          nonce: Data(repeating: 7, count: 32).base64URL,
                          expiresAt: Date().addingTimeInterval(100).timeIntervalSince1970 * 1000,
                          name: "Invitation test", sdp: "")
        let payload = try JSONEncoder().encode(offer)
        return ["type": "offer", "from": viewer.id, "body": [
            "payload": payload.base64URL,
            "signature": try viewer.sign(payload, domain: "wai-remote/offer/v1"),
            "proof": DeviceIdentity.pairingProof(secret: try XCTUnwrap(invite.secret), payload: payload)
        ]]
    }

    func testInvitationHasNoTimeLimitAndStillNeedsOwnerApproval() throws {
        let model = host()
        defer { model.stop() }
        let invitation = model.invite
        model.housekeeping(now: Date().addingTimeInterval(365 * 24 * 60 * 60))

        XCTAssertEqual(model.invite, invitation, "Elapsed time must not close an invitation.")
        model.receiveSignal(try request(invitation))
        XCTAssertNotNil(model.pending, "A valid invitation should reach the owner for approval.")
        XCTAssertNil(model.connectedName, "An invitation alone does not approve a new device.")
    }

    func testClosingAccessRevokesTheInvitation() throws {
        let model = host()
        let old = model.invite
        model.stop()
        model.receiveSignal(try request(old))
        XCTAssertTrue(model.invite.isEmpty)
        XCTAssertNil(model.pending)

        model.isLab = true
        model.sharing = true
        model.newInvite()
        defer { model.stop() }
        model.receiveSignal(try request(old))
        XCTAssertNil(model.pending, "Reopening access must not reactivate an old invitation.")
        model.receiveSignal(try request(model.invite))
        XCTAssertNotNil(model.pending)
    }

    func testReplacingInvitationRevokesThePreviousLink() throws {
        let model = host()
        defer { model.stop() }
        let old = model.invite
        model.newInvite()
        XCTAssertNotEqual(model.invite, old)
        model.receiveSignal(try request(old))
        XCTAssertNil(model.pending)
        model.receiveSignal(try request(model.invite))
        XCTAssertNotNil(model.pending)
    }
}
