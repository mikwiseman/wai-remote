import XCTest
@testable import RemoteCore

final class ICEConfigurationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var ice: [String: Any] {
        ["iceServers": [["urls": ["turn:relay.example:3478?transport=udp"], "username": "temporary", "credential": "temporary-password"]],
         "iceTransportPolicy": "relay", "expiresAt": 1_800_003_600]
    }
    func testLegacyLANAndAuthenticatedRelayConfiguration() throws {
        XCTAssertTrue(try ICEConfiguration.read(["type": "ready"], now: now).iceServers.isEmpty)
        let config = try ICEConfiguration.read(["ice": ice], now: now)
        XCTAssertEqual(config.iceTransportPolicy, "relay")
        XCTAssertEqual(config.iceServers.first?.urls, ["turn:relay.example:3478?transport=udp"])
    }
    func testDirectFirstConfigurationKeepsBothRelays() throws {
        var direct = ice; direct["iceTransportPolicy"] = "all"
        let urls = ["stun:relay.example:3478", "turn:relay.example:3478?transport=udp", "turn:relay.example:3478?transport=tcp"]
        direct["iceServers"] = [["urls": urls, "username": "temporary", "credential": "temporary-password"]]
        let config = try ICEConfiguration.read(["ice": direct], now: now)
        XCTAssertEqual(config.iceTransportPolicy, "all")
        XCTAssertEqual(config.iceServers.first?.urls, urls)
        direct["iceServers"] = [["urls": ["stun:relay.example:3478?transport=udp"], "username": "temporary", "credential": "temporary-password"]]
        XCTAssertThrowsError(try ICEConfiguration.read(["ice": direct], now: now))
    }
    func testInvalidOrExpiredRelayCannotSilentlyFallBackToLAN() {
        for expiry in [1_799_999_999, 1_800_008_000] {
            var invalid = ice; invalid["expiresAt"] = expiry
            XCTAssertThrowsError(try ICEConfiguration.read(["ice": invalid], now: now))
        }
        var invalid = ice; invalid["iceServers"] = []
        XCTAssertThrowsError(try ICEConfiguration.read(["ice": invalid], now: now))
        invalid = ice; invalid["iceTransportPolicy"] = "unknown"
        XCTAssertThrowsError(try ICEConfiguration.read(["ice": invalid], now: now))
        invalid = ice; invalid["iceServers"] = [["urls": ["https://relay.example"], "username": "temporary", "credential": "temporary-password"]]
        XCTAssertThrowsError(try ICEConfiguration.read(["ice": invalid], now: now))
        XCTAssertThrowsError(try ICEConfiguration.read(["ice": NSNull()], now: now))
    }
}
