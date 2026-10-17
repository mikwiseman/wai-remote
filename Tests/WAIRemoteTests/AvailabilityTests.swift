import AppKit
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class AvailabilityTests: XCTestCase {
    private final class Viewer: MacViewerModel {
        var onReconnect: ((String) -> Void)?
        override func connect() { onReconnect?(invitation) }
        func begin() { super.connect() }
    }
    private func viewer() -> Viewer {
        let identity = DeviceIdentity()
        let model = Viewer(identity: DeviceIdentity())
        model.invitation = "http://127.0.0.1:1/#host=\(identity.id)&key=\(identity.publicKey)&secret=\(Data(repeating: 1, count: 32).base64URL)"
        return model
    }
    func testAnEstablishedConnectionRecoversWithPinnedIdentityAndNoPairingSecret() throws {
        let model = viewer()
        let saved = try RemoteInvite(model.invitation).savedURL.absoluteString
        model.begin(); model.connecting = false; model.connected = true; model.receivedFrame = true
        model.invitation = "a different invitation in the editor"
        let restored = expectation(description: "The same trusted Mac is retried")
        model.onReconnect = { target in XCTAssertEqual(target, saved); restored.fulfill() }
        model.recover(message: "Recovery")
        XCTAssertFalse(model.connected)
        XCTAssertFalse(model.receivedFrame)
        XCTAssertFalse(model.canControl)
        XCTAssertTrue(model.connecting)
        wait(for: [restored], timeout: 2)
        model.disconnect()
    }
    func testExplicitDisconnectCancelsRecovery() {
        let model = viewer()
        model.begin(); model.connecting = false; model.connected = true
        let restored = expectation(description: "Never reconnect after cancellation"); restored.isInverted = true
        model.onReconnect = { _ in restored.fulfill() }
        model.recover(message: "Recovery"); model.disconnect()
        wait(for: [restored], timeout: 1.2)
        XCTAssertFalse(model.connecting)
    }
    func testAnUnapprovedPairingDoesNotRetryInTheBackground() {
        let model = viewer()
        model.begin()
        model.recover(message: "Network lost")
        XCTAssertFalse(model.connecting)
        XCTAssertFalse(model.connected)
    }
    func testPersistentWindowGrantKeepsItsOriginalProcessIdentity() throws {
        let name = "availability-\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let original = PersistentAccess(target: .window(pid: 123, id: 456, launchedAt: Date(timeIntervalSince1970: 789), boot: "boot-session"))
        PersistentAccess.save(original, to: defaults)
        XCTAssertEqual(PersistentAccess.read(from: defaults), original)
        PersistentAccess.save(nil, to: defaults)
        XCTAssertNil(PersistentAccess.read(from: defaults))
    }
    func testIndependentMouseDoesNotRestoreAsTheOwnersSystemMouse() throws {
        let name = "independent-access-\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        PersistentAccess.save(.init(target: .independentDisplay), to: defaults)
        XCTAssertEqual(PersistentAccess.read(from: defaults)?.target, .independentDisplay)
        // Existing full-display grants retain their original control mode.
        defaults.set(Data("{\"target\":{\"display\":{}}}".utf8), forKey: PersistentAccess.key)
        XCTAssertEqual(PersistentAccess.read(from: defaults)?.target, .display)
    }
    func testDisplaySleepDoesNotCloseAccessAndSystemSleepPreservesConsent() {
        let previous = UserDefaults.standard.data(forKey: PersistentAccess.key)
        defer { UserDefaults.standard.set(previous, forKey: PersistentAccess.key) }
        PersistentAccess.save(.init(target: .display))
        let host = HostModel(identity: DeviceIdentity())
        host.sharing = true
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        XCTAssertTrue(host.sharing, "Turning off the display must not close access.")
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertFalse(host.sharing, "Capture and input must stop before system sleep.")
        XCTAssertTrue(host.accessEnabled)
        XCTAssertEqual(PersistentAccess.read()?.target, .display)
        host.stop()
        XCTAssertFalse(host.accessEnabled)
        XCTAssertNil(PersistentAccess.read(), "An explicit Close Access must cancel every automatic restoration.")
    }
}
