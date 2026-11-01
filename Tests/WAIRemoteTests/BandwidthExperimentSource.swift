import Accelerate
import CoreVideo
import Foundation
import WebRTC
@testable import WAIRemote

/// Test-only source. Two immutable scenes; two bulk plane copies, a bar and a stamp per frame.
final class BudgetSceneSource {
    struct Frame { let pixels: CVPixelBuffer; let allocationMs: Double; let copyMs: Double; let overlayMs: Double }
    enum Failure: Error { case allocation(Int32), geometry }
    private struct Scene { let y: [UInt8]; let uv: [UInt8] }
    private let desktop: SyntheticDesktop
    private let pool: CVPixelBufferPool
    private let yStride: Int, uvStride: Int
    private let scenes: [Scene]
    private static let allocationLimit = [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary
    init(_ desktop: SyntheticDesktop) throws {
        self.desktop = desktop
        guard let pool = SyntheticDesktop.pool() else { throw Failure.allocation(kCVReturnError) }
        self.pool = pool
        var sample: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, Self.allocationLimit, &sample)
        guard status == kCVReturnSuccess, let sample else { throw Failure.allocation(status) }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(sample, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(sample, 1)
        self.yStride = yStride; self.uvStride = uvStride
        scenes = (0..<2).map { window in
            var y = [UInt8](repeating: 16, count: yStride * 2160)
            var uv = [UInt8](repeating: 128, count: uvStride * 1080)
            var state = SyntheticDesktop.State(); state.window = window; state.typed = 64
            y.withUnsafeMutableBufferPointer { yp in uv.withUnsafeMutableBufferPointer { uvp in
                desktop.draw(state, index: 0, y: yp.baseAddress!, yStride: yStride, uv: uvp.baseAddress!, uvStride: uvStride)
            } }
            return Scene(y: y, uv: uv)
        }
    }
    func frame(_ index: Int, legacy: Bool = false) throws -> Frame {
        let begin = ProcessInfo.processInfo.systemUptime
        var pixel: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, Self.allocationLimit, &pixel)
        guard status == kCVReturnSuccess, let pixel else { throw Failure.allocation(status) }
        let allocated = ProcessInfo.processInfo.systemUptime
        guard CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) == yStride,
              CVPixelBufferGetBytesPerRowOfPlane(pixel, 1) == uvStride else { throw Failure.geometry }
        CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixel, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixel, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
        let uv = CVPixelBufferGetBaseAddressOfPlane(pixel, 1)!.assumingMemoryBound(to: UInt8.self)
        let scene = scenes[(index / 300) % 2]
        if legacy {
            var state = SyntheticDesktop.State(); state.window = (index / 300) % 2
            state.offsets = [(index * 4) % 1400, (index * 4) % 1400]; state.typed = (index / 8) % 90
            desktop.draw(state, index: index, y: y, yStride: yStride, uv: uv, uvStride: uvStride)
        } else {
            scene.y.withUnsafeBytes { memcpy(y, $0.baseAddress!, $0.count) }
            scene.uv.withUnsafeBytes { memcpy(uv, $0.baseAddress!, $0.count) }
        }
        let copied = ProcessInfo.processInfo.systemUptime
        if !legacy {
            // Motion is outside the fixed text ROI; this is not a scrolling workload.
            let x = (index * 20) % (3840 - 192)
            for row in 2024..<2040 { memset(y + row * yStride + x, 16, 192) }
            for row in 1012..<1020 { memset(uv + row * uvStride + x, 128, 192) }
            SyntheticDesktop.stamp(index, y: y, yStride: yStride, uv: uv, uvStride: uvStride)
        }
        let complete = ProcessInfo.processInfo.systemUptime
        return Frame(pixels: pixel, allocationMs: (allocated - begin) * 1000,
                     copyMs: (copied - allocated) * 1000, overlayMs: (complete - copied) * 1000)
    }
    func profile() throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for legacy in [true, false] {
            for index in 0..<120 {
                try autoreleasepool {
                    let frame = try self.frame(index * 5, legacy: legacy)
                    rows.append(["mode": legacy ? "legacy-row-draw" : "template-copy", "index": index * 5,
                                 "allocationMs": frame.allocationMs, "copyOrDrawMs": frame.copyMs, "overlayMs": frame.overlayMs])
                }
            }
        }
        return rows
    }
}

