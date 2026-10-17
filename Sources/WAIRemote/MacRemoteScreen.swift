import AppKit
import SwiftUI
import WebRTC
import RemoteCore
import AVFoundation

struct MacRemoteScreen: NSViewRepresentable {
    @ObservedObject var model: MacViewerModel
    func makeNSView(context: Context) -> RemoteScreenView { RemoteScreenView(model: model) }
    func updateNSView(_ view: RemoteScreenView, context: Context) { view.update() }
    static func dismantleNSView(_ view: RemoteScreenView, coordinator: ()) { view.detach() }
}

final class FrameRenderer: NSObject, RTCVideoRenderer {
    private let display: AVSampleBufferVideoRenderer
    var onFrame: (() -> Void)?
    private let lock = NSLock()
    private var delivered = false
    private var previousFrameTime = 0.0
    private var reportTime = 0.0
    private var frameGaps: [Double] = []
    private let timing = FrameTimingLog("render")
    private let enqueuing = FrameTimingLog("display-enqueue")
    private var active = true
    init(display: AVSampleBufferDisplayLayer) { self.display = display.sampleBufferRenderer }
    func awaitNextFrame() {
        lock.lock(); delivered = false; lock.unlock()
    }
    func stop() {
        lock.lock()
        active = false
        display.flush(removingDisplayedImage: true)
        lock.unlock()
    }
    func setSize(_ size: CGSize) {} // RemoteViewport owns the aspect-fit geometry.
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        timing.frame(frame.timeStampNs)
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        if display.status == .failed { display.flush() }
        // Never create an application-side video queue or block the UI waiting
        // for a drawable. The next decoded frame supersedes a congested frame.
        guard display.isReadyForMoreMediaData, let sample = VideoSampleBuffer.make(frame) else {
            PerformanceLog.record("display-skipped")
            return
        }
        display.enqueue(sample)
        enqueuing.frame(frame.timeStampNs)
        let first = !delivered; delivered = true
        if PerformanceLog.enabled {
            let now = ProcessInfo.processInfo.systemUptime
            if previousFrameTime > 0 { frameGaps.append((now - previousFrameTime) * 1000) }
            previousFrameTime = now
            if reportTime == 0 { reportTime = now }
            if now - reportTime >= 1, !frameGaps.isEmpty {
                let gaps = frameGaps.sorted()
                PerformanceLog.record("renderer", ["fps": Double(gaps.count) / (now - reportTime),
                    "gapP95Ms": gaps[Int(ceil(Double(gaps.count) * 0.95)) - 1],
                    "gapMaxMs": gaps.last!, "gapsOver100Ms": gaps.filter { $0 > 100 }.count])
                display.loadVideoPerformanceMetrics { metrics in
                    guard let metrics else { return }
                    PerformanceLog.record("display-metrics", ["frames": metrics.totalNumberOfFrames,
                        "dropped": metrics.numberOfDroppedFrames, "corrupted": metrics.numberOfCorruptedFrames,
                        "delaySeconds": metrics.totalAccumulatedFrameDelay])
                }
                frameGaps.removeAll(keepingCapacity: true); reportTime = now
            }
        }
        if first { DispatchQueue.main.async { [weak self] in self?.onFrame?() } }
    }
}

