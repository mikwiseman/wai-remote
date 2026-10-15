import Foundation
import Network
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class SignalingTests: XCTestCase {
    func testHostRegistersAgainAfterSignalingConnectionIsLost() throws {
        let gateway = try TestGateway()
        defer { gateway.stop() }
        let signal = Signaling(identity: DeviceIdentity())
        defer { signal.close() }
        let ready = expectation(description: "Host registers again without reopening sharing")
        ready.expectedFulfillmentCount = 2
        var registrations = 0
        signal.onReady = { _ in
            registrations += 1
            ready.fulfill()
            if registrations == 1 { gateway.connections[0].cancel() }
        }
        signal.onFailure = { error in XCTFail("A temporary disconnect must not close access: \(error)") }
        signal.connect(url: try start(gateway))
        wait(for: [ready], timeout: 4)
        XCTAssertEqual(gateway.connections.count, 2)
    }

    func testClosingAccessCancelsThePendingReconnect() throws {
        let gateway = try TestGateway()
        defer { gateway.stop() }
        let signal = Signaling(identity: DeviceIdentity())
        defer { signal.close() }
        let retryCancelled = expectation(description: "Closing access cancels recovery")
        let reopened = expectation(description: "Access must stay closed")
        reopened.isInverted = true
        var registrations = 0
        signal.onReady = { _ in
            registrations += 1
            if registrations == 1 { gateway.connections[0].cancel() }
            else { reopened.fulfill() }
        }
        signal.onReconnecting = { [weak signal] in signal?.close(); retryCancelled.fulfill() }
        signal.connect(url: try start(gateway))
        wait(for: [retryCancelled], timeout: 2)
        wait(for: [reopened], timeout: 1.3)
        XCTAssertEqual(gateway.connections.count, 1)
    }

    func testExpiredGatewayRegistrationCanBeRetried() throws {
        let gateway = try TestGateway()
        defer { gateway.stop() }
        gateway.onHello = { connection, number in
            if number == 1 { TestGateway.reject("identity already connected or capacity reached", connection: connection) }
            else { TestGateway.send(["type": "ready"], to: connection) }
        }
        let signal = Signaling(identity: DeviceIdentity())
        defer { signal.close() }
        let ready = expectation(description: "Stale server registration does not permanently close access")
        signal.onReady = { _ in ready.fulfill() }
        signal.onFailure = { error in XCTFail(error) }
        signal.connect(url: try start(gateway))
        wait(for: [ready], timeout: 4)
        XCTAssertEqual(gateway.connections.count, 2)
    }

    func testAuthenticationFailureIsTerminal() throws {
        try assertTerminalFailure { TestGateway.reject("authentication failed", connection: $0) }
    }

    func testInvalidRelayConfigurationIsTerminal() throws {
        try assertTerminalFailure { TestGateway.send(["type": "ready", "ice": ["expiresAt": 0]], to: $0) }
    }

    private func assertTerminalFailure(_ reject: @escaping (NWConnection) -> Void) throws {
        let gateway = try TestGateway()
        defer { gateway.stop() }
        gateway.onHello = { connection, _ in reject(connection) }
        let signal = Signaling(identity: DeviceIdentity())
        defer { signal.close() }
        let failed = expectation(description: "Invalid protocol data closes access")
        let retried = expectation(description: "Invalid protocol data must not trigger recovery")
        retried.isInverted = true
        signal.onReady = { _ in XCTFail("Invalid connection became ready") }
        signal.onFailure = { _ in failed.fulfill() }
        signal.onReconnecting = { retried.fulfill() }
        signal.connect(url: try start(gateway))
        wait(for: [failed], timeout: 2)
        wait(for: [retried], timeout: 1.3)
        XCTAssertEqual(gateway.connections.count, 1)
    }

    private func start(_ gateway: TestGateway) throws -> URL {
        let listening = expectation(description: "Loopback gateway is ready")
        gateway.listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
            if case .failed(let error) = state { XCTFail("\(error)"); listening.fulfill() }
        }
        gateway.listener.start(queue: .main)
        wait(for: [listening], timeout: 2)
        return URL(string: "ws://127.0.0.1:\(try XCTUnwrap(gateway.listener.port).rawValue)/signal")!
    }
}

/// A real loopback WebSocket peer exercises URLSession failure and re-registration.
private final class TestGateway {
    let listener: NWListener
    var connections: [NWConnection] = []
    var onHello: ((NWConnection, Int) -> Void)?

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            let number = self.connections.count
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard case .ready = state, let self, let connection else { return }
                Self.send(["type": "challenge", "nonce": "test-challenge"], to: connection)
                connection.receiveMessage { [weak self, weak connection] data, _, _, error in
                    guard let self, let connection, let data else { XCTFail("Missing host hello: \(String(describing: error))"); return }
                    let hello = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    XCTAssertEqual(hello?["type"] as? String, "hello")
                    let host = hello?["hostID"] as? String ?? ""
                    XCTAssertTrue(DeviceIdentity.verify(hello?["signature"] as? String ?? "",
                        data: Data("host\n\(host)\n\(host)\ntest-challenge".utf8),
                        domain: "wai-remote/signal/v1", publicKey: hello?["publicKey"] as? String ?? ""))
                    if let onHello = self.onHello { onHello(connection, number) }
                    else { Self.send(["type": "ready"], to: connection) }
                }
            }
            connection.start(queue: .main)
        }
    }

    static func send(_ object: [String: Any], to connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "test-message", metadata: [metadata])
        connection.send(content: try! JSONSerialization.data(withJSONObject: object), contentContext: context,
            isComplete: true, completion: .contentProcessed { error in
                if let error { XCTFail("Gateway send failed: \(error)") }
            })
    }

    static func reject(_ reason: String, connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.policyViolation)
        let context = NWConnection.ContentContext(identifier: "test-close", metadata: [metadata])
        connection.send(content: Data(reason.utf8), contentContext: context, isComplete: true,
            completion: .contentProcessed { error in
                if let error { XCTFail("Gateway close failed: \(error)") }
            })
    }

    func stop() { listener.cancel(); connections.forEach { $0.cancel() } }
}
