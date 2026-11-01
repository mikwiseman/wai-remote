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
        let metadata = directory.appendingPathComponent("state.json")
        let process = Process(); process.executableURL = try bundle("Target"); process.arguments = [metadata.path, kind]
        try process.run()
        defer {
            let ownedWasActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier
            if process.isRunning { process.terminate() }; process.waitUntilExit()
            if ownedWasActive { _ = previous?.activate(options: []) }
        }
        let ready = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: metadata.path), Date() < ready { pump(0.05) }
        func state() throws -> [String: NSNumber] { try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as! [String: NSNumber] }
        let initial = try state()
        if kind == "document" { XCTAssertEqual(initial["buttons"]?.intValue, 3, "Use the real unsaved-document Delete/Cancel/Save panel.") }
        let point = CGPoint(x: try XCTUnwrap(initial["x"]).doubleValue, y: try XCTUnwrap(initial["y"]).doubleValue)
        let target = WindowInputTarget(pid: process.processIdentifier, windowID: try XCTUnwrap(initial["sheet"]).uint32Value)
        let focus = Process(); focus.executableURL = try bundle("Foreground")
        focus.arguments = [directory.appendingPathComponent("focus.json").path, "focus"]
        try focus.run()
        defer {
            let ownedWasActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processIdentifier
            if focus.isRunning { focus.terminate() }; focus.waitUntilExit()
            if ownedWasActive { _ = previous?.activate(options: []) }
        }
        let inactive = Date().addingTimeInterval(2)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != focus.processIdentifier, Date() < inactive { pump(0.05) }
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, focus.processIdentifier)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.processIdentifier else { return }
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
if CommandLine.arguments[2] == "focus" {
    let focus = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 100, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
    focus.title = "Owned focus fixture"; focus.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    app.run(); exit(0)
}
func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var raw: CFTypeRef?; return AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success ? raw : nil
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
    window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    var data: [String: NSNumber] = [:]
    let ready = Timer(timeInterval: 0.1, repeats: true) { _ in
        if data.isEmpty {
            var pending = (value(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute) as? [AXUIElement]) ?? [], visited = 0
            while let element = pending.popLast(), visited < 100 {
                visited += 1
                if value(element, kAXRoleAttribute) as? String == kAXPopUpButtonRole,
                   let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute) {
                    var point = CGPoint.zero, extent = CGSize.zero
                    if AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) {
                        var actions: CFArray?; _ = AXUIElementCopyActionNames(element, &actions)
                        data = ["sheet": NSNumber(value: window.windowNumber), "x": NSNumber(value: point.x + extent.width / 2), "y": NSNumber(value: point.y + extent.height / 2), "enabled": NSNumber(value: value(element, kAXEnabledAttribute) as? Bool == true), "supportsPress": NSNumber(value: (actions as? [String])?.contains(kAXPressAction) == true)]
                        break
                    }
                }
                pending += (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            }
        }
        guard !data.isEmpty else { return }
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
}
let document = Document(); document.fileType = "public.plain-text"
NSDocumentController.shared.addDocument(document)
let window = NSWindow(contentRect: CGRect(x: 180, y: 150, width: 700, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false; window.animationBehavior = .none
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
let controller = NSWindowController(window: window); document.addWindowController(controller)
window.makeKeyAndOrderFront(nil); app.activate()
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
document.canClose(withDelegate: result, shouldClose: #selector(CloseResult.result(_:shouldClose:context:)), contextInfo: nil)
let ready = Timer(timeInterval: 0.1, repeats: true) { timer in
    guard let sheet = window.attachedSheet else { return }
    var pending = (value(AXUIElementCreateApplication(getpid()), kAXWindowsAttribute) as? [AXUIElement]) ?? []
    var cancel: AXUIElement?, buttons = 0, visited = 0
    while let element = pending.popLast(), visited < 200 {
        visited += 1
        if value(element, kAXIdentifierAttribute) as? String == "CancelButton" { cancel = element }
        if let id = value(element, kAXIdentifierAttribute) as? String, ["CancelButton", "OKButton", "DontSaveButton"].contains(id) { buttons += 1 }
        pending += (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
    guard let cancel, let position = value(cancel, kAXPositionAttribute), let size = value(cancel, kAXSizeAttribute) else { return }
    var point = CGPoint.zero, extent = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return }
    data = ["sheet": NSNumber(value: sheet.windowNumber), "x": NSNumber(value: point.x + extent.width / 2), "y": NSNumber(value: point.y + extent.height / 2), "buttons": NSNumber(value: buttons), "enabled": NSNumber(value: value(cancel, kAXEnabledAttribute) as? Bool == true), "completions": 0]
    record(); timer.invalidate()
}
RunLoop.main.add(ready, forMode: .common)
app.run()
"""#
}
