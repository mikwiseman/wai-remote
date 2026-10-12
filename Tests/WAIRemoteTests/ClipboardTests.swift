import AppKit
import XCTest
import WebRTC
@testable import WAIRemote

final class ClipboardTests: XCTestCase {
    private func board() -> NSPasteboard { NSPasteboard.withUniqueName() }

    func testClipboardPreservesTextFormattingAndImageBytesTogether() throws {
        let source = board(), destination = board()
        defer { source.releaseGlobally(); destination.releaseGlobally() }
        let text = NSPasteboardItem(), image = NSPasteboardItem()
        text.setString("Mini → MacBook, привет 👋", forType: .string)
        text.setData(Data("<b>Привет</b>".utf8), forType: .html)
        let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try XCTUnwrap(pixels.representation(using: .png, properties: [:]))
        image.setData(png, forType: .png)
        source.writeObjects([text, image])

        let content = try XCTUnwrap(ClipboardContent.read(from: source))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try content.write(to: destination, directory: directory)

        XCTAssertEqual(destination.pasteboardItems?.count, 2)
        XCTAssertEqual(destination.string(forType: .string), "Mini → MacBook, привет 👋")
        XCTAssertEqual(destination.data(forType: .html), Data("<b>Привет</b>".utf8))
        XCTAssertEqual(destination.pasteboardItems?[1].data(forType: .png), png)
    }

