import AppKit
import RemoteCore

final class InputInjector {
    private var buttons = Set<Int>()
    private var keys = Set<CGKeyCode>()
    private var lastPoint = CGPoint.zero
    private var clickSequence = ClickSequence()
    private var clickCounts: [Int: Int] = [:]
    private let source = CGEventSource(stateID: .privateState)
    var bounds = CGDisplayBounds(CGMainDisplayID())
    var allowed: Bool { CGPreflightPostEventAccess() }
    private func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: 0x574149)
        event?.post(tap: .cghidEventTap)
    }
    func apply(_ m: WireMessage) {
        guard allowed else { releaseAll(); return }
        if m.type == "pointer", let x = m.x, let y = m.y, let action = m.action {
            let p = CGPoint(x: bounds.minX + x * max(1, bounds.width - 1), y: bounds.minY + y * max(1, bounds.height - 1))
            lastPoint = p
            let b = m.button ?? buttons.sorted().first ?? 0
            let button: CGMouseButton = b == 2 ? .right : b == 1 ? .center : .left
            let down: CGEventType = b == 2 ? .rightMouseDown : b == 1 ? .otherMouseDown : .leftMouseDown
            let up: CGEventType = b == 2 ? .rightMouseUp : b == 1 ? .otherMouseUp : .leftMouseUp
            let drag: CGEventType = b == 2 ? .rightMouseDragged : b == 1 ? .otherMouseDragged : .leftMouseDragged
            if action == "scroll" {
                let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                    wheel1: Int32(-(m.deltaY ?? 0)), wheel2: Int32(-(m.deltaX ?? 0)), wheel3: 0)
                event?.location = p; post(event)
            } else {
                if action == "down" {
                    guard !buttons.contains(b) else { return }
                    buttons.insert(b)
                    clickCounts[b] = clickSequence.down(x: p.x, y: p.y, button: b,
                        now: ProcessInfo.processInfo.systemUptime, interval: NSEvent.doubleClickInterval)
                }
                if action == "up" && !buttons.contains(b) { return }
                let type: CGEventType = action == "down" ? down : action == "up" ? up : buttons.isEmpty ? .mouseMoved : drag
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCounts[b] ?? 0))
                post(event)
                if action == "up" { buttons.remove(b); clickCounts[b] = nil }
                if action == "move" && !buttons.isEmpty { clickSequence.reset() }
            }
        } else if m.type == "key", let code = Self.keyCodes[m.key ?? ""] {
            let down = m.action == "down"
            if !down && !keys.contains(code) { return }
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = Self.flags(m.modifiers ?? [])
            if down { keys.insert(code) } else { keys.remove(code) }
            post(event)
        } else if m.type == "text", let text = m.text {
            // Chunk on Character boundaries; never split a surrogate pair or composed character.
            var chunk = [UniChar]()
            func flush() {
                guard !chunk.isEmpty else { return }
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.flags = []; event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk); post(event)
                }
                chunk.removeAll(keepingCapacity: true)
            }
            for character in text { let units = Array(String(character).utf16); if chunk.count + units.count > 20 { flush() }; chunk += units }
            flush()
        }
    }
    func releaseAll() {
        for b in buttons {
            let type: CGEventType = b == 2 ? .rightMouseUp : b == 1 ? .otherMouseUp : .leftMouseUp
            post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastPoint,
                         mouseButton: b == 2 ? .right : b == 1 ? .center : .left))
        }
        for code in keys { let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false); event?.flags = []; post(event) }
        buttons.removeAll(); keys.removeAll(); clickCounts.removeAll(); clickSequence.reset()
    }
    private static func flags(_ modifiers: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in modifiers { switch m { case "Meta": f.insert(.maskCommand); case "Control": f.insert(.maskControl); case "Alt": f.insert(.maskAlternate); case "Shift": f.insert(.maskShift); default: break } }
        return f
    }
    // DOM KeyboardEvent.code is physical. Printable/IME text uses the separate Unicode path.
    static let keyCodes: [String: CGKeyCode] = [
        "KeyA":0,"KeyS":1,"KeyD":2,"KeyF":3,"KeyH":4,"KeyG":5,"KeyZ":6,"KeyX":7,"KeyC":8,"KeyV":9,"KeyB":11,
        "KeyQ":12,"KeyW":13,"KeyE":14,"KeyR":15,"KeyY":16,"KeyT":17,"Digit1":18,"Digit2":19,"Digit3":20,"Digit4":21,
        "Digit6":22,"Digit5":23,"Equal":24,"Digit9":25,"Digit7":26,"Minus":27,"Digit8":28,"Digit0":29,"BracketRight":30,
        "KeyO":31,"KeyU":32,"BracketLeft":33,"KeyI":34,"KeyP":35,"Enter":36,"KeyL":37,"KeyJ":38,"Quote":39,"KeyK":40,
        "Semicolon":41,"Backslash":42,"Comma":43,"Slash":44,"KeyN":45,"KeyM":46,"Period":47,"Tab":48,"Space":49,
        "Backquote":50,"Backspace":51,"Escape":53,"MetaRight":54,"MetaLeft":55,"ShiftLeft":56,"AltLeft":58,"ControlLeft":59,
        "ShiftRight":60,"AltRight":61,"ControlRight":62,"F5":96,"F6":97,"F7":98,"F3":99,"F8":100,"F9":101,"F11":103,
        "F10":109,"F12":111,"Home":115,"PageUp":116,"Delete":117,"F4":118,"End":119,"F2":120,"PageDown":121,
        "F1":122,"ArrowLeft":123,"ArrowRight":124,"ArrowDown":125,"ArrowUp":126]
}
