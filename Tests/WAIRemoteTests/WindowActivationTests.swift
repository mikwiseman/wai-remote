import AppKit
import RemoteCore
import XCTest
@testable import WAIRemote

/// The target is a separate AppKit process: same-process AX is not proof of
/// ordinary desktop activation. No user application receives test input.
@MainActor
final class WindowActivationTests: XCTestCase {
    private func runApplication(for duration: TimeInterval) {
        let stop = Timer(timeInterval: duration, repeats: false) { _ in
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        RunLoop.main.add(stop, forMode: .common)
        NSApp.run(); stop.invalidate()
    }
    func testDesktopAXButtonClickActivatesOnlyItsSelectedForeignWindow() throws { try clickForeignWindow(viewMode: false) }
    func testDesktopPointerClickActivatesOnlyItsSelectedForeignWindow() throws { try clickForeignWindow(viewMode: true) }

    func testSingleWindowGrantKeepsItsForeignAppInBackground() throws { try clickForeignWindow(viewMode: false, scoped: true) }

    private func clickForeignWindow(viewMode: Bool, scoped: Bool = false) throws {
        try XCTSkipUnless(CGPreflightPostEventAccess() && AXIsProcessTrusted(), "Native input requires existing permissions; this test never requests them.")
        NSApplication.shared.setActivationPolicy(.accessory)
        let previous = NSWorkspace.shared.frontmostApplication
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wai-activation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.swift"), binary = directory.appendingPathComponent("fixture")
        try Self.fixture.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process(), compilerOutput = Pipe()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-swift-version", "5", source.path, "-framework", "AppKit", "-o", binary.path]
        compiler.standardOutput = compilerOutput; compiler.standardError = compilerOutput
        try compiler.run()
        let diagnostics = compilerOutput.fileHandleForReading.readDataToEndOfFile()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
        let metadata = directory.appendingPathComponent("state.json")
        let process = Process()
        process.executableURL = binary; process.arguments = [metadata.path, viewMode ? "view" : "button"]
        try process.run()
        defer {
            let active = NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
            if process.isRunning { process.terminate() }; process.waitUntilExit()
            if active { _ = previous?.activate(options: []) }
        }
        let ready = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: metadata.path), Date() < ready { runApplication(for: 0.05) }
        func state() throws -> [String: NSNumber] { try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: NSNumber] }
        let initial = try state(), rear = try XCTUnwrap(initial["rear"]).uint32Value, front = try XCTUnwrap(initial["front"]).uint32Value
        func order() -> [UInt32] {
            // optionAll also contains offscreen windows and does not promise
            // front-to-back order. Both fixtures must actually be onscreen.
            ((CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]]) ?? []).compactMap {
                guard let id = ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value, [rear, front].contains(id) else { return nil }; return id
            }
        }
        let visible = Date().addingTimeInterval(3)
        while order() != [front, rear], Date() < visible { runApplication(for: 0.05) }
        XCTAssertEqual(order(), [front, rear])
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, process.processIdentifier)
        let point = CGPoint(x: try XCTUnwrap(initial["x"]).doubleValue, y: try XCTUnwrap(initial["y"]).doubleValue)
        XCTAssertEqual(DesktopInputTarget.target(at: point, excluding: [])?.windowID, rear)
        let target = WindowInputTarget(pid: process.processIdentifier, windowID: rear)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var checks = 0
        XCTAssertFalse(target.activateForDesktopClick(at: point, if: { checks += 1; return checks == 1 }))
        XCTAssertGreaterThan(checks, 1, "Cancellation must be rechecked after the AX lookup")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
        XCTAssertEqual(order(), [front, rear])
        let pointer = try XCTUnwrap(CGEvent(source: nil)).location
        var samples: [(TimeInterval, CGPoint)] = [(ProcessInfo.processInfo.systemUptime, pointer)]
        let sampler = Timer.connectionTimer(withTimeInterval: 0.01, repeats: true) { _ in
            if let event = CGEvent(source: nil) { samples.append((ProcessInfo.processInfo.systemUptime, event.location)) }
        }
        defer { sampler.invalidate() }
        let injector = InputInjector()
        if scoped { injector.setWindowTarget(target) } else { injector.setIndependentPointer(true) }
        defer { injector.resetSession() }
        let bounds = scoped ? try XCTUnwrap(target.frame) : injector.bounds
        func message(_ action: String) -> WireMessage {
            var event = WireMessage(type: "pointer", state: SessionMachine(surface: .init(id: "fixture", width: 800, height: 600)).state)
            event.action = action; event.button = 0
            event.x = (point.x - bounds.minX) / max(1, bounds.width - 1)
            event.y = (point.y - bounds.minY) / max(1, bounds.height - 1)
            return event
        }
        injector.apply(message("move"))
        var scroll = message("scroll"); scroll.deltaY = 8; injector.apply(scroll)
        runApplication(for: 0.05)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost, "Hover and scroll do not activate an app")
        XCTAssertEqual(order(), [front, rear])
        for action in ["down", "up"] {
            injector.apply(message(action))
        }
        let delivered = Date().addingTimeInterval(2)
        while try state()["presses"]?.intValue != 1, Date() < delivered { runApplication(for: 0.05) }
        runApplication(for: 0.1)
        XCTAssertEqual(try state()["presses"]?.intValue, 1, "The original click must arrive once, including the AX fast path.")
        XCTAssertEqual(order(), scoped ? [front, rear] : [rear, front], "Only a full-desktop click raises the selected window.")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, scoped ? frontmost : process.processIdentifier)
        sampler.invalidate()
        samples.append((ProcessInfo.processInfo.systemUptime, try XCTUnwrap(CGEvent(source: nil)).location))
        XCTAssertGreaterThan(samples.count, 2)
        XCTAssertTrue(samples.allSatisfy { $0.1 == pointer }, "Activation must not move the owner's physical pointer.")
        let gap = zip(samples, samples.dropFirst()).map { $1.0 - $0.0 }.max() ?? 0
        print("ACTIVATION_PROOF scoped=\(scoped) axButton=\(!viewMode) pointerSamples=\(samples.count) maximumSampleGapMs=\(gap * 1000)")
    }

    private static let fixture = #"""