    func testCopiedFilesContainBytesInsteadOfUnusableRemotePaths() throws {
        let source = board(), destination = board()
        defer { source.releaseGlobally(); destination.releaseGlobally() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("source/Папка")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
        try bytes.write(to: folder.appendingPathComponent("image.dat"))
        source.writeObjects([folder as NSURL])
        let content = try XCTUnwrap(ClipboardContent.read(from: source))
        XCTAssertEqual(Set(content.items.flatMap { $0.files ?? [] }.map { $0.path.joined(separator: "/") }), ["Папка", "Папка/empty", "Папка/image.dat"])
        try content.write(to: destination, directory: root.appendingPathComponent("received"))
        let copied = try XCTUnwrap((destination.readObjects(forClasses: [NSURL.self]) as? [URL])?.first)
        XCTAssertNotEqual(copied, folder)
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("image.dat")), bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.appendingPathComponent("empty").path))
    }

    @MainActor
    func testBidirectionalChunkedClipboardDoesNotEchoAndStopsWithoutPermission() async throws {
        let a = board(), b = board()
        defer { a.releaseGlobally(); b.releaseGlobally() }
        a.setString("before connection", forType: .string)
        b.setString("keep remote", forType: .string)
        let left = ClipboardSync(pasteboard: a), right = ClipboardSync(pasteboard: b)
        var toLeft: [Data] = [], toRight: [Data] = [], messages = 0
        left.send = { toRight.append($0); messages += 1; return true }
        right.send = { toLeft.append($0); messages += 1; return true }
        left.setEnabled(true); right.setEnabled(true); left.setOpen(true); right.setOpen(true)
        defer { left.close(); right.close() }
        func drain() {
            let l = toLeft, r = toRight; toLeft = []; toRight = []
            l.forEach(left.receive); r.forEach(right.receive)
            left.tick(); right.tick()
        }
        for _ in 0..<4 { drain() }
        XCTAssertTrue(left.available && right.available)
        XCTAssertEqual(a.string(forType: .string), "before connection")
        XCTAssertEqual(b.string(forType: .string), "keep remote")
        let image = Data((0..<120_000).map { UInt8($0 % 251) })
        a.clearContents(); a.setData(image, forType: .png); left.poll()
        for _ in 0..<200 {
            drain()
            if b.data(forType: .png) == image { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(b.data(forType: .png), image)
        for _ in 0..<5 { drain() }
        let settled = messages
        left.poll(); right.poll(); drain()
        XCTAssertEqual(messages, settled, "Received clipboard changes must not loop back.")
        b.clearContents(); b.setString("Mac Mini → MacBook 👋", forType: .string); right.poll()
        for _ in 0..<200 {
            drain()
            if a.string(forType: .string) == "Mac Mini → MacBook 👋" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(a.string(forType: .string), "Mac Mini → MacBook 👋")
        right.setEnabled(false)
        a.clearContents(); a.setString("must stay local", forType: .string); left.poll()
        for _ in 0..<30 { drain(); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(b.string(forType: .string), "Mac Mini → MacBook 👋")
        XCTAssertTrue(toLeft.allSatisfy { $0.count <= ClipboardSync.messageLimit })
    }

    @MainActor
    func testLateClipboardCannotOverwriteANewerLocalCopy() async throws {
        let b = board(); defer { b.releaseGlobally() }
        let sync = ClipboardSync(pasteboard: b)
        sync.send = { _ in true }; sync.setEnabled(true); sync.setOpen(true)
        defer { sync.close() }
        func receive(_ packet: ClipboardSync.Packet) throws { sync.receive(try JSONEncoder().encode(packet)) }
        try receive(.init(type: "hello"))
        let payload = try PropertyListEncoder().encode(ClipboardContent(items: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data("old".utf8))], files: nil)]))
        let id = UUID().uuidString
        try receive(.init(type: "begin", id: id, revision: 1, size: payload.count))
        b.clearContents(); b.setString("new local copy", forType: .string)
        try receive(.init(type: "chunk", id: id, offset: 0, data: payload))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(b.string(forType: .string), "new local copy")
    }

    func testConcealedClipboardDoesNotLeaveTheComputer() throws {
        let source = board()
        defer { source.releaseGlobally() }
        source.setString("secret", forType: .string)
        source.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        XCTAssertNil(try ClipboardContent.read(from: source))
    }

    func testUnsafeFilePathIsRejectedBeforeChangingPasteboard() throws {
        let destination = board()
        defer { destination.releaseGlobally() }
        destination.setString("keep", forType: .string)
        let content = ClipboardContent(items: [.init(representations: [], files: [.init(path: ["..", "escape"], data: Data([1]))])])
        XCTAssertThrowsError(try content.write(to: destination, directory: FileManager.default.temporaryDirectory))
        XCTAssertEqual(destination.string(forType: .string), "keep")
    }

    @MainActor
    func testRealWebRTCClipboardKeepsTheInputChannelUsable() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WAI_NETWORK_TESTS"] == "1",
                          "Opt-in network integration test: requires incoming connections for xctest. Also verify on both installed Macs.")
        _ = NSApplication.shared
        RTCInitializeSSL()
        // A command-line XCTest process does not inherit the app's SIGPIPE handling.
        signal(SIGPIPE, SIG_IGN)
        let a = board(), b = board()
        defer { a.releaseGlobally(); b.releaseGlobally() }
        let left = ClipboardSync(pasteboard: a), right = ClipboardSync(pasteboard: b)
        let factory = RTCPeerConnectionFactory()
        let host = PeerTransport(factory: factory, source: factory.videoSource(), ice: .local, clipboard: right)
        let viewer = ViewerTransport(ice: .local, clipboard: left)
        defer { host.close(); viewer.close() }
        let connected = expectation(description: "Authenticated transport is ready")
        var states: [String] = []
        host.onState = { states.append("host:\($0.rawValue)") }
        viewer.onState = { states.append("viewer:\($0.rawValue)") }
        host.onOpen = { connected.fulfill() }
        viewer.offer { result in
            guard case .success(let offer) = result else { XCTFail("Offer failed"); return }
            host.answer(offer: offer) { result in
                guard case .success(let answer) = result else { XCTFail("Answer failed"); return }
                viewer.answer(answer) { XCTAssertNil($0) }
            }
        }
        await fulfillment(of: [connected], timeout: 10)
        guard host.isReady else { XCTFail("Transport did not connect: \(states)"); return }
        left.setEnabled(true); right.setEnabled(true)
        for _ in 0..<300 {
            if left.available && right.available { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(left.available && right.available)
        let bytes = Data((0..<1_000_000).map { UInt8($0 % 251) })
        var controls = 0
        host.onMessage = { _ in controls += 1 }
        a.clearContents(); a.setData(bytes, forType: .png); left.poll()
        for _ in 0..<600 {
            XCTAssertTrue(viewer.send(Data("{}".utf8)))
            if b.data(forType: .png) == bytes { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(b.data(forType: .png), bytes)
        XCTAssertGreaterThan(controls, 0, "Input messages must pass while clipboard data is in flight.")
        b.clearContents(); b.setString("Remote copy returns", forType: .string); right.poll()
        for _ in 0..<300 {
            if a.string(forType: .string) == "Remote copy returns" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(a.string(forType: .string), "Remote copy returns")
    }

    @MainActor
    func testPasteUsesTheClipboardAtTheTimeOfTheCommand() async throws {
        let a = board(), b = board()
        defer { a.releaseGlobally(); b.releaseGlobally() }
        let left = ClipboardSync(pasteboard: a), right = ClipboardSync(pasteboard: b)
        var toLeft: [Data] = [], toRight: [Data] = []
        left.send = { toRight.append($0); return true }
        right.send = { toLeft.append($0); return true }
        left.setEnabled(true); right.setEnabled(true); left.setOpen(true); right.setOpen(true)
        defer { left.close(); right.close() }
        func drain() {
            let l = toLeft, r = toRight; toLeft = []; toRight = []
            l.forEach(left.receive); r.forEach(right.receive); left.tick(); right.tick()
        }
        for _ in 0..<4 { drain() }
        a.clearContents(); a.setString("paste this", forType: .string)
        var pasted: String?
        left.pushCurrent { pasted = b.string(forType: .string) }
        a.clearContents(); a.setString("copied afterwards", forType: .string)
        for _ in 0..<200 {
            drain()
            if pasted != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pasted, "paste this")
        left.poll()
        for _ in 0..<200 {
            drain()
            if b.string(forType: .string) == "copied afterwards" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(b.string(forType: .string), "copied afterwards")
    }

    func testReceivedFilesCacheIsBoundedAndKeepsCurrentPasteboardFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var transfers: [URL] = []
        for _ in 0..<6 {
            let url = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: url.appendingPathComponent("copied-file"))
            transfers.append(url)
        }
        let unrelated = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        ClipboardSync.trimCache(root, keeping: transfers[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: transfers[0].appendingPathComponent("copied-file").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(transfers.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 3)
    }

    @MainActor
    func testAnotherSessionDoesNotRelayAReceivedClipboardAutomatically() throws {
        let board = board(); defer { board.releaseGlobally() }
        let sync = ClipboardSync(pasteboard: board)
        var packets: [ClipboardSync.Packet] = []
        sync.send = { if let p = try? JSONDecoder().decode(ClipboardSync.Packet.self, from: $0) { packets.append(p) }; return true }
        sync.setEnabled(true); sync.setOpen(true)
        defer { sync.close() }
        sync.receive(try JSONEncoder().encode(ClipboardSync.Packet(type: "hello")))
        let content = ClipboardContent(items: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data("from third Mac".utf8))], files: nil)])
        let objects = try content.objects(directory: FileManager.default.temporaryDirectory, markReceived: true)
        board.clearContents(); board.writeObjects(objects); sync.poll()
        XCTAssertFalse(packets.contains { $0.type == "begin" })
        let snapshot = try XCTUnwrap(ClipboardContent.read(from: board))
        XCTAssertEqual(snapshot.items.first?.representations.count, 1, "Local origin markers must never leave this Mac.")
    }
}
