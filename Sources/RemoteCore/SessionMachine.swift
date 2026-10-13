import Foundation

/// Serialized by the host. OS input is possible only through an accepted effect.
public final class SessionMachine {
    public private(set) var state: HostState
    public private(set) var connected = true
    public private(set) var stalled = false
    public let author: String
    public private(set) var ink = InkStore()
    private var lastActivity: Double?
    private var locallyPaused = false
    private var transportAvailable = true
    private var approvedPermissions: Permissions
    private var systemControlAllowed = true

    public init(surface: Surface, permissions: Permissions = .init(), author: String = "remote") {
        self.author = author
        approvedPermissions = permissions
        state = HostState(sessionID: UUID().uuidString, controllerEpoch: 1, inputEpoch: 1,
                          modeGeneration: 0, mode: .control, permissions: permissions,
                          surface: surface, layerEpoch: 1, reason: "connected")
    }

    public func handle(_ m: WireMessage, now: Double) -> SessionEffects {
        var e = SessionEffects()
        guard connected, transportAvailable, m.v == 1, m.sessionID == state.sessionID,
              m.controllerEpoch == state.controllerEpoch, m.inputEpoch == state.inputEpoch,
              m.surfaceID == state.surface.id, m.geometryRevision == state.surface.revision,
              m.sequence >= state.nextSequence, m.sequence < Int.max,
              !m.operationID.isEmpty, m.operationID.utf8.count <= 128 else { return e }
        switch m.type {
        case "heartbeat": break
        case "release", "resync":
            lastActivity = now
            return invalidate(reason: m.type == "release" ? "focus-lost" : "resync")
        case "mode":
            guard !locallyPaused, let mode = m.mode, mode != .paused,
                  m.modeGeneration > state.modeGeneration,
                  mode != .draw || state.permissions.annotate else { return e }
            ink.cancelAll()
            state.mode = mode; state.modeGeneration = m.modeGeneration; state.reason = "mode"
            e.releaseInput = true; e.stateChanged = true; e.inkChanged = true
        case "pointer":
            guard canControl(m), let action = m.action, ["move", "down", "up", "scroll"].contains(action),
                  let x = m.x, let y = m.y, InkPoint(x, y).isValid,
                  (m.modifiers ?? []).allSatisfy({ ["Meta", "Control", "Alt", "Shift"].contains($0) }) else { return e }
            if action == "scroll" {
                guard let dx = m.deltaX, let dy = m.deltaY, dx.isFinite, dy.isFinite,
                      abs(dx) <= 2000, abs(dy) <= 2000 else { return e }
            } else if action != "move" {
                guard let button = m.button, (0...2).contains(button) else { return e }
            }
            e.input = m
        case "key":
            guard canControl(m), let key = m.key, !key.isEmpty, key.utf8.count <= 40,
                  m.action == "down" || m.action == "up",
                  (m.modifiers ?? []).allSatisfy({ ["Meta", "Control", "Alt", "Shift"].contains($0) }) else { return e }
            e.input = m
        case "text":
            guard canControl(m), let text = m.text, !text.isEmpty, text.utf16.count <= 4096,
                  !text.contains("\0") else { return e }
            e.input = m
        case "strokeBegin", "strokeAppend", "strokeEnd", "strokeCancel":
            guard !locallyPaused, state.permissions.annotate, state.mode == .draw,
                  m.modeGeneration == state.modeGeneration, m.layerEpoch == ink.epoch,
                  ink.apply(m, author: author) else { return e }
            e.inkChanged = true
        case "laser":
            guard !locallyPaused, state.permissions.annotate, state.mode == .draw,
                  m.modeGeneration == state.modeGeneration, let x = m.x, let y = m.y,
                  InkPoint(x, y).isValid else { return e }
            e.laser = InkPoint(x, y)
        case "erase":
            guard !locallyPaused, state.permissions.annotate, state.mode == .draw,
                  m.modeGeneration == state.modeGeneration, m.layerEpoch == ink.epoch,
                  let ids = m.strokeIDs, ink.erase(ids, author: author) else { return e }
            state.layerEpoch = ink.epoch
            e.inkChanged = true; e.snapshot = true; e.stateChanged = true
        case "undo", "redo", "clear":
            guard !locallyPaused, state.permissions.annotate, m.layerEpoch == ink.epoch,
                  ink.edit(m.type, author: author) else { return e }
            state.layerEpoch = ink.epoch
            e.inkChanged = true; e.snapshot = true; e.stateChanged = true
        default: return e
        }
        e.accepted = true; state.nextSequence = m.sequence + 1; lastActivity = now
        if stalled { stalled = false; state.reason = "reconnected"; e.stateChanged = true }
        return e
    }

