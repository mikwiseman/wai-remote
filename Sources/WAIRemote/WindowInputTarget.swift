import AppKit
import Darwin

/// Window addressing follows KWWKComputerUseCore and cua-driver (MIT).
/// See licenses/KWWK.txt and licenses/cua-driver.txt. No global-input fallback.
struct WindowInputTarget: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
    struct Button {
        let frame: CGRect
        let requiresMainThread: Bool
        let action: () -> Bool
        func press(if current: @escaping () -> Bool) -> Bool {
            let perform = { current() && action() }
            // AX short-circuits same-process calls onto the caller's thread.
            // SwiftUI actions must execute on MainActor, also through AX.
            if requiresMainThread && !Thread.isMainThread { return DispatchQueue.main.sync(execute: perform) }
            return perform()
        }
    }
    private typealias WindowNumber = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowNumber: WindowNumber? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowNumber.self)
    }()
    private typealias SetLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetLocation? = {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetLocation.self)
    }()
    static var isSupported: Bool { setWindowLocation != nil }
    var frame: CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]] else { return nil }
        return frame(in: list)
    }
    func frame(in windows: [[String: Any]]) -> CGRect? {
        guard let window = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID &&
            ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }),
              let value = window[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: value as CFDictionary),
              frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }
    func address(_ event: CGEvent, frame: CGRect) -> Bool {
        guard let setLocation = Self.setWindowLocation, pid > 0, windowID > 0 else { return false }
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(windowID))
        event.setIntegerValueField(CGEventField(rawValue: 58)!, value: 1)
        setLocation(event, CGPoint(x: event.location.x - frame.minX, y: frame.maxY - event.location.y))
        return true
    }
    func post(_ event: CGEvent) {
        guard let frame, address(event, frame: frame) else { return }
        event.postToPid(pid)
    }
    /// Native buttons can track the real desktop pointer and cancel a synthetic
    /// background click. Their standard Press action does not need that pointer.
    /// Foreign-app AX runs on the input queue. Same-process AX calls bypass IPC,
    /// so inspect our own AppKit/SwiftUI views on their main thread.
    func button(at point: CGPoint) -> Button? {
        if pid == ProcessInfo.processInfo.processIdentifier && !Thread.isMainThread {
            return DispatchQueue.main.sync { button(at: point) }
        }
        guard let frame, frame.contains(point) else { return nil }
        guard let windowNumber = Self.windowNumber else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement],
              let window = list.first(where: { var id: CGWindowID = 0; return windowNumber($0, &id) == .success && id == windowID }) else { return nil }
        // App-level hit testing can be unimplemented and may follow occlusion.
        // Inspect only the selected window, with bounded work on a background queue.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute, kAXEnabledAttribute] as CFArray
        var pending = [window], visited = 0
        while let element = pending.popLast(), visited < 128, ProcessInfo.processInfo.systemUptime < deadline {
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.05)
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 5 else { continue }
            var origin = CGPoint.zero, size = CGSize.zero
            let positioned = CFGetTypeID(values[1]) == AXValueGetTypeID() && CFGetTypeID(values[2]) == AXValueGetTypeID() &&
                AXValueGetValue(values[1] as! AXValue, .cgPoint, &origin) && AXValueGetValue(values[2] as! AXValue, .cgSize, &size)
            let bounds = CGRect(origin: origin, size: size)
            if positioned, size.width > 0, size.height > 0, !bounds.contains(point) { continue }
            if values[0] as? String == kAXButtonRole, positioned, bounds.contains(point), values[4] as? Bool == true {
                var actions: CFArray?
                guard AXUIElementCopyActionNames(element, &actions) == .success,
                      (actions as? [String])?.contains(kAXPressAction) == true else { continue }
                return Button(frame: bounds, requiresMainThread: pid == ProcessInfo.processInfo.processIdentifier, action: {
                    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
                })
            }
            if let children = values[3] as? [AXUIElement] { pending.append(contentsOf: children.reversed()) }
        }
        return nil
    }
}
