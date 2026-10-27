import SwiftUI
import UIKit

/// The system keyboard types straight into the Mac: no field, no send button.
/// The session shows `KeyboardBar` above it for the keys a phone keyboard lacks; modifiers apply to the next key.
struct RemoteKeyboard: UIViewRepresentable {
    @ObservedObject var model: PhoneModel
    let modifiers: KeyboardModifiers
    @Binding var active: Bool

    func makeUIView(context: Context) -> KeyCatcher { KeyCatcher(model: model, modifiers: modifiers) }
    func updateUIView(_ view: KeyCatcher, context: Context) {
        view.onResign = { DispatchQueue.main.async { active = false } }
        if active, !view.isFirstResponder { DispatchQueue.main.async { _ = view.becomeFirstResponder() } }
        if !active, view.isFirstResponder { _ = view.resignFirstResponder() }
    }
}

final class KeyboardModifiers: ObservableObject {
    @Published var held: Set<String> = []
    func toggle(_ modifier: String) { if held.remove(modifier) == nil { held.insert(modifier) } }
    /// The held modifiers in the Mac's order, released by the key they apply to.
    func take(adding extra: Set<String> = []) -> [String] {
        defer { if !held.isEmpty { held = [] } }
        return ["Meta", "Alt", "Control", "Shift"].filter(held.union(extra).contains)
    }
}

final class KeyCatcher: UIView, UIKeyInput {
    private let model: PhoneModel
    private let modifiers: KeyboardModifiers
    var onResign: () -> Void = {}

    init(model: PhoneModel, modifiers: KeyboardModifiers) { self.model = model; self.modifiers = modifiers; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { modifiers.held = []; onResign() }
        return resigned
    }

    // Typing goes out as it happens; the Mac's own field shows the result.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" { press("Enter"); return }
        if text == "\t" { press("Tab"); return }
        if !modifiers.held.subtracting(["Shift"]).isEmpty, text.count == 1, let (code, shifted) = Self.code(for: text.first!) {
            model.key(code, modifiers: modifiers.take(adding: shifted ? ["Shift"] : []))
        } else {
            model.text(text); _ = modifiers.take()
        }
    }
    func deleteBackward() { press("Backspace") }
    private func press(_ key: String) { model.key(key, modifiers: modifiers.take()) }

    /// A shortcut needs the physical key. Russian letters map through the standard ЙЦУКЕН layout.
    static func code(for character: Character) -> (String, Bool)? {
        let lower = Character(character.lowercased())
        let shifted = lower != character
        if let ascii = lower.asciiValue, (97...122).contains(ascii) { return ("Key" + String(lower).uppercased(), shifted) }
        if let digit = lower.wholeNumberValue, lower.isASCII { return ("Digit\(digit)", false) }
        let punctuation: [Character: String] = [" ": "Space", "-": "Minus", "=": "Equal", "[": "BracketLeft", "]": "BracketRight",
            ";": "Semicolon", "'": "Quote", ",": "Comma", ".": "Period", "/": "Slash", "\\": "Backslash", "`": "Backquote"]
        if let code = punctuation[lower] { return (code, false) }
        let cyrillic: [Character: String] = ["й": "KeyQ", "ц": "KeyW", "у": "KeyE", "к": "KeyR", "е": "KeyT", "н": "KeyY",
            "г": "KeyU", "ш": "KeyI", "щ": "KeyO", "з": "KeyP", "х": "BracketLeft", "ъ": "BracketRight", "ф": "KeyA",
            "ы": "KeyS", "в": "KeyD", "а": "KeyF", "п": "KeyG", "р": "KeyH", "о": "KeyJ", "л": "KeyK", "д": "KeyL",
            "ж": "Semicolon", "э": "Quote", "я": "KeyZ", "ч": "KeyX", "с": "KeyC", "м": "KeyV", "и": "KeyB", "т": "KeyN",
            "ь": "KeyM", "б": "Comma", "ю": "Period", "ё": "Backquote"]
        return cyrillic[lower].map { ($0, shifted) }
    }
}

/// One glass strip of keys the phone keyboard lacks, sized like its keys so all of them fit, and a button to put it away.
struct KeyboardBar: View {
    @ObservedObject var model: PhoneModel
    @ObservedObject var modifiers: KeyboardModifiers
    let hide: () -> Void

    var body: some View {
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    key("esc", "Escape", "Escape")
                    key("tab", "Tab", "Tab")
                    modifier("⌘", "Meta", "Command")
                    modifier("⌥", "Alt", "Option")
                    modifier("⌃", "Control", "Control")
                    modifier("⇧", "Shift", "Shift")
                    key("←", "ArrowLeft", "Влево"); key("↑", "ArrowUp", "Вверх"); key("↓", "ArrowDown", "Вниз"); key("→", "ArrowRight", "Вправо")
                }
                .padding(.horizontal, 6)
                .glass(in: Capsule(), interactive: true)
                Button(action: hide) {
                    Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44).contentShape(Circle())
                        .glass(in: Circle(), interactive: true)
                }
                .buttonStyle(.plain).accessibilityLabel("Скрыть клавиатуру")
            }
        }
        .padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 56)
        .sensoryFeedback(.selection, trigger: modifiers.held)
    }

    private func key(_ title: String, _ code: String, _ name: String) -> some View {
        Button { model.key(code, modifiers: modifiers.take()) } label: { label(title, selected: false) }
            .buttonStyle(.plain).accessibilityLabel(name)
            .accessibilityShowsLargeContentViewer { Text(title) }
    }
    private func modifier(_ title: String, _ code: String, _ name: String) -> some View {
        let selected = modifiers.held.contains(code)
        return Button { modifiers.toggle(code) } label: { label(title, selected: selected) }
            .buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityShowsLargeContentViewer { Text(title) }
    }
    private func label(_ title: String, selected: Bool) -> some View {
        Text(title).font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(selected ? Brand.forest : .primary)
            .frame(minWidth: 28, maxWidth: 40, minHeight: 36)
            .background { if selected { Capsule().fill(Brand.mint) } }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
    }
}
