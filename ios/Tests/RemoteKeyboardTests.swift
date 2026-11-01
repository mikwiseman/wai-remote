import XCTest
import RemoteCore
@testable import WAI_Remote

final class RemoteKeyboardTests: XCTestCase {
    private func code(_ character: Character) -> String? {
        KeyCatcher.code(for: character).map { $0.1 ? "⇧" + $0.0 : $0.0 }
    }

    func testShortcutsUseThePhysicalKey() {
        XCTAssertEqual(code("c"), "KeyC")
        XCTAssertEqual(code("C"), "⇧KeyC")
        XCTAssertEqual(code("5"), "Digit5")
        XCTAssertEqual(code(" "), "Space")
        XCTAssertEqual(code("/"), "Slash")
        XCTAssertEqual(code("`"), "Backquote")
    }

    func testRussianLettersMapThroughTheStandardLayout() {
        XCTAssertEqual(code("с"), "KeyC")
        XCTAssertEqual(code("м"), "KeyV")
        XCTAssertEqual(code("я"), "KeyZ")
        XCTAssertEqual(code("Ф"), "⇧KeyA")
        XCTAssertEqual(code("х"), "BracketLeft")
        XCTAssertEqual(code("ж"), "Semicolon")
        XCTAssertEqual(code("ё"), "Backquote")
    }

    func testCharactersWithoutAKeyAreTypedAsText() {
        XCTAssertNil(code("é"))
        XCTAssertNil(code("!"))
        XCTAssertNil(code("١"))
    }

    @MainActor
    func testTypingSendsEachCharacterBeforeReturningWithoutWaitingForHost() {
        let model = PhoneModel()
        let host = SessionMachine(surface: Surface(id: "keyboard", revision: 1, width: 1920, height: 1080))
        model.acceptDemo(host.state)
        model.connected = true; model.receivedFrame = true
        var sent: [WireMessage] = []
        model.onTransmitForTesting = { sent.append($0) }
        let keyboard = KeyCatcher(model: model, modifiers: KeyboardModifiers())
        let text = ["a", "Я", "👨‍👩‍👧‍👦", "é"]
        for (index, character) in text.enumerated() {
            keyboard.insertText(character)
            XCTAssertEqual(sent.count, index + 1, "Typing must not wait for a timer or acknowledgement")
            XCTAssertEqual(sent.last?.text, character)
        }
        XCTAssertEqual(sent.map(\.type), Array(repeating: "text", count: text.count))
        XCTAssertEqual(sent.map(\.sequence), Array(0..<text.count))
    }

    @MainActor
    func testTypingBackspaceAndReturnKeepTheirOrder() {
        let model = PhoneModel()
        model.acceptDemo(SessionMachine(surface: Surface(id: "keyboard", revision: 1, width: 1920, height: 1080)).state)
        model.connected = true; model.receivedFrame = true
        var sent: [WireMessage] = []
        model.onTransmitForTesting = { sent.append($0) }
        let keyboard = KeyCatcher(model: model, modifiers: KeyboardModifiers())
        keyboard.insertText("a")
        keyboard.deleteBackward()
        keyboard.insertText("б")
        keyboard.insertText("\n")
        XCTAssertEqual(sent.map(\.type), ["text", "key", "key", "text", "key", "key"])
        XCTAssertEqual(sent.compactMap(\.text), ["a", "б"])
        XCTAssertEqual(sent.compactMap(\.key), ["Backspace", "Backspace", "Enter", "Enter"])
        XCTAssertEqual(sent.compactMap(\.action), ["down", "up", "down", "up"])
    }
}
