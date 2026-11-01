import AppKit
import RemoteCore
import XCTest
@testable import WAIRemote

/// Separate caller, target and foreground apps reproduce the regular host's
/// activation context. No user application receives test input.
@MainActor
final class BackgroundSavePanelTests: XCTestCase {
    private func pump(_ duration: TimeInterval) {
        let stop = Timer(timeInterval: duration, repeats: false) { _ in
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        RunLoop.main.add(stop, forMode: .common)
        NSApp.run(); stop.invalidate()
    }

    func testInactiveUnsavedDocumentCancelReceivesTheFirstDesktopClick() throws {
        try clickForeignControl("document")
    }
    func testInactiveSwiftUIPickerOpensOnTheFirstDesktopClick() throws {
        try clickForeignControl("picker")
    }
    private func clickForeignControl(_ kind: String) throws {
        try XCTSkipUnless(CGPreflightPostEventAccess() && AXIsProcessTrusted(), "Requires existing native input permissions.")
        let previousPolicy = NSApplication.shared.activationPolicy()
        defer { NSApplication.shared.setActivationPolicy(previousPolicy) }
        NSApplication.shared.setActivationPolicy(.regular)
        let previous = NSWorkspace.shared.frontmostApplication
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wai-unsaved-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.swift"), binary = directory.appendingPathComponent("fixture")
        try Self.fixture.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process(), output = Pipe()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-swift-version", "5", source.path, "-framework", "AppKit", "-o", binary.path]
        compiler.standardOutput = output; compiler.standardError = output
        try compiler.run(); let diagnostics = output.fileHandleForReading.readDataToEndOfFile(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
        guard compiler.terminationStatus == 0 else { return }
        func bundle(_ name: String) throws -> URL {
            let root = directory.appendingPathComponent(name + ".app/Contents")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("MacOS/fixture")
            try FileManager.default.copyItem(at: binary, to: executable)
            let info: [String: Any] = ["CFBundleExecutable": "fixture", "CFBundleIdentifier": "is.wai.tests.\(name.lowercased()).\(UUID().uuidString)", "CFBundleName": name, "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Info.plist"))
            return executable
        }
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
        let process = Process(); process.executableURL = try bundle("Target"); process.arguments = [metadata.path, kind]
        try capture(process, name: "target")
        try process.run()
        defer {
            let ownedWasActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
            if process.isRunning { process.terminate() }; process.waitUntilExit()
            if ownedWasActive { _ = previous?.activate(options: []) }
        }
        let ready = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: metadata.path), process.isRunning, Date() < ready { pump(0.05) }
        guard FileManager.default.fileExists(atPath: metadata.path) else {
            let windows = (CGWindowListCopyWindowInfo(.optionAll, 0) as? [[String: Any]]) ?? []
            let owned = windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.processIdentifier }
            print("MISSING_CONTROL ownedWindows=\(owned.map { ["id": $0[kCGWindowNumber as String] ?? 0, "bounds": $0[kCGWindowBounds as String] ?? [:], "onscreen": $0[kCGWindowIsOnscreen as String] ?? false] })")
            XCTFail("The owned \(kind) app did not expose its control; child lifecycle diagnostics follow")
            return
        }
        func state() throws -> [String: NSNumber] { try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: NSNumber] }
        while try state()["active"]?.boolValue != true, Date() < ready { pump(0.05) }
        XCTAssertEqual(try state()["active"]?.boolValue, true, "The target must complete its initial activation before the foreground fixture takes over")
        guard try state()["active"]?.boolValue == true else { return }
        let initial = try state()
        let target = WindowInputTarget(pid: process.processIdentifier, windowID: try XCTUnwrap(initial["sheet"]).uint32Value)
        // The helper must service its own AppKit/XPC loop, not recursively
        // query its remote save view from a main-thread timer. Discover the
        // rendered control externally within the original readiness deadline.
        let discoveryDeadline = ProcessInfo.processInfo.systemUptime + max(0, ready.timeIntervalSinceNow)
        func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            let remaining = discoveryDeadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining)))
            var raw: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success ? raw : nil
        }
        let app = AXUIElementCreateApplication(process.processIdentifier)
        var controlPoint: CGPoint?, buttonCount = 0
        repeat {
            var pending = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [], visited = 0
            buttonCount = 0; controlPoint = nil
            while let element = pending.popLast(), visited < 200, ProcessInfo.processInfo.systemUptime < discoveryDeadline {
                visited += 1
                let identifier = value(element, kAXIdentifierAttribute) as? String
                if ["CancelButton", "OKButton", "DontSaveButton"].contains(identifier ?? "") { buttonCount += 1 }
                let matches = kind == "document" ? identifier == "CancelButton" : value(element, kAXRoleAttribute) as? String == kAXPopUpButtonRole
                if matches, value(element, kAXEnabledAttribute) as? Bool == true,
                   let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
                   CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() {
                    var origin = CGPoint.zero, extent = CGSize.zero
                    if AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) {
                        controlPoint = CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
                    }
                }
                pending += (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
            if controlPoint == nil || kind == "document" && buttonCount != 3 { pump(0.05) }
        } while (controlPoint == nil || kind == "document" && buttonCount != 3) && ProcessInfo.processInfo.systemUptime < discoveryDeadline
        if kind == "document" { XCTAssertEqual(buttonCount, 3, "Use the real unsaved-document Delete/Cancel/Save panel.") }
        let point = try XCTUnwrap(controlPoint, "The owned control must be rendered and inspectable before testing its first click")
        let focus = Process(); focus.executableURL = try bundle("Foreground")
        let focusReady = directory.appendingPathComponent("focus.json")
        focus.arguments = [focusReady.path, "focus"]
        try capture(focus, name: "foreground")
        try focus.run()
        defer {
            let ownedWasActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processIdentifier
            if focus.isRunning { focus.terminate() }; focus.waitUntilExit()
            if ownedWasActive { _ = previous?.activate(options: []) }
        }
        let inactive = Date().addingTimeInterval(2)
        while Date() < inactive {
            let targetState = try state()
            if FileManager.default.fileExists(atPath: focusReady.path),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processIdentifier,
               targetState["deactivated"]?.boolValue == true, targetState["active"]?.boolValue == false { break }
            pump(0.05)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: focusReady.path), "Foreground setup must finish inside its running AppKit loop")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, focus.processIdentifier)
        XCTAssertEqual(try state()["active"]?.boolValue, false, "The target must finish processing deactivation before its first remote click")
        XCTAssertEqual(try state()["deactivated"]?.boolValue, true, "The target must acknowledge didResignActive before its first remote click")
        guard FileManager.default.fileExists(atPath: focusReady.path), NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processIdentifier,
              try state()["deactivated"]?.boolValue == true, try state()["active"]?.boolValue == false else { return }
        XCTAssertEqual(DesktopInputTarget.target(at: point, excluding: []), target)
        let pointer = try XCTUnwrap(CGEvent(source: nil)).location
        let injector = InputInjector(); injector.setIndependentPointer(true)
        defer { injector.resetSession() }
        for action in ["down", "up"] {
            var event = WireMessage(type: "pointer", state: SessionMachine(surface: .init(id: "fixture", width: 800, height: 600)).state)
            event.action = action; event.button = 0
            event.x = (point.x - injector.bounds.minX) / max(1, injector.bounds.width - 1)
            event.y = (point.y - injector.bounds.minY) / max(1, injector.bounds.height - 1)
            injector.apply(event)
        }
        let delivered = Date().addingTimeInterval(2)
        while Date() < delivered {
            let performed = try state()[kind == "document" ? "completions" : "menus"]?.intValue ?? 0
            if performed > 0, NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier { break }
            pump(0.05)
        }
        let final = try state()
        print("DESKTOP_CONTROL_PROOF kind=\(kind) caller=\(getpid()) target=\(process.processIdentifier) previous=\(focus.processIdentifier) active=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) result=\(final)")
        if kind == "document", final["completions"]?.intValue != 1 {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return nil }
                AXUIElementSetMessagingTimeout(element, Float(min(0.05, remaining)))
                var raw: CFTypeRef?
                return AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success ? raw : nil
            }
            let app = AXUIElementCreateApplication(process.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.05)
            var hit: AXUIElement?
            let result = AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit)
            if let hit {
                print("DOCUMENT_HIT result=\(result.rawValue) role=\(value(hit, kAXRoleAttribute) ?? "nil" as CFString) window=\(WindowInputTarget.axWindowID(hit, deadline: ProcessInfo.processInfo.systemUptime + 0.05) ?? 0) selected=\(target.windowID) frame=\(String(describing: target.frame))")
            }
            var pending = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [], count = 0
            while let element = pending.popLast(), count < 200, ProcessInfo.processInfo.systemUptime < deadline {
                count += 1
                if value(element, kAXIdentifierAttribute) as? String == "CancelButton" {
                    let started = ProcessInfo.processInfo.systemUptime
                    let direct = target.button(climbingFrom: element, at: point)
                    let directMS = (ProcessInfo.processInfo.systemUptime - started) * 1_000
                    let lookup = ProcessInfo.processInfo.systemUptime
                    let located = target.button(at: point)
                    print("DOCUMENT_CANCEL direct=\(direct != nil) directMs=\(directMS) point=\(located != nil) pointMs=\((ProcessInfo.processInfo.systemUptime - lookup) * 1_000)")
                    break
                }
                pending += (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
        }
        if kind == "document" {
            XCTAssertEqual(final["completions"]?.intValue, 1, "One initial desktop tap must cancel the unsaved-document panel.")
            XCTAssertEqual(final["shouldClose"]?.boolValue, false)
        } else {
            XCTAssertGreaterThan(final["menus"]?.intValue ?? 0, 0, "One initial desktop tap must open the SwiftUI menu.")
        }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, process.processIdentifier,
                       "A desktop click from the background regular host must activate the clicked app.")
        XCTAssertEqual(try XCTUnwrap(CGEvent(source: nil)).location, pointer)
    }

    private static let fixture = #"""
