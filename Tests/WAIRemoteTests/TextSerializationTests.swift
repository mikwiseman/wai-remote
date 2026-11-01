import AppKit
import RemoteCore
import XCTest
@testable import WAIRemote

@MainActor
final class TextSerializationTests: XCTestCase {
    private final class Sender: MacViewerModel {
        var packets: [String] = []
        var failAfter: Int?
        let host = SessionMachine(surface: Surface(id: "text", width: 640, height: 480))
        override var canControl: Bool { true }
        override func send(_ type: String, edit: (inout WireMessage) -> Void = { _ in }) -> Bool {
            guard failAfter != packets.count else { return false }
            var message = WireMessage(type: type, state: host.state)
            edit(&message)
            XCTAssertEqual(type, "text")
            packets.append(message.text ?? "")
            return true
        }
    }

    func testMultilineTextArrivesIntactInNativeTextViewThroughExistingHostEvents() throws {
        let text = "\n" + (1...40).map { String(format: "WAI scroll check — line %02d", $0) }.joined(separator: "\n")
        let sender = Sender(identity: DeviceIdentity())
        sender.text(text)
        XCTAssertEqual(try insertThroughExistingHost(sender.packets), text,
            "A native text view interprets a leading control as a command and can discard the rest of that event.")
    }

    func testControlsAreSeparatePacketsWithoutChangingUnicodeOrWireLimit() {
        let sender = Sender(identity: DeviceIdentity())
        let text = "\r\n\t" + String(repeating: "🙂e\u{301}", count: 1500) + "\tЗдравствуйте\nlast\r"
        sender.text(text)
        XCTAssertEqual(sender.packets.joined(), text)
        for packet in sender.packets {
            XCTAssertFalse(packet.isEmpty)
            XCTAssertLessThanOrEqual(packet.utf16.count, 4096)
            if packet.unicodeScalars.contains(where: { [9, 10, 13].contains($0.value) }) {
                XCTAssertTrue(packet.unicodeScalars.count == 1 || packet == "\r\n",
                    "CR, LF, CRLF and Tab must not consume adjacent text.")
            }
        }
    }

    func testCRLFProducesOneNativeReturnAndPreservesWireBytes() throws {
        let sender = Sender(identity: DeviceIdentity())
        let text = "first\r\nПривет café 日本語 👋\r\nlast"
        sender.text(text)
        XCTAssertEqual(sender.packets.joined(), text)
        XCTAssertEqual(try insertThroughExistingHost(sender.packets), text.replacingOccurrences(of: "\r\n", with: "\n"))
    }

    func testTabAndReturnKeepFollowingUnicodeInNativeTextView() throws {
        for (text, expected) in [("\tПривет café 日本語 👋", "\tПривет café 日本語 👋"),
                                 ("\rПривет café 日本語 👋", "\nПривет café 日本語 👋")] {
            let sender = Sender(identity: DeviceIdentity())
            sender.text(text)
            XCTAssertEqual(try insertThroughExistingHost(sender.packets), expected)
        }
    }

    func testFailedControlSendStopsBeforeFollowingText() {
        for control in ["\n", "\r", "\r\n", "\t"] {
            let sender = Sender(identity: DeviceIdentity())
            sender.failAfter = 1
            sender.text("first" + control + "second")
            XCTAssertEqual(sender.packets, ["first"], "Do not continue typing after a failed packet.")
        }
    }

    // Reproduce the existing host's 20-UTF16-unit CGEvents without any global
    // posting, input permission, real saved computer, or visible window.
    private func insertThroughExistingHost(_ packets: [String]) throws -> String {
        _ = NSApplication.shared
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        defer { window.close() }
        for text in packets {
            var chunk: [UniChar] = []
            func flush() throws {
                guard !chunk.isEmpty else { return }
                let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                view.interpretKeyEvents([try XCTUnwrap(NSEvent(cgEvent: event))])
                chunk.removeAll(keepingCapacity: true)
            }
            for character in text {
                let units = Array(String(character).utf16)
                if chunk.count + units.count > 20 { try flush() }
                chunk += units
            }
            try flush()
        }
        return view.string
    }
}
