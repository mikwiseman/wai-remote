import CoreMedia
import VideoToolbox
import WebRTC

/// VideoToolbox's conferencing encoder may hold several desktop frames. Apple's
/// low-latency rate control disables lookahead while retaining hardware H.264.
final class LowLatencyH264Encoder: NSObject, RTCVideoEncoder {
    private let codec: RTCVideoCodecInfo
    private var session: VTCompressionSession?
    private var fallback: RTCVideoEncoder?
    private var callback: RTCVideoEncoderCallback?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var framerate: UInt32 = 60

    init(codec: RTCVideoCodecInfo) { self.codec = codec }
    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }
    func implementationName() -> String { "VideoToolbox" }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }
    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        self.callback = callback
        fallback?.setCallback(callback)
    }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        invalidate()
        width = Int32(settings.width); height = Int32(settings.height)
        framerate = max(1, settings.maxFramerate)
        let specification: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
        ]
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        let status = VTCompressionSessionCreate(allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if status == noErr, let session {
            let properties: [CFString: Any] = [
                kVTCompressionPropertyKey_RealTime: true,
                kVTCompressionPropertyKey_AllowFrameReordering: false,
                kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
                kVTCompressionPropertyKey_AverageBitRate: max(1, settings.startBitrate) * 1000,
                kVTCompressionPropertyKey_ExpectedFrameRate: framerate
            ]
            if VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary) == noErr,
               VTCompressionSessionPrepareToEncodeFrames(session) == noErr {
                PerformanceLog.record("encoder", ["lowLatency": true])
                return 0
            }
        }
        // Intel hardware and peers using baseline H.264 retain WebRTC's encoder.
        invalidate()
        let encoder = RTCVideoEncoderH264(codecInfo: codec)
        fallback = encoder; encoder.setCallback(callback)
        PerformanceLog.record("encoder", ["lowLatency": false, "status": status])
        return encoder.startEncode(with: settings, numberOfCores: numberOfCores)
    }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo: RTCCodecSpecificInfo?, frameTypes: [NSNumber]) -> Int {
        if let fallback { return fallback.encode(frame, codecSpecificInfo: codecSpecificInfo, frameTypes: frameTypes) }
        guard let session, let pixels = frame.buffer as? RTCCVPixelBuffer, let callback,
              CVPixelBufferGetWidth(pixels.pixelBuffer) == width,
              CVPixelBufferGetHeight(pixels.pixelBuffer) == height else { return -4 }
        let forceKey = frameTypes.contains { $0.uintValue == RTCFrameType.videoFrameKey.rawValue }
        let properties = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let width = width, height = height, timestamp = UInt32(bitPattern: frame.timeStamp)
        let captureTime = frame.timeStampNs / 1_000_000, rotation = frame.rotation
        let packetization = RTCCodecSpecificInfoH264()
        packetization.packetizationMode = .nonInterleaved
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: pixels.pixelBuffer,
            presentationTimeStamp: CMTime(value: frame.timeStampNs, timescale: 1_000_000_000),
            duration: CMTime(value: 1, timescale: Int32(framerate)), frameProperties: properties, infoFlagsOut: nil) { status, flags, sample in
                guard status == noErr, !flags.contains(.frameDropped), let sample,
                      let data = Self.annexB(sample) else { return }
                let image = RTCEncodedImage()
                image.buffer = data
                image.encodedWidth = width; image.encodedHeight = height
                image.timeStamp = timestamp; image.captureTimeMs = captureTime
                image.rotation = rotation; image.contentType = .screenshare
                image.frameType = Self.isKeyframe(sample) ? .videoFrameKey : .videoFrameDelta
                image.qp = -1; image.flags = 255
                _ = callback(image, packetization)
            }
        return status == noErr ? 0 : -1
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 {
        if let fallback { return fallback.setBitrate(bitrateKbit, framerate: framerate) }
        guard let session else { return -7 }
        self.framerate = max(1, framerate)
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_AverageBitRate: max(1, bitrateKbit) * 1000,
            kVTCompressionPropertyKey_ExpectedFrameRate: self.framerate
        ]
        return VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary) == noErr ? 0 : -1
    }
    func release() -> Int { invalidate(); callback = nil; return 0 }
    private func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        _ = fallback?.release(); fallback = nil
    }
    deinit { invalidate() }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        return attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
    }
    private static func annexB(_ sample: CMSampleBuffer) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var parameterCount = 0, headerLength: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &parameterCount,
            nalUnitHeaderLengthOut: &headerLength) == noErr, headerLength == 4 else { return nil }
        let start: [UInt8] = [0, 0, 0, 1]
        var output = Data()
        if isKeyframe(sample) {
            for index in 0..<parameterCount {
                var bytes: UnsafePointer<UInt8>?, length = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &bytes, parameterSetSizeOut: &length, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let bytes else { return nil }
                output.append(contentsOf: start); output.append(bytes, count: length)
            }
        }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var avcc = Data(count: length)
        guard avcc.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }) == noErr else { return nil }
        var offset = 0
        while offset + 4 <= length {
            let count = (0..<4).reduce(0) { ($0 << 8) | Int(avcc[offset + $1]) }
            offset += 4
            guard count > 0, count <= length - offset else { return nil }
            output.append(contentsOf: start); output.append(avcc[offset..<(offset + count)])
            offset += count
        }
        return offset == length && !output.isEmpty ? output : nil
    }
}
