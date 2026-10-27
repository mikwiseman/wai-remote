import Foundation

/// AX requests may synchronously call into AppKit. Keep them off its main loop,
/// preserve input order, and invalidate both queued and in-flight lookups on release.
final class InputDeliveryQueue {
    private let queue = DispatchQueue(label: "is.wai.remote.input", qos: .userInteractive)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private final class PendingMove {
        var operation: (@escaping () -> Bool) -> Void
        init(_ operation: @escaping (@escaping () -> Bool) -> Void) { self.operation = operation }
    }
    private var pendingMove: PendingMove?

    func submit(coalescingPointerMove: Bool = false, _ operation: @escaping (@escaping () -> Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if coalescingPointerMove, let pendingMove { pendingMove.operation = operation; return }
        let token = generation
        let pending = PendingMove(operation)
        // Clicks, releases, keys and scrolls are barriers. Only consecutive,
        // not-yet-started pointer positions may replace one another.
        pendingMove = coalescingPointerMove ? pending : nil
        let current = { [self] in
            lock.lock(); defer { lock.unlock() }; return generation == token
        }
        queue.async { [self] in
            lock.lock()
            if pendingMove === pending { pendingMove = nil }
            let operation = pending.operation
            lock.unlock()
            if current() { operation(current) }
        }
    }

    /// Lifting held input is ordinary ordered work. Input accepted before it,
    /// such as keys and text behind a slow background click, still arrives first.
    func lift(release: @escaping () -> Void) { submit { _ in release() } }

    /// A disconnect or a new target discards everything not yet delivered.
    func cancel(release: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; pendingMove = nil
        queue.async(execute: release)
    }
}