/// Experiment pacer: prepare before waiting, then rebase the next deadline on actual submission.
/// Pixel indices count emissions; missed 60Hz slots are reported separately.
final class BudgetFeeder {
    enum Clock: String { case threadSleep, strictTimer }
    private let source: BudgetSceneSource
    private let clock: Clock
    private let start: Double, end: Double, interval: Double
    private let stampOffset: Int
    private var nextDeadline: Double
    private let emit: (BudgetSceneSource.Frame, Int, Double) -> Double
    private let record: (String, [String: Any], Double) -> Void
    private let completed: () -> Void
    private let queue = DispatchQueue(label: "wai.budget-source", qos: .userInteractive)
    private let lock = NSLock()
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var index = 0, totalMissed = 0
    private var lastPush: Double?
    init(source: BudgetSceneSource, clock: Clock, start: Double, duration: Double, fps: Double = 60, stampOffset: Int = 0,
         emit: @escaping (BudgetSceneSource.Frame, Int, Double) -> Double,
         record: @escaping (String, [String: Any], Double) -> Void, completed: @escaping () -> Void) {
        self.source = source; self.clock = clock; self.start = start; end = start + duration
        interval = 1 / fps; self.stampOffset = stampOffset; nextDeadline = start
        self.emit = emit; self.record = record; self.completed = completed
    }
    func startFeeding() {
        if clock == .threadSleep {
            let thread = Thread { [self] in
                while !isStopped {
                    guard let pending = prepare() else { break }
                    let wait = max(0, pending.deadline - ProcessInfo.processInfo.systemUptime)
                    let before = ProcessInfo.processInfo.systemUptime
                    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                    if !submit(pending, before: before, requestedWait: wait) { break }
                }
                finish()
            }
            thread.qualityOfService = .userInteractive; thread.start()
        } else {
            queue.async { [self] in
                let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
                self.timer = timer; timer.activate(); scheduleNext()
            }
        }
    }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    private struct Pending { let frame: BudgetSceneSource.Frame?; let generationMs: Double; let deadline: Double }
    private func prepare() -> Pending? {
        guard !isStopped, ProcessInfo.processInfo.systemUptime < end else { return nil }
        let deadline = nextDeadline
        guard deadline < end else { return nil }
        let begin = ProcessInfo.processInfo.systemUptime
        do {
            let frame = try source.frame(index + stampOffset)
            return Pending(frame: frame, generationMs: (ProcessInfo.processInfo.systemUptime - begin) * 1000, deadline: deadline)
        } catch BudgetSceneSource.Failure.allocation(let code) {
            record("source-allocation-failed", ["index": index + stampOffset, "status": code], begin)
        } catch { record("source-geometry-failed", ["index": index + stampOffset], begin) }
        // Skip this planned attempt; retry only at the next paced deadline, never spin.
        return Pending(frame: nil, generationMs: (ProcessInfo.processInfo.systemUptime - begin) * 1000, deadline: deadline)
    }
    private func scheduleNext() {
        guard let pending = prepare() else { finish(); return }
        arm(pending)
    }
    private func arm(_ pending: Pending) {
        let before = ProcessInfo.processInfo.systemUptime
        let wait = max(0, pending.deadline - before)
        timer?.setEventHandler { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            // Even an early/spurious callback cannot bunch submissions.
            if now < pending.deadline { arm(pending); return }
            if submit(pending, before: before, requestedWait: wait) { scheduleNext() }
            else { finish() }
        }
        timer?.schedule(deadline: .now() + wait, leeway: .nanoseconds(0))
    }
    private func submit(_ pending: Pending, before: Double, requestedWait: Double) -> Bool {
        let woke = ProcessInfo.processInfo.systemUptime
        guard !isStopped, woke < end else { return false }
        let gap = lastPush.map { woke - $0 }
        // A platform wake before the deadline is discarded; never replay another planned slot.
        guard gap == nil || gap! >= interval / 2 else { return false }
        guard let frame = pending.frame else {
            nextDeadline = woke + interval
            record("source-skipped", ["index": index + stampOffset, "reason": "generation-unavailable"], woke)
            return true
        }
        let pushedAt = autoreleasepool { emit(frame, index + stampOffset, woke) }
        let returned = ProcessInfo.processInfo.systemUptime
        let missed = max(0, Int(floor((pushedAt - start) / interval)) - index)
        let newlyMissed = max(0, missed - totalMissed); totalMissed = missed
        record("source", ["index": index + stampOffset, "plannedMissedSlots": newlyMissed,
                          "requestedSleepMs": requestedWait * 1000, "actualSleepMs": (woke - before) * 1000,
                          "wakeLateMs": max(0, woke - pending.deadline) * 1000,
                          "allocationMs": frame.allocationMs, "copyMs": frame.copyMs,
                          "overlayMs": frame.overlayMs, "generationMs": pending.generationMs,
                          "pushMs": (returned - pushedAt) * 1000,
                          "scheduleLateMs": max(0, pushedAt - pending.deadline) * 1000], pushedAt)
        lastPush = pushedAt; nextDeadline = pushedAt + interval; index += 1
        return true
    }
    private func finish() {
        timer?.setEventHandler {}; timer?.cancel(); timer = nil
        record("source-finished", ["emitted": index, "plannedMissedSlots": max(0, Int(((end - start) / interval).rounded()) - index)], ProcessInfo.processInfo.systemUptime)
        completed()
    }
}