import AppKit
import Darwin
import SwiftUI
let metadata = URL(fileURLWithPath: CommandLine.arguments[1])
DispatchQueue.global().asyncAfter(deadline: .now() + 15) { exit(2) }
let app = NSApplication.shared
app.setActivationPolicy(.regular); app.finishLaunching()
func trace(_ phase: String) {
    let line = "phase=\(phase) pid=\(getpid()) active=\(app.isActive) ax=\(AXIsProcessTrusted())\n"
    FileHandle.standardError.write(Data(line.utf8))
}
trace("launched")
var didResignActive = false
let activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: app, queue: .main) { _ in
    didResignActive = true; trace("deactivated")
}
if CommandLine.arguments[2] == "focus" {
    let focus = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
    focus.title = "Owned focus fixture"
    DispatchQueue.main.async {
        focus.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        let ready = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard app.isActive, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() else { return }
            trace("foreground-ready"); try! Data().write(to: metadata, options: .atomic); timer.invalidate()
        }
        RunLoop.main.add(ready, forMode: .common)
    }
    app.run(); exit(0)
}
if CommandLine.arguments[2] == "picker" {
    final class Choice: ObservableObject { @Published var value = 0 }
    struct Content: View {
        @ObservedObject var choice: Choice
        var body: some View {
            Picker("Owned choice", selection: $choice.value) {
                Text("First owned choice").tag(0); Text("Second owned choice").tag(1)
            }.pickerStyle(.menu).frame(width: 260).padding(30)
        }
    }
    let choice = Choice()
    let window = NSWindow(contentRect: CGRect(x: 180, y: 150, width: 360, height: 150), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.animationBehavior = .none
    window.contentView = NSHostingView(rootView: Content(choice: choice))
    DispatchQueue.main.async { window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); trace("picker-shown") }
    let ready = Timer(timeInterval: 0.1, repeats: true) { _ in
        guard window.isVisible else { return }
        var data = ["sheet": NSNumber(value: window.windowNumber), "active": NSNumber(value: app.isActive), "deactivated": NSNumber(value: didResignActive)]
        let windows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]]) ?? []
        data["menus"] = NSNumber(value: windows.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == getpid() && (($0[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) >= Int(NSWindow.Level.popUpMenu.rawValue) }.count)
        data["selection"] = NSNumber(value: choice.value)
        try! JSONSerialization.data(withJSONObject: data).write(to: metadata, options: .atomic)
    }
    RunLoop.main.add(ready, forMode: .common)
    app.run(); exit(0)
}
final class Document: NSDocument {
    override class var autosavesInPlace: Bool { true }
    override class var readableTypes: [String] { ["public.plain-text"] }
    override class var writableTypes: [String] { ["public.plain-text"] }
    override func data(ofType typeName: String) throws -> Data { Data("owned fixture".utf8) }
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.directoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        trace("save-panel-prepared")
        return true
    }
}
let document = Document(); document.fileType = "public.plain-text"
NSDocumentController.shared.addDocument(document)
let window = NSWindow(contentRect: CGRect(x: 180, y: 150, width: 700, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false; window.animationBehavior = .none
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
let controller = NSWindowController(window: window); document.addWindowController(controller)
var data: [String: NSNumber] = [:]
func record() { try! JSONSerialization.data(withJSONObject: data).write(to: metadata, options: .atomic) }
final class CloseResult: NSObject {
    @objc func result(_ document: NSDocument, shouldClose: Bool, context: UnsafeMutableRawPointer?) {
        data["completions"] = NSNumber(value: (data["completions"]?.intValue ?? 0) + 1)
        data["shouldClose"] = NSNumber(value: shouldClose); record()
    }
}
let result = CloseResult()
document.updateChangeCount(.changeDone)
// Install observation before canClose: AppKit may enter a nested modal loop.
let ready = Timer(timeInterval: 0.05, repeats: true) { _ in
    guard let sheet = window.attachedSheet, sheet.isVisible else { return }
    if data["sheet"] == nil { data["completions"] = 0; trace("document-sheet-visible") }
    data["sheet"] = NSNumber(value: sheet.windowNumber); data["active"] = NSNumber(value: app.isActive)
    data["deactivated"] = NSNumber(value: didResignActive)
    record()
}
RunLoop.main.add(ready, forMode: .common)
DispatchQueue.main.async {
    window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    trace("can-close-enter visible=\(window.isVisible) key=\(window.isKeyWindow) candidate=\(document.windowForSheet?.windowNumber ?? 0)")
    document.canClose(withDelegate: result, shouldClose: #selector(CloseResult.result(_:shouldClose:context:)), contextInfo: nil)
    trace("can-close-return")
}
app.run()
"""#
}
