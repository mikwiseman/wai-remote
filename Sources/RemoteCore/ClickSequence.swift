import Foundation

/// The viewer counts clicks where the user clicked: network delay can bunch
/// separate clicks or stretch a double-click. Older viewers send no count;
/// the host then groups in host points and host monotonic time.
public struct ClickSequence {
    private var previous: (x: Double, y: Double, button: Int, time: Double, count: Int)?
    public init() {}
    public mutating func down(x: Double, y: Double, button: Int, now: Double, interval: Double,
                              radius: Double = 4, reported: Int? = nil) -> Int {
        var count = 1
        if let reported { count = min(max(reported, 1), 3) }
        else if let p = previous, p.button == button, now >= p.time, now - p.time <= interval,
           hypot(x - p.x, y - p.y) <= radius { count = min(p.count + 1, 3) }
        previous = (x, y, button, now, count)
        return count
    }
    public mutating func reset() { previous = nil }
}
