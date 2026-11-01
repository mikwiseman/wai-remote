import UIKit

/// One accumulated movement per display frame; lifecycle packets retain their order.
/// Coordinates enter in phone points and leave in the remote surface's logical points.
final class PhoneScrollStream {
    struct Output {
        var delta: CGPoint
        var scrollPhase: String?
        var momentumPhase: String?
    }
    private enum Phase { case idle, dragging, decelerating }
    private var phase = Phase.idle
    private var pending = CGPoint.zero
    private var position = CGPoint.zero
    private var scale = CGPoint(x: 1, y: 1)
    private var samples: [(time: TimeInterval, point: CGPoint)] = []
    private var velocity = CGPoint.zero
    private var endTime: TimeInterval?
    private var lastTick: TimeInterval = 0
    private var began = false
    private var momentumBegan = false
    private let canSend: () -> Bool
    private let emit: (Output) -> Void
    private let decay = -log(Double(UIScrollView.DecelerationRate.normal.rawValue)) * 1000
    var isActive: Bool { phase != .idle }

    init(canSend: @escaping () -> Bool = { true }, emit: @escaping (Output) -> Void) {
        self.canSend = canSend; self.emit = emit
    }
    func begin(at timestamp: TimeInterval, scale: CGPoint = CGPoint(x: 1, y: 1)) {
        cancel()
        guard timestamp.isFinite, scale.x.isFinite, scale.y.isFinite, scale.x > 0, scale.y > 0 else { return }
        self.scale = scale; phase = .dragging; position = .zero
        samples = [(timestamp, .zero)]
    }
    func move(by delta: CGPoint, at timestamp: TimeInterval) {
        guard phase == .dragging, endTime == nil, timestamp.isFinite,
              delta.x.isFinite, delta.y.isFinite, delta != .zero else { return }
        pending.x += delta.x * scale.x; pending.y += delta.y * scale.y
        position.x += delta.x; position.y += delta.y
        if let last = samples.last, timestamp <= last.time {
            if timestamp == last.time { samples[samples.count - 1].point = position }
            else { samples = [(timestamp, position)] }
        } else { samples.append((timestamp, position)) }
        while samples.count > 2 && (samples[1].time < timestamp - 0.08 || samples.count > 64) { samples.removeFirst() }
    }
    func end(at timestamp: TimeInterval) {
        guard phase == .dragging, endTime == nil, timestamp.isFinite else { return }
        endTime = timestamp; velocity = releaseVelocity(at: timestamp)
        tick(at: timestamp)
    }
    func cancel() {
        let terminal: Output? = phase == .dragging && began
            ? Output(delta: .zero, scrollPhase: "cancelled", momentumPhase: nil)
            : phase == .decelerating && momentumBegan
                ? Output(delta: .zero, scrollPhase: nil, momentumPhase: "ended") : nil
        phase = .idle; pending = .zero; velocity = .zero; samples = []
        endTime = nil; began = false; momentumBegan = false
        // One terminal packet may bypass congestion; stale movement never does.
        if let terminal { emit(terminal) }
    }
    func tick(at timestamp: TimeInterval) {
        guard timestamp.isFinite else { cancel(); return }
        switch phase {
        case .idle: return
        case .dragging:
            guard canSend() else { return }
            flush(momentum: false)
            guard phase == .dragging, let endTime, pending == .zero else { return }
            let hadBegan = began
            phase = hadBegan && timestamp - endTime <= 0.08 && hypot(velocity.x, velocity.y) >= 40 ? .decelerating : .idle
            lastTick = timestamp; samples = []; began = false
            if hadBegan { emit(Output(delta: .zero, scrollPhase: "ended", momentumPhase: nil)) }
        case .decelerating:
            let elapsed = timestamp - lastTick
            guard elapsed > 0 else { return }
            // A stalled display/channel must not replay a large or stale fling.
            guard elapsed <= 0.1, canSend() else { cancel(); return }
            lastTick = timestamp
            let speed = hypot(velocity.x, velocity.y)
            if speed > 5 {
                let duration = min(elapsed, log(Double(speed / 5)) / decay)
                let factor = exp(-decay * duration)
                pending.x += velocity.x * CGFloat((1 - factor) / decay) * scale.x
                pending.y += velocity.y * CGFloat((1 - factor) / decay) * scale.y
                velocity.x *= factor; velocity.y *= factor
                if duration < elapsed || hypot(velocity.x, velocity.y) <= 5.000001 { velocity = .zero }
            } else { velocity = .zero }
            flush(momentum: true)
            guard phase == .decelerating, velocity == .zero, pending == .zero else { return }
            let hadBegan = momentumBegan
            phase = .idle; momentumBegan = false
            if hadBegan { emit(Output(delta: .zero, scrollPhase: nil, momentumPhase: "ended")) }
        }
    }
    private func flush(momentum: Bool) {
        guard pending != .zero else { return }
        // PhoneModel's wire limit is 2000. Keep the rest for the next frame.
        let divisor = max(1, max(abs(pending.x), abs(pending.y)) / 2000)
        let delta = CGPoint(x: pending.x / divisor, y: pending.y / divisor)
        pending.x -= delta.x; pending.y -= delta.y
        if abs(pending.x) < 0.0000001 { pending.x = 0 }
        if abs(pending.y) < 0.0000001 { pending.y = 0 }
        let output = Output(delta: delta, scrollPhase: momentum ? nil : began ? "changed" : "began",
                            momentumPhase: momentum ? momentumBegan ? "changed" : "began" : nil)
        if momentum { momentumBegan = true } else { began = true }
        emit(output)
    }
    private func releaseVelocity(at timestamp: TimeInterval) -> CGPoint {
        guard let first = samples.first, let last = samples.last, samples.count > 1,
              timestamp >= last.time, timestamp - last.time <= 0.08, last.time - first.time >= 0.001 else { return .zero }
        let elapsed = last.time - first.time
        var result = CGPoint(x: (last.point.x - first.point.x) / elapsed, y: (last.point.y - first.point.y) / elapsed)
        let divisor = max(1, hypot(result.x, result.y) / 2500)
        result.x /= divisor; result.y /= divisor
        return result
    }
}