    private func canControl(_ m: WireMessage) -> Bool {
        !locallyPaused && state.permissions.control && state.mode == .control && m.modeGeneration == state.modeGeneration
    }
    public func tick(now: Double) -> SessionEffects {
        guard connected, !stalled, let lastActivity, now - lastActivity > 2 else { return .init() }
        stalled = true
        return invalidate(reason: "connection-stalled")
    }
    public func transportInterrupted() -> SessionEffects {
        guard connected, transportAvailable else { return .init() }
        transportAvailable = false; state.mode = .paused
        return invalidate(reason: "transport-disconnected")
    }
    public func transportRestored() -> SessionEffects {
        guard connected, !transportAvailable else { return .init() }
        transportAvailable = true; stalled = false; lastActivity = nil
        state.mode = locallyPaused ? .paused : .control
        return invalidate(reason: locallyPaused ? "host-drawing" : "transport-restored")
    }
    @discardableResult public func pause(reason: String) -> SessionEffects {
        locallyPaused = true; state.mode = .paused
        return invalidate(reason: reason)
    }
    @discardableResult public func resume() -> SessionEffects {
        locallyPaused = false; state.mode = transportAvailable ? .control : .paused
        return invalidate(reason: "host-resumed")
    }
    @discardableResult public func resizeSurface(width: Int, height: Int) -> SessionEffects {
        guard width > 0, height > 0, width != state.surface.width || height != state.surface.height else { return .init() }
        state.surface.width = width; state.surface.height = height; state.surface.revision += 1
        ink.clearAll(); state.layerEpoch = ink.epoch
        return invalidate(reason: "surface-resized")
    }
    @discardableResult public func setPermissions(_ permissions: Permissions) -> SessionEffects {
        approvedPermissions = permissions
        return refreshEffectivePermissions()
    }
    @discardableResult public func setSystemControlAllowed(_ allowed: Bool) -> SessionEffects {
        systemControlAllowed = allowed
        return refreshEffectivePermissions()
    }
    private func refreshEffectivePermissions() -> SessionEffects {
        let effective = Permissions(control: approvedPermissions.control && systemControlAllowed, annotate: approvedPermissions.annotate)
        guard state.permissions != effective else { return .init() }
        state.permissions = effective
        if !effective.annotate { _ = ink.edit("clear", author: author); state.layerEpoch = ink.epoch }
        return invalidate(reason: "permissions-changed")
    }
    @discardableResult public func reconnect() -> SessionEffects {
        connected = true; transportAvailable = true; locallyPaused = false; stalled = false; state.mode = .control
        state.controllerEpoch += 1; lastActivity = nil
        return invalidate(reason: "reconnected")
    }
    public func disconnect() { connected = false; ink.cancelAll() }
    public func stop() { connected = false; ink = InkStore(); state.layerEpoch = ink.epoch }
    @discardableResult public func clearAllLocally() -> SessionEffects {
        ink.clearAll(); state.layerEpoch = ink.epoch
        var e = invalidate(reason: "host-cleared"); e.snapshot = true
        return e
    }
    private func invalidate(reason: String) -> SessionEffects {
        state.inputEpoch += 1; state.nextSequence = 0; state.reason = reason; ink.cancelAll()
        var e = SessionEffects(); e.accepted = true; e.releaseInput = true
        e.stateChanged = true; e.inkChanged = true; e.snapshot = true
        return e
    }
}
