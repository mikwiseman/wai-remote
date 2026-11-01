import AVFoundation
import CoreImage
import ImageIO
import WebRTC

/// Retain one decoded frame. PNG conversion happens only on the socket worker.
final class AgentFrameCapture {
    struct Captured {
        let frame: RTCVideoFrame
        let generation: UInt64
        let sequence: UInt64
        let receivedAt: TimeInterval
        func png() throws -> (data: Data, width: Int, height: Int) {
            guard frame.width > 0, frame.height > 0, Int64(frame.width) * Int64(frame.height) <= 16_777_216,
                  let sample = VideoSampleBuffer.make(frame), let pixels = CMSampleBufferGetImageBuffer(sample) else {
                throw AgentSocket.Failure("frame_unavailable")
            }
            let orientation: CGImagePropertyOrientation
            switch frame.rotation {
            case ._90: orientation = .right
            case ._180: orientation = .down
            case ._270: orientation = .left
            default: orientation = .up
            }
            let image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let data = AgentFrameCapture.encoder.pngRepresentation(of: image, format: .RGBA8, colorSpace: colorSpace),
                  data.count <= 32 * 1024 * 1024 else { throw AgentSocket.Failure("frame_unavailable") }
            return (data, Int(image.extent.width), Int(image.extent.height))
        }
    }
    private static let encoder = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var stream: UInt64 = 0
    private var sequence: UInt64 = 0
    private var current: Captured?
    var generation: UInt64 { lock.lock(); defer { lock.unlock() }; return stream }
    func beginStream() -> RTCVideoRenderer {
        lock.lock(); stream &+= 1; current = nil; let generation = stream; lock.unlock()
        return Sink { [weak self] frame in self?.receive(frame, generation: generation) }
    }
    func endStream() { lock.lock(); stream &+= 1; current = nil; lock.unlock() }
    func clearFrame() { lock.lock(); current = nil; lock.unlock() }
    func latest() -> Captured? { lock.lock(); defer { lock.unlock() }; return current }
    private func receive(_ frame: RTCVideoFrame, generation: UInt64) {
        guard frame.width > 0, frame.height > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard generation == stream else { return }
        sequence &+= 1
        current = Captured(frame: frame, generation: generation, sequence: sequence,
                           receivedAt: ProcessInfo.processInfo.systemUptime)
    }
    private final class Sink: NSObject, RTCVideoRenderer {
        private let receive: (RTCVideoFrame) -> Void
        init(receive: @escaping (RTCVideoFrame) -> Void) { self.receive = receive }
        func setSize(_ size: CGSize) {}
        func renderFrame(_ frame: RTCVideoFrame?) { if let frame { receive(frame) } }
    }
}
