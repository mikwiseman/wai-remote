import AppKit
import ScreenCaptureKit
import WebRTC
import RemoteCore

final class VideoCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let source: RTCVideoSource
    private let capturer: RTCVideoCapturer
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "is.wai.remote.capture", qos: .userInteractive)
    private var lastMeasurement = 0.0
    private var capturedFrames = 0
    private var lastCapturedTime = 0.0
    private var largestCaptureGap = 0.0
    private var labTimer: Timer?
    var onError: ((String) -> Void)?
    var onLabImage: ((NSImage) -> Void)?
    var clicks = 0
    var typed = ""
    var cursor = CGPoint(x: 0.5, y: 0.5)
    init(factory: RTCPeerConnectionFactory) {
        source = factory.videoSource(forScreenCast: true)
        capturer = RTCVideoCapturer(delegate: source)
        super.init()
    }
    func startDisplay(_ display: SCDisplay, excluding windowIDs: [CGWindowID]) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let excluded = content.windows.filter { windowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = Self.configuration(size: filter.contentRect.size, pixelScale: CGFloat(filter.pointPixelScale))
        PerformanceLog.record("capture-config", ["width": config.width, "height": config.height, "fps": 60, "format": "NV12", "queueDepth": config.queueDepth])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }
    static func configuration(size: CGSize, pixelScale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let ratio = max(1, Double(pixelScale))
        config.width = max(2, Int(Double(size.width) * ratio) / 2 * 2)
        config.height = max(2, Int(Double(size.height) * ratio) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // VideoToolbox retains surfaces asynchronously. Three surfaces stall
        // 60 Hz capture once encoding takes over 33 ms under GPU load.
        // Eight is ScreenCaptureKit's supported limit, not a playout queue.
        config.queueDepth = 8; config.showsCursor = true; config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return config
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if PerformanceLog.enabled {
            let now = ProcessInfo.processInfo.systemUptime
            if lastCapturedTime > 0 { largestCaptureGap = max(largestCaptureGap, (now - lastCapturedTime) * 1000) }
            lastCapturedTime = now
            if lastMeasurement == 0 { lastMeasurement = now }
            capturedFrames += 1
            if now - lastMeasurement >= 1 {
                let fps = Double(capturedFrames) / (now - lastMeasurement)
                lastMeasurement = now
                capturedFrames = 0
                // ScreenCaptureKit's display timestamp can be slightly in the future.
                // This clock offset is not an end-to-end capture latency measurement.
                PerformanceLog.record("capture", ["fps": fps, "gapMaxMs": largestCaptureGap,
                    "sampleOffsetMs": (CMClockGetTime(CMClockGetHostTimeClock()).seconds - sampleBuffer.presentationTimeStamp.seconds) * 1000])
                largestCaptureGap = 0
            }
        }
        push(buffer, timestamp: sampleBuffer.presentationTimeStamp)
    }
    private func push(_ buffer: CVPixelBuffer, timestamp: CMTime? = nil) {
        let seconds = timestamp.flatMap { $0.isNumeric && $0.seconds.isFinite ? $0.seconds : nil } ?? ProcessInfo.processInfo.systemUptime
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0,
                                 timeStampNs: Int64(seconds * 1_000_000_000))
        source.capturer(capturer, didCapture: frame)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { DispatchQueue.main.async { [weak self] in self?.onError?(error.localizedDescription) } }
    func stop() {
        labTimer?.invalidate(); labTimer = nil
        if let stream { Task { try? await stream.stopCapture() } }; stream = nil
    }
    func startLab() {
        labTimer = Timer.connectionTimer(withTimeInterval: 1.0/15, repeats: true) { [weak self] _ in self?.renderLab() }
        renderLab()
    }
    func applyLab(_ m: WireMessage) {
        if let x = m.x, let y = m.y { cursor = CGPoint(x: x, y: y) }
        if m.type == "pointer", m.action == "down" { clicks += 1 }
        if m.type == "text" { typed = String((typed + (m.text ?? "")).suffix(90)) }
        if m.type == "key", m.action == "down", m.key == "Backspace", !typed.isEmpty { typed.removeLast() }
    }
    private func renderLab() {
        let w = 1280, h = 800
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                                 [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixel) == kCVReturnSuccess,
              let pixel else { return }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let cg = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        NSColor(calibratedRed: 0.96, green: 0.945, blue: 0.918, alpha: 1).setFill(); cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor = .darkGray, _ weight: NSFont.Weight = .regular) {
            (s as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        }
        text("WAI REMOTE / ПРОВЕРОЧНЫЙ ЭКРАН", 70, 720, 17, .gray, .medium)
        text("Ваш Mac. Под рукой.", 70, 580, 64, .black, .semibold)
        text("Нажмите здесь. Переключитесь в рисование. Оставьте след.", 74, 524, 24)
        let box = NSBezierPath(roundedRect: NSRect(x: 70, y: 190, width: 1140, height: 260), xRadius: 24, yRadius: 24)
        NSColor.white.setFill(); box.fill()
        text("КЛИКОВ", 108, 388, 15, .gray, .medium)
        text(String(clicks), 104, 280, 82, NSColor(calibratedRed: 0.24, green: 0.39, blue: 0.32, alpha: 1), .medium)
        text(typed.isEmpty ? "Текст с пульта появится здесь…" : typed, 330, 325, 24)
        text("Изображение передаётся через настоящий WebRTC.", 74, 110, 20)
        text("Этот режим не читает экран и не управляет приложениями macOS.", 74, 76, 17, .gray)
        NSColor(calibratedRed: 0.88, green: 0.35, blue: 0.28, alpha: 1).setFill()
        let dot = NSRect(x: cursor.x * CGFloat(w) - 6, y: (1 - cursor.y) * CGFloat(h) - 6, width: 12, height: 12)
        NSBezierPath(ovalIn: dot).fill()
        NSGraphicsContext.restoreGraphicsState()
        if let image = cg.makeImage() { onLabImage?(NSImage(cgImage: image, size: NSSize(width: w, height: h))) }
        push(pixel)
    }
}
