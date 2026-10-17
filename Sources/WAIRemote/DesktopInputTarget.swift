import AppKit
import Darwin

/// Screen coordinates select a destination; a held gesture keeps that destination.
struct DesktopInputTarget {
    private(set) var keyboardTarget: WindowInputTarget?
    private var gestureTarget: WindowInputTarget?
    private var buttons = Set<Int>()

    mutating func pointer(action: String, button: Int, at point: CGPoint,
                          hitTest: (CGPoint) -> WindowInputTarget?) -> WindowInputTarget? {
        let target = buttons.isEmpty ? hitTest(point) : gestureTarget
        if action == "down" {
            if buttons.isEmpty { gestureTarget = target; keyboardTarget = target }
            buttons.insert(button)
        } else if action == "up" {
            buttons.remove(button)
            if buttons.isEmpty { gestureTarget = nil }
        }
        return target
    }

    mutating func reset() { keyboardTarget = nil; gestureTarget = nil; buttons.removeAll() }

    // WindowServer hit-testing respects input regions. Bounding-box scans do
    // not: the Dock has a transparent window covering the entire display.
    private typealias Connection = @convention(c) () -> Int32
    private typealias FindWindow = @convention(c) (Int32, Int32, Int32, Int32,
        UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<CGPoint>,
        UnsafeMutablePointer<CGWindowID>, UnsafeMutablePointer<Int32>) -> Int32
    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection: Connection? = {
        guard let library, let symbol = dlsym(library, "SLSMainConnectionID") else { return nil }
        return unsafeBitCast(symbol, to: Connection.self)
    }()
    private static let findWindow: FindWindow? = {
        guard let library, let symbol = dlsym(library, "SLSFindWindowByGeometry") else { return nil }
        return unsafeBitCast(symbol, to: FindWindow.self)
    }()
    static var isSupported: Bool { WindowInputTarget.isSupported && connection != nil && findWindow != nil }

    static func target(at point: CGPoint, excluding: Set<CGWindowID>) -> WindowInputTarget? {
        guard let connection, let findWindow else { return nil }
        var point = point, local = CGPoint.zero, id: CGWindowID = 0, owner: Int32 = 0
        guard findWindow(connection(), 0, 1, 0, &point, &local, &id, &owner) == 0,
              let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return nil }
        return target(windowID: id, windows: windows, excluding: excluding)
    }
    static func target(windowID: CGWindowID, windows: [[String: Any]],
                       excluding: Set<CGWindowID> = []) -> WindowInputTarget? {
        guard windowID > 0, !excluding.contains(windowID),
              let window = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
              let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        let target = WindowInputTarget(pid: pid, windowID: windowID)
        return target.frame(in: [window]) == nil ? nil : target
    }
}
