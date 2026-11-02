import SwiftUI
import UIKit
import Combine
import MetalKit
import WebRTC
import RemoteCore

struct RemoteScreen: UIViewRepresentable {
    @ObservedObject var model: PhoneModel
    var onZoom: (Bool) -> Void = { _ in }
    func makeUIView(context: Context) -> ScreenView { let view = ScreenView(model: model); view.onZoom = onZoom; return view }
    func updateUIView(_ view: ScreenView, context: Context) { view.onZoom = onZoom; view.update() }
    static func dismantleUIView(_ view: ScreenView, coordinator: ()) { view.detach() }
}

final class ScreenView: UIView, RTCVideoViewDelegate {
    private let model: PhoneModel
    private let content = UIView()
    private let video = RTCMTLVideoView(frame: .zero)
    private var videoCadence: PhoneVideoCadence?
    private let ink = PhoneInkView()
    private var currentTrack: RTCVideoTrack?
    private let frameObserver = FirstPhoneFrame()
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var touches = [ObjectIdentifier: CGPoint]()
    private var start = CGPoint.zero
    private var startPoint = InkPoint(0.5, 0.5)
    private var previous = CGPoint.zero
    private var moved = false
    private var dragging = false
    private var longPress: Timer?
    private var navigation: String?
    private var pairCenter = CGPoint.zero
    private var pairDistance: CGFloat = 0
    private var pairZoom: CGFloat = 1
    private var pairPoint = InkPoint(0.5, 0.5)
    private var pairSize = CGSize.zero
    private var pairIDs: [ObjectIdentifier] = []
    private var pairOrigins: [CGPoint] = []
    private var pairStarted: TimeInterval = 0
    private var scrollState: HostState?
    private var revisionObserver: AnyCancellable?
    private var displayLink: CADisplayLink?
    private lazy var displayTarget = PhoneScrollDisplayTarget { [weak self] time in self?.advanceScroll(at: time) }
    private lazy var scroll = PhoneScrollStream(canSend: { [weak self] in
        guard let self else { return false }; return self.canDeliverScroll && self.model.canSendScroll
    }, emit: { [weak self] output in
        guard let self, self.canDeliverScroll else { return }
        self.model.pointer("scroll", at: self.pairPoint, dx: output.delta.x, dy: output.delta.y,
                           scrollPhase: output.scrollPhase, momentumPhase: output.momentumPhase)
    })
    private var revision = -1
    private var zoomRevision = -1
    private var erasePrevious: CGPoint?
    private var reportedZoom = false
    var onZoom: ((Bool) -> Void)?
    // UIKit-like double-tap limits, in phone points: a finger lands less precisely than a pointer.
    private var taps = ClickSequence()

