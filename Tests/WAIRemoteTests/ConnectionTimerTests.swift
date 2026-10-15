import AppKit
import XCTest
@testable import WAIRemote

@MainActor
final class ConnectionTimerTests: XCTestCase {
    func testHeartbeatKeepsRunningWhileTheUserTracksAMenu() {
        // AppKit adds its tracking mode when it starts the application event loop.
        _ = NSApplication.shared
        var ticks = 0
        let timer = Timer.connectionTimer(withTimeInterval: 0.01, repeats: true) { _ in ticks += 1 }
        defer { timer.invalidate() }
        let deadline = Date().addingTimeInterval(0.08)
        while Date() < deadline { RunLoop.main.run(mode: .eventTracking, before: deadline) }
        XCTAssertGreaterThan(ticks, 0, "A menu must not pause the heartbeat and make the host reject subsequent input.")
    }
}
