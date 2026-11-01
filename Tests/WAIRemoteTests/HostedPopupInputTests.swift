import AppKit
import Darwin
import RemoteCore
import XCTest
@testable import WAIRemote

/// The standard NSDocument format selector lives inside the real XPC save
/// panel. No document is saved; only the owned panel's format choice changes.
@MainActor
final class HostedPopupInputTests: XCTestCase {
    private func pump(_ duration: TimeInterval) {
        let stop = Timer(timeInterval: duration, repeats: false) { _ in
            NSApp.stop(nil)
            NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        RunLoop.main.add(stop, forMode: .common)
        NSApp.run(); stop.invalidate()
    }
    private func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.03)
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success ? raw : nil
    }
    private func find(in roots: [AXUIElement], matching: (AXUIElement) -> Bool) -> AXUIElement? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        var pending = roots, visited = 0
        while let element = pending.popLast(), visited < 200, ProcessInfo.processInfo.systemUptime < deadline {
            visited += 1
            if matching(element) { return element }
            pending += (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return nil
    }
    private func center(_ element: AXUIElement) -> CGPoint? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent), extent.width > 0, extent.height > 0 else { return nil }
        return CGPoint(x: origin.x + extent.width / 2, y: origin.y + extent.height / 2)
    }
    private func windowID(_ element: AXUIElement) -> CGWindowID? {
        WindowInputTarget.axWindowID(element, deadline: ProcessInfo.processInfo.systemUptime + 0.03)
    }
    private func owner(_ windowID: CGWindowID) -> pid_t? {
        _ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let library = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connection = dlsym(library, "SLSMainConnectionID"), let owner = dlsym(library, "SLSGetWindowOwner"),
              let pid = dlsym(library, "SLSConnectionGetPID") else { return nil }
        let getConnection = unsafeBitCast(connection, to: (@convention(c) () -> Int32).self)
        let getOwner = unsafeBitCast(owner, to: (@convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Int32>) -> Int32).self)
        let getPID = unsafeBitCast(pid, to: (@convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Int32).self)
        var ownedConnection: Int32 = 0, result: pid_t = 0
        guard getOwner(getConnection(), windowID, &ownedConnection) == 0, getPID(ownedConnection, &result) == 0 else { return nil }
        return result
    }
    private func click(_ point: CGPoint, injector: InputInjector) {
        for action in ["down", "up"] {
            var event = WireMessage(type: "pointer", state: SessionMachine(surface: .init(id: "hosted-popup", width: 800, height: 600)).state)
            event.action = action; event.button = 0
            event.x = (point.x - injector.bounds.minX) / max(1, injector.bounds.width - 1)
            event.y = (point.y - injector.bounds.minY) / max(1, injector.bounds.height - 1)
            injector.apply(event)
        }
    }
    private func diagnoseHit(target: WindowInputTarget, point: CGPoint,
                             actual: WindowInputTarget?, state: [String: NSNumber]) {
        print("HOSTED_POPUP_HIT expected=\(target.pid):\(target.windowID) actual=\(String(describing: actual)) point=\(point) state=\(state)")
        let windows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, 0) as? [[String: Any]]) ?? []
        for window in windows where (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.pid {
            print("HOSTED_POPUP_OWNED_WINDOW id=\(window[kCGWindowNumber as String] ?? 0) layer=\(window[kCGWindowLayer as String] ?? 0) bounds=\(window[kCGWindowBounds as String] ?? [:])")
        }
    }
    private func assertStaleReceiverRejectsKeyUp(_ target: WindowInputTarget) throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: false))
        event.flags = []
        var delivered = 0, delivery = WindowInputTarget.Delivery.system
        delivery.key = { _, _ in delivered += 1 }
        XCTAssertEqual(target.post(event, permitted: { true }, delivery: delivery), .frameGone)
        XCTAssertEqual(delivered, 0, "A stale menu key must never reach its former service or another window")
    }
    func testHostedFormatPopupSelectsItsSecondItem() throws { try interact(select: true) }
    func testEscapeDismissesHostedFormatMenuWithoutClosingThePanel() throws { try interact(select: false) }
    func testEscapeDismissesStandaloneHostedFormatMenuWithoutClosingThePanel() throws {
        try interact(select: false, standalone: true)
    }

    func testStandaloneHostedMenuCannotBorrowAnUnrelatedWindow() throws {
        try interact(select: false, standalone: true, inspectScope: true)
    }

    private func interact(select: Bool, standalone: Bool = false, inspectScope: Bool = false) throws {
        try XCTSkipUnless(CGPreflightPostEventAccess() && AXIsProcessTrusted(), "Requires existing native input permissions; never requests access")
        let initialFailures = testRun?.failureCount ?? 0
        let app = NSApplication.shared, previousPolicy = NSApplication.shared.activationPolicy()
        let previous = NSWorkspace.shared.frontmostApplication
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(previousPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wai-hosted-popup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("fixture.swift")
        let contents = directory.appendingPathComponent("Fixture.app/Contents")
        let executable = contents.appendingPathComponent("MacOS/fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.fixture.write(to: source, atomically: true, encoding: .utf8)
        let info: [String: Any] = ["CFBundleExecutable": "fixture", "CFBundleIdentifier": "is.wai.tests.hosted-popup.\(UUID())",
            "CFBundleName": "Owned hosted popup", "CFBundlePackageType": "APPL", "CFBundleDocumentTypes": [
                ["CFBundleTypeName": "First owned format", "CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.plain-text"], "NSDocumentClass": "Document"],
                ["CFBundleTypeName": "Second owned format", "CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.rtf"], "NSDocumentClass": "Document"]]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let compiler = Process(), diagnostics = Pipe()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-swift-version", "5", source.path, "-framework", "AppKit", "-o", executable.path]
        compiler.standardOutput = diagnostics; compiler.standardError = diagnostics
        try compiler.run(); let compilerOutput = diagnostics.fileHandleForReading.readDataToEndOfFile(); compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0, String(decoding: compilerOutput, as: UTF8.self))
        guard compiler.terminationStatus == 0 else { return }
        let stateURL = directory.appendingPathComponent("state.json"), childLog = directory.appendingPathComponent("child.log")
        FileManager.default.createFile(atPath: childLog.path, contents: nil)
        let output = try FileHandle(forWritingTo: childLog)
        let child = Process(); child.executableURL = executable
        // NSDocumentController treats argv paths as documents to open.
        child.environment = ProcessInfo.processInfo.environment.merging([
            "WAI_HOSTED_POPUP_STATE_PATH": stateURL.path,
            "WAI_HOSTED_POPUP_DIRECTORY_PATH": directory.path,
            "WAI_HOSTED_POPUP_MODE": standalone ? "standalone" : "sheet"
        ]) { _, fixtureValue in fixtureValue }
        child.standardOutput = output; child.standardError = output
        try child.run()
        defer {
            let ownedWasActive = NSWorkspace.shared.frontmostApplication?.processIdentifier == child.processIdentifier
            let exitedUnexpectedly = !child.isRunning
            if child.isRunning { child.terminate() }; child.waitUntilExit()
            try? output.close()
            if exitedUnexpectedly || (testRun?.failureCount ?? 0) > initialFailures,
               let log = try? String(contentsOf: childLog, encoding: .utf8), !log.isEmpty {
                print("HOSTED_POPUP_CHILD \(log)")
            }
            if ownedWasActive { _ = previous?.activate(options: []) }
        }
        func state() -> [String: NSNumber] {
            guard let data = try? Data(contentsOf: stateURL), let object = try? JSONSerialization.jsonObject(with: data) else { return [:] }
            return object as? [String: NSNumber] ?? [:]
        }
        let application = AXUIElementCreateApplication(child.processIdentifier)
        let ready = Date().addingTimeInterval(7)
        var popup: AXUIElement?
        repeat {
            pump(0.05)
            guard state()["active"]?.boolValue == true, state()["sheet"] != nil else { continue }
            let windows = (value(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            popup = find(in: windows) {
                value($0, kAXRoleAttribute) as? String == kAXPopUpButtonRole &&
                value($0, kAXValueAttribute) as? String == "First owned format" && center($0) != nil
            }
        } while popup == nil && child.isRunning && Date() < ready
        guard let popup else {
            let windows = (value(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            _ = find(in: windows) {
                if value($0, kAXRoleAttribute) as? String == kAXPopUpButtonRole {
                    print("HOSTED_POPUP_CANDIDATE value=\(String(describing: value($0, kAXValueAttribute))) title=\(String(describing: value($0, kAXTitleAttribute))) id=\(windowID($0) ?? 0)")
                }
                return false
            }
            XCTFail("The owned document must expose its real File Format popup before input"); return
        }
        let target = WindowInputTarget(pid: child.processIdentifier, windowID: try XCTUnwrap(state()["sheet"]).uint32Value)
        if standalone {
            let windows = (value(application, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            let outer = try XCTUnwrap(windows.first { windowID($0) == target.windowID })
            XCTAssertEqual(value(outer, kAXRoleAttribute) as? String, kAXWindowRole,
                           "The standalone case must exercise a host window, not an attached AXSheet")
        }
        let point = try XCTUnwrap(center(popup)), virtualID = try XCTUnwrap(windowID(popup))
        var proxyPID: pid_t = 0; AXUIElementGetPid(popup, &proxyPID)
        let remotePID = try XCTUnwrap(owner(virtualID))
        print("HOSTED_POPUP_TOPOLOGY standalone=\(standalone) outer=\(target.pid):\(target.windowID) proxy=\(proxyPID):\(virtualID) actualOwner=\(remotePID)")
        XCTAssertNotEqual(virtualID, target.windowID)
        XCTAssertNotEqual(remotePID, target.pid, "This must exercise an actual cross-process hosted popup")
        guard virtualID != target.windowID, remotePID != target.pid else { return }
        let actualTarget = DesktopInputTarget.target(at: point, excluding: [])
        if actualTarget != target { diagnoseHit(target: target, point: point, actual: actualTarget, state: state()) }
        XCTAssertEqual(actualTarget, target)
        guard actualTarget == target else { return }
        let pointer = try XCTUnwrap(CGEvent(source: nil)).location
        let injector = InputInjector(); injector.setIndependentPointer(true)
        defer { injector.resetSession() }
        click(point, injector: injector)
        let opened = Date().addingTimeInterval(2)
        var item: AXUIElement?, menuTarget: WindowInputTarget?
        repeat {
            pump(0.05)
            item = find(in: [popup]) {
                value($0, kAXRoleAttribute) as? String == kAXMenuItemRole &&
                value($0, kAXTitleAttribute) as? String == "Second owned format"
            }
            if let item, let point = center(item), let actual = DesktopInputTarget.target(at: point, excluding: []), actual.windowID != target.windowID {
                menuTarget = actual
            }
        } while menuTarget == nil && Date() < opened
        let menu = try XCTUnwrap(menuTarget, "One production click must open the real remote popup menu")
        let second = try XCTUnwrap(item), secondPoint = try XCTUnwrap(center(second))
        print("HOSTED_POPUP_MENU target=\(menu.pid):\(menu.windowID) itemWindow=\(windowID(second) ?? 0)")
        XCTAssertEqual(menu.pid, remotePID)
        var retainedMenuDestination: WindowInputTarget?
        if inspectScope {
            let documentID = try XCTUnwrap(state()["document"]).uint32Value
            XCTAssertNotEqual(documentID, target.windowID)
            XCTAssertEqual(state()["attached"]?.intValue, 0, "The unrelated document has no attached sheet")
            let unrelated = WindowInputTarget(pid: target.pid, windowID: documentID)
            XCTAssertNotNil(unrelated.frame)
            let otherDestination = try XCTUnwrap(unrelated.keyboardDestination())
            XCTAssertEqual(otherDestination.pid, unrelated.pid)
            XCTAssertEqual(otherDestination.windowID, unrelated.windowID)
            XCTAssertNil(otherDestination.keyboardReceiver, "An unrelated document cannot borrow the open remote menu")
            let selectedDestination = try XCTUnwrap(target.keyboardDestination())
            let selectedReceiver = try XCTUnwrap(selectedDestination.keyboardReceiver)
            XCTAssertEqual(selectedReceiver.pid, menu.pid)
            XCTAssertEqual(selectedReceiver.windowID, menu.windowID)
            let menuFrame = try XCTUnwrap(selectedReceiver.windowFrame)
            XCTAssertEqual(menuFrame, menu.frame)
            retainedMenuDestination = selectedDestination
            var changedGeometry = selectedDestination
            changedGeometry.keyboardReceiver?.windowFrame = menuFrame.offsetBy(dx: 1, dy: 0)
            try assertStaleReceiverRejectsKeyUp(changedGeometry)
        }
        if select { click(secondPoint, injector: injector) }
        else {
            for action in ["down", "up"] {
                var event = WireMessage(type: "key", state: SessionMachine(surface: .init(id: "hosted-popup", width: 800, height: 600)).state)
                event.key = "Escape"; event.action = action; injector.apply(event)
            }
        }
        let completed = Date().addingTimeInterval(2)
        while menu.frame != nil && Date() < completed { pump(0.05) }
        let selected = value(popup, kAXValueAttribute) as? String
        XCTAssertNil(menu.frame, "The single selection or Escape must dismiss the transient menu")
        XCTAssertEqual(selected, select ? "Second owned format" : "First owned format")
        XCTAssertNotNil(target.frame, "Escape dismisses the menu, not the save panel")
        XCTAssertEqual(state()["writes"]?.intValue, 0, "The test never saves a document")
        XCTAssertEqual(try XCTUnwrap(CGEvent(source: nil)).location, pointer)
        print("HOSTED_POPUP_RESULT select=\(select) value=\(selected ?? "nil") menuClosed=\(menu.frame == nil) panelAlive=\(target.frame != nil)")
        if menu.frame == nil {
            if let retainedMenuDestination { try assertStaleReceiverRejectsKeyUp(retainedMenuDestination) }
            let receiver = try XCTUnwrap(target.keyboardDestination()?.keyboardReceiver)
            XCTAssertEqual(receiver.pid, remotePID)
            XCTAssertEqual(receiver.windowID, virtualID, "A dismissed menu cannot remain the keyboard receiver")
            XCTAssertNotEqual(receiver.windowID, menu.windowID)
        }
    }

    private static let fixture = #"""
import AppKit
import Darwin
let configuration = ProcessInfo.processInfo.environment
let metadata = URL(fileURLWithPath: configuration["WAI_HOSTED_POPUP_STATE_PATH"]!)
DispatchQueue.global().asyncAfter(deadline: .now() + 25) { exit(2) }
let app = NSApplication.shared
app.setActivationPolicy(.regular); app.finishLaunching()
var writes = 0
let standalone = configuration["WAI_HOSTED_POPUP_MODE"] == "standalone"
var preparedPanel: NSSavePanel?
final class Document: NSDocument {
    override class var readableTypes: [String] { ["public.plain-text", "public.rtf"] }
    override class var writableTypes: [String] { readableTypes }
    override class func isNativeType(_ type: String) -> Bool { readableTypes.contains(type) }
    override var windowForSheet: NSWindow? { standalone ? nil : super.windowForSheet }
    override func data(ofType typeName: String) throws -> Data {
        writes += 1; throw NSError(domain: "FixtureNeverSaves", code: 1)
    }
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        preparedPanel = savePanel
        savePanel.directoryURL = URL(fileURLWithPath: configuration["WAI_HOSTED_POPUP_DIRECTORY_PATH"]!, isDirectory: true)
        savePanel.canCreateDirectories = false
        savePanel.nameFieldStringValue = "Owned unsaved popup fixture.txt"
        return true
    }
}
let document = Document(); document.fileType = "public.plain-text"
NSDocumentController.shared.addDocument(document)
let window = NSWindow(contentRect: CGRect(x: 180, y: 150, width: 700, height: 500),
    styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.isReleasedWhenClosed = false; window.animationBehavior = .none
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
document.addWindowController(NSWindowController(window: window))
let record = Timer(timeInterval: 0.05, repeats: true) { _ in
    guard let sheet = standalone ? preparedPanel : window.attachedSheet, sheet.isVisible else { return }
    let data: [String: NSNumber] = ["sheet": NSNumber(value: sheet.windowNumber),
        "document": NSNumber(value: window.windowNumber), "attached": NSNumber(value: window.attachedSheet?.windowNumber ?? 0),
        "active": NSNumber(value: app.isActive), "writes": NSNumber(value: writes)]
    try! JSONSerialization.data(withJSONObject: data).write(to: metadata, options: .atomic)
}
RunLoop.main.add(record, forMode: .common)
DispatchQueue.main.async {
    window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
    document.saveAs(nil)
}
app.run()
"""#
}
