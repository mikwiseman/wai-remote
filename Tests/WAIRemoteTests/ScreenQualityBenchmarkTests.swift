import CoreVideo
import WebRTC
import XCTest
@testable import WAIRemote

/// Generated pixels only. No desktop capture, network access or user input.
/// The opt-in benchmark measures coding quality, not optical latency:
/// WAI_QUALITY_BENCH=1 swift test --filter ScreenQualityBenchmarkTests
final class ScreenQualityBenchmarkTests: XCTestCase {
    func testPSNRComparesVideoRangeSourceWithFullRangeDecoderOutput() throws {
        let source = (0..<4096).map { UInt8(16 + $0 % 220) }
        let decoded = source.map { UInt8((Double($0) - 16) * 255 / 219 + 0.5) }
        XCTAssertGreaterThan(try XCTUnwrap(SyntheticDesktop.psnr(reference: source, decoded: decoded, decodedFullRange: true)), 50)
        XCTAssertLessThan(try XCTUnwrap(SyntheticDesktop.psnr(reference: source, decoded: decoded, decodedFullRange: false)), 35,
                          "Comparing the ranges directly is the bias this benchmark must not have.")
        XCTAssertEqual(SyntheticDesktop.psnr(reference: source, decoded: source, decodedFullRange: false), 99)
        XCTAssertNil(SyntheticDesktop.psnr(reference: source, decoded: Array(decoded.dropLast()), decodedFullRange: true))
    }

