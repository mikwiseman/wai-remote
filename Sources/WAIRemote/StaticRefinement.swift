import CoreVideo
import Foundation

/// ScreenCaptureKit is silent while the screen is static, and WebRTC's own
/// repeat mode cannot be enabled from the ObjC source, so a frame compressed
/// hard on a starved link would never sharpen, and a frame the encoder dropped
/// would never arrive. Re-send the last frame briefly after each change, like
/// Chrome Remote Desktop's top-off, then go idle and release the capture surface.
final class StaticRefinement {
    static let interval = 1.0 / 12, window = 2.5
    private let queue: DispatchQueue
    private let interval: Double, window: Double
    private let send: (CVPixelBuffer, Double) -> Void
    private let clock: () -> Double
    private let timer: DispatchSourceTimer
    private var last: CVPixelBuffer?
    private var changed = 0.0

    /// `send` runs on `queue` with uptime seconds, for new and repeated frames alike.
    init(queue: DispatchQueue, interval: Double = StaticRefinement.interval, window: Double = StaticRefinement.window,
         clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         send: @escaping (CVPixelBuffer, Double) -> Void) {
        self.queue = queue; self.interval = interval; self.window = window; self.clock = clock; self.send = send
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.repeatLast() }
        timer.schedule(deadline: .distantFuture)
        timer.activate()
    }
    deinit { timer.cancel() }

    /// On `queue`: sends a changed frame and restarts refinement from it.
    func frame(_ buffer: CVPixelBuffer, at time: Double) {
        dispatchPrecondition(condition: .onQueue(queue))
        send(buffer, time)
        // One retained surface out of ScreenCaptureKit's pool of eight.
        last = buffer; changed = clock()
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(5))
    }
    /// On `queue`.
    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        last = nil; timer.schedule(deadline: .distantFuture)
    }
    /// On `queue`: one timer tick.
    func repeatLast() {
        let now = clock()
        guard let last, now - changed < window else { stop(); return }
        send(last, now)
    }
}
