import AppKit
import AVFoundation
import WebRTC

/// Display the decoder's IOSurface directly. RTCMTLNSVideoView converts it to
/// I420 and uploads three CPU planes on every display tick, including repeats.
final class DecodedVideoView: NSView {
    let display = AVSampleBufferDisplayLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        display.videoGravity = .resizeAspect
        display.backgroundColor = NSColor.black.cgColor
        layer = display
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum VideoSampleBuffer {
    static func make(_ frame: RTCVideoFrame) -> CMSampleBuffer? {
        guard let pixel = pixelBuffer(frame.buffer) else { return nil }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixel, formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: frame.timeStampNs, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                imageBuffer: pixel, formatDescription: format, sampleTiming: &timing,
                sampleBufferOut: &sample) == noErr, let sample,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return nil }
        let properties = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(properties,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        return sample
    }

    private static func pixelBuffer(_ buffer: RTCVideoFrameBuffer) -> CVPixelBuffer? {
        if let native = buffer as? RTCCVPixelBuffer, !native.requiresCropping(),
           !native.requiresScaling(toWidth: native.width, height: native.height) {
            return native.pixelBuffer
        }
        // Software decoders still produce planar I420. Keep that supported,
        // without making hardware-decoded NV12 take the same copying path.
        let planar = buffer.toI420()
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(planar.width), Int(planar.height),
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess,
              let result else { return nil }
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(result, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(result, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(result, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(result, 1)
        for row in 0..<Int(planar.height) {
            memcpy(y.advanced(by: row * yStride), planar.dataY.advanced(by: row * Int(planar.strideY)), Int(planar.width))
        }
        for row in 0..<Int(planar.chromaHeight) {
            let u = planar.dataU.advanced(by: row * Int(planar.strideU))
            let v = planar.dataV.advanced(by: row * Int(planar.strideV))
            let destination = uv.advanced(by: row * uvStride)
            for column in 0..<Int(planar.chromaWidth) {
                destination[column * 2] = u[column]
                destination[column * 2 + 1] = v[column]
            }
        }
        return result
    }
}
