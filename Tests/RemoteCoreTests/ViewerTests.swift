import XCTest
@testable import RemoteCore

final class ViewerTests: XCTestCase {
    func testHostedGatewayKeepsItsBasePath() throws {
        let identity = DeviceIdentity()
        let invite = try RemoteInvite("https://waiwai.is/remote/connect/#host=\(identity.id)&key=\(identity.publicKey)")
        XCTAssertEqual(invite.signalingURL.absoluteString, "wss://waiwai.is/remote/connect/signal")
        XCTAssertEqual(invite.savedURL.path, "/remote/connect")
        XCTAssertFalse(RemoteInvite.isAllowedGateway(URL(string: "https://waiwai.is/a/../remote")!))
    }
    func testInvitePinsHostAndDoesNotPersistPairingSecret() throws {
        let identity = DeviceIdentity()
        let secret = Data(repeating: 7, count: 32).base64URL
        let url = "http://my-mac.local:8789/#host=\(identity.id)&key=\(identity.publicKey)&secret=\(secret)"
        let invite = try RemoteInvite(url)
        XCTAssertEqual(invite.signalingURL.absoluteString, "ws://my-mac.local:8789/signal")
        XCTAssertNil(try RemoteInvite(invite.savedURL.absoluteString).secret)
        XCTAssertEqual(try RemoteInvite(invite.savedURL.absoluteString).hostID, identity.id)
        let phone = try XCTUnwrap(RemoteInvite.phoneURL(for: url))
        let restored = try XCTUnwrap(URLComponents(url: phone, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        XCTAssertEqual(try RemoteInvite(restored).secret, invite.secret)
        XCTAssertThrowsError(try RemoteInvite(url.replacingOccurrences(of: identity.id, with: String(repeating: "0", count: 64))))
        XCTAssertThrowsError(try RemoteInvite(url + "&secret=\(secret)"))
        XCTAssertThrowsError(try RemoteInvite(url.replacingOccurrences(of: secret, with: "bad")))
        XCTAssertThrowsError(try RemoteInvite(url.replacingOccurrences(of: "my-mac.local", with: "example.com")))
    }

    func testPlaintextSignalingIsRestrictedToLocalAddresses() {
        for address in ["http://localhost:8788", "http://192.168.1.66:8789", "http://10.0.0.2", "http://172.16.0.1", "http://my-mac.local", "https://example.com"] {
            XCTAssertTrue(RemoteInvite.isAllowedGateway(URL(string: address)!))
        }
        for address in ["http://8.8.8.8", "http://172.32.0.1", "http://192.168.1.256", "http://evil.local.example.com", "file:///tmp/x", "https://user:pass@example.com", "https://example.com/?secret=x"] {
            XCTAssertFalse(RemoteInvite.isAllowedGateway(URL(string: address)!))
        }
    }

    func testViewerDoesNotRegressModeOnDelayedHostAcknowledgement() throws {
        let host = SessionMachine(surface: .init(id: "s", width: 1280, height: 800))
        var viewer = ViewerSession()
        XCTAssertTrue(try viewer.accept(host.state))
        let mode = try XCTUnwrap(viewer.changeMode(.draw))
        XCTAssertTrue(host.handle(mode, now: 0).accepted)
        var delayed = host.state; delayed.modeGeneration = 0; delayed.mode = .control
        _ = try viewer.accept(delayed)
        XCTAssertEqual(viewer.mode, .draw)
        let heartbeat = try XCTUnwrap(viewer.make("heartbeat"))
        XCTAssertGreaterThan(heartbeat.sequence, mode.sequence)
        XCTAssertEqual(heartbeat.modeGeneration, mode.modeGeneration)
    }

    func testReleaseStopsInputUntilFreshEpochAndLocalPauseCannotBeOverridden() throws {
        let host = SessionMachine(surface: .init(id: "s", width: 1280, height: 800))
        var viewer = ViewerSession()
        _ = try viewer.accept(host.state)
        let release = try XCTUnwrap(viewer.release())
        XCTAssertNil(viewer.make("pointer"))
        _ = try viewer.accept(host.state)
        XCTAssertNil(viewer.make("pointer"), "A delayed acknowledgement must not undo a release")
        XCTAssertTrue(host.handle(release, now: 1).accepted)
        _ = try viewer.accept(host.state)
        XCTAssertNotNil(viewer.make("heartbeat"))
        _ = host.pause(reason: "local-draw")
        _ = try viewer.accept(host.state)
        XCTAssertNil(viewer.changeMode(.control))
        XCTAssertNil(viewer.make("pointer"))
        XCTAssertNotNil(viewer.make("heartbeat"))
    }

    func testViewOnlyGuestCanFinishDrawingWithoutGainingControl() throws {
        let host = SessionMachine(surface: .init(id: "s", width: 1280, height: 800),
                                  permissions: .init(control: false, annotate: true))
        var viewer = ViewerSession()
        try viewer.accept(host.state)
        XCTAssertTrue(host.handle(try XCTUnwrap(viewer.changeMode(.draw)), now: 0).accepted)
        let finish = try XCTUnwrap(viewer.changeMode(.control), "Finishing a drawing must return to viewing.")
        XCTAssertTrue(host.handle(finish, now: 1).accepted)
        try viewer.accept(host.state)
        XCTAssertEqual(viewer.mode, .control)
        XCTAssertFalse(host.state.permissions.control)
        var pointer = try XCTUnwrap(viewer.make("pointer"))
        pointer.action = "down"; pointer.x = 0.5; pointer.y = 0.5; pointer.button = 0
        XCTAssertNil(host.handle(pointer, now: 2).input, "Leaving Draw must never grant input permission.")
    }
}
