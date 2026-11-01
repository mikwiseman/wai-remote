import XCTest
@testable import RemoteCore

final class ScrollProtocolTests: XCTestCase {
    func testScrollLifecycleSurvivesTheWireIncludingZeroDistanceEnd() throws {
        for (field, phases) in [("scrollPhase", ["began", "changed", "ended", "cancelled"]),
                                ("momentumPhase", ["began", "changed", "ended"])] {
            for phase in phases {
                let host = machine()
                let message = try packet(host.state, extra: [field: phase])
                let input = try XCTUnwrap(host.handle(message, now: 1).input)
                let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
                XCTAssertEqual(encoded[field] as? String, phase)
            }
        }
    }

    func testInvalidOrMisplacedPhasesCannotReachNativeInput() throws {
        let invalid: [[String: Any]] = [
            ["scrollPhase": "unknown"], ["momentumPhase": "cancelled"],
            ["scrollPhase": "changed", "momentumPhase": "changed"],
            ["action": "move", "scrollPhase": "began"],
            ["type": "heartbeat", "momentumPhase": "ended"]
        ]
        for extra in invalid {
            let host = machine()
            XCTAssertFalse(host.handle(try packet(host.state, extra: extra), now: 1).accepted, "\(extra)")
            XCTAssertEqual(host.state.nextSequence, 0)
        }
    }

    func testLegacyScrollStillWorksAndPhasesDoNotBypassPermissionsOrEpochs() throws {
        let host = machine()
        XCTAssertNotNil(host.handle(try packet(host.state, extra: [:]), now: 1).input)
        var stale = try packet(host.state, extra: ["scrollPhase": "ended"])
        stale.inputEpoch -= 1
        XCTAssertNil(host.handle(stale, now: 2).input)
        let readOnly = machine(control: false)
        XCTAssertNil(readOnly.handle(try packet(readOnly.state, extra: ["scrollPhase": "began"]), now: 1).input)
    }

    private func machine(control: Bool = true) -> SessionMachine {
        SessionMachine(surface: .init(id: "display", width: 1600, height: 900),
                       permissions: .init(control: control, annotate: true))
    }
    private func packet(_ state: HostState, extra: [String: Any]) throws -> WireMessage {
        var message = WireMessage(type: "pointer", state: state)
        message.action = "scroll"; message.x = 0.5; message.y = 0.5
        message.deltaX = 0; message.deltaY = 0
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        object.merge(extra) { _, value in value }
        return try JSONDecoder().decode(WireMessage.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
