import Foundation
import WebRTC

/// H264's hardware encoder trades detail for cadence when bandwidth falls.
/// Keep the desktop's pixels and reduce cadence only after measured damage.
/// Recovery is deliberately slower than reduction to avoid oscillating.
struct ScreenQualityController {
    private(set) var frameRate = 60
    private var poorSamples = 0
    private var clearSamples = 0
    private var previous: (id: String, frames: Double, qp: Double, time: Double)?

    mutating func sample(_ report: RTCStatisticsReport, now: Double) -> Int? {
        let stats = report.statistics
        guard let video = stats.values.first(where: {
            $0.type == "outbound-rtp" && $0.values["kind"] as? String == "video"
        }), let codecID = video.values["codecId"] as? String,
              stats[codecID]?.values["mimeType"] as? String == "video/H264",
              let frames = video.values["framesEncoded"] as? NSNumber,
              let qp = video.values["qpSum"] as? NSNumber else { return nil }
        let next = (id: video.id, frames: frames.doubleValue, qp: qp.doubleValue, time: now)
        defer { previous = next }
        guard let before = previous, before.id == next.id,
              next.frames > before.frames, next.qp >= before.qp,
              now > before.time, now - before.time < 3 else {
            poorSamples = 0; clearSamples = 0
            return nil
        }
        return observe(qp: (next.qp - before.qp) / (next.frames - before.frames),
                       framesPerSecond: (next.frames - before.frames) / (now - before.time))
    }

    mutating func observe(qp: Double, framesPerSecond: Double) -> Int? {
        guard qp.isFinite, (0...51).contains(qp), framesPerSecond.isFinite,
              framesPerSecond >= 5 else { poorSamples = 0; clearSamples = 0; return nil }
        poorSamples = qp >= 34 ? poorSamples + 1 : 0
        clearSamples = qp <= 28 ? clearSamples + 1 : 0
        let steps = [10, 15, 20, 30, 45, 60]
        var next = frameRate
        if poorSamples >= 2 || qp >= 42 {
            // A 30 Hz source must not spend two seconds stepping 60 -> 45 -> 30.
            let current = min(Double(frameRate), framesPerSecond)
            next = steps.last(where: { Double($0) <= current * 0.75 }) ?? 10
            next = min(frameRate, next)
        } else if clearSamples >= 8 {
            next = steps.first(where: { $0 > frameRate }) ?? 60
        }
        guard next != frameRate else { return nil }
        frameRate = next; poorSamples = 0; clearSamples = 0
        return next
    }
}
