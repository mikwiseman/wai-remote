import Foundation
import WebRTC
import RemoteCore

final class PeerTransport: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate {
    private var pc: RTCPeerConnection!
    private var channel: RTCDataChannel?
    private var answerCompletion: ((Result<String, Error>) -> Void)?
    private var answerTimer: Timer?
    var onOpen: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onState: ((RTCPeerConnectionState) -> Void)?
    private var closed = false
    private var opened = false
    var isReady: Bool { !closed && channel?.readyState == .open }
    init(factory: RTCPeerConnectionFactory, source: RTCVideoSource, ice: ICEConfiguration) {
        super.init()
        let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
        config.iceServers = ice.iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.iceTransportPolicy = ice.iceTransportPolicy == "relay" ? .relay : .all
        config.bundlePolicy = .maxBundle; config.rtcpMuxPolicy = .require
        pc = factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: self)
        let track = factory.videoTrack(with: source, trackId: "screen")
        _ = pc.add(track, streamIds: ["wai-screen"])
    }
    func answer(offer: String, completion: @escaping (Result<String, Error>) -> Void) {
        answerCompletion = completion
        answerTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.finishAnswer(.failure(NSError(domain: "WebRTC", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось подготовить соединение"])))
        }
        pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: offer)) { [weak self] error in
            if let error { DispatchQueue.main.async { self?.finishAnswer(.failure(error)) }; return }
            self?.pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { description, error in
                guard let description else { if let error { DispatchQueue.main.async { self?.finishAnswer(.failure(error)) } }; return }
                self?.pc.setLocalDescription(description) { error in
                    DispatchQueue.main.async {
                        if let error { self?.finishAnswer(.failure(error)) }
                        else if self?.pc.iceGatheringState == .complete { self?.finishGathering() }
                    }
                }
            }
        }
    }
    private func finishGathering() { if let sdp = pc.localDescription?.sdp { finishAnswer(.success(sdp)) } }
    private func finishAnswer(_ result: Result<String, Error>) {
        guard !closed else { return }; answerTimer?.invalidate(); answerTimer = nil
        let completion = answerCompletion; answerCompletion = nil; completion?(result)
    }
    @discardableResult func send(_ object: Any) -> Bool {
        guard let channel, channel.readyState == .open, channel.bufferedAmount < 256_000,
              let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 60_000 else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }
    func close() { closed = true; answerTimer?.invalidate(); answerCompletion = nil; channel?.delegate = nil; channel?.close(); pc.delegate = nil; pc.close() }
    private func notifyOpen() { guard !closed, !opened else { return }; opened = true; onOpen?() }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete { DispatchQueue.main.async { [weak self] in self?.finishGathering() } }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.onState?(newState) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, self.channel == nil, dataChannel.label == "interaction", dataChannel.isOrdered else { dataChannel.close(); return }
            self.channel = dataChannel; dataChannel.delegate = self
            if dataChannel.readyState == .open { self.notifyOpen() }
        }
    }
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed else { return }
            if dataChannel.readyState == .open { self.notifyOpen() }
            if dataChannel.readyState == .closed { self.onState?(.closed) }
        }
    }
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, buffer.data.count <= 32_768 else { return }
        DispatchQueue.main.async { [weak self] in guard let self, !self.closed else { return }; self.onMessage?(buffer.data) }
    }
}

extension Encodable {
    func jsonObject() -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) ?? [:] }
}
