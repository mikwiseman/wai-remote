import Foundation

/// Clicks are grouped in host screen points and host monotonic time.
public struct ClickSequence {
    private var previous: (x: Double, y: Double, button: Int, time: Double, count: Int)?
    public init() {}
    public mutating func down(x: Double, y: Double, button: Int, now: Double, interval: Double) -> Int {
        var count = 1
        if let p = previous, p.button == button, now >= p.time, now - p.time <= interval,
           hypot(x - p.x, y - p.y) <= 4 { count = min(p.count + 1, 3) }
        previous = (x, y, button, now, count)
        return count
    }
    public mutating func reset() { previous = nil }
}
