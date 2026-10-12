import WebRTC

enum ScreenVideoPolicy {
    static func screenCodecs(_ supported: [RTCVideoCodecInfo]) -> [RTCVideoCodecInfo] {
        supported.map { codec in
            guard codec.name == "H264", let profile = codec.parameters["profile-level-id"], profile.count == 6 else { return codec }
            var parameters = codec.parameters
            // WebRTC's default level 3.1 is limited to 720p30. VideoToolbox needs
            // level 5.2 for a 3840x2160 desktop at 60 fps; peers negotiate down.
            parameters["profile-level-id"] = String(profile.prefix(4)) + "34"
            return RTCVideoCodecInfo(name: codec.name, parameters: parameters, scalabilityModes: codec.scalabilityModes)
        }
    }
    static func codecs(_ supported: [RTCRtpCodecCapability]) -> [RTCRtpCodecCapability] {
        // Use VideoToolbox on Macs, while retaining the codecs offered by other clients.
        supported.filter { $0.name == "H264" } + supported.filter { $0.name != "H264" }
    }
    static func configure(_ sender: RTCRtpSender) {
        let parameters = sender.parameters
        // Hardware encoding is asynchronous; its wall time is not CPU load.
        // Keep the native display cadence instead of reducing it on that heuristic.
        parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainFramerateAndResolution.rawValue)
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = 32_000_000
            encoding.maxFramerate = 60
            encoding.scaleResolutionDownBy = 1
        }
        sender.parameters = parameters
    }
}

final class ScreenVideoEncoderFactory: NSObject, RTCVideoEncoderFactory {
    private let base = RTCDefaultVideoEncoderFactory()
    func supportedCodecs() -> [RTCVideoCodecInfo] { ScreenVideoPolicy.screenCodecs(base.supportedCodecs()) }
    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        PerformanceLog.record("encoder", ["implementation": "WebRTC", "lowLatency": false])
        return base.createEncoder(info)
    }
}

final class ScreenVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let base = RTCDefaultVideoDecoderFactory()
    func supportedCodecs() -> [RTCVideoCodecInfo] { ScreenVideoPolicy.screenCodecs(base.supportedCodecs()) }
    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? {
        guard let decoder = base.createDecoder(info) else { return nil }
        return PerformanceLog.enabled ? MeasuredVideoDecoder(decoder) : decoder
    }
}

private final class MeasuredVideoDecoder: NSObject, RTCVideoDecoder {
    private let decoder: RTCVideoDecoder
    private let input = FrameTimingLog("decode-input")
    private let output = FrameTimingLog("decode-output")
    init(_ decoder: RTCVideoDecoder) { self.decoder = decoder }
    func implementationName() -> String { decoder.implementationName() }
    func startDecode(withNumberOfCores cores: Int32) -> Int { decoder.startDecode(withNumberOfCores: cores) }
    func release() -> Int { decoder.release() }
    func setCallback(_ callback: @escaping RTCVideoDecoderCallback) {
        decoder.setCallback { [output] frame in
            output.frame(frame.timeStampNs)
            callback(frame)
        }
    }
    func decode(_ image: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: RTCCodecSpecificInfo?, renderTimeMs: Int64) -> Int {
        input.frame(Int64(image.timeStamp), detail: renderTimeMs)
        return decoder.decode(image, missingFrames: missingFrames, codecSpecificInfo: info, renderTimeMs: renderTimeMs)
    }
}
