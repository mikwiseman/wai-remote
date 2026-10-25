import AppKit
import CoreVideo
import WebRTC
import XCTest
@testable import WAIRemote

/// Opt-in hardware experiment with generated pixels only. No desktop capture,
/// network access or user input. Measures coding quality, not optical latency.
@MainActor
final class ScreenQualityBenchmarkTests: XCTestCase {
    private final class Measurements {
        let lock = NSLock()
        var expected: [UInt32: [UInt8]] = [:]
        var qp: [Double] = []
        var errors: [Double] = []
        var bytes = 0
        var keyFrames = 0
        func reference(_ timestamp: UInt32, _ pixels: [UInt8]) {
            lock.lock(); defer { lock.unlock() }; expected[timestamp] = pixels
        }
        func encoded(_ image: RTCEncodedImage) {
            lock.lock(); defer { lock.unlock() }
            qp.append(image.qp.doubleValue); bytes += image.buffer.count
            if image.frameType == .videoFrameKey { keyFrames += 1 }
        }
        func decoded(_ frame: RTCVideoFrame) {
            let actual = ScreenQualityBenchmarkTests.luma(frame.buffer)
            lock.lock(); defer { lock.unlock() }
            guard let reference = expected.removeValue(forKey: UInt32(bitPattern: frame.timeStamp)),
                  reference.count == actual.count else { return }
            let error = zip(reference, actual).reduce(0.0) { sum, pair in
                let delta = Double(pair.0) - Double(pair.1); return sum + delta * delta
            } / Double(actual.count)
            errors.append(error)
        }
        func result(fps: Int) -> [String: Double] {
            lock.lock(); defer { lock.unlock() }
            let sorted = qp.sorted()
            return ["fps": Double(fps), "encoded": Double(qp.count), "decoded": Double(errors.count),
                    "qpMedian": sorted.isEmpty ? 0 : sorted[sorted.count / 2],
                    "psnr": 10 * log10(255 * 255 / max(0.001, errors.reduce(0, +) / Double(max(1, errors.count)))),
                    "bytes": Double(bytes), "keyFrames": Double(keyFrames),
                    "finalPSNR": 10 * log10(255 * 255 / max(0.001, errors.suffix(10).reduce(0, +) / Double(max(1, min(10, errors.count)))))]
        }
    }

    nonisolated private static func luma(_ buffer: RTCVideoFrameBuffer) -> [UInt8] {
        let pixels = buffer.toI420()
        var result: [UInt8] = []
        for y in stride(from: 0, to: Int(pixels.height), by: 8) {
            for x in stride(from: 0, to: Int(pixels.width), by: 8) {
                result.append(pixels.dataY[y * Int(pixels.strideY) + x])
            }
        }
        return result
    }

    func testCongestedRetinaTextAtEqualBitrate() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAI_QUALITY_BENCH"] == "1")
        let width = 3200, height = 2000
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height + 400, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height + 400))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for row in 0..<70 {
            let line = "\(row)  let remoteDesktop = Screen(width: 3200, height: 2000)  // Retina text quality 0123456789"
            (line as NSString).draw(at: CGPoint(x: 60, y: row * 36), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .regular), .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        let page = try XCTUnwrap(context.makeImage())
        var results: [[String: Double]] = []
        for fps in [30, 10] {
            let factory = RTCDefaultVideoEncoderFactory()
            let codec = try XCTUnwrap(ScreenVideoPolicy.screenCodecs(factory.supportedCodecs()).first { $0.name == "H264" })
            let encoder = try XCTUnwrap(factory.createEncoder(codec))
            let decoder = try XCTUnwrap(RTCDefaultVideoDecoderFactory().createDecoder(codec))
            let measurements = Measurements()
            let settings = RTCVideoEncoderSettings()
            settings.name = "H264"; settings.width = UInt16(width); settings.height = UInt16(height)
            settings.startBitrate = 1000; settings.maxBitrate = 1000; settings.maxFramerate = UInt32(fps)
            settings.mode = .screensharing
            XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 4), 0)
            XCTAssertEqual(decoder.startDecode(withNumberOfCores: 4), 0)
            decoder.setCallback { measurements.decoded($0) }
            encoder.setCallback { image, info in
                measurements.encoded(image)
                _ = decoder.decode(image, missingFrames: false, codecSpecificInfo: info, renderTimeMs: 0)
                return true
            }
            let started = ProcessInfo.processInfo.systemUptime
            for index in 0..<(fps * 4) {
                let deadline = started + Double(index) / Double(fps)
                let wait = deadline - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                var pixel: CVPixelBuffer?
                XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
                let pixels = try XCTUnwrap(pixel)
                CVPixelBufferLockBaseAddress(pixels, [])
                let target = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue))
                let offset = -Double(index) * 80.0 / Double(fps)
                target.draw(page, in: CGRect(x: 0.0, y: offset, width: Double(width), height: Double(height + 400)))
                CVPixelBufferUnlockBaseAddress(pixels, [])
                // Match ScreenCaptureKit's real NV12 video-range input. Feeding
                // BGRA directly uses a different VideoToolbox color conversion.
                let planar = RTCCVPixelBuffer(pixelBuffer: pixels).toI420()
                var nv12: CVPixelBuffer?
                XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &nv12), kCVReturnSuccess)
                let native = try XCTUnwrap(nv12)
                CVPixelBufferLockBaseAddress(native, [])
                let yBase = CVPixelBufferGetBaseAddressOfPlane(native, 0)!.assumingMemoryBound(to: UInt8.self)
                let uvBase = CVPixelBufferGetBaseAddressOfPlane(native, 1)!.assumingMemoryBound(to: UInt8.self)
                for row in 0..<height {
                    memcpy(yBase + row * CVPixelBufferGetBytesPerRowOfPlane(native, 0), planar.dataY + row * Int(planar.strideY), width)
                }
                // This fixture contains only black/white text, so chroma is neutral.
                memset(uvBase, 128, CVPixelBufferGetBytesPerRowOfPlane(native, 1) * (height / 2))
                CVPixelBufferUnlockBaseAddress(native, [])
                let buffer = RTCCVPixelBuffer(pixelBuffer: native)
                let timestamp = UInt32(index * 90000 / fps)
                measurements.reference(timestamp, Self.luma(buffer))
                let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: Int64(index) * 1_000_000_000 / Int64(fps))
                frame.timeStamp = Int32(bitPattern: timestamp)
                XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [index == 0 ? 3 : 4]), 0)
            }
            try await Task.sleep(for: .seconds(0.5))
            _ = encoder.release(); _ = decoder.release()
            results.append(measurements.result(fps: fps))
        }
        print("RETINA_QUALITY_BENCH " + String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), as: UTF8.self))
        XCTAssertGreaterThan(results[0]["decoded"] ?? 0, 80)
        XCTAssertGreaterThan(results[1]["decoded"] ?? 0, 25)
        XCTAssertGreaterThan(results[1]["psnr"] ?? 0, results[0]["psnr"] ?? 0,
                             "Less cadence must buy more detail at the same constrained bitrate.")
    }
}
