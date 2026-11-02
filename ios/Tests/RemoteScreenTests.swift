import XCTest
import UIKit
import MetalKit
import WebRTC
import RemoteCore
@testable import WAI_Remote

@MainActor
final class RemoteScreenTests: XCTestCase {
    private final class Finger: UITouch {
        var point: CGPoint
        init(_ x: CGFloat, _ y: CGFloat) { point = CGPoint(x: x, y: y); super.init() }
        override func location(in view: UIView?) -> CGPoint { point }
    }
    private final class TouchEvent: UIEvent {
        let fingers: Set<UITouch>
        let time: TimeInterval
        init(_ fingers: Set<UITouch>, at time: TimeInterval) { self.fingers = fingers; self.time = time; super.init() }
        override var allTouches: Set<UITouch>? { fingers }
        override var timestamp: TimeInterval { time }
    }

    private func screen(surface: CGSize = CGSize(width: 1600, height: 1600),
                        viewport: CGSize = CGSize(width: 400, height: 400)) -> (PhoneModel, ScreenView) {
        let model = PhoneModel()
        model.acceptDemo(SessionMachine(surface: .init(id: "touch-test", width: Int(surface.width), height: Int(surface.height))).state)
        model.connected = true; model.receivedFrame = true
        model.onTransmitForTesting = { _ in }
        let screen = ScreenView(model: model)
        screen.frame = CGRect(origin: .zero, size: viewport)
        screen.update(); screen.layoutIfNeeded()
        return (model, screen)
    }

    func testTapKeepsTheTargetWhereTheFingerLanded() throws {
        let (model, screen) = screen()
        var sent: [WireMessage] = []
        model.onTransmitForTesting = { sent.append($0) }
        let finger = Finger(200, 200)
        screen.touchesBegan([finger], with: nil)
        finger.point = CGPoint(x: 206, y: 204)
        screen.touchesMoved([finger], with: nil)
        screen.touchesEnded([finger], with: nil)
        let click = try XCTUnwrap(sent.first { $0.action == "down" })
        XCTAssertEqual(click.x, 0.5, "A small lift-off movement must not miss a small Mac button.")
        XCTAssertEqual(click.y, 0.5)
        XCTAssertEqual(sent.filter { $0.type == "pointer" }.map(\.action), ["down", "up"])
    }

    func testTwoFingerScrollFollowsTheFingersAndKeepsItsOriginalTarget() throws {
        let (model, screen) = screen()
        var sent: [WireMessage] = []
        model.onTransmitForTesting = { sent.append($0) }
        let left = Finger(150, 150), right = Finger(250, 150)
        screen.touchesBegan([left, right], with: nil)
        left.point.y += 20; right.point.y += 20
        screen.touchesMoved([left, right], with: nil)
        screen.advanceScrollForTesting(at: ProcessInfo.processInfo.systemUptime)
        left.point.y += 20; right.point.y += 20
        screen.touchesMoved([left, right], with: nil)
        screen.advanceScrollForTesting(at: ProcessInfo.processInfo.systemUptime)
        let scrolls = sent.filter { $0.action == "scroll" }
        XCTAssertEqual(scrolls.count, 2)
        for (index, scroll) in scrolls.enumerated() {
            XCTAssertEqual(try XCTUnwrap(scroll.deltaY), index == 0 ? -48 : -80, accuracy: 0.001,
                           "The host negates wheel deltas; scrolling must follow the fingers at the displayed image scale.")
            XCTAssertEqual(scroll.x, 0.5)
            XCTAssertEqual(scroll.y, 0.375, "Crossing another Mac pane must not redirect an ongoing scroll.")
        }
        screen.touchesEnded([left], with: nil)
        right.point.y += 30
        screen.touchesMoved([right], with: nil)
        screen.touchesEnded([right], with: nil)
        XCTAssertFalse(sent.contains { $0.action == "down" }, "Lifting one finger must not turn navigation into a click.")
    }

    func testPinchKeepsTheMacPointUnderTheFingers() throws {
        let (_, screen) = screen()
        let content = try XCTUnwrap(screen.subviews.first)
        let anchor = CGPoint(x: 150, y: 150)
        let initial = content.convert(anchor, from: screen)
        let target = CGPoint(x: initial.x / content.bounds.width, y: initial.y / content.bounds.height)
        let left = Finger(110, 150), right = Finger(190, 150)
        screen.touchesBegan([left, right], with: nil)
        left.point.x = 70; right.point.x = 230
        screen.touchesMoved([left, right], with: nil)
        screen.layoutIfNeeded()
        let zoomed = content.convert(anchor, from: screen)
        XCTAssertEqual(content.bounds.width, 800, accuracy: 0.001)
        XCTAssertEqual(zoomed.x / content.bounds.width, target.x, accuracy: 0.001)
        XCTAssertEqual(zoomed.y / content.bounds.height, target.y, accuracy: 0.001)
        screen.touchesEnded([left, right], with: nil)
    }