/// Retains only the last decoded frame of each phase. PNG and detail work runs after media stops.
final class BudgetSamples {
    private struct Sample { let frame: RTCVideoFrame; let index: Int; let time: Double }
    private let lock = NSLock()
    private var phase: String
    private var phases: Set<String>
    private var samples: [String: Sample] = [:]
    init(phase: String) { self.phase = phase; self.phases = [phase] }
    func setPhase(_ phase: String) { lock.lock(); self.phase = phase; phases.insert(phase); lock.unlock() }
    func capture(_ frame: RTCVideoFrame, index: Int) {
        lock.lock(); samples[phase] = Sample(frame: frame, index: index, time: ProcessInfo.processInfo.systemUptime); lock.unlock()
    }
    func write(source: BudgetSceneSource, directory: URL, prefix: String, start: Double) throws -> [[String: Any]] {
        lock.lock(); let captured = samples, phases = self.phases; lock.unlock()
        var results: [[String: Any]] = []
        for phase in phases.sorted() {
            guard let sample = captured[phase] else {
                results.append(["phase": phase, "missing": "No decoded frame in this phase"]); continue
            }
            let decodedPNG = try AgentFrameCapture.Captured(frame: sample.frame, generation: 0, sequence: 0, receivedAt: sample.time).png()
            try decodedPNG.data.write(to: directory.appendingPathComponent(prefix + "-" + phase + "-decoded.png"))
            guard sample.index >= 0 else {
                results.append(["phase": phase, "index": sample.index, "decodedAtSeconds": sample.time - start,
                                "missing": "Latest decoded frame has an unreadable stamp; reference/detail metric unavailable"])
                continue
            }
            let reference = try source.frame(sample.index)
            let refFrame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: reference.pixels), rotation: ._0, timeStampNs: 0)
            let referencePNG = try AgentFrameCapture.Captured(frame: refFrame, generation: 0, sequence: UInt64(sample.index), receivedAt: sample.time).png()
            try referencePNG.data.write(to: directory.appendingPathComponent(prefix + "-" + phase + "-reference.png"))
            let original = SyntheticDesktop.luma(of: refFrame.buffer)
            let decoded = SyntheticDesktop.luma(of: sample.frame.buffer)
            let width = Int(sample.frame.width), height = Int(sample.frame.height)
            guard decoded.pixels.count == width * height else { throw BudgetSceneSource.Failure.geometry }
            var scaled = [UInt8](repeating: 0, count: 3840 * 2160)
            let scalingError = decoded.pixels.withUnsafeBytes { input in scaled.withUnsafeMutableBytes { output -> vImage_Error in
                var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: input.baseAddress!), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var output = vImage_Buffer(data: output.baseAddress!, height: 2160, width: 3840, rowBytes: 3840)
                return vImageScale_Planar8(&input, &output, nil, vImage_Flags(kvImageHighQualityResampling))
            } }
            guard scalingError == kvImageNoError else { throw BudgetSceneSource.Failure.geometry }
            // Fixed text-bearing region at the same 4K presentation scale for all policies.
            let x = 760, top = 350, roiWidth = 2000, roiHeight = 1000
            var refROI: [UInt8] = [], decROI: [UInt8] = []
            refROI.reserveCapacity(roiWidth * roiHeight); decROI.reserveCapacity(roiWidth * roiHeight)
            var edgeError = 0.0, edgeCount = 0
            for row in top..<(top + roiHeight) {
                let offset = row * 3840 + x
                refROI.append(contentsOf: original.pixels[offset..<(offset + roiWidth)])
                decROI.append(contentsOf: scaled[offset..<(offset + roiWidth)])
                for column in 1..<(roiWidth - 1) {
                    let index = offset + column
                    let gradient = abs(Int(original.pixels[index - 1]) - Int(original.pixels[index + 1]))
                        + abs(Int(original.pixels[index - 3840]) - Int(original.pixels[index + 3840]))
                    if gradient >= 30 {
                        let expected = decoded.fullRange ? (Double(original.pixels[index]) - 16) * 255 / 219 : Double(original.pixels[index])
                        edgeError += abs(expected - Double(scaled[index])); edgeCount += 1
                    }
                }
            }
            results.append(["phase": phase, "index": sample.index, "decodedAtSeconds": sample.time - start, "width": width, "height": height,
                            "roi": [x, top, roiWidth, roiHeight], "textROIPsnr": SyntheticDesktop.psnr(reference: refROI, decoded: decROI, decodedFullRange: decoded.fullRange) ?? -1,
                            "textEdgeMeanAbsoluteError": edgeCount > 0 ? edgeError / Double(edgeCount) : -1, "textEdgePixels": edgeCount,
                            "method": "Decoded luma upsampled to 3840x2160 with vImage high-quality resampling; range-correct text-ROI PSNR and reference-edge MAE. Detail metrics, not OCR or human readability acceptance."])
        }
        return results
    }
}
