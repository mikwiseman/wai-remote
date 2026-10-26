import SwiftUI
import UIKit
import WebRTC
import RemoteCore

struct RemoteScreen: UIViewRepresentable {
    @ObservedObject var model: PhoneModel
    func makeUIView(context: Context) -> ScreenView { ScreenView(model: model) }
    func updateUIView(_ view: ScreenView, context: Context) { view.update() }
    static func dismantleUIView(_ view: ScreenView, coordinator: ()) { view.detach() }
}

final class ScreenView: UIView, RTCVideoViewDelegate {
    private let model: PhoneModel
    private let content = UIView()
    private let video = RTCMTLVideoView(frame: .zero)
    private let ink = PhoneInkView()
    private var currentTrack: RTCVideoTrack?
    private let frameObserver = FirstPhoneFrame()
    private var zoom: CGFloat = 1
    private var offset = CGPoint.zero
    private var touches = [ObjectIdentifier: CGPoint]()
    private var start = CGPoint.zero
    private var previous = CGPoint.zero
    private var moved = false
    private var dragging = false
    private var longPress: Timer?
    private var navigation: String?
    private var pairCenter = CGPoint.zero
    private var pairDistance: CGFloat = 0
    private var pairZoom: CGFloat = 1
    private var revision = -1
    private var zoomRevision = -1
    private var erasePrevious: CGPoint?
    // UIKit-like double-tap limits, in phone points: a finger lands less precisely than a pointer.
    private var taps = ClickSequence()

    init(model: PhoneModel) {
        self.model = model; super.init(frame: .zero)
        isMultipleTouchEnabled = true; clipsToBounds = true; backgroundColor = UIColor(white: 0.08, alpha: 1)
        content.isUserInteractionEnabled = false; content.clipsToBounds = true
        video.videoContentMode = .scaleAspectFit; video.delegate = self
        frameObserver.onFrame = { [weak self] in
            guard let self, self.currentTrack != nil, !self.model.connectionInterrupted else { return }
            self.model.receivedFrame = true
        }
        addSubview(content); content.addSubview(video); content.addSubview(ink)
        isAccessibilityElement = true; accessibilityLabel = "Экран Mac"
        accessibilityHint = "Касание — клик, удержание — перетаскивание. Два пальца — прокрутка или масштаб."
        accessibilityTraits = [.allowsDirectInteraction]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update() {
        if currentTrack !== model.track {
            currentTrack?.remove(video); currentTrack?.remove(frameObserver)
            currentTrack = model.track; frameObserver.reset()
            currentTrack?.add(video); currentTrack?.add(frameObserver)
        }
        if !model.receivedFrame && !model.connectionInterrupted { frameObserver.arm() }
        if revision != model.gestureRevision { revision = model.gestureRevision; resetGesture() }
        if zoomRevision != model.resetZoomRevision { zoomRevision = model.resetZoomRevision; zoom = 1; offset = .zero }
        ink.strokes = model.visibleStrokes; ink.selectedID = model.selectedID; ink.surfaceWidth = CGFloat(model.session.state?.surface.width ?? 1280)
        ink.setNeedsDisplay(); setNeedsLayout()
    }
    func detach() { frameObserver.reset(); resetGesture(); currentTrack?.remove(video); currentTrack?.remove(frameObserver); currentTrack = nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        let surface = model.session.state?.surface
        let ratio = CGFloat(surface?.width ?? 1280) / CGFloat(surface?.height ?? 800)
        let baseWidth = min(bounds.width, bounds.height * ratio)
        let size = CGSize(width: baseWidth * zoom, height: baseWidth / ratio * zoom)
        offset.x = max(-max(0, (size.width - bounds.width) / 2), min(max(0, (size.width - bounds.width) / 2), offset.x))
        offset.y = max(-max(0, (size.height - bounds.height) / 2), min(max(0, (size.height - bounds.height) / 2), offset.y))
        content.frame = CGRect(x: (bounds.width - size.width) / 2 + offset.x, y: (bounds.height - size.height) / 2 + offset.y, width: size.width, height: size.height)
        video.frame = content.bounds; ink.frame = content.bounds; ink.setNeedsDisplay()
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
        dragging = false; touches = [:]; navigation = nil; erasePrevious = nil
    }
    override func touchesBegan(_ incoming: Set<UITouch>, with event: UIEvent?) {
        guard model.canControl || model.canDraw else { return }
        for touch in incoming { touches[ObjectIdentifier(touch)] = touch.location(in: self) }
        if touches.count >= 2 {
            longPress?.invalidate(); longPress = nil
            if dragging { model.pointer("up", at: model.lastCursor); dragging = false }
            // Starting navigation must not leave a pen dot or half an erase behind.
            let positions = touches
            model.cancelGesture(notify: true); revision = model.gestureRevision; touches = positions
            navigation = "pending"; moved = true; erasePrevious = nil
            let pair = Array(touches.values.prefix(2)); pairCenter = midpoint(pair[0], pair[1]); pairDistance = distance(pair[0], pair[1]); pairZoom = zoom
            return
        }
        guard let p = touches.values.first, content.frame.contains(p) else { touches = [:]; return }
        start = p; previous = p; moved = false; navigation = nil; erasePrevious = nil
        if model.canDraw {
            if model.tool == .eraser { erase(at: p) }
            else if model.tool == .select { model.selectedID = hit(at: p)?.id }
            else { model.beginStroke(at: normalized(p)) }
        } else {
            longPress = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                guard let self, self.touches.count == 1, !self.moved, self.model.canControl else { return }
                self.dragging = true; self.model.pointer("down", at: self.normalized(self.start))
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }
    override func touchesMoved(_ incoming: Set<UITouch>, with event: UIEvent?) {
        guard !touches.isEmpty else { return }
        for touch in incoming where touches[ObjectIdentifier(touch)] != nil { touches[ObjectIdentifier(touch)] = touch.location(in: self) }
        if touches.count >= 2 {
            let pair = Array(touches.values.prefix(2)), center = midpoint(pair[0], pair[1]), spread = distance(pair[0], pair[1])
            if navigation == "pending" {
                if abs(spread - pairDistance) > 8 { navigation = "zoom" }
                else if distance(center, pairCenter) > 8 { navigation = model.mode == .control ? "scroll" : "pan" }
            }
            if navigation == "zoom" { zoom = max(1, min(5, pairZoom * spread / max(1, pairDistance))); setNeedsLayout() }
            else if navigation == "scroll" {
                model.pointer("scroll", at: normalized(center), dx: Double(center.x - pairCenter.x) * 2, dy: Double(center.y - pairCenter.y) * 2); pairCenter = center
            } else if navigation == "pan" { offset.x += center.x - pairCenter.x; offset.y += center.y - pairCenter.y; pairCenter = center; setNeedsLayout() }
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
        guard !touches.isEmpty else { return }
        let p = incoming.first?.location(in: self) ?? previous
        for touch in incoming { touches.removeValue(forKey: ObjectIdentifier(touch)) }
        longPress?.invalidate(); longPress = nil
        if navigation == nil {
            if model.canDraw {
                if model.tool == .eraser { model.finishErase() } else { model.endStroke() }
            } else if dragging { model.pointer("up", at: normalized(p)) }
            else if !moved {
                let count = taps.down(x: p.x, y: p.y, button: 0, now: ProcessInfo.processInfo.systemUptime, interval: 0.5, radius: 22)
                model.pointer("down", at: normalized(p), clickCount: count); model.pointer("up", at: normalized(p))
            }
        }
        dragging = false
        if touches.isEmpty { navigation = nil; erasePrevious = nil }
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
