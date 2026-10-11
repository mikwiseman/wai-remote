import AppKit
import SwiftUI
import RemoteCore

final class InkView: NSView {
    override var isFlipped: Bool { true }
    var strokes: [InkStroke] = [] { didSet { needsDisplay = true } }
    var onDraw: ((String, InkPoint) -> Void)?
    var referenceWidth: Double = 1280
    private var laser: [(point: InkPoint, time: Double)] = []
    private var laserTimer: Timer?
    func showLaser(_ point: InkPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        laser.removeAll { now - $0.time > 0.8 }; laser.append((point, now))
        if laser.count > 50 { laser.removeFirst(laser.count - 50) }
        if laserTimer == nil {
            laserTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.laser.removeAll { ProcessInfo.processInfo.systemUptime - $0.time > 0.8 }
                self.needsDisplay = true
                if self.laser.isEmpty { timer.invalidate(); self.laserTimer = nil }
            }
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            let hex = String(stroke.color.dropFirst()); let n = UInt32(hex, radix: 16) ?? 0xE05A47
            let color = NSColor(calibratedRed: CGFloat((n >> 16) & 255)/255, green: CGFloat((n >> 8) & 255)/255,
                                blue: CGFloat(n & 255)/255, alpha: stroke.tool == .marker ? 0.32 : 1)
            color.setStroke(); color.setFill()
            func point(_ p: InkPoint) -> NSPoint { NSPoint(x: p.x * bounds.width, y: p.y * bounds.height) }
            let path = NSBezierPath(); path.lineWidth = max(1, stroke.width * bounds.width / referenceWidth * (stroke.tool == .marker ? 3 : 1))
            path.lineCapStyle = .round; path.lineJoinStyle = .round; path.move(to: point(first))
            for p in stroke.points.dropFirst() { path.line(to: point(p)) }
            if stroke.points.count == 1 { path.line(to: NSPoint(x: point(first).x + 0.1, y: point(first).y)) }
            path.stroke()
            if stroke.tool == .arrow, let last = stroke.points.last, stroke.points.count > 1 {
                let a = point(first), b = point(last); let angle = atan2(b.y-a.y,b.x-a.x); let length = max(10, path.lineWidth*4)
                let head = NSBezierPath(); head.lineWidth = path.lineWidth; head.lineCapStyle = .round
                head.move(to: NSPoint(x:b.x-length*cos(angle-0.45),y:b.y-length*sin(angle-0.45))); head.line(to:b)
                head.line(to:NSPoint(x:b.x-length*cos(angle+0.45),y:b.y-length*sin(angle+0.45))); head.stroke()
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        for sample in laser {
            let alpha = max(0, 1 - (now - sample.time)/0.8)
            NSColor(calibratedRed: 0.88, green: 0.35, blue: 0.28, alpha: alpha).setFill()
            let size = max(6, 10 * bounds.width/referenceWidth)
            NSBezierPath(ovalIn: NSRect(x: sample.point.x*bounds.width-size/2, y: sample.point.y*bounds.height-size/2, width:size,height:size)).fill()
        }
    }
    private func point(_ event: NSEvent) -> InkPoint {
        let p = convert(event.locationInWindow, from: nil)
        return InkPoint(min(1,max(0,p.x/bounds.width)),min(1,max(0,p.y/bounds.height)))
    }
    override func mouseDown(with event: NSEvent) { onDraw?("strokeBegin", point(event)) }
    override func mouseDragged(with event: NSEvent) { onDraw?("strokeAppend", point(event)) }
    override func mouseUp(with event: NSEvent) { onDraw?("strokeEnd", point(event)) }
}

private final class DrawingInputPanel: NSPanel {
    var onFinish: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onFinish?() } else { super.keyDown(with: event) } }
}

private final class DrawingInputView: NSView {
    var onDraw: ((String, InkPoint) -> Void)?
    var onFinish: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // A completely transparent window is click-through on macOS, even with ignoresMouseEvents = false.
        NSColor.black.withAlphaComponent(0.01).setFill(); dirtyRect.fill()
    }
    private func point(_ event: NSEvent) -> InkPoint {
        let p = convert(event.locationInWindow, from: nil)
        return InkPoint(min(1,max(0,p.x/bounds.width)),min(1,max(0,p.y/bounds.height)))
    }
    override func mouseDown(with event: NSEvent) { onDraw?("strokeBegin", point(event)) }
    override func mouseDragged(with event: NSEvent) { onDraw?("strokeAppend", point(event)) }
    override func mouseUp(with event: NSEvent) { onDraw?("strokeEnd", point(event)) }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onFinish?() } }
}

final class InkOverlay {
    let panel: NSPanel
    let view = InkView()
    var onFinish: (() -> Void)?
    var onClear: (() -> Void)?
    private var inputPanel: DrawingInputPanel?
    private var toolbar: NSPanel?
    private let screen: NSScreen
    init(screen: NSScreen) {
        self.screen = screen
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.contentView = view; view.referenceWidth = Double(screen.frame.width)
        panel.orderFrontRegardless()
    }
    var drawing: Bool {
        get { inputPanel != nil }
        set {
            inputPanel?.orderOut(nil); inputPanel = nil; toolbar?.orderOut(nil); toolbar = nil
            guard newValue else { return }
            // Only the noninteractive ink window is excluded from capture. Input and its toolbar are separate windows.
            let input = DrawingInputPanel(contentRect: screen.frame, styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
            input.title = "Локальное рисование WAI Remote"
            input.isOpaque = false; input.backgroundColor = .clear; input.hasShadow = false
            input.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
            input.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]; input.hidesOnDeactivate = false
            let inputView = DrawingInputView(); inputView.onDraw = view.onDraw
            inputView.onFinish = { [weak self] in self?.onFinish?() }; input.contentView = inputView
            input.onFinish = { [weak self] in self?.onFinish?() }; inputPanel = input
            input.makeKeyAndOrderFront(nil); input.makeFirstResponder(inputView)
            let controls = NSPanel(contentRect: NSRect(x:screen.visibleFrame.midX-180,y:screen.visibleFrame.maxY-76,width:360,height:56),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            controls.title = "Инструменты рисования WAI Remote"
            controls.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
            controls.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; controls.hidesOnDeactivate = false
            controls.isOpaque = false; controls.backgroundColor = .clear; controls.hasShadow = true
            controls.contentView = NSHostingView(rootView: HStack(spacing:14) {
                Text("Рисуете вы").font(.system(size:13,weight:.medium))
                Button("Очистить") { [weak self] in self?.onClear?() }
                Button("Готово · Esc") { [weak self] in self?.onFinish?() }.buttonStyle(.borderedProminent).tint(Color(red:0.23,green:0.38,blue:0.31))
            }.padding(12).frame(width:360,height:56).background(.regularMaterial,in:RoundedRectangle(cornerRadius:14)).preferredColorScheme(.light))
            toolbar = controls; controls.orderFrontRegardless()
        }
    }
    func close() { drawing = false; panel.orderOut(nil) }
}
