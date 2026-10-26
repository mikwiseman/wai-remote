import Foundation
import WebRTC
import RemoteCore

final class ViewerTransport: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private let factory = RTCPeerConnectionFactory(encoderFactory: ScreenVideoEncoderFactory(), decoderFactory: ScreenVideoDecoderFactory())
    private var peer: RTCPeerConnection!
    private var channel: RTCDataChannel!
    private var clipboardChannel: RTCDataChannel?
    let clipboard: ClipboardSync
    private let gathering: ICEGatheringDeadline
    private var completion: ((Result<String, Error>) -> Void)?
    private var closed = false
    private var statisticsTimer: Timer?
    var onVideo: ((RTCVideoTrack) -> Void)?
    var onMessage: ((Data) -> Void)?
    var onState: ((RTCPeerConnectionState) -> Void)?
    init(ice: ICEConfiguration, clipboard: ClipboardSync = .init()) {
        self.clipboard = clipboard
        gathering = ICEGatheringDeadline(ice: ice)
        super.init()
        clipboard.send = { [weak self] data in
            guard let self, !self.closed, let channel = self.clipboardChannel,
                  channel.readyState == .open, channel.bufferedAmount < 32_768 else { return false }
            return channel.sendData(RTCDataBuffer(data: data, isBinary: true))
        }
        let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle; config.rtcpMuxPolicy = .require
        config.iceServers = ice.iceServers.compactMap {
            let urls = PerformanceLog.tcpOnly ? $0.urls.filter { $0.contains("transport=tcp") } : $0.urls
            return urls.isEmpty ? nil : RTCIceServer(urlStrings: urls, username: $0.username, credential: $0.credential)
        }
        config.iceTransportPolicy = ice.iceTransportPolicy == "relay" ? .relay : .all
        PerformanceLog.record("ice-policy", ["relayOnly": config.iceTransportPolicy == .relay])
        peer = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        PerformanceLog.startNetworkTrace(peer, role: "viewer")
        let receive = RTCRtpTransceiverInit(); receive.direction = .recvOnly
        if let video = peer.addTransceiver(of: .video, init: receive) {
            video.setCodecPreferences(ScreenVideoPolicy.codecs(factory.rtpReceiverCapabilities(forKind: "video").codecs))
        }
        let data = RTCDataChannelConfiguration(); data.isOrdered = true
        channel = peer.dataChannel(forLabel: "interaction", configuration: data); channel.delegate = self
        clipboardChannel = peer.dataChannel(forLabel: ClipboardSync.label, configuration: data)
        clipboardChannel?.delegate = self
    }
    private func startMeasurements() {
        guard PerformanceLog.enabled, statisticsTimer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, !self.closed else { return }
            let buffered = self.channel.bufferedAmount
            self.peer.statistics { report in PerformanceLog.record(report, role: "viewer", buffered: buffered) }
        }
        statisticsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func offer(_ completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        startMeasurements()
        gathering.start(description: { [weak self] in self?.peer.localDescription?.sdp },
                        completion: { [weak self] in self?.finish($0) })
        peer.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] sdp, error in
            guard let self else { return }
            if let error { DispatchQueue.main.async { self.finish(.failure(error)) }; return }
            guard let sdp else { return }
            self.peer.setLocalDescription(sdp) { error in
                DispatchQueue.main.async { if let error { self.finish(.failure(error)) } else if self.peer.iceGatheringState == .complete { self.gathered() } }
            }
        }
    }
    func answer(_ sdp: String, completion: @escaping (Error?) -> Void) {
        peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in DispatchQueue.main.async { completion(error) } }
    }
    private func gathered() { if let sdp = peer.localDescription?.sdp { finish(ICEGatheringDeadline.result(for: sdp)) } }
    private func finish(_ result: Result<String, Error>) {
        guard !closed else { return }; gathering.cancel()
        let callback = completion; completion = nil; callback?(result)
    }
    var bufferedAmount: UInt64 { closed ? 0 : channel.bufferedAmount }
    @discardableResult func send(_ data: Data) -> Bool {
        guard !closed, channel.readyState == .open, channel.bufferedAmount < 128_000, data.count <= 32_768 else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }
    func close() {
        closed = true; statisticsTimer?.invalidate(); statisticsTimer = nil; gathering.cancel(); completion = nil
        clipboard.close(); clipboardChannel?.delegate = nil; clipboardChannel?.close()
        channel.delegate = nil; channel.close(); peer.delegate = nil; peer.close()
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { DispatchQueue.main.async { [weak self] in self?.gathered() } }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { dataChannel.close() }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        PerformanceLog.record("transport-state", ["role": "viewer", "state": newState.rawValue])
        DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.onState?(newState) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.onVideo?(track) }
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.label == ClipboardSync.label {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, dataChannel === self.clipboardChannel else { return }
                self.clipboard.setOpen(dataChannel.readyState == .open)
            }; return
        }
        if dataChannel.readyState == .closed { DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.onState?(.closed) } }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if dataChannel.label == ClipboardSync.label {
            guard buffer.isBinary, buffer.data.count <= ClipboardSync.messageLimit else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, dataChannel === self.clipboardChannel else { return }
                self.clipboard.receive(buffer.data)
            }; return
        }
        guard !buffer.isBinary, buffer.data.count <= 65_536 else { return }
        RunLoop.main.perform(inModes: [.common]) { [weak self] in guard let self, !self.closed else { return }; self.onMessage?(buffer.data) }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didChangeBufferedAmount amount: UInt64) {
        guard dataChannel.label == ClipboardSync.label else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, dataChannel === self.clipboardChannel else { return }
            self.clipboard.pump()
        }
    }
}
