import XCTest
import UIKit

/// Real system gestures pass through SessionView and its overlays. The debug demo
/// records emitted wire messages; no remote computer or input permission is used.
final class SessionInteractionTests: XCTestCase {
    private var app: XCUIApplication!
    private var output: URL!
    private var trace: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let root = ProcessInfo.processInfo.environment["WAI_IOS_INTERACTION_OUTPUT"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("wai-interaction-qa")
        output = root.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        trace = output.appendingPathComponent("events.jsonl")
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "desktop", withExtension: "png"))
        let readableFixture = root.appendingPathComponent("desktop.png")
        try Data(contentsOf: fixture).write(to: readableFixture, options: .atomic)
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-WAIDemoSession", readableFixture.path, "-WAIDemoEventsPath", trace.path]
        app.launch()
        let keyboard = app.buttons["Клавиатура"]
        XCTAssertTrue(keyboard.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: keyboard)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trace.path))
    }

    override func tearDownWithError() throws { app?.terminate() }

    func testTapsMatchRenderedTargetsAfterPinchAndPan() throws {
        try tapRenderedCenter("fitted")
        app.pinch(withScale: 1.8, velocity: 1)
        XCTAssertTrue(app.buttons["Вписать экран"].waitForExistence(timeout: 3))
        try tapRenderedCenter("pinched")

        let start = try renderedCenter()
        let count = try pointerEvents().count
        coordinate(start).press(forDuration: 0.05, thenDragTo: coordinate(CGPoint(x: start.x + 40, y: start.y + 30)),
                                withVelocity: 500, thenHoldForDuration: 0)
        XCTAssertEqual(try pointerEvents().count, count, "A short single-finger movement pans the zoomed viewport locally.")
        let panned = try renderedCenter()
        XCTAssertGreaterThan(hypot(panned.x - start.x, panned.y - start.y), 20)
        try tapRenderedCenter("panned")

        app.pinch(withScale: 1.8, velocity: 1)
        try tapRenderedCenter("high-zoom")
        let beforeTwoFingerTap = try pointerEvents().count
        app.twoFingerTap()
        XCTAssertEqual(try pointerEvents().count, beforeTwoFingerTap)
        try tapRenderedCenter("after-two-finger-release")

        let beforeFit = try pointerEvents().count
        app.buttons["Вписать экран"].tap()
        XCTAssertEqual(try pointerEvents().count, beforeFit, "The floating Fit control must not click the Mac behind it.")
        try tapRenderedCenter("refitted")
    }

    func testKeyboardAndFloatingControlsDoNotStealOrLeakTaps() throws {
        app.pinch(withScale: 1.8, velocity: 1)
        try tapRenderedCenter("before-keyboard")
        let beforeKeyboard = try pointerEvents().count
        app.buttons["Клавиатура"].tap()
        if app.buttons["Continue"].waitForExistence(timeout: 1) { app.buttons["Continue"].tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try pointerEvents().count, beforeKeyboard)
        _ = try capture("keyboard-visible")
        app.keys["q"].tap(); app.keys["a"].tap()
        _ = try capture("after-software-keys")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Typing on the software keyboard must keep it open.")
        XCTAssertEqual(try events().filter { $0.type == "text" }.compactMap(\.text).joined(), "qa")
        app.buttons["Escape"].tap(); app.buttons["Tab"].tap()
        XCTAssertEqual(try events().filter { $0.type == "key" }.compactMap(\.key), ["Escape", "Escape", "Tab", "Tab"])
        XCTAssertEqual(try events().filter { $0.type == "key" }.compactMap(\.action), ["down", "up", "down", "up"])
        app.buttons["Скрыть клавиатуру"].tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        let hiddenResult = XCTWaiter.wait(for: [hidden], timeout: 3)
        _ = try capture("after-hide")
        XCTAssertEqual(hiddenResult, .completed)
        XCTAssertEqual(try pointerEvents().count, beforeKeyboard)
        try tapRenderedCenter("keyboard-dismissed")

        let beforeMenu = try pointerEvents().count
        let outsideMenu = try renderedCenter()
        app.buttons["Ещё"].tap()
        coordinate(outsideMenu).tap()
        XCTAssertEqual(try pointerEvents().count, beforeMenu, "Dismissing an overlay must not activate the desktop underneath.")
        try tapRenderedCenter("menu-dismissed")
        let beforeMode = try pointerEvents().count
        app.buttons["Рисовать"].tap(); app.buttons["Управлять"].tap()
        XCTAssertEqual(try pointerEvents().count, beforeMode)
        try tapRenderedCenter("control-restored")
    }

    func testHoldDragReleasesAndNextTapStillWorks() throws {
        let center = try renderedCenter()
        let end = CGPoint(x: center.x + 40, y: center.y - 20)
        coordinate(center).press(forDuration: 0.55, thenDragTo: coordinate(end), withVelocity: 500, thenHoldForDuration: 0)
        let drag = try pointerEvents()
        XCTAssertEqual(drag.first?.action, "down")
        XCTAssertEqual(drag.last?.action, "up")
        XCTAssertEqual(drag.filter { $0.action == "down" }.count, 1)
        XCTAssertEqual(drag.filter { $0.action == "up" }.count, 1)
        XCTAssertTrue(drag.contains { $0.action == "move" })
        XCTAssertEqual(try XCTUnwrap(drag.first?.x), 0.5, accuracy: 0.007)
        XCTAssertEqual(try XCTUnwrap(drag.first?.y), 0.5, accuracy: 0.007)
        XCTAssertGreaterThan(try XCTUnwrap(drag.last?.x), 0.58)
        XCTAssertLessThan(try XCTUnwrap(drag.last?.y), 0.44)
        try tapRenderedCenter("after-drag")
    }

    func testOffCenterTapAfterPinchAndPan() throws {
        app.pinch(withScale: 1.8, velocity: 1)
        let center = try renderedCenter()
        coordinate(center).press(forDuration: 0.05,
                                 thenDragTo: coordinate(CGPoint(x: center.x + 40, y: center.y + 30)),
                                 withVelocity: 500, thenHoldForDuration: 0)
        // Panning also brings the 35% marker fully inside the viewport.
        let anchor = try renderedCenter("off-center-panned", fromBottom: 1)
        let before = try pointerEvents().count
        coordinate(anchor).tap()
        let emitted = Array(try pointerEvents().dropFirst(before))
        XCTAssertEqual(emitted.map(\.action), ["down", "up"])
        for event in emitted {
            XCTAssertEqual(try XCTUnwrap(event.x), 0.35, accuracy: 0.007)
            XCTAssertEqual(try XCTUnwrap(event.y), 0.35, accuracy: 0.007)
        }
    }

    private struct Event: Decodable {
        let type: String
        let action: String?
        let x: Double?
        let y: Double?
        let text: String?
        let key: String?
    }
    private func events() throws -> [Event] {
        try Data(contentsOf: trace).split(separator: 0x0A).map { try JSONDecoder().decode(Event.self, from: Data($0)) }
    }
    private func pointerEvents() throws -> [Event] { try events().filter { $0.type == "pointer" } }
    private func coordinate(_ point: CGPoint) -> XCUICoordinate {
        app.coordinate(withNormalizedOffset: CGVector(dx: point.x / app.frame.width, dy: point.y / app.frame.height))
    }
    private func tapRenderedCenter(_ label: String) throws {
        let center = try renderedCenter(label)
        let count = try pointerEvents().count
        coordinate(center).tap()
        let emitted = Array(try pointerEvents().dropFirst(count))
        XCTAssertEqual(emitted.map(\.action), ["down", "up"], label)
        for event in emitted {
            XCTAssertEqual(try XCTUnwrap(event.x), 0.5, accuracy: 0.007, label)
            XCTAssertEqual(try XCTUnwrap(event.y), 0.5, accuracy: 0.007, label)
        }
    }
    @discardableResult private func capture(_ label: String) throws -> XCUIScreenshot {
        let shot = app.screenshot()
        try shot.pngRepresentation.write(to: output.appendingPathComponent(label + ".png"))
        let attachment = XCTAttachment(screenshot: shot); attachment.name = label; attachment.lifetime = .keepAlways
        add(attachment)
        return shot
    }
    /// Locate the lower red bullseye in the actual screenshot. Its fixture
    /// coordinate is (0.5,0.5), independent of the app's layout/normalization code.
    private func renderedCenter(_ label: String = "target", fromBottom: Int = 0) throws -> CGPoint {
        let image = try XCTUnwrap(capture(label).image.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { data in
            let context = try XCTUnwrap(CGContext(data: data.baseAddress, width: width, height: height,
                                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var rows: [(Int, [Int])] = []
        for y in 0..<height {
            var xs: [Int] = []
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                if r > 140 && r > g * 3 / 2 && r > b * 3 / 2 { xs.append(x) }
            }
            if !xs.isEmpty { rows.append((y, xs)) }
        }
        _ = try XCTUnwrap(rows.last, "The rendered desktop target must be visible.")
        var end = rows.count - 1
        var start = end
        for index in 0...fromBottom {
            start = try XCTUnwrap(end >= 0 ? end : nil, "The requested target must be visible.")
            while start > 0 && rows[start].0 - rows[start - 1].0 <= 24 { start -= 1 }
            if index < fromBottom { end = start - 1 }
        }
        let targetRows = rows[start...end]
        let points = targetRows.flatMap { row in row.1.map { CGPoint(x: $0, y: row.0) } }
        XCTAssertGreaterThan(points.count, 10)
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count) * app.frame.width / CGFloat(width),
                       y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count) * app.frame.height / CGFloat(height))
    }
}
