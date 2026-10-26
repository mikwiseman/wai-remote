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
        let codec = try Codec(kbps: 150, fps: 30)
        defer { codec.release() }
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
            let output = try XCTUnwrap(codec.encode(buffer, frame: frame, key: frame == 0))
            XCTAssertEqual(output.decoded.flatMap { SyntheticDesktop.index(in: $0.buffer) }, index, "QP \(output.qp)")
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
            let frame = try XCTUnwrap(run(desktop, kbps: kbps, fps: 30, frames: [(page, 0)]).first)
            keyframes.append(["mbps": Bench.round(Double(kbps) / 1000), "bytes": frame.bytes, "qp": frame.qp, "psnr": Bench.round(frame.psnr)])
        }
        // One second of scrolling at 600 px/s, then three static seconds: silent
        // like ScreenCaptureKit today, or the final frame repeated at 30 fps.
        let scroll = [(page, 0)] + (1...30).map { (scrolled($0 * 20), $0) }
        for kbps in rates {
            for repeats in [false, true] {
                let frames = try run(desktop, kbps: kbps, fps: 30, frames: scroll + (repeats ? Array(repeating: scroll[30], count: 90) : []))
                XCTAssertEqual(frames.compactMap(\.psnr).count, frames.count)
                let sharp = frames.indices.dropFirst(30).first { (frames[$0].psnr ?? 0) >= 35 }
                scrolls.append(["mbps": Bench.round(Double(kbps) / 1000), "repeats": repeats, "keyBytes": frames[0].bytes, "keyQP": frames[0].qp,
                    "qp": frames.map(\.qp), "psnrScroll": Bench.round(Bench.mean(frames[1...30].compactMap(\.psnr))),
                    "psnrFinal": Bench.round(frames.last?.psnr), "sharpMs": Bench.round(sharp.map { Double($0 - 30) * 1000 / 30 }),
                    "scrollMbps": Bench.round(Double(frames[1...30].map(\.bytes).reduce(0, +)) * 8 / 1e6),
                    "staticMbps": Bench.round(Double(frames.dropFirst(31).map(\.bytes).reduce(0, +)) * 8 / 3e6)])
            }
        }
        // ScreenQualityController's premise: less cadence buys detail at a constrained rate.
        var cadencePSNR: [Double] = []
        for fps in [30, 10] {
            let frames = try run(desktop, kbps: 1000, fps: fps, frames: (0..<(fps * 4)).map { (scrolled($0 * 120 / fps), $0) })
            XCTAssertEqual(frames.compactMap(\.psnr).count, frames.count)
            cadencePSNR.append(Bench.mean(frames.compactMap(\.psnr)) ?? 0)
            cadence.append(["fps": fps, "mbps": 1, "psnr": Bench.round(cadencePSNR.last),
                            "qpMedian": Bench.percentile(frames.map { Double($0.qp) }, 0.5) ?? -1,
                            "actualMbps": Bench.round(Double(frames.map(\.bytes).reduce(0, +)) * 8 / 4e6)])
        }
        print("QUALITY_BENCH " + Bench.json(["width": SyntheticDesktop.width, "height": SyntheticDesktop.height,
                                             "keyframe": keyframes, "scrollStatic": scrolls, "cadence": cadence]))
        XCTAssertGreaterThan(cadencePSNR[1], cadencePSNR[0])
    }

    /// Encodes in real time, because RTCVideoEncoderH264 adjusts its bitrate on
    /// the wall clock. PSNR runs on another queue so it cannot slow the cadence.
    private func run(_ desktop: SyntheticDesktop, kbps: UInt32, fps: Int,
                     frames: [(state: SyntheticDesktop.State, index: Int)]) throws -> [(bytes: Int, qp: Int, psnr: Double?)] {
        let codec = try Codec(kbps: kbps, fps: fps)
        defer { codec.release() }
        let pool = try XCTUnwrap(SyntheticDesktop.pool())
        let queue = DispatchQueue(label: "psnr", qos: .utility)
        let lock = NSLock()
        var results: [(bytes: Int, qp: Int, psnr: Double?)] = []
        var reference: (index: Int, pixels: [UInt8])?
        var buffer: CVPixelBuffer?
        let start = ProcessInfo.processInfo.systemUptime
        for (number, frame) in frames.enumerated() {
            let wait = start + Double(number) / Double(fps) - ProcessInfo.processInfo.systemUptime
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            if number == 0 || frame.index != frames[number - 1].index { buffer = desktop.frame(frame.state, index: frame.index, pool: pool) }
            let output = try XCTUnwrap(codec.encode(try XCTUnwrap(buffer), frame: number, key: number == 0))
            lock.lock(); results.append((output.bytes, output.qp, nil)); lock.unlock()
            guard let decoded = output.decoded else { continue }
            let luma = SyntheticDesktop.luma(of: decoded.buffer)
            queue.async {
                if reference?.index != frame.index { reference = (frame.index, desktop.luma(frame.state, index: frame.index)) }
                let psnr = SyntheticDesktop.psnr(reference: reference!.pixels, decoded: luma.pixels, decodedFullRange: luma.fullRange)
                lock.lock(); results[number].psnr = psnr; lock.unlock()
            }
        }
        queue.sync {}
        return results
    }
}

