import XCTest
import UIKit
import RemoteCore
@testable import WAI_Remote

@MainActor
final class PhoneScrollTests: XCTestCase {
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
    private func screen(letterboxed: Bool = false) -> (PhoneModel, ScreenView) {
        let model = PhoneModel()
        model.acceptDemo(SessionMachine(surface: .init(id: "scroll-test", width: 1600,
                                                     height: letterboxed ? 900 : 1600)).state)
        model.connected = true; model.receivedFrame = true
        model.onTransmitForTesting = { _ in }
        let view = ScreenView(model: model)
        view.frame = CGRect(x: 0, y: 0, width: letterboxed ? 390 : 400, height: letterboxed ? 844 : 400)
        view.update(); view.layoutIfNeeded()
        return (model, view)
    }
    private func scrolls(_ messages: [WireMessage]) -> [WireMessage] {
        messages.filter { $0.action == "scroll" && ($0.deltaX != 0 || $0.deltaY != 0) }
    }

    func testChangedTouchSubsetUsesTheWholeEventSnapshot() {
        let (model, view) = screen()
        var sent: [WireMessage] = []; model.onTransmitForTesting = { sent.append($0) }
        let upper = Finger(200, 150), lower = Finger(200, 250)
        view.touchesBegan([upper, lower], with: TouchEvent([upper, lower], at: 100))
        upper.point.y -= 20; lower.point.y -= 20
        view.touchesMoved([lower], with: TouchEvent([upper, lower], at: 100.02))
        view.advanceScrollForTesting(at: 100.03)
        XCTAssertGreaterThan(scrolls(sent).reduce(0) { $0 + ($1.deltaY ?? 0) }, 0)
        XCTAssertEqual(view.subviews.first?.bounds.width, 400)
        view.detach()
    }

    func testStaggeredFingersCannotLockAnUnusablePinchAtMinimumZoom() {
        let (model, view) = screen()
        var sent: [WireMessage] = []; model.onTransmitForTesting = { sent.append($0) }
        let upper = Finger(200, 150), lower = Finger(200, 250)
        view.touchesBegan([upper, lower], with: TouchEvent([upper, lower], at: 100))
        lower.point.y -= 20
        view.touchesMoved([lower], with: TouchEvent([upper, lower], at: 100.01))
        upper.point.y -= 20
        view.touchesMoved([upper], with: TouchEvent([upper, lower], at: 100.02))
        upper.point.y -= 10; lower.point.y -= 10
        view.touchesMoved([upper, lower], with: TouchEvent([upper, lower], at: 100.03))
        view.advanceScrollForTesting(at: 100.04)
        XCTAssertGreaterThan(scrolls(sent).reduce(0) { $0 + ($1.deltaY ?? 0) }, 0)
        XCTAssertEqual(view.subviews.first?.bounds.width, 400)
        view.detach()
    }

    func testPairCanBeginWithOneFingerInTheLetterbox() {
        let (model, view) = screen(letterboxed: true)
        var sent: [WireMessage] = []; model.onTransmitForTesting = { sent.append($0) }
        let upper = Finger(195, 290), lower = Finger(195, 400)
        view.touchesBegan([upper], with: TouchEvent([upper], at: 100))
        view.touchesBegan([lower], with: TouchEvent([upper, lower], at: 100.01))
        upper.point.y -= 20; lower.point.y -= 20
        view.touchesMoved([upper, lower], with: TouchEvent([upper, lower], at: 100.03))
        view.advanceScrollForTesting(at: 100.04)
        XCTAssertGreaterThan(scrolls(sent).count, 0)
        XCTAssertFalse(sent.contains { $0.action == "down" })
        view.detach()
    }

    func testRecognitionSlopDoesNotBecomeAStartupJump() throws {
        let (model, view) = screen()
        var sent: [WireMessage] = []; model.onTransmitForTesting = { sent.append($0) }
        let left = Finger(150, 150), right = Finger(250, 150)
        view.touchesBegan([left, right], with: TouchEvent([left, right], at: 100))
        for step in 1...4 {
            left.point.y -= 4; right.point.y -= 4
            view.touchesMoved([left, right], with: TouchEvent([left, right], at: 100 + Double(step) * 0.02))
            view.advanceScrollForTesting(at: 100 + Double(step) * 0.02 + 0.001)
        }
        let deltas = scrolls(sent).compactMap(\.deltaY)
        XCTAssertEqual(deltas.count, 2)
        XCTAssertEqual(try XCTUnwrap(deltas.first), 16, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(deltas.last), 16, accuracy: 0.001)
        view.detach()
    }

