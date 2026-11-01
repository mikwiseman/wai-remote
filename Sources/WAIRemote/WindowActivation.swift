import AppKit

extension WindowInputTarget {
    /// Full-desktop clicks behave like ordinary Mac clicks, while event delivery
    /// retains the independent cursor and the selected window. Window grants do
    /// not call this path and keep their background input behavior.
    @discardableResult func activateForDesktopClick(at point: CGPoint, if current: @escaping () -> Bool) -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier && !Thread.isMainThread {
            return Self.onMainRunLoop { self.activateForDesktopClick(at: point, if: current) }
        }
        guard current(), frame != nil else { return false }
        // Re-raising an active window can dismiss its tracking menu before the
        // clicked item receives input. It already has the intended activation.
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        traceInput("activate frontmost=\(frontmost ?? 0) ownActive=\(NSApp.isActive)")
        if frontmost == pid, isTransient(at: point) { traceInput("activate skipped-transient"); return current() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.05
        let app = AXUIElementCreateApplication(pid)
        guard let windows = Self.axValues(app, [kAXWindowsAttribute], deadline: deadline)?.first as? [AXUIElement] else { return false }
        var pending = windows.map { (element: $0, window: $0) }, visited = 0
        while let (element, window) = pending.popLast(), visited < 64 {
            visited += 1
            if Self.axWindowID(element, deadline: deadline) == windowID {
                guard current(), frame != nil, let application = NSRunningApplication(processIdentifier: pid) else { return false }
                // Choose the clicked document before activation. No "all windows"
                // option: other documents are not deliberately brought forward.
                AXUIElementSetMessagingTimeout(window, 0.05)
                _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                guard current(), frame != nil else { return false }
                traceInput("activate requested")
                let activated = application.activate(options: [])
                guard current(), frame != nil else { return false }
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                if pid == ProcessInfo.processInfo.processIdentifier, current(), frame != nil {
                    NSApp.windows.first { CGWindowID($0.windowNumber) == windowID }?.orderFrontRegardless()
                }
                traceInput("activate raised result=\(activated)")
                return activated
            }
            guard let children = Self.axValues(element, [kAXChildrenAttribute], deadline: deadline)?.first as? [AXUIElement] else { continue }
            for child in children where Self.axValues(child, [kAXRoleAttribute], deadline: deadline)?.first as? String == kAXSheetRole {
                pending.append((child, window))
            }
        }
        return false
    }
}
