import XCTest
import UIKit
@testable import WAI_Remote

@MainActor
final class RemoteKeyboardResignTests: XCTestCase {
    private func makeKeyboard() -> (KeyCatcher, KeyboardModifiers, UIWindow) {
        let modifiers = KeyboardModifiers()
        let keyboard = KeyCatcher(model: PhoneModel(), modifiers: modifiers)
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            .map(UIWindow.init(windowScene:)) ?? UIWindow(frame: UIScreen.main.bounds)
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        keyboard.frame = CGRect(x: 10, y: 10, width: 20, height: 20)
        controller.view.addSubview(keyboard)
        XCTAssertTrue(keyboard.becomeFirstResponder())
        XCTAssertTrue(keyboard.isFirstResponder)
        return (keyboard, modifiers, window)
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testResignDefersPublishedChangesAndNotification() async {
        let (keyboard, modifiers, window) = makeKeyboard()
        defer { window.isHidden = true }
        modifiers.held = ["Shift"]
        var notifications = 0
        keyboard.onResign = { notifications += 1 }

        XCTAssertTrue(keyboard.resignFirstResponder())
        XCTAssertEqual(modifiers.held, ["Shift"], "updateUIView can resign; publishing here is a SwiftUI runtime violation.")
        XCTAssertEqual(notifications, 0)
        await nextMainTurn()
        XCTAssertTrue(modifiers.held.isEmpty)
        XCTAssertEqual(notifications, 1)
    }

    func testReopeningBeforeResignCallbackKeepsKeyboardAndNewModifiers() async {
        let (keyboard, modifiers, window) = makeKeyboard()
        defer { window.isHidden = true }
        var active = true
        keyboard.onResign = { active = false }

        XCTAssertTrue(keyboard.resignFirstResponder())
        XCTAssertTrue(keyboard.becomeFirstResponder())
        modifiers.held = ["Meta"]
        await nextMainTurn()
        XCTAssertTrue(keyboard.isFirstResponder)
        XCTAssertTrue(active, "An old resignation must not hide a reopened keyboard.")
        XCTAssertEqual(modifiers.held, ["Meta"], "An old resignation must not clear the new keyboard's modifiers.")
    }
}