import AppKit
import Darwin
let metadata = URL(fileURLWithPath: CommandLine.arguments[1])
let viewMode = CommandLine.arguments[2] == "view"
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
func make(_ x: CGFloat) -> NSWindow {
    let window = NSWindow(contentRect: CGRect(x: x, y: 120, width: 340, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "WAI Remote owned activation fixture"
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.animationBehavior = .none
    return window
}
final class Presses: NSObject {
    var count = 0
    var changed: () -> Void = {}
    @objc func press() { count += 1; changed() }
}
final class TargetView: NSView {
    let presses: Presses
    init(presses: Presses) { self.presses = presses; super.init(frame: CGRect(x: 8, y: 80, width: 100, height: 40)) }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { presses.press() }
}
let rear = make(100), front = make(220), presses = Presses()
let target: NSView
if viewMode { target = TargetView(presses: presses) }
else {
    let button = NSButton(title: "Fixture action", target: presses, action: #selector(Presses.press))
    button.frame = CGRect(x: 8, y: 80, width: 100, height: 40)
    target = button
}
rear.contentView?.addSubview(target)
rear.orderFrontRegardless(); front.orderFrontRegardless()
func record() {
    let local = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
    let screen = rear.convertPoint(toScreen: local)
    try! JSONSerialization.data(withJSONObject: ["pid": Int(getpid()), "rear": rear.windowNumber, "front": front.windowNumber, "x": screen.x, "y": CGDisplayBounds(CGMainDisplayID()).maxY - screen.y, "presses": presses.count]).write(to: metadata, options: .atomic)
}
presses.changed = record
record()
let timer = Timer(timeInterval: 15, repeats: false) { _ in app.terminate(nil) }
RunLoop.main.add(timer, forMode: .common)
app.run()
"""#
}