    init(model: PhoneModel) {
        self.model = model; super.init(frame: .zero)
        isMultipleTouchEnabled = true; clipsToBounds = true; backgroundColor = .black
        content.isUserInteractionEnabled = false; content.clipsToBounds = true
        video.videoContentMode = .scaleAspectFit; video.delegate = self
        videoCadence = PhoneVideoCadence(video: video); video.isEnabled = false
        frameObserver.onFrame = { [weak self] in
            guard let self, self.currentTrack != nil, !self.model.connectionInterrupted else { return }
            self.model.receivedFrame = true
        }
        addSubview(content); content.addSubview(video); content.addSubview(ink)
        #if DEBUG
        if let image = PhoneModel.demoScreen { let sample = UIImageView(image: image); sample.frame = .zero; sample.autoresizingMask = [.flexibleWidth, .flexibleHeight]; content.insertSubview(sample, aboveSubview: video) }
        if PhoneModel.demoMoment == "zoomed" { zoom = 2.2; zoomRevision = model.resetZoomRevision }
        #endif
        isAccessibilityElement = true; accessibilityLabel = "Экран Mac"
        accessibilityHint = "Касание — клик, удержание — перетаскивание. Два пальца — прокрутка или масштаб."
        accessibilityTraits = [.allowsDirectInteraction]
        // Published sends before assignment: focus/mode changes end the old
        // gesture synchronously, while its original epoch is still current.
        revisionObserver = model.$gestureRevision.dropFirst().sink { [weak self] _ in self?.resetGesture() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { displayLink?.invalidate() }
    #if DEBUG
    // Deterministic display timestamps for the native gesture regressions.
    func advanceScrollForTesting(at timestamp: TimeInterval) { advanceScroll(at: timestamp) }
    #endif
    func update() {
        if currentTrack !== model.track {
            currentTrack?.remove(video); currentTrack?.remove(frameObserver)
            currentTrack = model.track; frameObserver.reset()
            video.isEnabled = currentTrack != nil
            currentTrack?.add(video); currentTrack?.add(frameObserver)
        }
        if !model.receivedFrame && !model.connectionInterrupted { frameObserver.arm() }
        if revision != model.gestureRevision { revision = model.gestureRevision; resetGesture() }
        if zoomRevision != model.resetZoomRevision { resetGesture(); zoomRevision = model.resetZoomRevision; zoom = 1; offset = .zero }
        ink.strokes = model.visibleStrokes; ink.selectedID = model.selectedID; ink.surfaceWidth = CGFloat(model.session.state?.surface.width ?? 1280)
        ink.setNeedsDisplay(); setNeedsLayout()
    }
    func detach() { frameObserver.reset(); resetGesture(); currentTrack?.remove(video); currentTrack?.remove(frameObserver); currentTrack = nil; video.isEnabled = false }
    override func layoutSubviews() {
        super.layoutSubviews()
        let surface = model.session.state?.surface
        let ratio = CGFloat(surface?.width ?? 1280) / CGFloat(surface?.height ?? 800)
        let baseWidth = min(bounds.width, bounds.height * ratio)
        let size = CGSize(width: baseWidth * zoom, height: baseWidth / ratio * zoom)
        // A zoomed desktop may still fit on one axis. Its letterbox space lets
        // that axis follow the pinch too, without moving the image offscreen.
        let limitX = zoom > 1 ? abs(size.width - bounds.width) / 2 : 0
        let limitY = zoom > 1 ? abs(size.height - bounds.height) / 2 : 0
        offset.x = max(-limitX, min(limitX, offset.x))
        offset.y = max(-limitY, min(limitY, offset.y))
        content.frame = CGRect(x: (bounds.width - size.width) / 2 + offset.x, y: (bounds.height - size.height) / 2 + offset.y, width: size.width, height: size.height)
        video.frame = content.bounds; ink.frame = content.bounds; ink.setNeedsDisplay()
        if (zoom > 1.01) != reportedZoom {
            reportedZoom.toggle(); let zoomed = reportedZoom, report = onZoom
            DispatchQueue.main.async { report?(zoomed) }
        }
    }
    /// Answers the finger at once; the Mac's picture follows a round trip later.
    private func ripple(at point: CGPoint) {
        let ring = CAShapeLayer()
        ring.path = UIBezierPath(ovalIn: CGRect(x: -22, y: -22, width: 44, height: 44)).cgPath
        ring.position = point; ring.fillColor = UIColor.clear.cgColor; ring.lineWidth = 2
        ring.strokeColor = UIColor(red: 0.875, green: 0.949, blue: 0.784, alpha: 0.95).cgColor
        layer.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.35; scale.toValue = 1.15
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup(); group.animations = [scale, fade]; group.duration = 0.42
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin(); CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.opacity = 0; ring.add(group, forKey: "ripple"); CATransaction.commit()
    }
    func videoView(_ videoView: RTCVideoRenderer, didChangeVideoSize size: CGSize) {
        // Size negotiation is not proof of a fresh frame.
    }
    private func normalized(_ point: CGPoint) -> InkPoint {
        let p = content.convert(point, from: self)
        return InkPoint(Double(min(1, max(0, p.x / max(1, content.bounds.width)))), Double(min(1, max(0, p.y / max(1, content.bounds.height)))))
    }
    private func resetGesture() {
        longPress?.invalidate(); longPress = nil
        if dragging { model.pointer("up", at: model.lastCursor) }
        scroll.cancel(); displayLink?.invalidate(); displayLink = nil; scrollState = nil
        dragging = false; touches = [:]; navigation = nil; erasePrevious = nil
        pairIDs = []; pairOrigins = []
    }
    private var sameScrollContext: Bool {
        guard revision == model.gestureRevision, let old = scrollState, let current = model.session.state else { return false }
        return old.sessionID == current.sessionID && old.controllerEpoch == current.controllerEpoch
            && old.inputEpoch == current.inputEpoch && old.modeGeneration == current.modeGeneration
            && old.layerEpoch == current.layerEpoch && old.surface == current.surface
    }
    private var canDeliverScroll: Bool { sameScrollContext && model.canControl }
    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: displayTarget, selector: #selector(PhoneScrollDisplayTarget.tick(_:)))
        link.add(to: .main, forMode: .common); displayLink = link
    }
    private func advanceScroll(at timestamp: TimeInterval) {
        guard scroll.isActive || navigation == "pending" else {
            displayLink?.invalidate(); displayLink = nil; return
        }
        guard sameScrollContext, model.canControl || model.canDraw else { resetGesture(); return }
        if navigation == "pending" { movePair(at: timestamp) }
        scroll.tick(at: timestamp)
        if !scroll.isActive && navigation != "pending" { displayLink?.invalidate(); displayLink = nil }
    }
    private func updateTouches(_ incoming: Set<UITouch>, event: UIEvent?) {
        // UIKit's changed set may contain only one finger; use its coherent snapshot.
        for touch in event?.allTouches ?? [] where touches[ObjectIdentifier(touch)] != nil {
            touches[ObjectIdentifier(touch)] = touch.location(in: self)
        }
        for touch in incoming where touches[ObjectIdentifier(touch)] != nil { touches[ObjectIdentifier(touch)] = touch.location(in: self) }
    }
    private func movePair(at timestamp: TimeInterval) {
        guard pairIDs.count == 2, let a = touches[pairIDs[0]], let b = touches[pairIDs[1]] else { return }
        let center = midpoint(a, b), spread = distance(a, b)
        if navigation == "pending" {
            let bothMoved = distance(a, pairOrigins[0]) >= 3 && distance(b, pairOrigins[1]) >= 3
            guard bothMoved || timestamp - pairStarted >= 0.06 else { return }
            let translation = distance(center, pairCenter), expansion = abs(spread - pairDistance)
            if expansion > 8 && expansion > translation {
                // At either zoom limit, keep recognizing instead of locking an
                // invisible pinch when one scrolling finger moves first.
                guard abs(max(1, min(5, pairZoom * spread / max(1, pairDistance))) - pairZoom) > 0.001 else { return }
                navigation = "zoom"
            } else if translation > 8 {
                navigation = model.mode == .control ? "scroll" : "pan"
                // Consume the recognition dead zone once; retain every point after it.
                let fraction = 8 / translation
                pairCenter.x += (center.x - pairCenter.x) * fraction
                pairCenter.y += (center.y - pairCenter.y) * fraction
                if navigation == "scroll" {
                    let surface = model.session.state?.surface
                    scroll.begin(at: pairStarted, scale: CGPoint(x: CGFloat(surface?.width ?? 1280) / max(1, content.bounds.width),
                                                                y: CGFloat(surface?.height ?? 800) / max(1, content.bounds.height)))
                }
            }
        }
        if navigation == "zoom" {
            zoom = max(1, min(5, pairZoom * spread / max(1, pairDistance)))
            let scale = zoom / pairZoom
            offset = CGPoint(x: center.x - bounds.midX - (CGFloat(pairPoint.x) - 0.5) * pairSize.width * scale,
                             y: center.y - bounds.midY - (CGFloat(pairPoint.y) - 0.5) * pairSize.height * scale)
            setNeedsLayout()
        } else if navigation == "scroll" {
            scroll.move(by: CGPoint(x: pairCenter.x - center.x, y: pairCenter.y - center.y), at: timestamp)
            pairCenter = center
        } else if navigation == "pan" {
            offset.x += center.x - pairCenter.x; offset.y += center.y - pairCenter.y; pairCenter = center; setNeedsLayout()
        }
    }
    override func touchesBegan(_ incoming: Set<UITouch>, with event: UIEvent?) {
        guard model.canControl || model.canDraw else { return }
        if touches.isEmpty { resetGesture(); revision = model.gestureRevision }
        else if !pairIDs.isEmpty && touches.count < 2 {
            // Keep the remaining finger and form a fresh pair with its replacement.
            scroll.cancel(); displayLink?.invalidate(); displayLink = nil
            pairIDs = []; pairOrigins = []
        }
        // Extra fingers must not replace an established pair or restart its target.
        guard pairIDs.isEmpty else { return }
        guard touches.count + incoming.count <= 2 else { resetGesture(); return }
        layoutIfNeeded()
        for touch in incoming { touches[ObjectIdentifier(touch)] = touch.location(in: self) }
        updateTouches(incoming, event: event)
        if touches.count >= 2 {
            longPress?.invalidate(); longPress = nil
            if dragging { model.pointer("up", at: model.lastCursor); dragging = false }
            // Starting navigation must not leave a pen dot or half an erase behind.
            let positions = touches
            model.cancelGesture(notify: true); revision = model.gestureRevision; touches = positions
            navigation = "pending"; moved = true; erasePrevious = nil
            pairIDs = Array(touches.keys); pairOrigins = pairIDs.compactMap { touches[$0] }
            let pair = pairOrigins; pairCenter = midpoint(pair[0], pair[1]); pairDistance = distance(pair[0], pair[1]); pairZoom = zoom
            pairPoint = normalized(pairCenter); pairSize = content.bounds.size
            pairStarted = event?.timestamp ?? ProcessInfo.processInfo.systemUptime; scrollState = model.session.state
            if content.frame.contains(pairCenter) { startDisplayLink() } else { navigation = "outside" }
            return
        }
        guard let p = touches.values.first, content.frame.contains(p) else { navigation = "outside"; return }
        start = p; startPoint = normalized(p); previous = p; moved = false; navigation = nil; erasePrevious = nil
        if model.canDraw {
            if model.tool == .eraser { erase(at: p) }
            else if model.tool == .select { model.selectedID = hit(at: p)?.id }
            else { model.beginStroke(at: normalized(p)) }
        } else {
            if !UIAccessibility.isReduceMotionEnabled { ripple(at: p) }
            longPress = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                guard let self, self.touches.count == 1, !self.moved, self.model.canControl else { return }
                self.dragging = true; self.model.pointer("down", at: self.startPoint)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
    override func touchesMoved(_ incoming: Set<UITouch>, with event: UIEvent?) {
        guard !touches.isEmpty else { return }
        guard revision == model.gestureRevision, model.canControl || model.canDraw else { resetGesture(); return }
        updateTouches(incoming, event: event)
        if touches.count >= 2 {
            guard sameScrollContext else { resetGesture(); return }
            movePair(at: event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
            return
        }
        // A two-finger gesture stays navigation until both fingers are lifted.
        guard navigation == nil, let p = touches.values.first else { return }
        if distance(p, start) > 8 { moved = true; longPress?.invalidate() }
        if model.canDraw {
            if model.tool == .eraser { erase(at: p) }
            else if model.tool != .select { model.appendStroke(at: normalized(p)) }
        } else if dragging { model.pointer("move", at: normalized(p)) }
        else if moved { offset.x += p.x - previous.x; offset.y += p.y - previous.y; setNeedsLayout() }
        previous = p
    }
    override func touchesEnded(_ incoming: Set<UITouch>, with event: UIEvent?) {
        guard incoming.contains(where: { touches[ObjectIdentifier($0)] != nil }) else { return }
        guard revision == model.gestureRevision, model.canControl || model.canDraw else { resetGesture(); return }
        updateTouches(incoming, event: event)
        let timestamp = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if touches.count >= 2 {
            guard sameScrollContext else { resetGesture(); return }
            movePair(at: timestamp)
            if navigation == "scroll" { scroll.end(at: timestamp) }
        }
        let p = incoming.first?.location(in: self) ?? previous
        for touch in incoming { touches.removeValue(forKey: ObjectIdentifier(touch)) }
        longPress?.invalidate(); longPress = nil
        if navigation == nil {
            if model.canDraw {
                if model.tool == .eraser { model.finishErase() } else { model.endStroke() }
            } else if dragging { model.pointer("up", at: normalized(p)) }
            else if !moved {
                // Lift-off jitter becomes a large miss when a desktop is reduced to phone size.
                let count = taps.down(x: start.x, y: start.y, button: 0, now: ProcessInfo.processInfo.systemUptime, interval: 0.5, radius: 22)
                model.pointer("down", at: startPoint, clickCount: count); model.pointer("up", at: startPoint)
            }
        }
        dragging = false
        if touches.isEmpty { navigation = nil; erasePrevious = nil; pairIDs = []; pairOrigins = [] }
    }
    override func touchesCancelled(_ incoming: Set<UITouch>, with event: UIEvent?) { model.cancelGesture(notify: true); resetGesture() }
    private func erase(at p: CGPoint) {
        let a = erasePrevious ?? p, steps = max(1, Int(ceil(distance(a, p) / 4)))
        for index in 1...steps {
            let t = CGFloat(index) / CGFloat(steps), point = CGPoint(x: a.x + (p.x - a.x) * t, y: a.y + (p.y - a.y) * t)
            if let stroke = hit(at: point) { model.markErased(stroke.id) }
        }
        erasePrevious = p
    }
    private func hit(at point: CGPoint) -> InkStroke? {
        let p = content.convert(point, from: self), size = content.bounds.size
        for stroke in model.strokes.reversed() where stroke.author == model.identity?.id && stroke.complete && !model.hiddenIDs.contains(stroke.id) {
            var points = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
            let width = stroke.width * size.width / max(1, ink.surfaceWidth) * (stroke.tool == .marker ? 3 : 1), radius = 12 + width / 2
            if stroke.tool == .arrow { points += PhoneInkView.arrowHead(points, width: width) }
            if points.count == 1, distance(p, points[0]) <= radius { return stroke }
            for index in 1..<max(1, points.count) where segmentDistance(p, points[index - 1], points[index]) <= radius { return stroke }
        }
        return nil
    }
}

final class PhoneInkView: UIView {
    var strokes: [InkStroke] = []
    var selectedID: String?
    var surfaceWidth: CGFloat = 1280
    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; backgroundColor = .clear; contentMode = .redraw }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func arrowHead(_ points: [CGPoint], width: CGFloat) -> [CGPoint] {
        guard let a = points.first, let b = points.last, points.count > 1 else { return [] }
        let angle = atan2(b.y - a.y, b.x - a.x), length = max(10, width * 4)
        return [CGPoint(x: b.x - length * cos(angle - 0.45), y: b.y - length * sin(angle - 0.45)), b, CGPoint(x: b.x - length * cos(angle + 0.45), y: b.y - length * sin(angle + 0.45))]
    }
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        for stroke in strokes {
            let points = stroke.points.map { CGPoint(x: $0.x * bounds.width, y: $0.y * bounds.height) }
            guard let first = points.first else { continue }
            let width = stroke.width * bounds.width / max(1, surfaceWidth) * (stroke.tool == .marker ? 3 : 1)
            ctx.saveGState(); ctx.setStrokeColor(UIColor(hex: stroke.color).cgColor); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.setAlpha(stroke.tool == .marker ? 0.32 : 1); ctx.move(to: first)
            for p in points.dropFirst() { ctx.addLine(to: p) }
            if points.count == 1 { ctx.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            ctx.strokePath()
            if stroke.tool == .arrow {
                let head = Self.arrowHead(points, width: width)
                if let a = head.first { ctx.move(to: a); head.dropFirst().forEach { ctx.addLine(to: $0) }; ctx.strokePath() }
            }
            ctx.restoreGState()
            if stroke.id == selectedID {
                let xs = points.map(\.x), ys = points.map(\.y)
                let selection = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!).insetBy(dx: -12, dy: -12)
                ctx.saveGState(); ctx.setStrokeColor(UIColor.systemBlue.cgColor); ctx.setLineWidth(1.5); ctx.setLineDash(phase: 0, lengths: [5, 4]); ctx.stroke(selection); ctx.restoreGState()
            }
        }
    }
}

extension UIColor {
    convenience init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xE05A47
        self.init(red: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
private func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
    let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
    return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
}

/// CADisplayLink retains its target; the callback holds the screen weakly.
private final class PhoneScrollDisplayTarget: NSObject {
    private let action: (TimeInterval) -> Void
    init(_ action: @escaping (TimeInterval) -> Void) { self.action = action }
    @objc func tick(_ link: CADisplayLink) { action(link.timestamp) }
}

/// WebRTC resets its wrapped Metal view to 30 Hz when a renderer is first used.
/// Forward its draw callbacks, then restore the screen stream's 60 Hz cadence.
private final class PhoneVideoCadence: NSObject, MTKViewDelegate {
    private weak var renderer: MTKViewDelegate?
    init(video: RTCMTLVideoView) {
        super.init()
        guard let metal = video.subviews.first(where: { $0 is MTKView }) as? MTKView else { return }
        renderer = metal.delegate; metal.delegate = self
        metal.preferredFramesPerSecond = 60
    }
    func draw(in view: MTKView) {
        renderer?.draw(in: view)
        if view.preferredFramesPerSecond != 60 { view.preferredFramesPerSecond = 60 }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer?.mtkView(view, drawableSizeWillChange: size)
    }
}

private final class FirstPhoneFrame: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var waiting = true
    private var generation = 0
    var onFrame: (() -> Void)?
    func arm() { lock.lock(); waiting = true; lock.unlock() }
    func reset() { lock.lock(); generation += 1; waiting = true; lock.unlock() }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, frame.width > 0, frame.height > 0 else { return }
        lock.lock(); let notify = waiting, token = generation; waiting = false; lock.unlock()
        if notify { DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.generation == token; self.lock.unlock()
            if current { self.onFrame?() }
        } }
    }
}
