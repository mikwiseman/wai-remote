import XCTest
@testable import RemoteCore

final class InkAndIdentityTests: XCTestCase {
    func testObjectDeletionIsAtomicOwnedAndUndoable() {
        let machine = SessionMachine(surface: Surface(id: "screen", width: 1280, height: 800))
        var mode = WireMessage(type: "mode", state: machine.state); mode.mode = .draw; mode.modeGeneration = 1
        _ = machine.handle(mode, now: 0)
        var begin = WireMessage(type: "strokeBegin", state: machine.state)
        begin.strokeID = "object"; begin.tool = .arrow; begin.color = "#E05A47"; begin.width = 4; begin.points = [InkPoint(0.1,0.1)]
        XCTAssertTrue(machine.handle(begin, now: 0.1).accepted)
        var end = WireMessage(type: "strokeEnd", state: machine.state); end.strokeID = "object"
        XCTAssertTrue(machine.handle(end, now: 0.2).accepted)
        var erase = WireMessage(type: "erase", state: machine.state); erase.strokeIDs = ["object"]
        XCTAssertTrue(machine.handle(erase, now: 0.3).accepted)
        XCTAssertTrue(machine.ink.committed.isEmpty)
        XCTAssertTrue(machine.handle(WireMessage(type: "undo", state: machine.state), now: 0.4).accepted)
        XCTAssertEqual(machine.ink.committed.map(\.id), ["object"])
        XCTAssertTrue(machine.handle(WireMessage(type: "redo", state: machine.state), now: 0.5).accepted)
        XCTAssertTrue(machine.ink.committed.isEmpty)
    }
    func testClearCannotBeUndoneByLateStrokeEnd() {
        let host = SessionMachine(surface: .init(id: "screen", width: 960, height: 540))
        var mode = WireMessage(type: "mode", state: host.state); mode.mode = .draw; mode.modeGeneration = 1
        XCTAssertTrue(host.handle(mode, now: 1).accepted)
        var begin = WireMessage(type: "strokeBegin", state: host.state)
        begin.strokeID = "stroke"; begin.tool = .pen; begin.color = InkStore.colors[0]
        begin.width = 4; begin.points = [.init(0.1, 0.2)]
        XCTAssertTrue(host.handle(begin, now: 1.1).accepted)
        var oldEnd = WireMessage(type: "strokeEnd", state: host.state); oldEnd.strokeID = "stroke"
        XCTAssertTrue(host.handle(WireMessage(type: "clear", state: host.state), now: 1.2).accepted)
        oldEnd.sequence = host.state.nextSequence
        XCTAssertFalse(host.handle(oldEnd, now: 1.3).accepted)
        XCTAssertTrue(host.ink.visible.isEmpty)
    }
    func testEraseRejectsForeignOrMissingObjectsWithoutPartialDeletion() {
        let store = InkStore()
        let state = SessionMachine(surface: .init(id: "screen", width: 100, height: 100)).state
        for author in ["alice", "bob"] {
            var begin = WireMessage(type: "strokeBegin", state: state)
            begin.strokeID = author; begin.tool = .pen; begin.color = InkStore.colors[0]
            begin.width = 4; begin.points = [.init(0.2, 0.3)]
            XCTAssertTrue(store.apply(begin, author: author))
            var end = WireMessage(type: "strokeEnd", state: state); end.strokeID = author
            XCTAssertTrue(store.apply(end, author: author))
        }
        let epoch = store.epoch
        XCTAssertFalse(store.erase(["alice", "bob"], author: "alice"))
        XCTAssertFalse(store.erase(["alice", "missing"], author: "alice"))
        XCTAssertFalse(store.erase(["alice", "alice"], author: "alice"))
        XCTAssertEqual(store.epoch, epoch)
        XCTAssertEqual(store.committed.map(\.id), ["alice", "bob"])
        XCTAssertTrue(store.erase(["alice"], author: "alice"))
        XCTAssertEqual(store.committed.map(\.id), ["bob"])
        XCTAssertTrue(store.edit("undo", author: "alice"))
        XCTAssertEqual(Set(store.committed.map(\.id)), Set(["alice", "bob"]))
    }
    func testSnapshotContainsOnlyCommittedInk() {
        let store = InkStore()
        let state = SessionMachine(surface: .init(id: "s", width: 100, height: 100)).state
        var begin = WireMessage(type: "strokeBegin", state: state)
        begin.strokeID = "a"; begin.tool = .pen; begin.color = InkStore.colors[0]; begin.width = 4; begin.points = [.init(0.2, 0.3)]
        XCTAssertTrue(store.apply(begin, author: "alice")); XCTAssertEqual(store.visible.count, 1)
        XCTAssertEqual(store.committed.count, 0)
        var end = WireMessage(type: "strokeEnd", state: state); end.strokeID = "a"
        XCTAssertFalse(store.apply(end, author: "bob")); XCTAssertTrue(store.apply(end, author: "alice"))
        XCTAssertFalse(store.edit("undo", author: "bob")); XCTAssertEqual(store.committed.count, 1)
        XCTAssertTrue(store.edit("clear", author: "alice")); let epoch = store.epoch
        XCTAssertTrue(store.edit("undo", author: "alice")); XCTAssertEqual(store.committed.count, 1)
        XCTAssertGreaterThan(store.epoch, epoch)
    }
    func testSignedPayloadCannotChangeOrBeUsedForAnotherPurpose() throws {
        let identity = DeviceIdentity(), payload = Data("signed SDP fingerprint".utf8)
        let signature = try identity.sign(payload, domain: "wai-remote/offer/v1")
        XCTAssertTrue(DeviceIdentity.verify(signature, data: payload, domain: "wai-remote/offer/v1", publicKey: identity.publicKey))
        XCTAssertFalse(DeviceIdentity.verify(signature, data: Data("altered SDP".utf8), domain: "wai-remote/offer/v1", publicKey: identity.publicKey))
        XCTAssertFalse(DeviceIdentity.verify(signature, data: payload, domain: "wai-remote/answer/v1", publicKey: identity.publicKey))
    }
    func testPairingProofBindsDeviceAndOfferWithoutRevealingSecret() {
        let secret = Data(repeating: 7, count: 32), offer = Data("deviceA + SDP".utf8)
        let proof = DeviceIdentity.pairingProof(secret: secret, payload: offer)
        XCTAssertTrue(DeviceIdentity.verifyPairingProof(proof, secret: secret, payload: offer))
        XCTAssertFalse(DeviceIdentity.verifyPairingProof(proof, secret: secret, payload: Data("deviceB + SDP".utf8)))
        XCTAssertFalse(DeviceIdentity.verifyPairingProof(proof, secret: Data(repeating: 8, count: 32), payload: offer))
    }
}
