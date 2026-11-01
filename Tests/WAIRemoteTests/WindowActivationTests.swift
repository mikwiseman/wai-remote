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

    func testBackgroundCallerActivatesForeignAXButtonOwnerOnFirstClick() throws {
        try clickForeignWindow(viewMode: false, backgroundCaller: true)
    }
    func testBackgroundCallerActivatesForeignPointerOwnerOnFirstClick() throws {
        try clickForeignWindow(viewMode: true, backgroundCaller: true)
    }
    func testBackgroundCallerSingleWindowGrantKeepsItsForeignAppInBackground() throws {
        try clickForeignWindow(viewMode: false, scoped: true, backgroundCaller: true)
    }

    func testSingleWindowGrantKeepsItsForeignAppInBackground() throws { try clickForeignWindow(viewMode: false, scoped: true) }

    private func clickForeignWindow(viewMode: Bool, scoped: Bool = false, backgroundCaller: Bool = false) throws {
        try XCTSkipUnless(CGPreflightPostEventAccess() && AXIsProcessTrusted(), "Native input requires existing permissions; this test never requests them.")
        let previousPolicy = NSApplication.shared.activationPolicy()
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        NSApplication.shared.setActivationPolicy(backgroundCaller ? .regular : .accessory)
        let previous = NSWorkspace.shared.frontmostApplication
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wai-activation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func bundle(_ name: String) throws -> URL {
            let application = directory.appendingPathComponent(name + ".app")
            let contents = application.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "is.wai.remote.activation.\(name).\(UUID().uuidString)",
                                      "CFBundleExecutable": "fixture", "CFBundleName": name, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return contents.appendingPathComponent("MacOS/fixture")
        }
        let source = directory.appendingPathComponent("fixture.swift")
        let binary = backgroundCaller ? try bundle("Target") : directory.appendingPathComponent("fixture")
        try Self.fixture.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process(), compilerOutput = Pipe()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-swift-version", "5", source.path, "-framework", "AppKit", "-o", binary.path]
        compiler.standardOutput = compilerOutput; compiler.standardError = compilerOutput
        try compiler.run()
        let diagnostics = compilerOutput.fileHandleForReading.readDataToEndOfFile()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
        guard compiler.terminationStatus == 0 else { return }
        var childLogs: [(URL, FileHandle)] = []
        func capture(_ child: Process, name: String) throws {
            let url = directory.appendingPathComponent(name + ".log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let file = try FileHandle(forWritingTo: url)
            child.standardOutput = file; child.standardError = file
            childLogs.append((url, file))
        }
        defer {
            for (url, file) in childLogs {
                try? file.close()
                if let log = try? String(contentsOf: url, encoding: .utf8) { print("OWNED_CHILD \(url.lastPathComponent): \(log)") }
            }
        }
        let metadata = directory.appendingPathComponent("state.json")
        let process = Process()
        process.executableURL = binary
        process.arguments = [metadata.path, viewMode ? "view" : "button"] + (backgroundCaller ? ["regular"] : [])
        try capture(process, name: "target")
        try process.run()
        var foreground: Process?
        defer {
            let activePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let active = activePID == process.processIdentifier || activePID == foreground?.processIdentifier
            if let foreground { if foreground.isRunning { foreground.terminate() }; foreground.waitUntilExit() }
            if process.isRunning { process.terminate() }; process.waitUntilExit()
            if active { _ = previous?.activate(options: []) }
        }
        let ready = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: metadata.path), process.isRunning, Date() < ready { runApplication(for: 0.05) }
        guard FileManager.default.fileExists(atPath: metadata.path) else {
            XCTFail("The owned application must finish launching before a click can be tested")
            return
        }
        func state() throws -> [String: NSNumber] { try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: NSNumber] }
        let initial = try state(), rear = try XCTUnwrap(initial["rear"]).uint32Value, front = try XCTUnwrap(initial["front"]).uint32Value
        func order() -> [UInt32] {
            // optionAll also contains offscreen windows and does not promise
            // front-to-back order. Both fixtures must actually be onscreen.
            ((CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]]) ?? []).compactMap {
                guard let id = ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value, [rear, front].contains(id) else { return nil }; return id
            }
        }
        if backgroundCaller {
            let foregroundBinary = try bundle("Foreground")
            try FileManager.default.copyItem(at: binary, to: foregroundBinary)
            let owner = Process()
            owner.executableURL = foregroundBinary
            let foregroundReady = directory.appendingPathComponent("foreground.json")
            owner.arguments = [foregroundReady.path, "foreground"]
            try capture(owner, name: "foreground")
            try owner.run(); foreground = owner
            let activated = Date().addingTimeInterval(3)
            while (!FileManager.default.fileExists(atPath: foregroundReady.path) || NSWorkspace.shared.frontmostApplication?.processIdentifier != owner.processIdentifier), Date() < activated {
                runApplication(for: 0.05)
            }
            guard FileManager.default.fileExists(atPath: foregroundReady.path), NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.processIdentifier else {
                XCTFail("A third owned process must hold activation before testing a background caller")
                return
            }
            // Scoped focus records can leave AppKit's internal active flag set.
            // WindowServer's distinct foreground owner defines this precondition.
            XCTAssertEqual(NSApp.activationPolicy(), .regular)
            XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, getpid())
            XCTAssertNotEqual(owner.processIdentifier, getpid())
            XCTAssertNotEqual(owner.processIdentifier, process.processIdentifier)
            let foregroundID = try XCTUnwrap(NSRunningApplication(processIdentifier: owner.processIdentifier)?.bundleIdentifier)
            let targetID = try XCTUnwrap(NSRunningApplication(processIdentifier: process.processIdentifier)?.bundleIdentifier)
            XCTAssertNotEqual(foregroundID, targetID, "Activation must cross real application identities, not two instances of one executable")
            XCTAssertNotEqual(targetID, NSRunningApplication.current.bundleIdentifier)
            if !viewMode && !scoped {
                // The host may have been idle behind another app for a long
                // time. Do not rely on activation immediately after launch.
                runApplication(for: 10)
                XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, owner.processIdentifier)
                XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, getpid())
            }
        }
        // Configure the fixture's own ordering after app launch/activation has
        // settled. This uses no AX query or input and keeps the real click cold.
        try Data().write(to: URL(fileURLWithPath: metadata.path + ".arrange"), options: .atomic)
        let visible = Date().addingTimeInterval(3)
        while try state()["arranged"]?.boolValue != true || order() != [front, rear], Date() < visible { runApplication(for: 0.05) }
        XCTAssertEqual(try state()["arranged"]?.boolValue, true)
        XCTAssertEqual(order(), [front, rear])
        XCTAssertNotEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, process.processIdentifier)
        let point = CGPoint(x: try XCTUnwrap(initial["x"]).doubleValue, y: try XCTUnwrap(initial["y"]).doubleValue)
        XCTAssertEqual(DesktopInputTarget.target(at: point, excluding: [])?.windowID, rear)
        let target = WindowInputTarget(pid: process.processIdentifier, windowID: rear)
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if scoped && !backgroundCaller {
            // This cancellation-only probe needs a registered AX window. Keep
            // it out of the desktop cases: their first real click must be cold.
            let app = AXUIElementCreateApplication(process.processIdentifier)
            let axReady = Date().addingTimeInterval(3)
            var registered = false
            repeat {
                let deadline = ProcessInfo.processInfo.systemUptime + 0.05
                let windows = WindowInputTarget.axValues(app, [kAXWindowsAttribute], deadline: deadline)?.first as? [AXUIElement]
                registered = windows?.contains { WindowInputTarget.axWindowID($0, deadline: deadline) == rear } ?? false
                if !registered { runApplication(for: 0.05) }
            } while !registered && Date() < axReady
            XCTAssertTrue(registered)
            var checks = 0
            XCTAssertFalse(target.activateForDesktopClick(at: point, if: { checks += 1; return checks == 1 }))
            XCTAssertGreaterThan(checks, 1, "Cancellation must be rechecked after the AX lookup")
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
            XCTAssertEqual(order(), [front, rear])
        }
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
        print("ACTIVATION_PROOF scoped=\(scoped) axButton=\(!viewMode) backgroundCaller=\(backgroundCaller) pointerSamples=\(samples.count) maximumSampleGapMs=\(gap * 1000)")
    }

    private static let fixture = #"""
