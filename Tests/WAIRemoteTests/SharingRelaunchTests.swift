import AppKit
import Sparkle
import XCTest
@testable import WAIRemote

final class SharingRelaunchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let now = Date(timeIntervalSince1970: 1_000)

    override func setUp() {
        suite = "is.wai.remote.tests.relaunch.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func save(_ target: SharingRelaunch.Target? = .display(1)) {
        SharingRelaunch.save(target, defaults: defaults, now: now, build: "47", bootSession: "boot-a")
    }

    private func take(seconds: TimeInterval = 20, build: String = "48", boot: String = "boot-a", active: Bool = true) -> SharingRelaunch.Target? {
        SharingRelaunch.take(defaults: defaults, now: now.addingTimeInterval(seconds), build: build, bootSession: boot, sessionActive: active)
    }

    func testUpdateRestoresTheSameDisplayOnce() {
        save()
        XCTAssertEqual(take(), .display(1))
        XCTAssertNil(take(), "An ordinary subsequent launch must not reopen sharing.")
    }

    func testSelectedWindowNeverBecomesWholeDesktopSharing() {
        let target = SharingRelaunch.Target.window(pid: 123, id: 456, launchedAt: now.addingTimeInterval(-600))
        save(target)
        XCTAssertEqual(take(), target)
    }
    func testUpdateKeepsTheIndependentPointerMode() {
        save(.independentDisplay(1))
        XCTAssertEqual(take(), .independentDisplay(1))
    }

    func testClosedAccessClearsAnyPendingRestoration() {
        save()
        save(nil)
        XCTAssertNil(take())
    }

    func testUnfinishedUpdateExpiredIntentRebootAndLockDoNotReopenAccess() {
        save(); XCTAssertNil(take(build: "47")); XCTAssertNil(take())
        save(); XCTAssertNil(take(build: "46")); XCTAssertNil(take())
        save(); XCTAssertNil(take(seconds: 301)); XCTAssertNil(take())
        save(); XCTAssertNil(take(seconds: -1)); XCTAssertNil(take())
        save(); XCTAssertNil(take(boot: "boot-b")); XCTAssertNil(take())
        save(); XCTAssertNil(take(active: false)); XCTAssertNil(take())
    }

    @MainActor func testOnlyAnActualSparkleRelaunchMarksTheTerminationAsAnUpdate() {
        let delegate = AppUpdater()
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        XCTAssertFalse(delegate.relaunchingForUpdate)
        delegate.updaterWillRelaunchApplication(controller.updater)
        XCTAssertTrue(delegate.relaunchingForUpdate)
        delegate.updater(controller.updater, didAbortWithError: NSError(domain: "test", code: 1))
        XCTAssertFalse(delegate.relaunchingForUpdate)
    }
}
