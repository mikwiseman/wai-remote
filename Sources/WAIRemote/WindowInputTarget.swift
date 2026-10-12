import AppKit
import Darwin

/// Window addressing follows KWWKComputerUseCore and cua-driver (MIT).
/// See licenses/KWWK.txt and licenses/cua-driver.txt. No global-input fallback.
struct WindowInputTarget: Equatable {
    let pid: pid_t
    let windowID: CGWindowID
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
}