    func testReplacementFingerResumesScrollAndStillIgnoresAThirdFinger() throws {
        let (model, screen) = screen()
        defer { screen.detach() }
        var sent: [WireMessage] = []
        model.onTransmitForTesting = { sent.append($0) }
        let left = Finger(150, 150), right = Finger(250, 150)
        screen.touchesBegan([left, right], with: TouchEvent([left, right], at: 100))
        left.point.y += 20; right.point.y += 20
        screen.touchesMoved([left, right], with: TouchEvent([left, right], at: 100.02))
        screen.advanceScrollForTesting(at: 100.03)
        screen.touchesEnded([left], with: TouchEvent([left, right], at: 100.04))
        screen.advanceScrollForTesting(at: 100.05)
        XCTAssertEqual(sent.last?.momentumPhase, "began")

        let replacement = Finger(100, 210)
        screen.touchesBegan([replacement], with: TouchEvent([right, replacement], at: 100.06))
        XCTAssertEqual(sent.last { $0.action == "scroll" }?.momentumPhase, "ended")
        let restart = sent.count
        replacement.point.y += 20; right.point.y += 20
        screen.touchesMoved([replacement, right], with: TouchEvent([replacement, right], at: 100.08))
        screen.advanceScrollForTesting(at: 100.09)

        let extra = Finger(380, 380)
        screen.touchesBegan([extra], with: TouchEvent([replacement, right, extra], at: 100.10))
        replacement.point.y += 20; right.point.y += 20
        screen.touchesMoved([replacement, right], with: TouchEvent([replacement, right, extra], at: 100.12))
        screen.advanceScrollForTesting(at: 100.13)
        screen.touchesEnded([extra], with: TouchEvent([replacement, right, extra], at: 100.14))
        replacement.point.y += 4; right.point.y += 4
        screen.touchesMoved([replacement, right], with: TouchEvent([replacement, right], at: 100.16))
        screen.advanceScrollForTesting(at: 100.17)
        screen.touchesEnded([replacement, right], with: TouchEvent([replacement, right], at: 100.3))

        let resumed = sent.dropFirst(restart).filter { $0.action == "scroll" }
        XCTAssertEqual(resumed.compactMap(\.scrollPhase), ["began", "changed", "changed", "ended"])
        XCTAssertEqual(resumed.compactMap(\.deltaY), [-48, -80, -16, 0], "Only the new gesture's 8-point recognition slop is consumed.")
        for packet in resumed {
            XCTAssertEqual(packet.x, 0.4375)
            XCTAssertEqual(packet.y, 0.475, "The replacement pair gets a fresh target; a third finger cannot replace it.")
            XCTAssertNil(packet.momentumPhase)
        }
        XCTAssertFalse(sent.contains { $0.action == "down" || $0.action == "up" })
    }

    func testReplacementFingerStartsANewPinch() throws {
        let (model, screen) = screen()
        defer { screen.detach() }
        var sent: [WireMessage] = []
        model.onTransmitForTesting = { sent.append($0) }
        let left = Finger(110, 150), right = Finger(190, 150)
        screen.touchesBegan([left, right], with: TouchEvent([left, right], at: 100))
        left.point.x = 70; right.point.x = 230
        screen.touchesMoved([left, right], with: TouchEvent([left, right], at: 100.02))
        screen.layoutIfNeeded()
        XCTAssertEqual(screen.subviews.first?.bounds.width, 800)
        screen.touchesEnded([left], with: TouchEvent([left, right], at: 100.04))

        let replacement = Finger(70, 150)
        screen.touchesBegan([replacement], with: TouchEvent([right, replacement], at: 100.06))
        replacement.point.x = 30; right.point.x = 270
        screen.touchesMoved([replacement, right], with: TouchEvent([replacement, right], at: 100.08))
        screen.layoutIfNeeded()
        XCTAssertEqual(screen.subviews.first?.bounds.width, 1200, "The retained and replacement fingers form a new pinch pair.")
        XCTAssertFalse(sent.contains { $0.action == "scroll" || $0.action == "down" || $0.action == "up" })
        screen.touchesEnded([replacement, right], with: TouchEvent([replacement, right], at: 100.1))
    }

