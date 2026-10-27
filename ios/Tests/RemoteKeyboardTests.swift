import XCTest
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
}
