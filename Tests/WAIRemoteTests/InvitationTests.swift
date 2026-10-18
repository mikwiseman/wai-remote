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

    private func request(_ invitation: String, from viewer: DeviceIdentity = DeviceIdentity(), localPointer: Bool? = nil) throws -> [String: Any] {
        let invite = try RemoteInvite(invitation)
        let offer = Offer(hostID: invite.hostID, peerID: viewer.id, publicKey: viewer.publicKey,
                          nonce: Data(repeating: 7, count: 32).base64URL,
                          expiresAt: Date().addingTimeInterval(100).timeIntervalSince1970 * 1000,
                          name: "Invitation test", sdp: "", localPointer: localPointer)
        let payload = try JSONEncoder().encode(offer)
        return ["type": "offer", "from": viewer.id, "body": [
            "payload": payload.base64URL,
            "signature": try viewer.sign(payload, domain: "wai-remote/offer/v1"),
            "proof": DeviceIdentity.pairingProof(secret: try XCTUnwrap(invite.secret), payload: payload)
        ]]
    }

    func testLocalPointerIsOptInAndPartOfTheSignedOffer() throws {
        let legacy = host()
        defer { legacy.stop() }
        legacy.receiveSignal(try request(legacy.invite))
        XCTAssertNil(try XCTUnwrap(legacy.pending).offer.localPointer,
                     "Existing viewers must retain the captured independent pointer.")

        let desktop = host()
        defer { desktop.stop() }
        desktop.receiveSignal(try request(desktop.invite, localPointer: true))
        XCTAssertEqual(try XCTUnwrap(desktop.pending).offer.localPointer, true)

        let tampered = host()
        defer { tampered.stop() }
        var message = try request(tampered.invite)
        var body = try XCTUnwrap(message["body"] as? [String: String])
        let payload = try XCTUnwrap(Data(base64URL: try XCTUnwrap(body["payload"])))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        object["localPointer"] = true
        body["payload"] = try JSONSerialization.data(withJSONObject: object).base64URL
        message["body"] = body
        tampered.receiveSignal(message)
        XCTAssertNil(tampered.pending, "Changing a capability invalidates the existing signature.")
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