    func testFinalMovementAtLiftIsDelivered() throws {
        let (model, view) = screen()
        var sent: [WireMessage] = []; model.onTransmitForTesting = { sent.append($0) }
        let left = Finger(150, 150), right = Finger(250, 150)
        view.touchesBegan([left, right], with: TouchEvent([left, right], at: 100))
        left.point.y -= 20; right.point.y -= 20
        view.touchesMoved([left, right], with: TouchEvent([left, right], at: 100.02))
        view.advanceScrollForTesting(at: 100.03)
        sent.removeAll()
        left.point.y -= 6; right.point.y -= 6
        view.touchesEnded([left, right], with: TouchEvent([left, right], at: 100.3))
        view.advanceScrollForTesting(at: 100.31)
        XCTAssertEqual(scrolls(sent).reduce(0) { $0 + ($1.deltaY ?? 0) }, 24, accuracy: 0.001)
        view.detach()
    }

    func testThirdFingerDoesNotReplaceTheScrollPairOrTarget() throws {
        let (model, view) = screen()
        var sent: [WireMessage] = []; model.onTransmitForTesting = { sent.append($0) }
        let left = Finger(150, 150), right = Finger(250, 150), extra = Finger(370, 350)
        view.touchesBegan([left, right], with: TouchEvent([left, right], at: 100))
        left.point.y -= 20; right.point.y -= 20
        view.touchesMoved([left, right], with: TouchEvent([left, right], at: 100.02))
        view.advanceScrollForTesting(at: 100.03)
        sent.removeAll()
        view.touchesBegan([extra], with: TouchEvent([left, right, extra], at: 100.04))
        left.point.y -= 4; right.point.y -= 4
        view.touchesMoved([left, right], with: TouchEvent([left, right, extra], at: 100.05))
        view.advanceScrollForTesting(at: 100.06)
        let scroll = try XCTUnwrap(scrolls(sent).first)
        XCTAssertEqual(scroll.x, 0.5); XCTAssertEqual(scroll.y, 0.375)
        XCTAssertEqual(try XCTUnwrap(scroll.deltaY), 16, accuracy: 0.001)
        view.detach()
    }

    func testPinchWithOneStationaryFingerRecognizesWithinBoundedTime() {
        let (model, view) = screen()
        var sent: [WireMessage] = []; model.onTransmitForTesting = { sent.append($0) }
        let fixed = Finger(150, 150), moving = Finger(250, 150)
        view.touchesBegan([fixed, moving], with: TouchEvent([fixed, moving], at: 100))
        moving.point.x = 350
        view.touchesMoved([moving], with: TouchEvent([fixed, moving], at: 100.01))
        view.layoutIfNeeded()
        XCTAssertEqual(view.subviews.first?.bounds.width, 400, "Wait briefly for the other finger's sample.")
        view.advanceScrollForTesting(at: 100.07); view.layoutIfNeeded()
        XCTAssertEqual(view.subviews.first?.bounds.width, 800)
        XCTAssertTrue(scrolls(sent).isEmpty)
        view.detach()
    }

    func testClampedPinchAtEitherLimitCanBecomeACoherentScroll() {
        for maximum in [false, true] {
            let (model, view) = screen()
            if maximum {
                let left = Finger(150, 150), right = Finger(250, 150)
                view.touchesBegan([left, right], with: TouchEvent([left, right], at: 99))
                left.point.x = -50; right.point.x = 450
                view.touchesMoved([left, right], with: TouchEvent([left, right], at: 99.1))
                view.layoutIfNeeded()
                view.touchesEnded([left, right], with: TouchEvent([left, right], at: 99.2))
            }
            var sent: [WireMessage] = []; model.onTransmitForTesting = { sent.append($0) }
            let left = Finger(150, 150), right = Finger(250, 150)
            view.touchesBegan([left, right], with: TouchEvent([left, right], at: 100))
            left.point.x += maximum ? -20 : 20; right.point.x += maximum ? 20 : -20
            view.touchesMoved([left, right], with: TouchEvent([left, right], at: 100.1))
            view.advanceScrollForTesting(at: 100.11); view.layoutIfNeeded()
            XCTAssertEqual(view.subviews.first?.bounds.width, maximum ? 2000 : 400)
            XCTAssertTrue(scrolls(sent).isEmpty)
            left.point = CGPoint(x: 150, y: 130); right.point = CGPoint(x: 250, y: 130)
            view.touchesMoved([left, right], with: TouchEvent([left, right], at: 100.12))
            view.advanceScrollForTesting(at: 100.13)
            XCTAssertGreaterThan(scrolls(sent).count, 0)
            view.detach()
        }
    }

