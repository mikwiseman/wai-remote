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
        // Low-latency VideoToolbox chooses its own level. Use it only when the
        // peer negotiated our 4K60 capability, not a lower remote level.
        if info.name == "H264", let profile = info.parameters["profile-level-id"],
           profile.hasPrefix("64"), profile.hasSuffix("34"),
           info.parameters["packetization-mode"] == "1" {
            return LowLatencyH264Encoder(codec: info)
        }
        return base.createEncoder(info)
    }
}

final class ScreenVideoDecoderFactory: NSObject, RTCVideoDecoderFactory {
    private let base = RTCDefaultVideoDecoderFactory()
    func supportedCodecs() -> [RTCVideoCodecInfo] { ScreenVideoPolicy.screenCodecs(base.supportedCodecs()) }
    func createDecoder(_ info: RTCVideoCodecInfo) -> RTCVideoDecoder? { base.createDecoder(info) }
}
