import AppKit
import RemoteCore
import XCTest
@testable import WAIRemote

/// Private window input can mark an app active internally without making it
/// WindowServer's foreground app. A later desktop click must bridge that state.
@MainActor
final class BackgroundReactivationTests: XCTestCase {
    private func pump(_ duration: TimeInterval) {
        let stop = Timer(timeInterval: duration, repeats: false) { _ in
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        RunLoop.main.add(stop, forMode: .common)
        NSApp.run(); stop.invalidate()
    }

    func testDesktopClickActivatesTheSameAppAfterScopedPointerInput() throws {
        try XCTSkipUnless(CGPreflightPostEventAccess() && AXIsProcessTrusted(),
                          "Requires existing native input permissions; never requests access")
        let app = NSApplication.shared, previous = NSWorkspace.shared.frontmostApplication
        let previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wai-reactivation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func binary(_ name: String) throws -> URL {
            let contents = directory.appendingPathComponent(name + ".app/Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let info: [String: Any] = ["CFBundleIdentifier": "is.wai.remote.reactivation.\(name).\(UUID().uuidString)",
                                      "CFBundleExecutable": "fixture", "CFBundleName": name, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return contents.appendingPathComponent("MacOS/fixture")
        }
        let targetBinary = try binary("Target"), foregroundBinary = try binary("Foreground")
        let source = directory.appendingPathComponent("fixture.swift")
        try Self.fixture.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process(), output = Pipe()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-swift-version", "5", source.path, "-framework", "AppKit", "-o", targetBinary.path]
        compiler.standardOutput = output; compiler.standardError = output
        try compiler.run()
        let diagnostic = output.fileHandleForReading.readDataToEndOfFile()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            XCTFail(String(decoding: diagnostic, as: UTF8.self)); return
        }
        try FileManager.default.copyItem(at: targetBinary, to: foregroundBinary)
        let stateURL = directory.appendingPathComponent("state.json")
        let targetProcess = Process(), foregroundProcess = Process()
        targetProcess.executableURL = targetBinary; targetProcess.arguments = [stateURL.path, "target"]
        foregroundProcess.executableURL = foregroundBinary
        foregroundProcess.arguments = [directory.appendingPathComponent("foreground.json").path, "foreground"]
        var targetStarted = false, foregroundStarted = false
        defer {
            let active = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let restore = targetStarted && active == targetProcess.processIdentifier ||
                foregroundStarted && active == foregroundProcess.processIdentifier
            if foregroundStarted { if foregroundProcess.isRunning { foregroundProcess.terminate() }; foregroundProcess.waitUntilExit() }
            if targetStarted { if targetProcess.isRunning { targetProcess.terminate() }; targetProcess.waitUntilExit() }
            if restore { _ = previous?.activate(options: []) }
        }
        try targetProcess.run(); targetStarted = true
        let ready = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: stateURL.path), targetProcess.isRunning, Date() < ready { pump(0.05) }
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            XCTFail("Owned target did not finish launching"); return
        }
        func state() throws -> [String: NSNumber] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: NSNumber]
        }
        let initial = try state()
        let windowID = try XCTUnwrap(initial["window"]).uint32Value
        let point = CGPoint(x: try XCTUnwrap(initial["x"]).doubleValue, y: try XCTUnwrap(initial["y"]).doubleValue)
        let target = WindowInputTarget(pid: targetProcess.processIdentifier, windowID: windowID)
        try foregroundProcess.run(); foregroundStarted = true
        let foregroundReady = Date().addingTimeInterval(10)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != foregroundProcess.processIdentifier,
              foregroundProcess.isRunning, Date() < foregroundReady { pump(0.05) }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundProcess.processIdentifier else {
            XCTFail("The third owned app must hold global foreground before either input"); return
        }
        XCTAssertNotEqual(foregroundProcess.processIdentifier, getpid())
        XCTAssertNotEqual(targetProcess.processIdentifier, getpid())
        let targetIdentity = try XCTUnwrap(NSRunningApplication(processIdentifier: targetProcess.processIdentifier)?.bundleIdentifier)
        let foregroundIdentity = try XCTUnwrap(NSRunningApplication(processIdentifier: foregroundProcess.processIdentifier)?.bundleIdentifier)
        XCTAssertNotEqual(targetIdentity, foregroundIdentity)
        XCTAssertNotEqual(targetIdentity, NSRunningApplication.current.bundleIdentifier)
        XCTAssertEqual(DesktopInputTarget.target(at: point, excluding: [])?.windowID, windowID)
        let inactiveDeadline = Date().addingTimeInterval(2)
        while try state()["active"]?.boolValue == true, Date() < inactiveDeadline { pump(0.05) }
        XCTAssertFalse(try state()["active"]?.boolValue ?? true, "The target must begin internally inactive before scoped input")
        XCTAssertEqual(try state()["presses"]?.intValue, 0)

        let pointer = try XCTUnwrap(CGEvent(source: nil)).location
        var samples = [pointer]
        let sampler = Timer.connectionTimer(withTimeInterval: 0.01, repeats: true) { _ in
            if let event = CGEvent(source: nil) { samples.append(event.location) }
        }
        defer { sampler.invalidate() }
        let injector = InputInjector()
        defer { injector.resetSession() }
        func click(bounds: CGRect) {
            for action in ["down", "up"] {
                var message = WireMessage(type: "pointer", state: SessionMachine(surface: .init(id: "reactivation", width: 800, height: 600)).state)
                message.action = action; message.button = 0
                message.x = (point.x - bounds.minX) / max(1, bounds.width - 1)
                message.y = (point.y - bounds.minY) / max(1, bounds.height - 1)
                injector.apply(message)
            }
        }
        injector.setWindowTarget(target)
        click(bounds: try XCTUnwrap(target.frame))
        let scopedDeadline = Date().addingTimeInterval(3)
        while try state()["presses"]?.intValue != 1, Date() < scopedDeadline { pump(0.05) }
        pump(0.1)
        let scoped = try state()
        XCTAssertEqual(scoped["presses"]?.intValue, 1, "The scoped raw click must arrive exactly once")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, foregroundProcess.processIdentifier,
                       "A window grant must leave global foreground with the third app")
        XCTAssertTrue(scoped["active"]?.boolValue ?? false,
                      "The scoped focus record must establish the internally-active/global-background condition")
        XCTAssertTrue(samples.allSatisfy { $0 == pointer })

        // Same target process and window; no activation, deactivation, AX action,
        // or second preparation click is allowed between these two input modes.
        injector.setIndependentPointer(true)
        click(bounds: injector.bounds)
        let desktopDeadline = Date().addingTimeInterval(3)
        while (try state()["presses"]?.intValue != 2 ||
               NSWorkspace.shared.frontmostApplication?.processIdentifier != targetProcess.processIdentifier),
              Date() < desktopDeadline { pump(0.05) }
        pump(0.1)
        let desktop = try state()
        XCTAssertEqual(desktop["presses"]?.intValue, 2, "The first desktop click must arrive once after the scoped click")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, targetProcess.processIdentifier,
                       "Internal AppKit active state must not prevent real foreground activation")
        samples.append(try XCTUnwrap(CGEvent(source: nil)).location)
        XCTAssertGreaterThan(samples.count, 2)
        XCTAssertTrue(samples.allSatisfy { $0 == pointer }, "Neither input mode may move the physical pointer")
        print("REACTIVATION_PROOF scopedActive=\(scoped["active"]?.boolValue ?? false) scopedPresses=\(scoped["presses"]?.intValue ?? -1) desktopActive=\(desktop["active"]?.boolValue ?? false) desktopPresses=\(desktop["presses"]?.intValue ?? -1) target=\(targetProcess.processIdentifier) frontmost=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) pointerSamples=\(samples.count)")
    }

    private static let fixture = #"""
