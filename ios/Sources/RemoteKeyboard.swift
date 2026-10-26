import SwiftUI
import UIKit

/// The system keyboard types straight into the Mac: no field, no send button.
/// A bar above it adds the keys a phone keyboard lacks; modifiers apply to the next key.
struct RemoteKeyboard: UIViewRepresentable {
    @ObservedObject var model: PhoneModel
    @Binding var active: Bool

    func makeUIView(context: Context) -> KeyCatcher {
        let view = KeyCatcher(model: model)
        view.onResign = { DispatchQueue.main.async { active = false } }
        return view
    }
    func updateUIView(_ view: KeyCatcher, context: Context) {
        view.onResign = { DispatchQueue.main.async { active = false } }
        if active, !view.isFirstResponder { DispatchQueue.main.async { _ = view.becomeFirstResponder() } }
        if !active, view.isFirstResponder { _ = view.resignFirstResponder() }
    }
}

final class KeyboardModifiers: ObservableObject {
    @Published var held: Set<String> = []
    func toggle(_ modifier: String) { if held.remove(modifier) == nil { held.insert(modifier) } }
}

final class KeyCatcher: UIView, UIKeyInput {
    private let model: PhoneModel
    private let modifiers = KeyboardModifiers()
    private lazy var bar: UIView = {
        let host = UIHostingController(rootView: KeyboardBar(modifiers: modifiers, send: { [weak self] key in self?.press(key) },
                                                             hide: { [weak self] in _ = self?.resignFirstResponder() }))
        host.view.backgroundColor = .clear
        host.sizingOptions = .intrinsicContentSize
        host.view.frame = CGRect(x: 0, y: 0, width: 0, height: 60)
        host.view.autoresizingMask = .flexibleWidth
        barHost = host
        return host.view
    }()
    private var barHost: UIViewController?
    var onResign: () -> Void = {}

    init(model: PhoneModel) { self.model = model; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { bar }
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
        let held = modifiers.held
        if text == "\n" { press("Enter"); return }
        if text == "\t" { press("Tab"); return }
        if !held.subtracting(["Shift"]).isEmpty, text.count == 1, let (code, shifted) = Self.code(for: text.first!) {
            model.key(code, modifiers: Self.order(held.union(shifted ? ["Shift"] : [])))
        } else {
            model.text(text)
        }
        modifiers.held = []
    }
    func deleteBackward() { press("Backspace") }
    private func press(_ key: String) {
        model.key(key, modifiers: Self.order(modifiers.held))
        modifiers.held = []
    }
    private static func order(_ held: Set<String>) -> [String] { ["Meta", "Alt", "Control", "Shift"].filter(held.contains) }

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

private struct KeyboardBar: View {
    @ObservedObject var modifiers: KeyboardModifiers
    let send: (String) -> Void
    let hide: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                GlassGroup(spacing: 6) {
                    HStack(spacing: 6) {
                        key("esc", "Escape")
                        key("tab", "Tab")
                        modifier("⌘", "Meta", "Command")
                        modifier("⌥", "Alt", "Option")
                        modifier("⌃", "Control", "Control")
                        modifier("⇧", "Shift", "Shift")
                        key("←", "ArrowLeft"); key("↑", "ArrowUp"); key("↓", "ArrowDown"); key("→", "ArrowRight")
                    }
                    .padding(.horizontal, 10)
                }
            }
            .scrollClipDisabled()
            Button(action: hide) {
                Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 40).glass(in: Capsule(), interactive: true)
            }
            .buttonStyle(.plain).padding(.trailing, 10).accessibilityLabel("Скрыть клавиатуру")
        }
        .frame(height: 60)
        .tint(Brand.mint)
        .sensoryFeedback(.selection, trigger: modifiers.held)
    }

    private func key(_ title: String, _ code: String) -> some View {
        Button { send(code) } label: { label(title, selected: false) }
            .buttonStyle(.plain).accessibilityLabel(code == "Escape" ? "Escape" : title)
    }
    private func modifier(_ title: String, _ code: String, _ name: String) -> some View {
        let selected = modifiers.held.contains(code)
        return Button { modifiers.toggle(code) } label: { label(title, selected: selected) }
            .buttonStyle(.plain).accessibilityLabel(name).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func label(_ title: String, selected: Bool) -> some View {
        Text(title).font(.system(size: 16, weight: .semibold, design: .rounded))
            .foregroundStyle(selected ? Brand.forest : .primary)
            .frame(minWidth: 44).frame(height: 40).padding(.horizontal, 2)
            .background { if selected { Capsule().fill(Brand.mint) } }
            .glass(in: Capsule(), interactive: true)
            .contentShape(Capsule())
    }
}
