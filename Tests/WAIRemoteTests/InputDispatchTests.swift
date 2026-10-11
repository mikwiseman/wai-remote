import AppKit
import WebRTC
import XCTest
@testable import WAIRemote

@MainActor
final class InputDispatchTests: XCTestCase {
    func testMouseUpCanArriveWhileAppKitTracksTheMouseDown() throws {
        _ = NSApplication.shared
        let factory = RTCPeerConnectionFactory()
        let pc = factory.peerConnection(with: RTCConfiguration(), constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil)!
        let channel = try XCTUnwrap(pc.dataChannel(forLabel: "interaction", configuration: RTCDataChannelConfiguration()))
        let host = PeerTransport(factory: factory, source: factory.videoSource(forScreenCast: true), ice: .local)
        let viewer = ViewerTransport(ice: .local)
        defer { host.close(); viewer.close(); pc.close() }
        var delivered = Set<String>()
        host.onMessage = { _ in delivered.insert("host") }
        viewer.onMessage = { _ in delivered.insert("viewer") }
        let tracked = expectation(description: "Nested AppKit loop")
        DispatchQueue.main.async {
            let queued = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                let buffer = RTCDataBuffer(data: Data("{}".utf8), isBinary: false)
                host.dataChannel(channel, didReceiveMessageWith: buffer)
                viewer.dataChannel(channel, didReceiveMessageWith: buffer)
                queued.signal()
            }
            XCTAssertEqual(queued.wait(timeout: .now() + 1), .success)
            let deadline = Date().addingTimeInterval(0.15)
            while Date() < deadline && delivered.count < 2 { RunLoop.main.run(mode: .eventTracking, before: deadline) }
            XCTAssertEqual(delivered, ["host", "viewer"], "AppKit's nested mouse/menu loop must receive input and releases without waiting for the drag to end.")
            tracked.fulfill()
        }
        wait(for: [tracked], timeout: 2)
    }
}