import AppKit
import Darwin
let app = NSApplication.shared
app.setActivationPolicy(.regular); app.finishLaunching()
let metadata = URL(fileURLWithPath: CommandLine.arguments[1])
let foreground = CommandLine.arguments[2] == "foreground"
let window = NSWindow(contentRect: CGRect(x: foreground ? 700 : 100, y: 120, width: 340, height: 240),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = foreground ? "WAI owned foreground fixture" : "WAI owned reactivation target"
window.isReleasedWhenClosed = false; window.animationBehavior = .none
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
final class TargetView: NSView {
    var presses = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { presses += 1 }
    override func draw(_ dirtyRect: NSRect) { NSColor.systemGreen.setFill(); bounds.fill() }
}
let target = TargetView(frame: CGRect(x: 30, y: 60, width: 180, height: 80))
target.setAccessibilityElement(true); target.setAccessibilityRole(.group)
window.contentView?.addSubview(target)
window.orderFrontRegardless()
if foreground { window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true) }
func record() {
    let local = target.convert(CGPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
    let screen = window.convertPoint(toScreen: local)
    let object: [String: Any] = ["pid": Int(getpid()), "window": window.windowNumber,
        "x": screen.x, "y": CGDisplayBounds(CGMainDisplayID()).maxY - screen.y,
        "presses": target.presses, "active": app.isActive,
        "globalFrontmost": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)]
    try! JSONSerialization.data(withJSONObject: object).write(to: metadata, options: .atomic)
}
let stateTimer = Timer(timeInterval: 0.02, repeats: true) { _ in record() }
RunLoop.main.add(stateTimer, forMode: .common)
let timeout = Timer(timeInterval: 30, repeats: false) { _ in app.terminate(nil) }
RunLoop.main.add(timeout, forMode: .common)
record(); app.run()
"""#
}
