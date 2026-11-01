import Foundation
import RemoteCore

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
    private final class PendingScroll {
        var message: WireMessage
        let operation: (WireMessage, @escaping () -> Bool) -> Void
        init(_ message: WireMessage, _ operation: @escaping (WireMessage, @escaping () -> Bool) -> Void) {
            self.message = message; self.operation = operation
        }
    }
    private var pendingScroll: PendingScroll?

    func submit(coalescingPointerMove: Bool = false, _ operation: @escaping (@escaping () -> Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        pendingScroll = nil
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

    func submitScroll(_ message: WireMessage, _ operation: @escaping (WireMessage, @escaping () -> Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        pendingMove = nil
        if let pendingScroll, Self.canMerge(pendingScroll.message, message) {
            pendingScroll.message.deltaX = (pendingScroll.message.deltaX ?? 0) + (message.deltaX ?? 0)
            pendingScroll.message.deltaY = (pendingScroll.message.deltaY ?? 0) + (message.deltaY ?? 0)
            return
        }
        let pending = PendingScroll(message, operation), token = generation
        pendingScroll = pending
        let current = { [self] in
            lock.lock(); defer { lock.unlock() }; return generation == token
        }
        queue.async { [self] in
            lock.lock()
            if pendingScroll === pending { pendingScroll = nil }
            let message = pending.message
            lock.unlock()
            if current() { pending.operation(message, current) }
        }
    }
    private static func canMerge(_ a: WireMessage, _ b: WireMessage) -> Bool {
        // Boundaries and legacy wheel packets have no shared gesture contract.
        guard a.scrollPhase == "changed" || a.momentumPhase == "changed",
              a.scrollPhase == b.scrollPhase, a.momentumPhase == b.momentumPhase,
              a.sessionID == b.sessionID, a.controllerEpoch == b.controllerEpoch, a.inputEpoch == b.inputEpoch,
              a.modeGeneration == b.modeGeneration, a.surfaceID == b.surfaceID, a.geometryRevision == b.geometryRevision,
              a.x == b.x, a.y == b.y, (a.modifiers ?? []) == (b.modifiers ?? []) else { return false }
        func sameDirection(_ first: Double, _ second: Double) -> Bool {
            (first == 0 || second == 0 || first.sign == second.sign) &&
                abs(first + second) < Double(Int32.max)
        }
        return sameDirection(a.deltaX ?? 0, b.deltaX ?? 0) && sameDirection(a.deltaY ?? 0, b.deltaY ?? 0)
    }

    /// Lifting held input is ordinary ordered work. Input accepted before it,
    /// such as keys and text behind a slow background click, still arrives first.
    func lift(release: @escaping () -> Void) { submit { _ in release() } }

    /// A disconnect or a new target discards everything not yet delivered.
    func cancel(release: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; pendingMove = nil; pendingScroll = nil
        queue.async(execute: release)
    }
}
