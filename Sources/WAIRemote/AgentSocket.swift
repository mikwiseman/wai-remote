import Foundation
import Darwin

final class AgentSocket {
    struct Failure: Error { let code: String; init(_ code: String) { self.code = code } }
    static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/is.wai.remote.agent/control.sock")
    }
    let path: URL
    private let queue = DispatchQueue(label: "is.wai.remote.agent", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true
    private var source: DispatchSourceRead?
    private let inode: ino_t
    private let handler: (Data) -> AgentReply
    private let dispatchTimeout: TimeInterval
    final class Pending: @unchecked Sendable {
        private enum State { case queued, running, completed, cancelled, abandoned }
        private let lock = NSLock()
        private var state = State.queued
        private var value: AgentReply?
        private let deadline: TimeInterval
        let ready = DispatchSemaphore(value: 0)
        init(timeout: TimeInterval) { deadline = ProcessInfo.processInfo.systemUptime + timeout }
        func run(_ operation: () -> AgentReply) {
            lock.lock()
            guard state == .queued else { lock.unlock(); return }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                state = .cancelled; lock.unlock(); ready.signal(); return
            }
            state = .running; lock.unlock()
            let result = operation()
            lock.lock()
            if state == .running { value = result; state = .completed }
            lock.unlock(); ready.signal()
        }
        func finish() -> AgentReply {
            lock.lock(); defer { lock.unlock() }
            switch state {
            case .completed: return value!
            case .running: state = .abandoned; return .failure("execution_pending")
            case .abandoned: return .failure("execution_pending")
            case .queued, .cancelled: state = .cancelled; return .failure("app_busy")
            }
        }
    }
    init(path: URL, dispatchTimeout: TimeInterval = 5, handler: @escaping (Data) -> AgentReply) throws {
        self.path = path.standardizedFileURL; self.handler = handler; self.dispatchTimeout = dispatchTimeout
        let directory = self.path.deletingLastPathComponent()
        // Do not follow a redirected directory or socket, even inside the home folder.
        var component = URL(fileURLWithPath: "/", isDirectory: true)
        for name in directory.pathComponents.dropFirst() {
            component.appendPathComponent(name, isDirectory: true)
            var info = stat()
            if lstat(component.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure("unsafe_path") }
            } else if errno != ENOENT { throw Failure("unsafe_path") }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        var parent = stat()
        guard lstat(directory.path, &parent) == 0, parent.st_mode & S_IFMT == S_IFDIR,
              parent.st_uid == geteuid(), parent.st_mode & 0o777 == 0o700 else { throw Failure("unsafe_directory") }
        var address = try Self.address(self.path.path)
        var existing = stat()
        if lstat(self.path.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == geteuid(), existing.st_mode & 0o777 == 0o600 else { throw Failure("unsafe_path") }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw Failure("socket_unavailable") }
            _ = fcntl(probe, F_SETFL, O_NONBLOCK)
            let result = Self.withAddress(&address) { Darwin.connect(probe, $0, $1) }
            let failure = errno; Darwin.close(probe)
            guard result != 0, failure == ECONNREFUSED else { throw Failure("already_running") }
            var unchanged = stat()
            guard lstat(self.path.path, &unchanged) == 0, unchanged.st_ino == existing.st_ino,
                  unlink(self.path.path) == 0 else { throw Failure("unsafe_path") }
        } else if errno != ENOENT { throw Failure("unsafe_path") }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw Failure("socket_unavailable") }
        var bound = false
        do {
            _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
            guard Self.withAddress(&address, { Darwin.bind(listener, $0, $1) }) == 0 else { throw Failure("socket_unavailable") }
            bound = true
            guard chmod(self.path.path, 0o600) == 0, listen(listener, 4) == 0,
                  fcntl(listener, F_SETFL, O_NONBLOCK) == 0 else { throw Failure("socket_unavailable") }
            var info = stat()
            guard lstat(self.path.path, &info) == 0 else { throw Failure("socket_unavailable") }
            inode = info.st_ino
        } catch {
            Darwin.close(listener); if bound { unlink(self.path.path) }; throw error
        }
        let reader = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        reader.setEventHandler { [weak self] in
            guard let self else { return }
            while self.isActive {
                let client = accept(listener, nil, nil)
                guard client >= 0 else { break }
                self.serve(client)
            }
        }
        let socketPath = self.path.path, socketInode = inode
        reader.setCancelHandler {
            Darwin.close(listener)
            var info = stat()
            if lstat(socketPath, &info) == 0, info.st_ino == socketInode, info.st_mode & S_IFMT == S_IFSOCK { unlink(socketPath) }
        }
        source = reader; reader.resume()
    }
    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func stop() {
        lock.lock(); active = false; let reader = source; source = nil; lock.unlock()
        reader?.cancel()
    }
    deinit { stop() }
    private func serve(_ descriptor: Int32) {
        defer { Darwin.close(descriptor) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        // Darwin accepts inherit the listener's nonblocking flag. Each worker
        // uses bounded blocking I/O so a just-connected client can finish writing.
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else { return }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0, uid == geteuid() else { return }
        let response: Data
        do {
            var request = Data(), complete = false
            var bytes = [UInt8](repeating: 0, count: 8192)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while !complete {
                try Self.setDeadline(deadline, option: SO_RCVTIMEO, descriptor: descriptor)
                let count = recv(descriptor, &bytes, bytes.count, 0)
                guard count > 0 else { throw Failure("incomplete_request") }
                if let newline = bytes[..<count].firstIndex(of: 10) {
                    request.append(contentsOf: bytes[..<newline]); complete = true
                } else { request.append(contentsOf: bytes[..<count]) }
                guard request.count <= 65_536 else { throw Failure("request_too_large") }
            }
            let pending = Pending(timeout: dispatchTimeout)
            let packet = request
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                pending.run { guard let self, self.isActive else { return .failure("unavailable") }; return self.handler(packet) }
            }
            _ = pending.ready.wait(timeout: .now() + dispatchTimeout)
            response = try pending.finish().encoded()
        } catch {
            let code = (error as? Failure)?.code ?? "request_failed"
            response = (try? AgentReply.failure(code).encoded()) ?? Data()
        }
        try? write(response, to: descriptor)
    }
    private func write(_ data: Data, to descriptor: Int32) throws {
        let payload = data + Data([10])
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try Self.setDeadline(deadline, option: SO_SNDTIMEO, descriptor: descriptor)
                let count = send(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                guard count > 0 else { throw Failure("connection_closed") }; offset += count
            }
        }
    }
    private static func setDeadline(_ deadline: TimeInterval, option: Int32, descriptor: Int32) throws {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw Failure("connection_timeout") }
        let microseconds = max(1, min(999_999, Int((remaining.truncatingRemainder(dividingBy: 1) * 1_000_000).rounded(.up))))
        var timeout = timeval(tv_sec: Int(remaining), tv_usec: Int32(microseconds))
        guard setsockopt(descriptor, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.stride)) == 0 else { throw Failure("connection_timeout") }
    }
    private static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un(); value.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw Failure("path_too_long") }
        withUnsafeMutableBytes(of: &value.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return value
    }
    private static func withAddress<T>(_ address: inout sockaddr_un, _ operation: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { operation($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
}
