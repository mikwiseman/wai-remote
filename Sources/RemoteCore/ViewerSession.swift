import Foundation

public struct ViewerSession {
    public private(set) var state: HostState?
    public private(set) var mode: RemoteMode = .control
    public private(set) var invalidated = false
    private var sequence = 0
    private var generation = 0
    public init() {}

    /// Returns true when in-flight gestures must be discarded without replaying them.
    @discardableResult public mutating func accept(_ next: HostState) throws -> Bool {
        guard !next.sessionID.isEmpty, next.inputEpoch >= 0, next.controllerEpoch >= 0,
              next.modeGeneration >= 0, next.nextSequence >= 0, next.nextSequence < Int.max,
              (1...32768).contains(next.surface.width), (1...32768).contains(next.surface.height) else { throw RemoteInvite.Invalid.invitation }
        let changed = state == nil || next.sessionID != state?.sessionID || next.inputEpoch != state?.inputEpoch || next.controllerEpoch != state?.controllerEpoch
        let layerChanged = state?.layerEpoch != next.layerEpoch || state?.surface != next.surface
        if changed {
            sequence = next.nextSequence; generation = next.modeGeneration; mode = next.mode; invalidated = false
        } else {
            sequence = max(sequence, next.nextSequence)
            if next.modeGeneration >= generation { generation = next.modeGeneration; mode = next.mode }
        }
        state = next
        return changed || layerChanged
    }
    public mutating func make(_ type: String) -> WireMessage? {
        guard let state, !invalidated, sequence < Int.max else { return nil }
        if mode == .paused && !["heartbeat", "release", "resync"].contains(type) { return nil }
        var message = WireMessage(type: type, state: state)
        message.sequence = sequence; sequence += 1; message.modeGeneration = generation
        return message
    }
    public mutating func changeMode(_ next: RemoteMode) -> WireMessage? {
        guard let state, !invalidated, mode != .paused, next != .paused,
              next == .draw ? state.permissions.annotate : state.permissions.control else { return nil }
        generation += 1; mode = next
        var message = make("mode"); message?.mode = next; return message
    }
    public mutating func release() -> WireMessage? {
        let message = make("release"); invalidated = true; return message
    }
    public mutating func interrupt() { invalidated = true }
}
