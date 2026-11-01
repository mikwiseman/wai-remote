import Foundation
import XCTest
@testable import WAIRemote

@MainActor
final class AgentSocketTests: XCTestCase {
    func testRequestDeadlineIsCheckedBeforeExecutionAndCannotWaitBehindStartedWork() {
        let expired = AgentSocket.Pending(timeout: -1)
        expired.run { XCTFail("A queued action cannot begin after its deadline"); return AgentReply(body: [:]) }
        XCTAssertEqual(expired.finish().body["error"] as? String, "app_busy")
        let started = AgentSocket.Pending(timeout: 5), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.run { entered.signal(); _ = release.wait(timeout: .now() + 2); return AgentReply(body: ["ok":true]) }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let before = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(started.finish().body["error"] as? String, "execution_pending")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - before, 0.2)
        release.signal(); XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(started.finish().body["error"] as? String, "execution_pending")
    }
    func testRealUnixSocketIsPrivateAndDispatchesRequestsOnMainThread() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("wai-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = try AgentSocket(path: directory.appendingPathComponent("agent.sock")) { data in
            XCTAssertTrue(Thread.isMainThread)
            return AgentReply(body: ["ok":true, "echo":String(decoding:data, as:UTF8.self)])
        }
        defer { socket.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: socket.path.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let parent = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((parent[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertThrowsError(try AgentSocket(path: socket.path) { _ in AgentReply(body: [:]) })
        let result = try await Task.detached { try Self.exchange(path: socket.path.path, payload: Data(#"{"command":"status"}"#.utf8)) }.value
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["echo"] as? String, #"{"command":"status"}"#)
    }
    func testMalformedOversizedAndForeignPathRequestsCannotReachDispatcher() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("wai-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let socket = try AgentSocket(path: directory.appendingPathComponent("agent.sock")) { _ in calls += 1; return AgentReply(body: ["ok":true]) }
        defer { socket.stop() }
        let oversized = try await Task.detached { try Self.exchange(path: socket.path.path, payload: Data(repeating: 65, count: 65_537)) }.value
        XCTAssertTrue(String(decoding: oversized, as: UTF8.self).contains("request_too_large"))
        XCTAssertEqual(calls, 0)
        let link = directory.appendingPathComponent("alias.sock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: socket.path)
        XCTAssertThrowsError(try AgentSocket(path: link) { _ in AgentReply(body: [:]) })
    }
    func testTimedOutRequestDoesNotExecuteWhenTheMainLoopResumes() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("wai-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var calls = 0
        let socket = try AgentSocket(path: directory.appendingPathComponent("agent.sock"), dispatchTimeout: 0.05) { _ in
            calls += 1; return AgentReply(body: ["ok":true])
        }
        defer { socket.stop() }
        let returned = DispatchSemaphore(value: 0), path = socket.path.path
        var response = Data()
        DispatchQueue.global().async {
            response = (try? Self.exchange(path: path, payload: Data(#"{"command":"status"}"#.utf8))) ?? Data()
            returned.signal()
        }
        // Simulate an occupied main run loop while the socket's bounded request expires.
        XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("app_busy"))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls, 0, "A timed-out mutation must not run later.")
    }
    func testCLIExchangesUnicodeAndWritesAPrivateRemotePNG() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/wa-" + UUID().uuidString.prefix(8), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = AgentFrameCapture(), renderer = capture.beginStream()
        renderer.renderFrame(try AgentFrameCaptureTests.frame(luma: 100))
        var receivedText: String?
        let socket = try AgentSocket(path: directory.appendingPathComponent("Library/Caches/is.wai.remote.agent/control.sock")) { data in
            let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if request?["command"] as? String == "screenshot" {
                return AgentReply(body: ["ok":true, "snapshotID":"test-snapshot", "frameNumber":1], frame: capture.latest())
            }
            receivedText = request?["text"] as? String
            return AgentReply(body: ["ok":true, "status":"submitted"])
        }
        defer { socket.stop() }
        let text = "Exact x — Привет! 👨‍👩‍👧‍👦\n"
        _ = try await Task.detached { try Self.runCLI(home: directory.path, arguments: ["text", "--snapshot", "test-snapshot"], input: Data(text.utf8)) }.value
        XCTAssertEqual(receivedText, text)
        let output = directory.appendingPathComponent("remote.png")
        let reply = try await Task.detached { try Self.runCLI(home: directory.path, arguments: ["screenshot", "--output", output.path]) }.value
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertEqual(result["snapshotID"] as? String, "test-snapshot")
        XCTAssertFalse(String(decoding: reply, as: UTF8.self).contains("base64"))
        XCTAssertEqual(try Data(contentsOf: output).prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    nonisolated private static func runCLI(home: String, arguments: [String], input: Data = Data()) throws -> Data {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/wai-remote-agent.py")
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Redirect only Path.home inside this isolated test process; no app or shell settings change.
        process.arguments = ["-c", "import pathlib,runpy,sys\nfrom unittest.mock import patch\nscript=sys.argv.pop(1); home=sys.argv.pop(1); sys.argv[0]=script\nwith patch.object(pathlib.Path,'home',return_value=pathlib.Path(home)):\n runpy.run_path(script,run_name='__main__')", script.path, home] + arguments
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run(); stdin.fileHandleForWriting.write(input); try stdin.fileHandleForWriting.close()
        let result = stdout.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain:"AgentCLI", code:Int(process.terminationStatus), userInfo:[NSLocalizedDescriptionKey:String(decoding:stderr.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)]) }
        return result
    }
    nonisolated private static func exchange(path: String, payload: Data) throws -> Data {
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import socket,sys\ns=socket.socket(socket.AF_UNIX)\ns.settimeout(8)\ns.connect(sys.argv[1])\ntry: s.sendall(sys.stdin.buffer.read()+b'\\n')\nexcept BrokenPipeError: pass\nwhile True:\n d=s.recv(65536)\n if not d: break\n sys.stdout.buffer.write(d)", path]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run(); input.fileHandleForWriting.write(payload); try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw NSError(domain:"AgentSocketTests", code:Int(process.terminationStatus), userInfo:[NSLocalizedDescriptionKey:String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)]) }
        return result
    }
}