    func testFocusModeRevisionAndDetachDiscardPendingMovementImmediately() {
        for action in ["focus", "mode", "revision", "fit", "detach"] {
            let (model, view) = screen()
            var sent: [WireMessage] = []; model.onTransmitForTesting = { sent.append($0) }
            let left = Finger(150, 150), right = Finger(250, 150)
            view.touchesBegan([left, right], with: TouchEvent([left, right], at: 100))
            left.point.y -= 20; right.point.y -= 20
            view.touchesMoved([left, right], with: TouchEvent([left, right], at: 100.02))
            view.advanceScrollForTesting(at: 100.03)
            left.point.y -= 10; right.point.y -= 10
            view.touchesMoved([left, right], with: TouchEvent([left, right], at: 100.04))
            switch action {
            case "focus": model.liftHeldInput()
            case "mode": model.changeMode(.draw)
            case "revision": model.gestureRevision += 1
            case "fit": model.resetZoomRevision += 1; view.update()
            default: view.detach()
            }
            XCTAssertEqual(sent.filter { $0.action == "scroll" }.compactMap(\.scrollPhase), ["began", "cancelled"], action)
            let count = sent.count
            view.advanceScrollForTesting(at: 100.05)
            XCTAssertEqual(sent.count, count, action)
            XCTAssertEqual(scrolls(sent).reduce(0) { $0 + ($1.deltaY ?? 0) }, 48, accuracy: 0.001, action)
            view.detach()
        }
    }

    func testEpochOrPermissionChangeCannotEmitAnOldGesturesTerminalPacket() throws {
        for change in ["input", "controller", "layer", "mode", "surface", "permission"] {
            let (model, view) = screen()
            var sent: [WireMessage] = []; model.onTransmitForTesting = { sent.append($0) }
            let left = Finger(150, 150), right = Finger(250, 150)
            view.touchesBegan([left, right], with: TouchEvent([left, right], at: 100))
            left.point.y -= 20; right.point.y -= 20
            view.touchesMoved([left, right], with: TouchEvent([left, right], at: 100.02))
            view.advanceScrollForTesting(at: 100.03)
            var state = try XCTUnwrap(model.session.state)
            switch change {
            case "input": state.inputEpoch += 1
            case "controller": state.controllerEpoch += 1
            case "layer": state.layerEpoch += 1
            case "mode": state.modeGeneration += 1
            case "surface": state.surface.revision += 1
            default: state.permissions.control = false
            }
            model.acceptDemo(state)
            let count = sent.count
            view.advanceScrollForTesting(at: 100.04); view.detach()
            XCTAssertEqual(sent.count, count, change)
        }
    }

    func testNewTouchEndsMomentumBeforeItCanMoveAgain() {
        for leaveOneFinger in [false, true] {
            let (model, view) = screen()
            var sent: [WireMessage] = []; model.onTransmitForTesting = { sent.append($0) }
            let left = Finger(150, 150), right = Finger(250, 150)
            view.touchesBegan([left, right], with: TouchEvent([left, right], at: 100))
            left.point.y -= 20; right.point.y -= 20
            view.touchesMoved([left, right], with: TouchEvent([left, right], at: 100.02))
            view.touchesEnded(leaveOneFinger ? [left] : [left, right], with: TouchEvent([left, right], at: 100.02))
            view.advanceScrollForTesting(at: 100.04)
            XCTAssertEqual(sent.last?.momentumPhase, "began")
            let tap = Finger(200, 200)
            view.touchesBegan([tap], with: TouchEvent([tap], at: 100.05))
            XCTAssertEqual(sent.last?.momentumPhase, "ended")
            let count = sent.count
            view.advanceScrollForTesting(at: 100.06)
            XCTAssertEqual(sent.count, count)
            view.detach()
        }
    }

    func testStaleDisplayCallbackDoesNotCancelANewTap() {
        let (model, view) = screen()
        var sent: [WireMessage] = []; model.onTransmitForTesting = { sent.append($0) }
        let left = Finger(150, 150), right = Finger(250, 150)
        view.touchesBegan([left, right], with: TouchEvent([left, right], at: 100))
        left.point.y -= 20; right.point.y -= 20
        view.touchesMoved([left, right], with: TouchEvent([left, right], at: 100.02))
        view.touchesEnded([left, right], with: TouchEvent([left, right], at: 100.02))
        view.advanceScrollForTesting(at: 100.04)
        let tap = Finger(200, 200)
        view.touchesBegan([tap], with: TouchEvent([tap], at: 100.05))
        XCTAssertEqual(sent.last?.momentumPhase, "ended")
        view.advanceScrollForTesting(at: 100.06)
        view.touchesEnded([tap], with: TouchEvent([tap], at: 100.07))
        XCTAssertEqual(sent.filter { $0.action == "down" || $0.action == "up" }.map(\.action), ["down", "up"])
        view.detach()
    }
}
