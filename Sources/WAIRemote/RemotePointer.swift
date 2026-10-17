import AppKit
import RemoteCore

/// A separate visual pointer. Never moves the desktop cursor,
/// becomes key, or receives the owner's mouse events.
final class RemotePointer {
    private let panel: NSPanel
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }
    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 28, height: 34),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false; panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = PointerShape()
    }
    func show(_ point: InkPoint, in target: WindowInputTarget) {
        guard let frame = target.frame else { hide(); return }
        position(point, in: frame)
        panel.level = .normal
        // Place it directly above its target; another app can cover both together.
        panel.order(.above, relativeTo: Int(target.windowID))
    }
    func show(_ point: InkPoint, on display: CGRect) {
        position(point, in: display)
        let changedLevel = panel.level != .popUpMenu
        if changedLevel { panel.level = .popUpMenu }
        if changedLevel || !panel.isVisible { panel.orderFrontRegardless() }
    }
    private func position(_ point: InkPoint, in frame: CGRect) {
        guard let screen = NSScreen.screens.first else { return }
        let x = frame.minX + point.x * max(1, frame.width - 1)
        let y = frame.minY + point.y * max(1, frame.height - 1)
        let origin = NSPoint(x: x - 2, y: screen.frame.maxY - y - 32)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
    }
    func hide() { panel.orderOut(nil) }
    deinit { panel.close() }
}

private final class PointerShape: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 3, y: 2)); path.line(to: NSPoint(x: 3, y: 25))
        path.line(to: NSPoint(x: 9, y: 20)); path.line(to: NSPoint(x: 14, y: 31))
        path.line(to: NSPoint(x: 19, y: 29)); path.line(to: NSPoint(x: 14, y: 18))
        path.line(to: NSPoint(x: 23, y: 18)); path.close()
        NSColor.systemBlue.setFill(); path.fill()
        NSColor.white.setStroke(); path.lineWidth = 1.5; path.stroke()
    }
}