/// Synchronous encode and decode through the app's own codec factories.
final class Codec {
    struct Output { let bytes: Int; let qp: Int; let key: Bool; let decoded: RTCVideoFrame? }
    private let encoder: RTCVideoEncoder
    private let decoder: RTCVideoDecoder
    private let encodedSignal = DispatchSemaphore(value: 0), decodedSignal = DispatchSemaphore(value: 0)
    private var encoded: (bytes: Int, qp: Int, key: Bool)?
    private var decoded: RTCVideoFrame?
    let fps: Int
    init(kbps: UInt32, fps: Int) throws {
        self.fps = fps
        let factory = ScreenVideoEncoderFactory()
        let codec = try XCTUnwrap(factory.supportedCodecs().first { $0.name == "H264" })
        encoder = try XCTUnwrap(factory.createEncoder(codec))
        decoder = try XCTUnwrap(ScreenVideoDecoderFactory().createDecoder(codec))
        let settings = RTCVideoEncoderSettings()
        settings.name = "H264"; settings.width = UInt16(SyntheticDesktop.width); settings.height = UInt16(SyntheticDesktop.height)
        settings.startBitrate = kbps; settings.maxBitrate = 32000; settings.maxFramerate = UInt32(fps); settings.mode = .screensharing
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 8), 0)
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 8), 0)
        _ = encoder.setBitrate(kbps, framerate: UInt32(fps))
        decoder.setCallback { [unowned self] frame in decoded = frame; decodedSignal.signal() }
        encoder.setCallback { [unowned self] image, info in
            encoded = (image.buffer.count, image.qp.intValue, image.frameType == .videoFrameKey)
            encodedSignal.signal()
            _ = decoder.decode(image, missingFrames: false, codecSpecificInfo: info, renderTimeMs: 0)
            return true
        }
    }
    func encode(_ buffer: CVPixelBuffer, frame index: Int, key: Bool) -> Output? {
        encoded = nil; decoded = nil
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0,
                                  timeStampNs: Int64(index) * 1_000_000_000 / Int64(fps))
        frame.timeStamp = Int32(truncatingIfNeeded: index * 90000 / fps)
        guard encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: key ? 3 : 4)]) == 0,
              encodedSignal.wait(timeout: .now() + 3) == .success, let encoded else { return nil }
        let complete = decodedSignal.wait(timeout: .now() + 3) == .success
        return Output(bytes: encoded.bytes, qp: encoded.qp, key: encoded.key, decoded: complete ? decoded : nil)
    }
    func release() { _ = encoder.release(); _ = decoder.release() }
}
