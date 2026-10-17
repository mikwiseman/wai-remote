import AppKit
import WebRTC
import XCTest
@testable import WAIRemote

@MainActor
final class InputDispatchTests: XCTestCase {
    func testPointerFloodKeepsLatestPositionWithoutDelayingClicksOrCrossingReleases() async {
        let delivery = InputDeliveryQueue()
        let entered = expectation(description: "Input temporarily busy")
        let finished = expectation(description: "Gesture delivered")
        let resume = DispatchSemaphore(value: 0)
        var delivered: [String] = []
        delivery.submit { _ in entered.fulfill(); _ = resume.wait(timeout: .now() + 2) }
        await fulfillment(of: [entered], timeout: 1)
        for i in 0..<1_000 { delivery.submit(coalescingPointerMove: true) { _ in delivered.append("hover \(i)") } }
        delivery.submit { _ in delivered.append("down") }
        for i in 0..<1_000 { delivery.submit(coalescingPointerMove: true) { _ in delivered.append("drag \(i)") } }
        delivery.submit { _ in delivered.append("up") }
        delivery.submit { _ in delivered.append("key") }
        delivery.submit(coalescingPointerMove: true) { _ in delivered.append("next hover") }
        delivery.submit { _ in finished.fulfill() }
        resume.signal()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(delivered, ["hover 999", "down", "drag 999", "up", "key", "next hover"],
                       "Outdated pointer positions must not build a backlog or move a gesture across its down/up boundary.")
    }

    func testAccessibilityActionForOurWindowRunsOnMainAndRechecksCancellation() async {
        let finished = expectation(description: "Press returned")
        let button = WindowInputTarget.Button(frame: .zero, requiresMainThread: true, action: {
            XCTAssertTrue(Thread.isMainThread, "SwiftUI accessibility actions require MainActor")
            return true
        })
        DispatchQueue.global().async {
            XCTAssertTrue(button.press(if: { true }))
            let cancelled = WindowInputTarget.Button(frame: .zero, requiresMainThread: true, action: {
                XCTFail("A cancelled session must not perform its pending button action"); return true
            })
            XCTAssertFalse(cancelled.press(if: { false }))
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
    }

    func testReleaseCancelsWaitingAndInFlightInputBeforeTheNextSession() async {
        let delivery = InputDeliveryQueue()
        let entered = expectation(description: "Lookup started")
        let finished = expectation(description: "New input delivered")
        let resume = DispatchSemaphore(value: 0)
        var delivered: [String] = []
        delivery.submit { current in
            entered.fulfill()
            _ = resume.wait(timeout: .now() + 2)
            if current() { delivered.append("stale lookup") }
        }
        await fulfillment(of: [entered], timeout: 1)
        delivery.submit { _ in delivered.append("stale queued input") }
        delivery.cancel { delivered.append("release") }
        delivery.submit { _ in delivered.append("new input"); finished.fulfill() }
        resume.signal()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(delivered, ["release", "new input"])
    }

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
