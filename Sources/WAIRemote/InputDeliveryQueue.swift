import Foundation

/// AX requests may synchronously call into AppKit. Keep them off its main loop,
/// preserve input order, and invalidate both queued and in-flight lookups on release.
final class InputDeliveryQueue {
    private let queue = DispatchQueue(label: "is.wai.remote.input", qos: .userInteractive)
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func submit(_ operation: @escaping (@escaping () -> Bool) -> Void) {
        lock.lock(); let token = generation; lock.unlock()
        let current = { [self] in
            lock.lock(); defer { lock.unlock() }; return generation == token
        }
        queue.async { if current() { operation(current) } }
    }

    func cancel(release: @escaping () -> Void) {
        lock.lock(); generation &+= 1; lock.unlock()
        queue.async(execute: release)
    }
}
