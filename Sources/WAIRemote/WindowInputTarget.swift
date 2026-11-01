import AppKit
import Darwin

/// Window addressing follows KWWKComputerUseCore and cua-driver (MIT).
/// See licenses/KWWK.txt and licenses/cua-driver.txt. No global-input fallback.
struct WindowInputTarget: Equatable {
    private static func traceHostedMenu(_ message: @autoclosure () -> String) {
        #if DEBUG
        if getenv("WAI_HOSTED_MENU_TRACE") != nil { print("HOSTED_MENU_TRACE \(message())") }
        #endif
    }
    let pid: pid_t
    let windowID: CGWindowID
    struct KeyboardReceiver: Equatable {
        let pid: pid_t
        let windowID: CGWindowID
        var windowFrame: CGRect? = nil
    }
    var keyboardReceiver: KeyboardReceiver? = nil
    static func onMainRunLoop<Output>(_ perform: @escaping () -> Output) -> Output {
        if Thread.isMainThread { return perform() }
        let finished = DispatchSemaphore(value: 0)
        var result: Output?
        // A menu entered from a main-queue callback cannot drain main.sync.
        // Common-mode run-loop work can enter its nested tracking loop instead.
        RunLoop.main.perform(inModes: [.common]) {
            result = perform()
            finished.signal()
        }
        // Keep the input queue ordered and its cancellation closure alive until
        // the main-thread lookup or action has actually finished.
        finished.wait()
        return result!
    }
    struct Button {
        let frame: CGRect
        let requiresMainThread: Bool
        var isMenuItem = false
        var menuDocumentWindowID: CGWindowID? = nil
        let action: () -> Bool
        func press(if current: @escaping () -> Bool) -> Bool {
            let perform = { current() && action() }
            // AX short-circuits same-process calls onto the caller's thread.
            // SwiftUI actions must execute on MainActor, also through AX.
            if requiresMainThread && !Thread.isMainThread { return WindowInputTarget.onMainRunLoop(perform) }
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
    private typealias Connection = @convention(c) () -> Int32
    private typealias WindowOwner = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Int32>) -> Int32
    private typealias ConnectionPID = @convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Int32
    private static let windowOwner: ((CGWindowID) -> pid_t?)? = {
        _ = setWindowLocation
        let library = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connectionSymbol = dlsym(library, "SLSMainConnectionID"),
              let ownerSymbol = dlsym(library, "SLSGetWindowOwner"),
              let pidSymbol = dlsym(library, "SLSConnectionGetPID") else { return nil }
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)
        let owner = unsafeBitCast(ownerSymbol, to: WindowOwner.self)
        let process = unsafeBitCast(pidSymbol, to: ConnectionPID.self)
        return { id in
            var ownerConnection: Int32 = 0, pid: pid_t = 0
            guard owner(connection(), id, &ownerConnection) == 0,
                  process(ownerConnection, &pid) == 0, pid > 0 else { return nil }
            return pid
        }
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
    /// Follow this window's attached sheet or directly linked remote view.
    /// App-wide focus can point at an unrelated document and is never a fallback.
    func keyboardDestination(budget: TimeInterval = 0.01) -> WindowInputTarget? {
        if pid == ProcessInfo.processInfo.processIdentifier && !Thread.isMainThread {
            return Self.onMainRunLoop { self.keyboardDestination(budget: budget) }
        }
        guard let windowNumber = Self.windowNumber else { return self }
        let deadline = ProcessInfo.processInfo.systemUptime + budget
        #if DEBUG
        let traceStarted = ProcessInfo.processInfo.systemUptime
        var traceDestination: WindowInputTarget?
        defer { Self.traceHostedMenu("lookup outer=\(pid):\(windowID) elapsedMs=\((ProcessInfo.processInfo.systemUptime - traceStarted) * 1000) expired=\(ProcessInfo.processInfo.systemUptime >= deadline) destination=\(String(describing: traceDestination))") }
        #endif
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining)))
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        func number(_ element: AXUIElement) -> CGWindowID? {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            AXUIElementSetMessagingTimeout(element, Float(min(0.01, remaining)))
            var id: CGWindowID = 0
            return windowNumber(element, &id) == .success && id > 0 ? id : nil
        }
        let app = AXUIElementCreateApplication(pid)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return self }
        var selected = windows.first(where: { number($0) == windowID })
        // AXWindows contains documents, not their attached sheets. A pointer
        // click may already have selected a sheet's WindowServer address.
        var pending = windows, visited = 0
        while selected == nil, let window = pending.popLast(), visited < 64 {
            visited += 1
            let sheets = ((value(window, kAXChildrenAttribute) as? [AXUIElement]) ?? [])
                .filter { value($0, kAXRoleAttribute) as? String == kAXSheetRole }
            selected = sheets.first(where: { number($0) == windowID }); pending += sheets
        }
        guard var current = selected else { return self }
        var destination = self
        for _ in 0..<4 {
            guard let children = value(current, kAXChildrenAttribute) as? [AXUIElement] else { return destination }
            let sheets = children.filter { value($0, kAXRoleAttribute) as? String == kAXSheetRole }
            if sheets.isEmpty {
                if [kAXSheetRole, kAXWindowRole].contains(value(current, kAXRoleAttribute) as? String ?? "") {
                    destination.keyboardReceiver = destination.remoteKeyboardReceiver(children: children, deadline: deadline)
                    if let menu = destination.remoteMenuKeyboardReceiver(in: current, deadline: deadline) {
                        destination.keyboardReceiver = menu
                    }
                }
                #if DEBUG
                traceDestination = destination
                #endif
                return destination
            }
            guard sheets.count == 1, let sheet = sheets.first else { return nil }
            // A remote view may be hosted by another process. The AX parent-child
            // relationship proves scope; WindowServer supplies its actual owner.
            guard let id = number(sheet),
                  let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
                  let target = DesktopInputTarget.target(windowID: id, windows: windows) else { return nil }
            destination = target; current = sheet
        }
        return nil
    }
    /// A SavePanel's outer sheet/window belongs to its app, but keyboard events belong
    /// to the linked remote view service. Its virtual window is not listed by
    /// CGWindowList, but WindowServer still knows its owner. Keep geometry and
    /// validation on the outer sheet and resolve only its linked child window.
    private func remoteKeyboardReceiver(children: [AXUIElement], deadline: TimeInterval) -> KeyboardReceiver? {
        var roots: [CGWindowID] = []
        for child in children {
            guard let role = Self.axValues(child, [kAXRoleAttribute], deadline: deadline)?.first as? String else { return nil }
            if role == kAXSplitGroupRole, let id = Self.axWindowID(child, deadline: deadline), id != windowID { roots.append(id) }
        }
        // macOS 26's compact panel exposes only host-owned AX proxies. Looking
        // for a foreign AX descendant therefore misses a valid remote receiver.
        guard roots.count == 1, let remoteID = roots.first,
              ProcessInfo.processInfo.systemUptime < deadline,
              let owner = Self.windowOwner?(remoteID), owner != pid else { return nil }
        return KeyboardReceiver(pid: owner, windowID: remoteID)
    }
    /// A hosted popup's menu has its own real window. Its AX ancestry must lead
    /// through this outer window's linked remote root; a service PID alone can
    /// also own menus from unrelated documents.
    private func remoteMenuKeyboardReceiver(in root: AXUIElement, deadline: TimeInterval) -> KeyboardReceiver? {
        #if DEBUG
        let traceStarted = ProcessInfo.processInfo.systemUptime
        var traceNode = "window-list"
        defer { Self.traceHostedMenu("menu-lookup outer=\(pid):\(windowID) elapsedMs=\((ProcessInfo.processInfo.systemUptime - traceStarted) * 1000) expired=\(ProcessInfo.processInfo.systemUptime >= deadline) last=\(traceNode)") }
        #endif
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]] else { return nil }
        let menus = windows.filter { (($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) > 0 }
        guard !menus.isEmpty else { return nil }
        let containers = [kAXGroupRole, kAXSplitGroupRole, kAXScrollAreaRole, kAXToolbarRole, kAXPopUpButtonRole]
        var pending: [(AXUIElement, AXUIElement?, Int, KeyboardReceiver?, Bool)] = [(root, nil, 0, nil, false)]
        var visited = 0, result: KeyboardReceiver?
        while let (element, parent, depth, inherited, popupChild) = pending.popLast(), visited < 64 {
            visited += 1
            #if DEBUG
            traceNode = "node=\(visited) depth=\(depth)"
            #endif
            guard let values = Self.axValues(element, [kAXRoleAttribute, kAXChildrenAttribute], deadline: deadline),
                  let role = values[0] as? String else { return nil }
            #if DEBUG
            traceNode += " role=\(role)"
            #endif
            guard depth == 0 || containers.contains(role) || role == kAXMenuRole else { continue }
            guard let id = Self.axWindowID(element, deadline: deadline) else { return nil }
            var remote = inherited
            if let remote {
                guard id == remote.windowID else { return nil }
            } else if id != windowID {
                guard [kAXGroupRole, kAXSplitGroupRole].contains(role), let parent,
                      let owner = Self.windowOwner?(id), owner != pid,
                      let actualParent = Self.axValues(element, [kAXParentAttribute], deadline: deadline)?.first,
                      CFGetTypeID(actualParent) == AXUIElementGetTypeID(), CFEqual(actualParent, parent) else { return nil }
                var proxyPID: pid_t = 0
                guard AXUIElementGetPid(element, &proxyPID) == .success, proxyPID == pid || proxyPID == owner else { return nil }
                // Most keystrokes have no tracking menu. Avoid inspecting the
                // remote contents unless its service has an onscreen popup.
                guard menus.contains(where: { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == owner }) else { continue }
                remote = KeyboardReceiver(pid: owner, windowID: id)
            }
            if role == kAXMenuRole {
                guard popupChild, let remote,
                      let bounds = Self.axValues(element, [kAXPositionAttribute, kAXSizeAttribute], deadline: deadline),
                      let frame = Self.rect(bounds[0], bounds[1]) else { return nil }
                let matches = menus.compactMap { window -> WindowInputTarget? in
                    guard let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                          let target = DesktopInputTarget.target(windowID: id, windows: [window]),
                          target.pid == remote.pid, target.frame(in: [window]) == frame else { return nil }
                    return target
                }
                guard result == nil, matches.count == 1, let menu = matches.first else { return nil }
                result = KeyboardReceiver(pid: menu.pid, windowID: menu.windowID, windowFrame: frame)
            } else {
                guard depth < 8 else { return nil }
                pending += ((values[1] as? [AXUIElement]) ?? []).map { ($0, element, depth + 1, remote, role == kAXPopUpButtonRole) }
            }
        }
        return pending.isEmpty ? result : nil
    }
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
    @discardableResult func post(_ event: CGEvent, permitted: @escaping () -> Bool, hover: Bool = false, activating: Bool = false, delivery: Delivery = .system) -> InputOutcome {
        // A point inside a window does not move with the window. Address the
        // event with the geometry the user aimed at, even if activation moves it.
        guard permitted() else { return .cancelled }
        guard let frame = delivery.frame(self), address(event, frame: frame) else { return .frameGone }
        let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
        if activating && down {
            let activated = activateForDesktopClick(at: event.location, if: permitted)
            Self.traceHostedMenu("activated outer=\(pid):\(windowID) result=\(activated) frame=\(String(describing: self.frame))")
            guard permitted() else { return .cancelled }
        }
        var primed = false
        // An active app needs no synthetic activation. An open menu or popover is
        // already tracking, and an off-window primer would dismiss it first.
        let backgroundDown = down && delivery.frontmostPID() != pid
        if backgroundDown {
            Self.traceHostedMenu("prepare outer=\(pid):\(windowID) point=\(event.location)")
            delivery.prepare(self)
            Self.traceHostedMenu("prepared outer=\(pid):\(windowID) frame=\(String(describing: self.frame))")
        }
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
        // Activation above can block. Ordinary motion, scrolling
        // and typing already validated this window; another WindowServer round
        // trip here adds latency to every event without intervening work.
        if backgroundDown || activating, delivery.frame(self) == nil { return .frameGone }
        switch event.type {
        case .keyDown, .keyUp, .flagsChanged:
            // AppKit and Chromium perform menu key equivalents only for the
            // active app, so a background app ignores a posted Command-V.
            if event.type == .keyDown, event.flags.contains(.maskCommand), delivery.frontmostPID() != pid,
               let item = delivery.menuItem(self, event) {
                if item.press(if: permitted) { return .menu }
                guard permitted() else { return .cancelled }
            }
            if let receiver = keyboardReceiver {
                if let expected = receiver.windowFrame,
                   WindowInputTarget(pid: receiver.pid, windowID: receiver.windowID).frame != expected { return .frameGone }
                event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(receiver.pid))
                event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(receiver.windowID))
                delivery.key(receiver.pid, event)
                Self.traceHostedMenu("key type=\(event.type.rawValue) outer=\(pid):\(windowID) receiver=\(receiver)")
            } else { delivery.key(pid, event) }
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
    /// Native buttons and menu items can track the real pointer and cancel a synthetic
    /// background click. Their standard Press action does not need that pointer.
    /// Foreign-app AX runs on the input queue. Same-process AX calls bypass IPC,
    /// so inspect our own AppKit/SwiftUI views on their main thread.
    func button(at point: CGPoint, includingDisabledMenuItems: Bool = false, excluding: Set<CGWindowID> = []) -> Button? {
        if pid == ProcessInfo.processInfo.processIdentifier && !Thread.isMainThread {
            return Self.onMainRunLoop { self.button(at: point, includingDisabledMenuItems: includingDisabledMenuItems, excluding: excluding) }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        guard let frame, frame.contains(point), let hit = element(at: point, deadline: deadline) else {
            Self.traceHostedMenu("button-hit-miss outer=\(pid):\(windowID) point=\(point) elapsedMs=\((0.05 - deadline + ProcessInfo.processInfo.systemUptime) * 1000)")
            return nil
        }
        let result = button(climbingFrom: hit, at: point, deadline: deadline, includingDisabledMenuItems: includingDisabledMenuItems, excluding: excluding) ??
            button(inHitContainer: hit, at: point, deadline: deadline)
        Self.traceHostedMenu("button outer=\(pid):\(windowID) point=\(point) found=\(result != nil) menuItem=\(result?.isMenuItem ?? false) frame=\(String(describing: result?.frame)) elapsedMs=\((0.05 - deadline + ProcessInfo.processInfo.systemUptime) * 1000)")
        return result
    }
    /// Save panels bridge a separate process. Their app-scoped hit test can stop
    /// at the sheet, and their proxy buttons omit AXTopLevelUIElement entirely.
    static func axValues(_ element: AXUIElement, _ names: [String], deadline: TimeInterval) -> [AnyObject]? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(remaining))
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw) == .success,
              let values = raw as? [AnyObject], values.count == names.count else { return nil }
        return values
    }
    static func axWindowID(_ element: AXUIElement, deadline: TimeInterval) -> CGWindowID? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, let windowNumber else { return nil }
        AXUIElementSetMessagingTimeout(element, Float(remaining))
        var id: CGWindowID = 0
        return windowNumber(element, &id) == .success && id > 0 ? id : nil
    }
    static func singleContainingChild(_ children: [AXUIElement], at point: CGPoint, deadline: TimeInterval) -> AXUIElement? {
        var result: AXUIElement?
        for child in children {
            guard let values = axValues(child, [kAXPositionAttribute, kAXSizeAttribute], deadline: deadline),
                  let bounds = rect(values[0], values[1]) else { return nil }
            if bounds.contains(point) {
                guard result == nil else { return nil }
                result = child
            }
        }
        return result
    }
    private func button(inHitContainer hit: AXUIElement, at point: CGPoint, deadline: TimeInterval) -> Button? {
        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute]
        guard let values = Self.axValues(hit, names, deadline: deadline), let role = values[0] as? String,
              Self.axWindowID(hit, deadline: deadline) == windowID,
              let hitBounds = Self.rect(values[1], values[2]), hitBounds.contains(point) else { return nil }
        var root = hit, remoteWindow: CGWindowID?
        if role != kAXSheetRole {
            // A remote view's hit test can stop at its host group or window.
            // Descend only through its one containing, directly linked XPC
            // root. Ordinary host containers and ambiguous overlays stay closed.
            guard [kAXWindowRole, kAXGroupRole].contains(role),
                  let children = values[3] as? [AXUIElement],
                  let child = Self.singleContainingChild(children, at: point, deadline: deadline),
                  let childValues = Self.axValues(child, [kAXRoleAttribute, kAXParentAttribute], deadline: deadline),
                  [kAXGroupRole, kAXSplitGroupRole].contains(childValues[0] as? String ?? ""),
                  let id = Self.axWindowID(child, deadline: deadline), id != windowID,
                  let owner = Self.windowOwner?(id), owner != pid,
                  CFGetTypeID(childValues[1]) == AXUIElementGetTypeID(),
                  CFEqual(childValues[1], hit) else { return nil }
            var childPID: pid_t = 0
            guard AXUIElementGetPid(child, &childPID) == .success, childPID == pid || childPID == owner else { return nil }
            root = child; remoteWindow = id
        }
        let rootChildren = (values[3] as? [AXUIElement]) ?? []
        var pending = [(root, 0)], visited = 0, result: Button?
        while let (element, depth) = pending.popLast(), visited < 64 {
            visited += 1
            guard let values = Self.axValues(element, names, deadline: deadline) else { return nil }
            guard let bounds = Self.rect(values[1], values[2]), bounds.contains(point) else { continue }
            if let remoteWindow, Self.axWindowID(element, deadline: deadline) != remoteWindow { return nil }
            var hostedPopup = false
            if values[0] as? String == kAXPopUpButtonRole {
                let popupWindow = remoteWindow ?? (role == kAXSheetRole ?
                    remoteKeyboardReceiver(children: rootChildren, deadline: deadline)?.windowID : nil)
                hostedPopup = popupWindow != nil && Self.axWindowID(element, deadline: deadline) == popupWindow
            }
            if values[0] as? String == kAXButtonRole || hostedPopup {
                guard result == nil, let button = button(climbingFrom: element, at: point, deadline: deadline,
                                                        includingHostedPopup: hostedPopup) else { return nil }
                result = button
            } else {
                // An uninspectable containing branch may cover a sibling button.
                guard depth < 8, depth == 0 || ![kAXSheetRole, kAXWindowRole].contains(values[0] as? String ?? "") else { return nil }
                let children = (values[3] as? [AXUIElement]) ?? []
                if remoteWindow != nil {
                    guard let child = Self.singleContainingChild(children, at: point, deadline: deadline) else { return nil }
                    pending.append((child, depth + 1))
                } else { pending += children.map { ($0, depth + 1) } }
            }
        }
        return pending.isEmpty ? result : nil
    }
    /// Stop at the nearest sheet/window. A parent document cannot authorize an
    /// action in a child sheet, even when a remote-view proxy has no top-level ID.
    private func ownsButton(_ element: AXUIElement, topLevel: AnyObject, deadline: TimeInterval) -> Bool {
        if CFGetTypeID(topLevel) == AXUIElementGetTypeID() {
            return Self.axWindowID(topLevel as! AXUIElement, deadline: deadline) == windowID
        }
        var current = element
        for _ in 0..<8 {
            guard let values = Self.axValues(current, [kAXRoleAttribute, kAXParentAttribute], deadline: deadline) else { return false }
            if let role = values[0] as? String, [kAXSheetRole, kAXWindowRole].contains(role) {
                return Self.axWindowID(current, deadline: deadline) == windowID
            }
            guard CFGetTypeID(values[1]) == AXUIElementGetTypeID() else { return false }
            current = values[1] as! AXUIElement
        }
        return false
    }
    /// The app's own hit test returns the topmost element, so sheets, overlays and
    /// web modals win over the controls they cover, whatever their tree order.
    private func element(at point: CGPoint, deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 0.05) -> AXUIElement? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(remaining))
        var hit: AXUIElement?
        return AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success ? hit : nil
    }
    /// AppKit's menu items can retain their parent document's AX window ID
    /// after WindowServer creates a separate menu window. Accept only the hit
    /// menu's exact geometry and process, never another overlapping window.
    private func ownsMenuItem(_ item: AXUIElement, at point: CGPoint, deadline: TimeInterval, excluding: Set<CGWindowID>) -> Bool {
        // A supplied/stale AX item cannot authorize a different window that now
        // covers the menu, even if that window has the same owner and bounds.
        guard var hit = element(at: point, deadline: deadline) else { return false }
        for _ in 0..<4 {
            if CFEqual(hit, item) { break }
            guard let parent = Self.axValues(hit, [kAXParentAttribute], deadline: deadline)?.first,
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            hit = parent as! AXUIElement
        }
        guard CFEqual(hit, item) else { return false }
        var element = item
        for _ in 0..<4 {
            guard let values = Self.axValues(element, [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXParentAttribute], deadline: deadline) else { return false }
            if values[0] as? String == kAXMenuRole {
                var owner: pid_t = 0
                guard AXUIElementGetPid(element, &owner) == .success, owner == pid,
                      let menuFrame = Self.rect(values[1], values[2]), menuFrame.contains(point),
                      frame == menuFrame, ProcessInfo.processInfo.systemUptime < deadline else { return false }
                return DesktopInputTarget.target(at: point, excluding: excluding) == self
            }
            guard CFGetTypeID(values[3]) == AXUIElementGetTypeID() else { return false }
            element = values[3] as! AXUIElement
        }
        return false
    }
    /// The hit may be a title or image inside a button or menu item. Climb a few
    /// parents to an enabled control of this window; otherwise use ordinary events.
    func button(climbingFrom hit: AXUIElement, at point: CGPoint, deadline: TimeInterval = ProcessInfo.processInfo.systemUptime + 0.05,
                includingDisabledMenuItems: Bool = false, excluding: Set<CGWindowID> = [], includingHostedPopup: Bool = false) -> Button? {
        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute, kAXTopLevelUIElementAttribute, kAXParentAttribute]
        var element = hit
        for _ in 0...3 {
            guard let values = Self.axValues(element, names, deadline: deadline) else { return nil }
            // AXWindow deliberately returns a sheet's parent document. The top
            // level element preserves the sheet's own WindowServer address.
            let isMenuItem = values[0] as? String == kAXMenuItemRole
            let enabled = values[3] as? Bool == true
            if [kAXButtonRole, kAXMenuItemRole].contains(values[0] as? String ?? "") ||
                includingHostedPopup && values[0] as? String == kAXPopUpButtonRole,
               enabled || isMenuItem && includingDisabledMenuItems,
               let bounds = Self.rect(values[1], values[2]), bounds.contains(point) {
                var actions: CFArray?
                guard ownsButton(element, topLevel: values[4], deadline: deadline) ||
                        values[0] as? String == kAXMenuItemRole && ownsMenuItem(element, at: point, deadline: deadline, excluding: excluding) else { return nil }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return nil }
                AXUIElementSetMessagingTimeout(element, Float(remaining))
                if enabled {
                    guard AXUIElementCopyActionNames(element, &actions) == .success,
                          (actions as? [String])?.contains(kAXPressAction) == true else { return nil }
                }
                let pressed = element
                var menuDocumentWindowID: CGWindowID?
                if isMenuItem, CFGetTypeID(values[4]) == AXUIElementGetTypeID() {
                    let topLevel = values[4] as! AXUIElement
                    var owner: pid_t = 0
                    if AXUIElementGetPid(topLevel, &owner) == .success, owner == pid {
                        menuDocumentWindowID = Self.axWindowID(topLevel, deadline: deadline)
                    }
                }
                return Button(frame: bounds, requiresMainThread: pid == ProcessInfo.processInfo.processIdentifier,
                              isMenuItem: isMenuItem, menuDocumentWindowID: menuDocumentWindowID, action: {
                    // Disabled menu taps keep their document provenance but must
                    // never issue AXPress or fall through to pointer delivery.
                    guard enabled else { return false }
                    AXUIElementSetMessagingTimeout(pressed, 0.25)
                    let result = AXUIElementPerformAction(pressed, kAXPressAction as CFString)
                    Self.traceHostedMenu("press outer=\(self.pid):\(self.windowID) menuItem=\(isMenuItem) result=\(result.rawValue)")
                    // Closing an XPC save panel can tear down its reply channel.
                    // The action was submitted; never replay a pointer click.
                    return result == .success || result == .cannotComplete
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
            return Self.onMainRunLoop { self.menuItem(for: event, budget: budget) }
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
            return Self.onMainRunLoop { self.isTransient(at: point) }
        }
        if let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
           let window = windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID }),
           ((window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) > 0 { return true }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        var element = element(at: point, deadline: deadline)
        for _ in 0..<8 {
            guard let current = element,
                  let values = Self.axValues(current, [kAXRoleAttribute, kAXParentAttribute], deadline: deadline) else { return false }
            if let role = values[0] as? String, [kAXMenuRole, "AXPopover"].contains(role) { return true }
            element = CFGetTypeID(values[1]) == AXUIElementGetTypeID() ? (values[1] as! AXUIElement) : nil
        }
        return false
    }
}