    func testSmallFingerSpacingDriftDoesNotTurnAScrollIntoZoom() {
        let (model, screen) = screen()
        var sent: [WireMessage] = []
        model.onTransmitForTesting = { sent.append($0) }
        let left = Finger(150, 150), right = Finger(250, 150)
        screen.touchesBegan([left, right], with: nil)
        left.point = CGPoint(x: 145, y: 170); right.point = CGPoint(x: 255, y: 170)
        screen.touchesMoved([left, right], with: nil)
        screen.advanceScrollForTesting(at: ProcessInfo.processInfo.systemUptime)
        screen.layoutIfNeeded()
        XCTAssertEqual(sent.filter { $0.action == "scroll" }.count, 1)
        XCTAssertEqual(screen.subviews.first?.bounds.width, 400,
                       "Two fingers moving together must scroll despite a small change in spacing.")
        screen.touchesEnded([left, right], with: nil)
    }

    func testPinchPreservesTapTargetWithinLetterboxedViewports() throws {
        for viewport in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390),
                         CGSize(width: 390, height: 350)] {
            let (model, screen) = screen(surface: CGSize(width: 1600, height: 900), viewport: viewport)
            let content = try XCTUnwrap(screen.subviews.first)
            let anchor = CGPoint(x: content.frame.minX + content.bounds.width * 0.35,
                                 y: content.frame.minY + content.bounds.height * 0.35)
            let left = Finger(anchor.x - 40, anchor.y), right = Finger(anchor.x + 40, anchor.y)
            screen.touchesBegan([left, right], with: nil)
            left.point.x -= 6; right.point.x += 6
            screen.touchesMoved([left, right], with: nil)
            screen.layoutIfNeeded()
            screen.touchesEnded([left, right], with: nil)

            var sent: [WireMessage] = []
            model.onTransmitForTesting = { sent.append($0) }
            let tap = Finger(anchor.x, anchor.y)
            screen.touchesBegan([tap], with: nil); screen.touchesEnded([tap], with: nil)
            let click = try XCTUnwrap(sent.first { $0.action == "down" })
            XCTAssertEqual(try XCTUnwrap(click.x), 0.35, accuracy: 0.001, "Viewport: \(viewport)")
            XCTAssertEqual(try XCTUnwrap(click.y), 0.35, accuracy: 0.001, "Viewport: \(viewport)")
            if content.bounds.width < viewport.width {
                XCTAssertGreaterThanOrEqual(content.frame.minX, 0)
                XCTAssertLessThanOrEqual(content.frame.maxX, viewport.width)
            }
            if content.bounds.height < viewport.height {
                XCTAssertGreaterThanOrEqual(content.frame.minY, 0)
                XCTAssertLessThanOrEqual(content.frame.maxY, viewport.height)
            }
        }
    }

    func testVideoKeepsSixtyHzAfterFirstDecodedFrame() throws {
        let (_, screen) = screen()
        let video = try XCTUnwrap(screen.subviews.first?.subviews.first as? RTCMTLVideoView)
        let metal = try XCTUnwrap(video.subviews.first { $0 is MTKView } as? MTKView)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                         &buffer), kCVReturnSuccess)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(buffer)),
                                 rotation: ._0, timeStampNs: 1)
        video.isEnabled = true
        video.layoutIfNeeded()
        XCTAssertFalse(metal.bounds.isEmpty)
        video.renderFrame(frame)
        // WebRTC creates its renderer lazily in this callback and resets MTKView to 30 Hz.
        metal.delegate?.draw(in: metal)
        XCTAssertFalse(metal.autoResizeDrawable, "The test must reach WebRTC's lazy renderer setup.")
        XCTAssertEqual(metal.preferredFramesPerSecond, 60)
        video.isEnabled = false
    }

    func testDetachedVideoStopsDrawing() throws {
        let (model, screen) = screen()
        let video = try XCTUnwrap(screen.subviews.first?.subviews.first as? RTCMTLVideoView)
        let factory = RTCPeerConnectionFactory()
        model.track = factory.videoTrack(with: factory.videoSource(), trackId: "reattach-test")
        screen.update()
        XCTAssertTrue(video.isEnabled)
        screen.detach()
        XCTAssertFalse(video.isEnabled)
        screen.update()
        XCTAssertTrue(video.isEnabled, "Reattaching the same track must resume the renderer.")
        screen.detach()
    }
}
