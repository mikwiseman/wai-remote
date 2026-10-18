import Foundation
import WebRTC
import RemoteCore

final class ViewerTransport: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    private var peer: RTCPeerConnection!
    private var channel: RTCDataChannel!
    private let gathering: ICEGatheringDeadline
    private var completion: ((Result<String, Error>) -> Void)?
    private var closed = false
    var onVideo: ((RTCVideoTrack) -> Void)?
    var onMessage: ((Data) -> Void)?
    var onState: ((RTCPeerConnectionState) -> Void)?
    init(ice: ICEConfiguration) {
        gathering = ICEGatheringDeadline(ice: ice)
        super.init()
        let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle; config.rtcpMuxPolicy = .require
        config.iceServers = ice.iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.iceTransportPolicy = ice.iceTransportPolicy == "relay" ? .relay : .all
        peer = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        let receive = RTCRtpTransceiverInit(); receive.direction = .recvOnly
        if let video = peer.addTransceiver(of: .video, init: receive) {
            let supported = factory.rtpReceiverCapabilities(forKind: "video").codecs
            video.setCodecPreferences(supported.filter { $0.name == "H264" } + supported.filter { $0.name != "H264" })
        }
        let data = RTCDataChannelConfiguration(); data.isOrdered = true
        channel = peer.dataChannel(forLabel: "interaction", configuration: data); channel.delegate = self
    }
    func offer(_ completion: @escaping (Result<String, Error>) -> Void) {
        self.completion = completion
        gathering.start(description: { [weak self] in self?.peer.localDescription?.sdp }) { [weak self] result in self?.finish(result) }
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
    private func gathered() { if let sdp = peer.localDescription?.sdp { finish(.success(sdp)) } }
    private func finish(_ result: Result<String, Error>) {
        guard !closed else { return }; gathering.cancel()
        let callback = completion; completion = nil; callback?(result)
    }
    @discardableResult func send(_ data: Data) -> Bool {
        guard !closed, channel.readyState == .open, channel.bufferedAmount < 128_000, data.count <= 32_768 else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }
    func close() {
        closed = true; gathering.cancel(); completion = nil
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
        DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.onState?(newState) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.onVideo?(track) }
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed { DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.onState?(.closed) } }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, buffer.data.count <= 65_536 else { return }
        DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.onMessage?(buffer.data) }
    }
}
