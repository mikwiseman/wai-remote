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
    private typealias PostPointer = @convention(c) (pid_t, CGEvent) -> Void
    private static let postPointer: PostPointer? = {
        _ = setWindowLocation
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLEventPostToPid") else { return nil }
        return unsafeBitCast(symbol, to: PostPointer.self)
    }()
    private typealias ProcessNumber = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
    private typealias FocusRecord = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
    private static let processNumber: ProcessNumber? = {
        _ = dlopen("/System/Library/Frameworks/Carbon.framework/Carbon", RTLD_LAZY | RTLD_GLOBAL)
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID") else { return nil }
        return unsafeBitCast(symbol, to: ProcessNumber.self)
    }()
    private static let focusRecord: FocusRecord? = {
        _ = setWindowLocation
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLPSPostEventRecordTo") else { return nil }
        return unsafeBitCast(symbol, to: FocusRecord.self)
    }()
    static var isSupported: Bool { setWindowLocation != nil && postPointer != nil && processNumber != nil && focusRecord != nil }
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
        event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(windowID))
        if event.getIntegerValueField(CGEventField(rawValue: 58)!) == 0 {
            event.setIntegerValueField(CGEventField(rawValue: 58)!, value: 1)
        }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .mouseMoved,
             .leftMouseDragged, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
             .otherMouseDragged, .scrollWheel:
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
            // Keep CGEvent.location in screen space and stamp the top-left
            // window point separately. The native Chrome fixture verifies that
            // screen coordinates here would add the window origin twice.
            setLocation(event, CGPoint(x: event.location.x - frame.minX,
                                       y: event.location.y - frame.minY))
            switch event.type {
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                 .otherMouseDown, .otherMouseUp, .mouseMoved:
                event.setIntegerValueField(.mouseEventSubtype, value: 3)
                event.setIntegerValueField(.mouseEventNumber, value: event.type == .mouseMoved ? 2 : 3)
            default: break
            }
        default: break
        }
        return true
    }
    struct Delivery {
        var frame: (WindowInputTarget) -> CGRect?
        var frontmostPID: () -> pid_t?
        var prepare: (WindowInputTarget) -> Void
        var pointer: (pid_t, CGEvent) -> Void
        var pause: (TimeInterval) -> Void
        static let system = Delivery(frame: { $0.frame },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            prepare: { $0.prepareWindow() }, pointer: { WindowInputTarget.postPointer?($0, $1) },
            pause: { Thread.sleep(forTimeInterval: $0) })
    }
    func post(_ event: CGEvent, permitted: () -> Bool, delivery: Delivery = .system) {
        guard permitted(), delivery.frame(self) != nil else { return }
        let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        // An active app needs no synthetic activation. An off-window primer
        // here dismisses its open menus/popovers before the real click arrives.
        if down && delivery.frontmostPID() != pid {
            delivery.prepare(self)
            // Chromium also requires a complete background activation gesture.
            // The primer stays outside the window, so it hits no real control.
            // Its group is shared with the actual down/up; never post globally.
            let group = event.getIntegerValueField(CGEventField(rawValue: 58)!)
            let steps: [(CGEventType, CGPoint, Int64, TimeInterval)] = [
                (.mouseMoved, event.location, 2, 0.015),
                (.leftMouseDown, CGPoint(x: -1, y: -1), 1, 0.001),
                (.leftMouseUp, CGPoint(x: -1, y: -1), 2, 0.1)
            ]
            for (type, point, phase, delay) in steps {
                guard permitted(), let frame = delivery.frame(self),
                      let primer = CGEvent(mouseEventSource: nil, mouseType: type,
                                           mouseCursorPosition: point, mouseButton: .left) else { return }
                primer.flags = event.flags
                primer.setIntegerValueField(CGEventField(rawValue: 58)!, value: group)
                guard address(primer, frame: frame) else { return }
                primer.setIntegerValueField(.mouseEventNumber, value: phase)
                primer.setIntegerValueField(.mouseEventClickState, value: type == .mouseMoved ? 0 : 1)
                delivery.pointer(pid, primer)
                delivery.pause(delay)
            }
        }
        // Activation may move a window or lay out a sheet. Recompute the local
        // point immediately before delivery instead of keeping its old origin.
        guard permitted(), let frame = delivery.frame(self), address(event, frame: frame) else { return }
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged: event.postToPid(pid)
        default:
            // The public PID path misses Chromium's background mouse handler.
            // Deliver once through SkyLight, never through global HID.
            delivery.pointer(pid, event)
        }
    }
    private func prepareWindow() {
        guard let processNumber = Self.processNumber, let focusRecord = Self.focusRecord else { return }
        var process = [UInt32](repeating: 0, count: 2)
        guard processNumber(pid, &process) == 0 else { return }
        // cua-driver's target-only focus record. Do not send a defocus record
        // to the owner's app or change WindowServer's front/key process.
        var record = [UInt8](repeating: 0, count: 0xF8)
        record[0x04] = 0xF8; record[0x08] = 0x0D; record[0x8A] = 0x01
        for byte in 0..<4 { record[0x3C + byte] = UInt8(truncatingIfNeeded: windowID >> (byte * 8)) }
        if focusRecord(&process, &record) == 0 { Thread.sleep(forTimeInterval: 0.05) }
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
