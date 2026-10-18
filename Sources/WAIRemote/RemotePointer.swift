import AppKit
import RemoteCore

/// A separate visual pointer. Never moves the desktop cursor,
/// becomes key, or receives the owner's mouse events.
final class RemotePointer {
    private let panel: NSPanel
    private let pointer = CAShapeLayer()
    private var visible = false
    private var level = NSWindow.Level.normal
    private var surfaceFrame: CGRect?
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }
    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 28, height: 34),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.canHide = false
        panel.hidesOnDeactivate = false; panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Keep the window stationary. Moving a backed NSView window for every
        // packet makes AppKit synchronize/redraw its backing store. A small
        // vector layer moves on the compositor without that CPU drawing path.
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.isGeometryFlipped = true
        view.layer?.masksToBounds = true
        pointer.path = Self.path
        pointer.fillColor = NSColor.systemBlue.cgColor
        pointer.strokeColor = NSColor.white.cgColor
        pointer.lineWidth = 1.5
        pointer.bounds = CGRect(x: 0, y: 0, width: 28, height: 34)
        pointer.anchorPoint = .zero
        view.layer?.addSublayer(pointer)
        panel.contentView = view
    }
    func show(_ point: InkPoint, in target: WindowInputTarget) {
        guard let frame = target.frame else { hide(); return }
        position(point, in: frame)
        if level != .normal { panel.level = .normal; level = .normal }
        // Place it directly above its target; another app can cover both together.
        panel.order(.above, relativeTo: Int(target.windowID))
        visible = true
    }
    func show(_ point: InkPoint, on display: CGRect) {
        position(point, in: display)
        let changedLevel = level != .popUpMenu
        if changedLevel { panel.level = .popUpMenu; level = .popUpMenu }
        // Visibility queries can contact WindowServer. This panel owns its
        // geometry and ordering, so retain that state instead of querying it
        // synchronously for every packet.
        if changedLevel || !visible { panel.orderFrontRegardless(); visible = true }
    }
    private func position(_ point: InkPoint, in frame: CGRect) {
        guard let screen = NSScreen.screens.first else { return }
        let windowFrame = CGRect(x: frame.minX, y: screen.frame.maxY - frame.maxY,
                                 width: frame.width, height: frame.height)
        if surfaceFrame != windowFrame {
            panel.setFrame(windowFrame, display: false)
            surfaceFrame = windowFrame
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointer.position = CGPoint(x: point.x * max(1, frame.width - 1) - 3,
                                   y: point.y * max(1, frame.height - 1) - 2)
        CATransaction.commit()
    }
    func hide() { if visible { panel.orderOut(nil); visible = false } }
    deinit { panel.close() }
    private static let path: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 3, y: 2)); path.addLine(to: CGPoint(x: 3, y: 25))
        path.addLine(to: CGPoint(x: 9, y: 20)); path.addLine(to: CGPoint(x: 14, y: 31))
        path.addLine(to: CGPoint(x: 19, y: 29)); path.addLine(to: CGPoint(x: 14, y: 18))
        path.addLine(to: CGPoint(x: 23, y: 18)); path.closeSubpath()
        return path
    }()
}
