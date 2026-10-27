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
        var transient: (WindowInputTarget, CGPoint) -> Bool
        var prepare: (WindowInputTarget) -> Void
        var pointer: (pid_t, CGEvent) -> Void
        var pause: (TimeInterval) -> Void
        var menuItem: (WindowInputTarget, CGEvent) -> Button? = { _, _ in nil }
        var key: (pid_t, CGEvent) -> Void = { $1.postToPid($0) }
        static let system = Delivery(frame: { $0.frame },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            transient: { $0.isTransient(at: $1) },
            prepare: { $0.prepareWindow() }, pointer: { WindowInputTarget.postPointer?($0, $1) },
            pause: { Thread.sleep(forTimeInterval: $0) }, menuItem: { $0.menuItem(for: $1) })
    }
    /// `hover` places the pointer over the target first, for a press that no
    /// move preceded (touch taps). Hover-armed controls ignore a bare press.
    @discardableResult func post(_ event: CGEvent, permitted: () -> Bool, hover: Bool = false, delivery: Delivery = .system) -> InputOutcome {
        // A point inside a window does not move with the window. Address the
        // event with the geometry the user aimed at, even if activation moves it.
        guard permitted() else { return .cancelled }
        guard let frame = delivery.frame(self), address(event, frame: frame) else { return .frameGone }
        let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        var primed = false
        // An active app needs no synthetic activation. An open menu or popover is
        // already tracking, and an off-window primer would dismiss it first.
        if down && delivery.frontmostPID() != pid { delivery.prepare(self) }
        if down && delivery.frontmostPID() != pid && !delivery.transient(self, event.location) {
            primed = true
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
                guard permitted() else { return .cancelled }
                guard delivery.frame(self) != nil, let primer = CGEvent(mouseEventSource: nil, mouseType: type,
                                                                        mouseCursorPosition: point, mouseButton: .left) else { return .frameGone }
                primer.flags = event.flags
                primer.setIntegerValueField(CGEventField(rawValue: 58)!, value: group)
                guard address(primer, frame: frame) else { return .frameGone }
                primer.setIntegerValueField(.mouseEventNumber, value: phase)
                primer.setIntegerValueField(.mouseEventClickState, value: type == .mouseMoved ? 0 : 1)
                delivery.pointer(pid, primer)
                delivery.pause(delay)
            }
        }
        if down && hover && !primed, let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                                       mouseCursorPosition: event.location, mouseButton: .left) {
            move.flags = event.flags
            move.setIntegerValueField(CGEventField(rawValue: 58)!, value: event.getIntegerValueField(CGEventField(rawValue: 58)!))
            if address(move, frame: frame) { delivery.pointer(pid, move) }
        }
        guard permitted() else { return .cancelled }
        guard delivery.frame(self) != nil else { return .frameGone }
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            // AppKit and Chromium perform menu key equivalents only for the
            // active app, so a background app ignores a posted Command-V.
            if event.type == .keyDown, event.flags.contains(.maskCommand), delivery.frontmostPID() != pid,
               let item = delivery.menuItem(self, event) {
                if withoutActuallyEscaping(permitted, do: { item.press(if: $0) }) { return .menu }
                guard permitted() else { return .cancelled }
            }
            delivery.key(pid, event)
        default:
            // The public PID path misses Chromium's background mouse handler.
            // Deliver once through SkyLight, never through global HID.
            delivery.pointer(pid, event)
        }
        return primed ? .primer : .window
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
        guard let frame, frame.contains(point), let hit = element(at: point) else { return nil }
        return button(climbingFrom: hit, at: point)
    }
    /// The app's own hit test returns the topmost element, so sheets, overlays and
    /// web modals win over the controls they cover, whatever their tree order.
    private func element(at point: CGPoint) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        var hit: AXUIElement?
        return AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success ? hit : nil
    }
    /// The hit is often a title or image inside the button. Climb a few parents
    /// to an enabled button of this window; anything else gets ordinary events.
    func button(climbingFrom hit: AXUIElement, at point: CGPoint) -> Button? {
        guard let windowNumber = Self.windowNumber else { return nil }
        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXWindowAttribute, kAXParentAttribute] as CFArray
        var element = hit
        for _ in 0...3 {
            AXUIElementSetMessagingTimeout(element, 0.05)
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 6 else { return nil }
            if values[0] as? String == kAXButtonRole, values[3] as? Bool == true, let bounds = Self.rect(values[1], values[2]),
               bounds.contains(point), CFGetTypeID(values[4]) == AXUIElementGetTypeID() {
                var id: CGWindowID = 0, actions: CFArray?
                guard windowNumber(values[4] as! AXUIElement, &id) == .success, id == windowID,
                      AXUIElementCopyActionNames(element, &actions) == .success,
                      (actions as? [String])?.contains(kAXPressAction) == true else { return nil }
                let pressed = element
                return Button(frame: bounds, requiresMainThread: pid == ProcessInfo.processInfo.processIdentifier, action: {
                    AXUIElementPerformAction(pressed, kAXPressAction as CFString) == .success
                })
            }
            guard CFGetTypeID(values[5]) == AXUIElementGetTypeID() else { return nil }
            element = values[5] as! AXUIElement
        }
        return nil
    }
    /// The app's own menu item for a Command shortcut. Menus change with the
    /// app's state, so every lookup reads them afresh, within a fixed budget.
    func menuItem(for event: CGEvent, budget: TimeInterval = 0.25) -> Button? {
        if pid == ProcessInfo.processInfo.processIdentifier && !Thread.isMainThread {
            return DispatchQueue.main.sync { menuItem(for: event, budget: budget) }
        }
        guard let character = Self.shortcutCharacter(event) else { return nil }
        let flags = event.flags, deadline = ProcessInfo.processInfo.systemUptime + budget
        // AXMenuItemCmdModifiers: Shift 1, Option 2, Control 4; Command is implied.
        let modifiers = (flags.contains(.maskShift) ? 1 : 0) | (flags.contains(.maskAlternate) ? 2 : 0) | (flags.contains(.maskControl) ? 4 : 0)
        func values(_ element: AXUIElement, _ names: [String]) -> [AnyObject]? {
            AXUIElementSetMessagingTimeout(element, 0.05)
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == names.count else { return nil }
            return values
        }
        func elements(_ value: AnyObject?) -> [AXUIElement] {
            ((value as? [AnyObject]) ?? []).filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { $0 as! AXUIElement }
        }
        guard let bar = values(AXUIElementCreateApplication(pid), [kAXMenuBarAttribute])?.first,
              CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        var menus: [AXUIElement] = []
        for top in elements(values(bar as! AXUIElement, [kAXChildrenAttribute])?.first) {
            // The system's Apple menu (Lock Screen, Log Out) is not the app's.
            guard let item = values(top, [kAXTitleAttribute, kAXChildrenAttribute]), item[0] as? String != "Apple" else { continue }
            menus += elements(item[1])
        }
        // Breadth first: the standard editing shortcuts sit at the top level.
        let names = ["AXMenuItemCmdChar", "AXMenuItemCmdModifiers", kAXEnabledAttribute, kAXChildrenAttribute]
        while !menus.isEmpty {
            for item in elements(values(menus.removeFirst(), [kAXChildrenAttribute])?.first) {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
                guard let value = values(item, names) else { continue }
                if (value[0] as? String)?.uppercased() == character, ((value[1] as? NSNumber)?.intValue ?? 0) == modifiers,
                   value[2] as? Bool == true {
                    return Button(frame: .zero, requiresMainThread: pid == ProcessInfo.processInfo.processIdentifier, action: {
                        AXUIElementSetMessagingTimeout(item, 0.25)
                        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                        // A slow menu action still runs after its reply times out.
                        return result == .success || result == .cannotComplete
                    })
                }
                menus += elements(value[3])
            }
        }
        return nil
    }
    /// The character the key types on this Mac's layout. A non-Latin layout
    /// performs Command shortcuts with the US Latin keys, as AppKit does.
    static func shortcutCharacter(_ event: CGEvent) -> String? {
        var length = 0, units = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &units)
        if length == 1, (0x21...0x7e).contains(units[0]) { return String(UnicodeScalar(UInt8(units[0]))).uppercased() }
        let latin = Array("ASDFHGZXCV\0BQWERYT123465=97-80]OU[IP\0LJ'K;\\,/NM.")
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        return code < latin.count && latin[code] != "\0" ? String(latin[code]) : nil
    }
    private static func rect(_ position: AnyObject, _ size: AnyObject) -> CGRect? {
        var origin = CGPoint.zero, extent = CGSize.zero
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
              AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: origin, size: extent)
    }
    /// Menus and pop-ups sit above the normal window layer; popovers and some
    /// menus are only recognizable by their accessibility role.
    func isTransient(at point: CGPoint) -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier && !Thread.isMainThread {
            return DispatchQueue.main.sync { isTransient(at: point) }
        }
        if let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
           let window = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
           ((window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) > 0 { return true }
        let names = [kAXRoleAttribute, kAXParentAttribute] as CFArray
        var element = element(at: point)
        for _ in 0..<8 {
            guard let current = element else { return false }
            AXUIElementSetMessagingTimeout(current, 0.05)
            var raw: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(current, names, [], &raw) == .success,
                  let values = raw as? [AnyObject], values.count == 2 else { return false }
            if let role = values[0] as? String, [kAXMenuRole, "AXPopover"].contains(role) { return true }
            element = CFGetTypeID(values[1]) == AXUIElementGetTypeID() ? (values[1] as! AXUIElement) : nil
        }
        return false
    }
}
