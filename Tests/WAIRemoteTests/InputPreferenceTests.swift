import XCTest
import RemoteCore
@testable import WAIRemote

@MainActor
final class InputPreferenceTests: XCTestCase {
    func testIndependentMouseIsDefaultIncludingLegacyDisplayGrants() throws {
        let suite = "input-default-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for grant in [nil, PersistentAccess(target: .display), PersistentAccess(target: .independentDisplay)] {
            PersistentAccess.save(grant, to: defaults)
            let model = HostModel(identity: DeviceIdentity(), defaults: defaults, disableBackgroundAccess: {})
            XCTAssertTrue(model.independentPointerPreferred)
            XCTAssertEqual(PersistentAccess.read(from: defaults), grant, "A preference must not create or revoke access.")
        }
    }

    func testExplicitSharedMouseSettingSurvivesRelaunchWithoutChangingConsent() throws {
        let suite = "input-preference-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let grant = PersistentAccess(target: .independentDisplay)
        PersistentAccess.save(grant, to: defaults)
        let host = HostModel(identity: DeviceIdentity(), defaults: defaults, disableBackgroundAccess: {})
        host.independentPointerPreferred = false
        let reopened = HostModel(identity: DeviceIdentity(), defaults: defaults, disableBackgroundAccess: {})
        XCTAssertFalse(reopened.independentPointerPreferred)
        XCTAssertEqual(PersistentAccess.read(from: defaults), grant)
        reopened.independentPointerPreferred = true
        XCTAssertTrue(HostModel(identity: DeviceIdentity(), defaults: defaults, disableBackgroundAccess: {}).independentPointerPreferred)
    }
}
