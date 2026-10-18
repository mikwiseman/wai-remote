import AppKit
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class HostConsentTests: XCTestCase {
    func testRejectedHandshakePreservesConsentAndExplicitCloseStillRevokesIt() throws {
        let suite = "host-consent-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let consent = PersistentAccess(target: .independentDisplay)
        PersistentAccess.save(consent, to: defaults)
        var disabled = 0
        let host = HostModel(identity: DeviceIdentity(), defaults: defaults,
                             disableBackgroundAccess: { disabled += 1 })
        host.sharing = true

        host.signalingFailed("Сервер не подтвердил устройство")

        XCTAssertFalse(host.sharing, "The rejected connection must stop.")
        XCTAssertTrue(host.accessEnabled, "A gateway failure is not an owner revocation.")
        XCTAssertEqual(PersistentAccess.read(from: defaults), consent)
        XCTAssertEqual(disabled, 0, "Recovery must keep the background helper registered.")
        host.restoreAccess()
        XCTAssertFalse(host.starting, "Repeated rejection must not cause an immediate retry loop.")

        host.stop()
        XCTAssertFalse(host.accessEnabled)
        XCTAssertNil(PersistentAccess.read(from: defaults))
        XCTAssertEqual(disabled, 1)
        host.restoreAccess()
        XCTAssertFalse(host.starting, "Close Access must cancel recovery.")
    }

    func testRejectedHandshakeCannotCreateConsent() throws {
        let suite = "host-no-consent-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = HostModel(identity: DeviceIdentity(), defaults: defaults,
                             disableBackgroundAccess: { XCTFail("No access was registered.") })
        host.signalingFailed("Недействительные параметры подключения")
        XCTAssertFalse(host.accessEnabled)
        XCTAssertNil(PersistentAccess.read(from: defaults))
        host.restoreAccess()
        XCTAssertFalse(host.starting)
    }
}
