import AppKit
import Network
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class SignalingTests: XCTestCase {
    func testGatewayReportsSendFailureWhileActive() throws {
        try checkCancelledGatewaySend(stopping: false)
    }
    func testGatewayDoesNotReportPendingSendFailureAfterStop() throws {
        try checkCancelledGatewaySend(stopping: true)
    }
    private func checkCancelledGatewaySend(stopping: Bool) throws {
        let gateway = try TestGateway()
        defer { gateway.stop() }
        let signal = Signaling(identity: DeviceIdentity())
        defer { signal.close() }
        let ready = expectation(description: "Gateway connection is ready")
        signal.onReady = { _ in ready.fulfill() }
        signal.onFailure = { XCTFail($0) }
        signal.connect(url: try start(gateway))
        wait(for: [ready], timeout: 2)
        let connection = try XCTUnwrap(gateway.connections.first)
        var failures: [String] = []
        gateway.onFailure = { failures.append($0) }
        let completed = expectation(description: "Canceled send completion arrived")
        // Completion is delivered on the main queue. Stop synchronously before
        // pumping it, reproducing a pending callback outliving fixture teardown.
        connection.cancel()
        gateway.send(["type": "pong"], to: connection) { error in
            XCTAssertNotNil(error, "The regression must exercise a real failed send")
            completed.fulfill()
        }
        if stopping { gateway.stop() }
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(failures.count, stopping ? 0 : 1)
    }

    func testSilentHalfOpenSocketIsReplacedWithoutWaitingForTheTCPTimeout() throws {
        let gateway = try TestGateway()
        defer { gateway.stop() }
        let signal = Signaling(identity: DeviceIdentity(), heartbeatInterval: 0.1, responseTimeout: 0.25)
        defer { signal.close() }
        let ready = expectation(description: "Replace a socket that accepts writes but stops responding")
        ready.expectedFulfillmentCount = 2
        signal.onReady = { _ in ready.fulfill() }
        signal.onFailure = { error in XCTFail(error) }
        signal.connect(url: try start(gateway))
        wait(for: [ready], timeout: 3)
        XCTAssertEqual(gateway.connections.count, 2)
    }
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
        gateway.onHello = { [weak gateway] connection, number in
            if number == 1 { gateway?.reject("identity already connected or capacity reached", connection: connection) }
            else { gateway?.send(["type": "ready"], to: connection) }
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

    func testResponsiveGatewayDoesNotLoseHostRegistrationDuringMenuTracking() throws {
        _ = NSApplication.shared
        let gateway = try TestGateway(queue: DispatchQueue(label: "test.signaling.gateway"), repliesToPings: true)
        defer { gateway.stop() }
        let signal = Signaling(identity: DeviceIdentity(), heartbeatInterval: 0.05, responseTimeout: 0.3)
        defer { signal.close() }
        let ready = expectation(description: "Host registered")
        signal.onReady = { _ in ready.fulfill() }
        signal.onFailure = { XCTFail($0) }
        var reconnects = 0
        signal.onReconnecting = { reconnects += 1 }
        signal.connect(url: try start(gateway))
        wait(for: [ready], timeout: 2)
        let tracked = expectation(description: "Bounded menu tracking finished")
        DispatchQueue.main.async {
            let repliesBeforeTracking = gateway.pongs
            let deadline = Date().addingTimeInterval(0.7)
            while Date() < deadline { RunLoop.main.run(mode: .eventTracking, before: deadline) }
            XCTAssertGreaterThan(gateway.pongs, repliesBeforeTracking,
                                 "The real gateway must reply while the main queue is tracking.")
            tracked.fulfill()
        }
        wait(for: [tracked], timeout: 2)
        XCTAssertEqual(reconnects, 0, "A responsive socket must not be declared silent just because a menu is open.")
        XCTAssertEqual(gateway.connections.count, 1)
    }

    func testLostHostRegistrationCanRecoverBeforeMenuTrackingEnds() throws {
        _ = NSApplication.shared
        let gateway = try TestGateway(queue: DispatchQueue(label: "test.signaling.recovery"), repliesToPings: true)
        defer { gateway.stop() }
        let signal = Signaling(identity: DeviceIdentity())
        defer { signal.close() }
        let ready = expectation(description: "Initial host registration")
        let tracked = expectation(description: "Bounded menu tracking finished")
        var registrations = 0, tracking = false, recoveredDuringTracking = false
        signal.onReady = { _ in
            registrations += 1
            if registrations == 1 { ready.fulfill() }
            else { recoveredDuringTracking = tracking }
        }
        signal.onFailure = { XCTFail($0) }
        signal.connect(url: try start(gateway))
        wait(for: [ready], timeout: 2)
        DispatchQueue.main.async {
            tracking = true
            gateway.connections[0].cancel()
            let deadline = Date().addingTimeInterval(2.5)
            while !recoveredDuringTracking && Date() < deadline {
                RunLoop.main.run(mode: .eventTracking, before: deadline)
            }
            tracking = false
            tracked.fulfill()
        }
        wait(for: [tracked], timeout: 4)
        XCTAssertTrue(recoveredDuringTracking, "A new socket must complete its challenge while the menu remains open.")
        XCTAssertEqual(registrations, 2)
    }

    func testAuthenticationFailureIsTerminal() throws {
        try assertTerminalFailure { $0.reject("authentication failed", connection: $1) }
    }

    func testInvalidRelayConfigurationIsTerminal() throws {
        try assertTerminalFailure { $0.send(["type": "ready", "ice": ["expiresAt": 0]], to: $1) }
    }

    private func assertTerminalFailure(_ reject: @escaping (TestGateway, NWConnection) -> Void) throws {
        let gateway = try TestGateway()
        defer { gateway.stop() }
        gateway.onHello = { [weak gateway] connection, _ in
            if let gateway { reject(gateway, connection) }
        }
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
        gateway.listener.start(queue: gateway.queue)
        wait(for: [listening], timeout: 2)
        return URL(string: "ws://127.0.0.1:\(try XCTUnwrap(gateway.listener.port).rawValue)/signal")!
    }
}

/// A real loopback WebSocket peer exercises URLSession failure and re-registration.
private final class TestGateway {
    let listener: NWListener
    let queue: DispatchQueue
    private let lock = NSLock()
    private var opened: [NWConnection] = []
    private var replies = 0
    private var stopped = false
    var connections: [NWConnection] { lock.withLock { opened } }
    var pongs: Int { lock.withLock { replies } }
    var onHello: ((NWConnection, Int) -> Void)?
    var onFailure: (String) -> Void = { XCTFail($0) }

    init(queue: DispatchQueue = .main, repliesToPings: Bool = false) throws {
        self.queue = queue
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let number = self.lock.withLock { self.opened.append(connection); return self.opened.count }
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard case .ready = state, let self, let connection else { return }
                self.send(["type": "challenge", "nonce": "test-challenge"], to: connection)
                connection.receiveMessage { [weak self, weak connection] data, _, _, error in
                    guard let self, let connection, let data else { XCTFail("Missing host hello: \(String(describing: error))"); return }
                    let hello = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    XCTAssertEqual(hello?["type"] as? String, "hello")
                    let host = hello?["hostID"] as? String ?? ""
                    XCTAssertTrue(DeviceIdentity.verify(hello?["signature"] as? String ?? "",
                        data: Data("host\n\(host)\n\(host)\ntest-challenge".utf8),
                        domain: "wai-remote/signal/v1", publicKey: hello?["publicKey"] as? String ?? ""))
                    if let onHello = self.onHello { onHello(connection, number) }
                    else { self.send(["type": "ready"], to: connection) }
                    if repliesToPings { self.receivePing(connection) }
                }
            }
            connection.start(queue: queue)
        }
    }

    private func receivePing(_ connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, let data, error == nil else { return }
            let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if message?["type"] as? String == "ping" {
                self.lock.withLock { self.replies += 1 }
                self.send(["type": "pong"], to: connection)
            }
            self.receivePing(connection)
        }
    }

    func send(_ object: [String: Any], to connection: NWConnection, completion: ((NWError?) -> Void)? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "test-message", metadata: [metadata])
        connection.send(content: try! JSONSerialization.data(withJSONObject: object), contentContext: context,
            isComplete: true, completion: .contentProcessed { [weak self] error in
                if let error { self?.report("Gateway send failed: \(error)") }
                completion?(error)
            })
    }

    func reject(_ reason: String, connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.policyViolation)
        let context = NWConnection.ContentContext(identifier: "test-close", metadata: [metadata])
        connection.send(content: Data(reason.utf8), contentContext: context, isComplete: true,
            completion: .contentProcessed { [weak self] error in
                if let error { self?.report("Gateway close failed: \(error)") }
            })
    }

    private func report(_ message: String) {
        // Canceling the fixture can finish an already submitted send with
        // ECANCELED. Active-connection errors must still fail the owning test.
        guard lock.withLock({ !stopped }) else { return }
        onFailure(message)
    }
    func stop() {
        lock.withLock { stopped = true }
        listener.cancel(); connections.forEach { $0.cancel() }
    }
}