    func testFrameIndexSurvivesAStarvedHardwareEncoder() throws {
        let indices = [0, 1, 0x5A5A, 65535, 1234]
        let codec = try Codec(kbps: 150, fps: 30, stock: true)
        defer { codec.release() }
        var decoded: (index: Int?, qp: Int)?
        codec.encoded = { _, _, qp, _ in decoded = (nil, qp) }
        for (frame, index) in indices.enumerated() {
            let buffer = try XCTUnwrap(SyntheticDesktop.buffer())
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 0), 140, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * SyntheticDesktop.height)
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * SyntheticDesktop.height / 2)
            SyntheticDesktop.stamp(index, y: CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self),
                                   yStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                                   uv: CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self),
                                   uvStride: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertEqual(SyntheticDesktop.index(in: RTCCVPixelBuffer(pixelBuffer: buffer)), index)
            let done = expectation(description: "Frame \(frame) decoded")
            codec.decoded = { _, image in decoded?.index = SyntheticDesktop.index(in: image.buffer); done.fulfill() }
            XCTAssertTrue(codec.submit(buffer, number: frame, time: Double(frame) / 30, key: frame == 0))
            wait(for: [done], timeout: 3)
            XCTAssertEqual(decoded?.index, index, "QP \(decoded?.qp ?? -1)")
        }
    }

    func testTextQualityAt4K() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAI_QUALITY_BENCH"] == "1")
        let desktop = SyntheticDesktop()
        let rates: [UInt32] = [150, 1000, 3000, 8000]
        let page = SyntheticDesktop.State()
        func scrolled(_ offset: Int) -> SyntheticDesktop.State { var state = page; state.offsets[0] = offset / 2 * 2; return state }
        var keyframes: [[String: Any]] = [], scrolls: [[String: Any]] = [], cadence: [[String: Any]] = []
        for kbps in rates {
            let frame = try XCTUnwrap(run(desktop, kbps: kbps, fps: 30, frames: [(page, 0, 0)]).first)
            keyframes.append(["mbps": Bench.round(Double(kbps) / 1000), "bytes": frame.bytes, "qp": frame.qp, "psnr": Bench.round(frame.psnr)])
        }
        // One second of scrolling at 600 px/s at 30 fps, then the static screen:
        // silent like ScreenCaptureKit, or re-sent by StaticRefinement. PSNR is
        // what the viewer shows at each frame's time, so a dropped frame counts
        // as the previous picture.
        let scroll = [(page, 0, 0.0)] + (1...30).map { (scrolled($0 * 20), $0, Double($0) / 30) }
        let refine = Int(StaticRefinement.window / StaticRefinement.interval - 0.5)
        let repeats = (1...refine).map { (scrolled(600), 30, 1 + Double($0) * StaticRefinement.interval) }
        for kbps in rates {
            for refined in [false, true] {
                let frames = try run(desktop, kbps: kbps, fps: 30, frames: scroll + (refined ? repeats : []))
                let sharp = frames.indices.dropFirst(30).first { (frames[$0].psnr ?? 0) >= 35 }
                scrolls.append(["mbps": Bench.round(Double(kbps) / 1000), "repeats": refined, "keyBytes": frames[0].bytes, "keyQP": frames[0].qp,
                    "qp": frames.map(\.qp), "dropped": frames.filter { $0.bytes == 0 }.count,
                    "psnrScroll": Bench.round(Bench.mean(frames[1...30].compactMap(\.psnr))), "psnrFinal": Bench.round(frames.last?.psnr),
                    "sharpMs": Bench.round(sharp.map { $0 == 30 ? 0 : Double($0 - 30) * StaticRefinement.interval * 1000 }),
                    "scrollMbps": Bench.round(Double(frames[1...30].map(\.bytes).reduce(0, +)) * 8 / 1e6),
                    "staticMbps": Bench.round(Double(frames.dropFirst(31).map(\.bytes).reduce(0, +)) * 8 / StaticRefinement.window / 1e6)])
            }
        }
        // Whether fewer frames buy detail during continuous motion at a constrained rate.
        for fps in [30, 10] {
            let frames = try run(desktop, kbps: 1000, fps: fps, frames: (0..<(fps * 4)).map { (scrolled($0 * 120 / fps), $0, Double($0) / Double(fps)) })
            cadence.append(["fps": fps, "mbps": 1, "psnr": Bench.round(Bench.mean(frames.compactMap(\.psnr))),
                            "qpMedian": Bench.percentile(frames.filter { $0.bytes > 0 }.map { Double($0.qp) }, 0.5) ?? -1,
                            "dropped": frames.filter { $0.bytes == 0 }.count,
                            "actualMbps": Bench.round(Double(frames.map(\.bytes).reduce(0, +)) * 8 / 4e6)])
        }
        print("QUALITY_BENCH " + Bench.json(["width": SyntheticDesktop.width, "height": SyntheticDesktop.height,
                                             "keyframe": keyframes, "scrollStatic": scrolls, "cadence": cadence]))
    }

    /// Submits frames on the wall clock, as RTCVideoEncoderH264 and VideoToolbox's rate
    /// control expect, without waiting for output. Each source frame is scored by the
    /// picture the viewer would show at its time: its own decode, or the last earlier
    /// one when the encoder dropped it. PSNR runs on another queue to keep the cadence.
    private func run(_ desktop: SyntheticDesktop, kbps: UInt32, fps: Int, stock: Bool = false,
                     frames: [(state: SyntheticDesktop.State, index: Int, time: Double)]) throws -> [(bytes: Int, qp: Int, psnr: Double?)] {
        let codec = try Codec(kbps: kbps, fps: fps, stock: stock)
        defer { codec.release() }
        let pool = try XCTUnwrap(SyntheticDesktop.pool())
        let queue = DispatchQueue(label: "psnr", qos: .utility)
        let lock = NSLock()
        var results = Array(repeating: (bytes: 0, qp: -1, psnr: Double?.none), count: frames.count)
        var shown: (number: Int, luma: [UInt8], fullRange: Bool)?
        var reference: (index: Int, pixels: [UInt8])?
        func score(_ number: Int, _ luma: [UInt8], _ fullRange: Bool) {
            queue.async {
                let frame = frames[number]
                if reference?.index != frame.index { reference = (frame.index, desktop.luma(frame.state, index: frame.index)) }
                let psnr = SyntheticDesktop.psnr(reference: reference!.pixels, decoded: luma, decodedFullRange: fullRange)
                lock.lock(); results[number].psnr = psnr; lock.unlock()
            }
        }
        codec.encoded = { number, bytes, qp, _ in lock.lock(); results[number].bytes = bytes; results[number].qp = qp; lock.unlock() }
        codec.decoded = { number, image in
            let luma = SyntheticDesktop.luma(of: image.buffer)
            lock.lock(); let previous = shown; shown = (number, luma.pixels, luma.fullRange); lock.unlock()
            if let previous { for skipped in (previous.number + 1)..<max(previous.number + 1, number) { score(skipped, previous.luma, previous.fullRange) } }
            score(number, luma.pixels, luma.fullRange)
        }
        var buffer: CVPixelBuffer?
        let start = ProcessInfo.processInfo.systemUptime
        for (number, frame) in frames.enumerated() {
            let wait = start + frame.time - ProcessInfo.processInfo.systemUptime
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            if number == 0 || frame.index != frames[number - 1].index { buffer = desktop.frame(frame.state, index: frame.index, pool: pool) }
            XCTAssertTrue(codec.submit(try XCTUnwrap(buffer), number: number, time: frame.time, key: number == 0))
        }
        Thread.sleep(forTimeInterval: 0.5)
        lock.lock(); let last = shown; lock.unlock()
        if let last { for number in (last.number + 1)..<max(last.number + 1, frames.count) { score(number, last.luma, last.fullRange) } }
        queue.sync {}
        lock.lock(); defer { lock.unlock() }
        return results
    }
}

