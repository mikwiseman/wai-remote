import RemoteCore
import XCTest
@testable import WAI_Remote

@MainActor
final class PhoneConnectionTests: XCTestCase {
    private func waiting() throws -> (PhoneModel, DeviceIdentity) {
        let host = DeviceIdentity(), model = PhoneModel()
        try model.prepareConnectionForTesting(invitation: "http://127.0.0.1:1/#host=\(host.id)&key=\(host.publicKey)", nonce: "current-offer")
        return (model, host)
    }

    private func busy(_ model: PhoneModel, host: DeviceIdentity, sessionID: String? = "session-A",
                      nonce: String = "current-offer", changes: [String: String] = [:], signer: DeviceIdentity? = nil) throws -> [String: Any] {
        var payload: [String: Any] = ["hostID": host.id, "peerID": try XCTUnwrap(model.identity).id, "nonce": nonce]
        if let sessionID { payload["sessionID"] = sessionID }
        changes.forEach { payload[$0.key] = $0.value }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return ["type": "reject", "from": host.id,
                "body": ["reason": "busy", "payload": data.base64URL,
                         "signature": try (signer ?? host).sign(data, domain: "wai-remote/busy/v1")]]
    }
    private func payload(_ body: [String: Any], signedBy identity: DeviceIdentity) throws -> [String: Any] {
        let data = try XCTUnwrap(Data(base64URL: XCTUnwrap(body["payload"] as? String)))
        XCTAssertTrue(DeviceIdentity.verify(try XCTUnwrap(body["signature"] as? String), data: data,
                                           domain: "wai-remote/offer/v1", publicKey: identity.publicKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testBusyExplainsTheOtherDeviceAndDoesNotAutomaticallyRetry() async throws {
        let (model, _) = try waiting()
        let retried = expectation(description: "Busy waits for a deliberate choice"); retried.isInverted = true
        model.onConnectForTesting = { _ in retried.fulfill() }
        model.receiveSignalForTesting(["type": "reject", "body": ["reason": "busy"]])
        XCTAssertEqual(model.status, "Mac подключён к другому устройству")
        XCTAssertEqual(model.detail, "Отключитесь на другом устройстве и повторите подключение.")
        XCTAssertTrue(model.connecting)
        XCTAssertFalse(model.connectionInterrupted, "Busy is not a broken network connection")
        await fulfillment(of: [retried], timeout: 1.2)
        model.disconnect()
    }

    func testReplacedSessionStopsWithoutRecovering() async throws {
        let (model, _) = try waiting()
        model.connected = true; model.connecting = false
        let retried = expectation(description: "A replaced viewer cannot reclaim the Mac"); retried.isInverted = true
        model.onConnectForTesting = { _ in retried.fulfill() }
        model.receiveSignalForTesting(["type": "reject", "body": ["reason": "session-replaced"]])
        XCTAssertEqual(model.status, "Подключение продолжено на другом устройстве")
        XCTAssertFalse(model.connecting)
        XCTAssertFalse(model.connected)
        await fulfillment(of: [retried], timeout: 1.2)
    }

    func testSignedSessionSwitchIsExplicitAndAutomaticRecoveryCannotRepeatIt() async throws {
        let (model, host) = try waiting()
        var offers: [[String: Any]] = []
        let recovered = expectation(description: "Network recovery makes an ordinary offer")
        model.onConnectForTesting = { offers.append($0); if offers.count == 2 { recovered.fulfill() } }
        model.receiveSignalForTesting(try busy(model, host: host))
        XCTAssertTrue(model.connectionBusy); XCTAssertTrue(model.canSwitchConnection)
        XCTAssertEqual(model.detail, "Подключение на другом устройстве завершится.")
        XCTAssertTrue(offers.isEmpty, "A host capability does not itself authorize switching")
        model.switchConnection()
        XCTAssertEqual(offers.count, 1)
        XCTAssertFalse(model.connectionBusy); XCTAssertFalse(model.canSwitchConnection)
        let identity = try XCTUnwrap(model.identity)
        let switched = try payload(XCTUnwrap(offers.first), signedBy: identity)
        XCTAssertEqual(switched["replaceSessionID"] as? String, "session-A")
        XCTAssertEqual(switched["hostID"] as? String, host.id)
        model.recover(message: "Network interruption")
        await fulfillment(of: [recovered], timeout: 2)
        let retry = try payload(XCTUnwrap(offers.last), signedBy: identity)
        XCTAssertNil(retry["replaceSessionID"], "A retry must never displace a later session")
        XCTAssertNotEqual(retry["nonce"] as? String, switched["nonce"] as? String)
        model.disconnect()
    }

    func testBusyCapabilityMustMatchPinnedHostViewerAndCurrentOffer() throws {
        for changes in [["hostID": "another-host"], ["peerID": "another-viewer"], ["nonce": "old-offer"]] {
            let (model, host) = try waiting()
            model.receiveSignalForTesting(try busy(model, host: host, changes: changes))
            XCTAssertFalse(model.canSwitchConnection)
            XCTAssertFalse(model.connecting)
            XCTAssertEqual(model.status, "Подлинность Mac не подтверждена. Откройте новое приглашение.")
        }
        let (model, host) = try waiting()
        model.receiveSignalForTesting(try busy(model, host: host, signer: DeviceIdentity()))
        XCTAssertFalse(model.canSwitchConnection)
        XCTAssertFalse(model.connecting)
    }

    func testSignedBusyWithoutControlCapabilityAllowsOnlyAnOrdinaryRetry() throws {
        let (model, host) = try waiting()
        var offers: [[String: Any]] = []
        model.onConnectForTesting = { offers.append($0) }
        model.receiveSignalForTesting(try busy(model, host: host, sessionID: nil))
        XCTAssertTrue(model.connectionBusy); XCTAssertFalse(model.canSwitchConnection)
        model.switchConnection()
        XCTAssertTrue(offers.isEmpty)
        model.retryConnection()
        let retried = try payload(XCTUnwrap(offers.first), signedBy: XCTUnwrap(model.identity))
        XCTAssertNil(retried["replaceSessionID"])
        model.disconnect()
    }

    func testBusyStateSurvivesBackgroundWithoutAutomaticConnectionAndCancelClearsIt() throws {
        let (model, host) = try waiting()
        var offers = 0
        model.onConnectForTesting = { _ in offers += 1 }
        model.receiveSignalForTesting(try busy(model, host: host))
        model.suspend(); model.resume()
        XCTAssertTrue(model.connectionBusy); XCTAssertTrue(model.canSwitchConnection)
        XCTAssertEqual(offers, 0)
        model.disconnect()
        model.switchConnection(); model.retryConnection()
        XCTAssertFalse(model.connectionBusy); XCTAssertFalse(model.canSwitchConnection)
        XCTAssertEqual(offers, 0)
    }

    func testChangedHostSessionRequiresAnotherExplicitSwitch() throws {
        let (model, host) = try waiting()
        var offers: [[String: Any]] = []
        model.onConnectForTesting = { offers.append($0) }
        model.receiveSignalForTesting(try busy(model, host: host))
        model.switchConnection()
        let identity = try XCTUnwrap(model.identity)
        let first = try payload(XCTUnwrap(offers.first), signedBy: identity)
        let nonce = try XCTUnwrap(first["nonce"] as? String)
        model.receiveSignalForTesting(try busy(model, host: host, sessionID: "session-B", nonce: nonce))
        XCTAssertTrue(model.connectionBusy); XCTAssertTrue(model.canSwitchConnection)
        XCTAssertEqual(offers.count, 1)
        model.switchConnection()
        let second = try payload(XCTUnwrap(offers.last), signedBy: identity)
        XCTAssertEqual(offers.count, 2)
        XCTAssertEqual(second["replaceSessionID"] as? String, "session-B")
        model.disconnect()
    }
}