import AppKit
import Darwin
let metadata = URL(fileURLWithPath: CommandLine.arguments[1])
let viewMode = CommandLine.arguments[2] == "view"
let app = NSApplication.shared
DispatchQueue.global().asyncAfter(deadline: .now() + 30) { exit(2) }
func trace(_ phase: String) {
    FileHandle.standardError.write(Data("phase=\(phase) pid=\(getpid()) active=\(app.isActive)\n".utf8))
}
if CommandLine.arguments[2] == "foreground" {
    app.setActivationPolicy(.regular); app.finishLaunching()
    let window = NSWindow(contentRect: CGRect(x: 700, y: 80, width: 260, height: 140), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "WAI Remote owned foreground fixture"; window.isReleasedWhenClosed = false
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    DispatchQueue.main.async {
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        let ready = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard app.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else { return }
            trace("foreground-ready"); try! Data().write(to: metadata, options: .atomic); timer.invalidate()
        }
        RunLoop.main.add(ready, forMode: .common)
    }
    app.run(); exit(0)
}
app.setActivationPolicy(CommandLine.arguments.contains("regular") ? .regular : .accessory)
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
var arranged = false
func record() {
    let local = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
    let screen = rear.convertPoint(toScreen: local)
    try! JSONSerialization.data(withJSONObject: ["pid": Int(getpid()), "rear": rear.windowNumber, "front": front.windowNumber, "x": screen.x, "y": CGDisplayBounds(CGMainDisplayID()).maxY - screen.y, "presses": presses.count, "arranged": arranged]).write(to: metadata, options: .atomic)
}
presses.changed = record
DispatchQueue.main.async { rear.orderFrontRegardless(); front.orderFrontRegardless(); trace("created"); record() }
let arrange = Timer(timeInterval: 0.05, repeats: true) { timer in
    guard FileManager.default.fileExists(atPath: metadata.path + ".arrange") else { return }
    rear.orderFrontRegardless(); front.orderFrontRegardless()
    arranged = true; trace("arranged"); record(); timer.invalidate()
}
RunLoop.main.add(arrange, forMode: .common)
app.run()
"""#
}