/// The app's codec factories, or WebRTC's stock encoder, with outputs matched to the
/// submitted frame by RTP timestamp. A frame the encoder drops has no output.
final class Codec {
    private let encoder: RTCVideoEncoder
    private let decoder: RTCVideoDecoder
    private let lock = NSLock()
    private var numbers: [UInt32: Int] = [:]
    var encoded: (_ number: Int, _ bytes: Int, _ qp: Int, _ key: Bool) -> Void = { _, _, _, _ in }
    var decoded: (_ number: Int, _ frame: RTCVideoFrame) -> Void = { _, _ in }
    init(kbps: UInt32, fps: Int, stock: Bool = false) throws {
        let factory = ScreenVideoEncoderFactory()
        let codec = try XCTUnwrap(factory.supportedCodecs().first { $0.name == "H264" })
        encoder = stock ? RTCVideoEncoderH264(codecInfo: codec) : try XCTUnwrap(factory.createEncoder(codec))
        decoder = try XCTUnwrap(ScreenVideoDecoderFactory().createDecoder(codec))
        let settings = RTCVideoEncoderSettings()
        settings.name = "H264"; settings.width = UInt16(SyntheticDesktop.width); settings.height = UInt16(SyntheticDesktop.height)
        settings.startBitrate = kbps; settings.maxBitrate = 32000; settings.maxFramerate = UInt32(fps); settings.mode = .screensharing
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 8), 0)
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 8), 0)
        _ = encoder.setBitrate(kbps, framerate: UInt32(fps))
        decoder.setCallback { [unowned self] frame in
            lock.lock(); let number = numbers[UInt32(bitPattern: frame.timeStamp)]; lock.unlock()
            if let number { decoded(number, frame) }
        }
        encoder.setCallback { [unowned self] image, info in
            lock.lock(); let number = numbers[image.timeStamp]; lock.unlock()
            if let number { encoded(number, image.buffer.count, image.qp.intValue, image.frameType == .videoFrameKey) }
            _ = decoder.decode(image, missingFrames: false, codecSpecificInfo: info, renderTimeMs: 0)
            return true
        }
    }
    func submit(_ buffer: CVPixelBuffer, number: Int, time: Double, key: Bool) -> Bool {
        let timestamp = UInt32(truncatingIfNeeded: Int((time * 90000).rounded()))
        lock.lock(); numbers[timestamp] = number; lock.unlock()
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: Int64((time * 1e9).rounded()))
        frame.timeStamp = Int32(bitPattern: timestamp)
        return encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: key ? 3 : 4)]) == 0
    }
    func release() { _ = encoder.release(); _ = decoder.release() }
}
