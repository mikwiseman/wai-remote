import AppKit
import XCTest
import RemoteCore
@testable import WAIRemote

@MainActor
final class ViewerSleepTests: XCTestCase {
    private final class Viewer: MacViewerModel {
        var reconnections: [String] = []
        override func connect() { reconnections.append(invitation) }
        func beginConnection() { super.connect() }
        func establish() { beginConnection(); connecting = false; connected = true }
    }

    private func viewer() throws -> Viewer {
        let host = DeviceIdentity()
        let model = Viewer(identity: DeviceIdentity())
        model.invitation = "http://127.0.0.1:1/#host=\(host.id)&key=\(host.publicKey)&secret=\(Data(repeating: 7, count: 32).base64URL)"
        return model
    }

    private func notify(_ name: Notification.Name) {
        NSWorkspace.shared.notificationCenter.post(name: name, object: NSWorkspace.shared)
    }

    func testWakeReconnectsOnlyThePreviouslyEstablishedSession() throws {
        let model = try viewer()
        let saved = try RemoteInvite(model.invitation).savedURL.absoluteString
        model.establish()
        model.receivedFrame = true
        model.invitation = "an unrelated invitation edited while the session was open"

        notify(NSWorkspace.willSleepNotification)
        XCTAssertFalse(model.connected, "Stop the old transport and input before sleep.")
        XCTAssertFalse(model.receivedFrame, "A stale frame must not look live after waking.")
        notify(NSWorkspace.didWakeNotification)
        XCTAssertEqual(model.reconnections, [saved], "Resume with pinned identity, without replaying an invitation secret.")
        notify(NSWorkspace.didWakeNotification)
        XCTAssertEqual(model.reconnections.count, 1)
    }

    func testExplicitDisconnectAfterSleepCancelsReconnection() throws {
        let model = try viewer()
        model.establish()
        notify(NSWorkspace.willSleepNotification)
        model.disconnect()
        notify(NSWorkspace.didWakeNotification)
        XCTAssertTrue(model.reconnections.isEmpty)
    }

    func testWakeDoesNotStartAnIdleOrUnapprovedConnection() throws {
        let model = try viewer()
        notify(NSWorkspace.willSleepNotification)
        notify(NSWorkspace.didWakeNotification)
        XCTAssertTrue(model.reconnections.isEmpty)

        model.beginConnection()
        notify(NSWorkspace.willSleepNotification)
        XCTAssertFalse(model.connecting)
        notify(NSWorkspace.didWakeNotification)
        XCTAssertTrue(model.reconnections.isEmpty)
    }
}