final class RemoteScreenView: NSView, NSTextInputClient {
    private let model: MacViewerModel
    private var video: DecodedVideoView?
    private let ink = InkView()
    private(set) var renderer: FrameRenderer?
    private var track: RTCVideoTrack?
    private var pressedKeys = Set<UInt16>()
    private var pointerDown = false
    private var marked = NSAttributedString(string: "")
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }

    init(model: MacViewerModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        addSubview(ink)
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Экран другого Mac. Нажмите для управления. Command Option Escape освобождает клавиатуру.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var viewport: RemoteViewport {
        RemoteViewport(width: bounds.width, height: bounds.height,
                       sourceWidth: Double(model.session.state?.surface.width ?? 1920),
                       sourceHeight: Double(model.session.state?.surface.height ?? 1080))
    }
    override func layout() {
        super.layout()
        let frame = videoFrame
        if let video, video.frame != frame { video.frame = frame }
        if ink.frame != frame { ink.frame = frame }
    }
    private var videoFrame: NSRect {
        let fit = viewport
        return NSRect(x: fit.x, y: fit.y, width: fit.width, height: fit.height)
    }
    func update() {
        if track !== model.track {
            detach()
            if let track = model.track {
                // Each track gets a fresh layer, so a disconnected Mac cannot
                // leave its last frame behind the next connection's status.
                let video = DecodedVideoView(frame: .zero)
                self.video = video; self.track = track
                addSubview(video, positioned: .below, relativeTo: ink)
                let renderer = FrameRenderer(display: video.display)
                renderer.onFrame = { [weak self, weak model, weak track] in
                    guard let self, let model, let track,
                          self.track === track, model.track === track else { return }
                    model.receivedFrame = true
                }
                self.renderer = renderer; track.add(renderer)
            }
        }
        // A brief ICE interruption can resume on the same track. Its next
        // displayed frame must dismiss the waiting overlay again.
        if !model.receivedFrame { renderer?.awaitNextFrame() }
        ink.referenceWidth = Double(model.session.state?.surface.width ?? 1920)
        let strokes = model.visibleStrokes
        if ink.strokes != strokes { ink.strokes = strokes }
        let frame = videoFrame
        if ink.frame != frame || (video != nil && video?.frame != frame) { needsLayout = true }
    }
    func detach() {
        renderer?.onFrame = nil
        if let renderer { track?.remove(renderer) }
        renderer?.stop()
        renderer = nil; track = nil
        video?.removeFromSuperview(); video = nil
        pressedKeys.removeAll(); pointerDown = false
    }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    private func point(_ event: NSEvent, clamp: Bool = false) -> InkPoint? {
        let local = convert(event.locationInWindow, from: nil), fit = viewport
        if let point = fit.point(x: local.x, y: local.y) { return point }
        guard clamp, fit.width > 0, fit.height > 0 else { return nil }
        return InkPoint(min(1, max(0, (local.x-fit.x)/fit.width)), min(1, max(0, (local.y-fit.y)/fit.height)))
    }
    private func pointer(_ action: String, _ event: NSEvent, button: Int = 0) {
        guard let point = point(event, clamp: pointerDown) else { return }
        if action == "down" { window?.makeFirstResponder(self); pointerDown = true }
        if model.canDraw, button == 0 {
            switch action { case "down": model.beginStroke(at: point); case "move" where pointerDown: model.appendStroke(at: point); case "up": model.endStroke(); default: break }
        } else { model.pointer(action, at: point, button: button, modifiers: modifiers(event)) }
        if action == "up" { pointerDown = false }
    }
    override func mouseDown(with event: NSEvent) { pointer("down", event) }
    override func mouseUp(with event: NSEvent) { pointer("up", event) }
    override func mouseDragged(with event: NSEvent) { pointer("move", event) }
    override func mouseMoved(with event: NSEvent) { pointer("move", event) }
    override func rightMouseDown(with event: NSEvent) { pointer("down", event, button: 2) }
    override func rightMouseUp(with event: NSEvent) { pointer("up", event, button: 2) }
    override func rightMouseDragged(with event: NSEvent) { pointer("move", event, button: 2) }
    override func scrollWheel(with event: NSEvent) {
        guard let point = point(event) else { return }
        model.pointer("scroll", at: point, dx: -Double(event.scrollingDeltaX), dy: -Double(event.scrollingDeltaY), modifiers: modifiers(event))
    }
    private func modifiers(_ event: NSEvent) -> [String] {
        [(.command, "Meta"), (.control, "Control"), (.option, "Alt"), (.shift, "Shift")]
            .compactMap { (flag: NSEvent.ModifierFlags, name: String) in event.modifierFlags.contains(flag) ? name : nil }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, model.canControl, event.modifierFlags.contains(.command) else { return false }
        // Always leave an escape hatch and the app's own Quit shortcut on this Mac.
        if (event.keyCode == 53 && event.modifierFlags.contains(.option)) || event.keyCode == 12 {
            model.releaseInput(); window?.makeFirstResponder(nil)
            return event.keyCode != 12
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if (flags == .command && [4, 46, 43, 29].contains(event.keyCode)) ||
            (flags == [.command, .option] && event.keyCode == 4) {
            model.releaseInput(); pressedKeys.removeAll()
            return false
        }
        if event.keyCode == 9 && !event.modifierFlags.contains(.shift) {
            paste(nil); return true
        }
        keyDown(with: event); return true
    }
    @objc func paste(_ sender: Any?) {
        model.paste()
    }
    @objc func copy(_ sender: Any?) { model.key("KeyC", modifiers: ["Meta"]) }
    @objc func cut(_ sender: Any?) { model.key("KeyX", modifiers: ["Meta"]) }
    override func selectAll(_ sender: Any?) { model.key("KeyA", modifiers: ["Meta"]) }
    override func keyDown(with event: NSEvent) {
        guard model.canControl else { return }
        if event.modifierFlags.intersection([.command, .control]).isEmpty,
           ![36,48,51,53,76,96,97,98,99,100,101,103,109,111,115,116,117,118,119,120,121,122,123,124,125,126].contains(event.keyCode) {
            interpretKeyEvents([event])
        } else if let code = InputInjector.keyCodes.first(where: { $0.value == event.keyCode })?.key {
            pressedKeys.insert(event.keyCode)
            model.keyEvent(code, action: "down", modifiers: modifiers(event))
        }
    }
    override func keyUp(with event: NSEvent) {
        guard pressedKeys.remove(event.keyCode) != nil,
              let code = InputInjector.keyCodes.first(where: { $0.value == event.keyCode })?.key else { return }
        model.keyEvent(code, action: "up", modifiers: modifiers(event))
    }
    override func flagsChanged(with event: NSEvent) {
        guard model.canControl else { return }
        let flag: NSEvent.ModifierFlags
        switch event.keyCode {
        case 54, 55: flag = .command
        case 56, 60: flag = .shift
        case 58, 61: flag = .option
        case 59, 62: flag = .control
        default: return
        }
        guard let code = InputInjector.keyCodes.first(where: { $0.value == event.keyCode })?.key else { return }
        // Aggregate flags can remain set while the other side is still held.
        let down = event.modifierFlags.contains(flag) && !pressedKeys.contains(event.keyCode)
        if down { pressedKeys.insert(event.keyCode) } else { pressedKeys.remove(event.keyCode) }
        model.keyEvent(code, action: down ? "down" : "up", modifiers: modifiers(event))
    }
    override func resignFirstResponder() -> Bool {
        model.releaseInput(); pressedKeys.removeAll(); pointerDown = false; unmarkText()
        return super.resignFirstResponder()
    }
    // interpretKeyEvents uses the NSResponder entry point for simple text;
    // input methods use NSTextInputClient's replacement-range entry point.
    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        unmarkText(); model.text(text)
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
    }
    func unmarkText() { marked = NSAttributedString(string: "") }
    func selectedRange() -> NSRange { NSRange(location: marked.length, length: 0) }
    func markedRange() -> NSRange { NSRange(location: marked.length == 0 ? NSNotFound : 0, length: marked.length) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        window?.convertToScreen(convert(NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 20), to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {
        let commands = ["insertNewline:":"Enter", "insertTab:":"Tab", "deleteBackward:":"Backspace", "cancelOperation:":"Escape"]
        if let key = commands[NSStringFromSelector(selector)] { model.key(key) }
    }
}

struct ViewerWindowView: View {
    @ObservedObject var model: MacViewerModel
    var body: some View {
        ZStack {
            Color.black
            MacRemoteScreen(model: model)
            if !model.connected || !model.receivedFrame {
                Color(nsColor: .windowBackgroundColor)
                VStack(spacing: 16) {
                    if model.connecting || model.connected { ProgressView() }
                    Text(model.status).font(.title2.weight(.semibold))
                    if !model.detail.isEmpty { Text(model.detail).foregroundStyle(.secondary).multilineTextAlignment(.center) }
                    if !model.connecting && !model.connected {
                        Button("Подключиться снова") { model.connect() }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }.frame(maxWidth: 420).padding(32)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .alert("Не удалось вставить", isPresented: Binding(get: { model.pasteFailure != nil }, set: { if !$0 { model.pasteFailure = nil } })) {
            Button("OK") { model.pasteFailure = nil }
        } message: { Text(model.pasteFailure ?? "") }
    }
}
