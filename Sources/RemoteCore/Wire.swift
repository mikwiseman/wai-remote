import Foundation

public enum RemoteMode: String, Codable, Sendable { case control, draw, paused }
public enum InkTool: String, Codable, Sendable { case pen, marker, arrow }
public struct InkPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}
public struct Surface: Codable, Equatable, Sendable {
    public var id: String
    public var revision: Int
    public var width: Int
    public var height: Int
    public init(id: String, revision: Int = 1, width: Int, height: Int) {
        self.id = id; self.revision = revision; self.width = width; self.height = height
    }
}
public struct Permissions: Codable, Equatable, Sendable {
    public var control: Bool
    public var annotate: Bool
    public init(control: Bool = true, annotate: Bool = true) { self.control = control; self.annotate = annotate }
}
public struct HostState: Codable, Equatable, Sendable {
    public var sessionID: String
    public var controllerEpoch: Int
    public var inputEpoch: Int
    public var modeGeneration: Int
    public var mode: RemoteMode
    public var permissions: Permissions
    public var surface: Surface
    public var layerEpoch: Int
    public var reason: String
    public var nextSequence: Int = 0
}
public struct WireMessage: Codable, Sendable {
    public var v = 1
    public var type: String
    public var sessionID: String
    public var controllerEpoch: Int
    public var inputEpoch: Int
    public var modeGeneration: Int
    public var surfaceID: String
    public var geometryRevision: Int
    public var layerEpoch: Int
    public var operationID: String
    public var sequence: Int
    public var mode: RemoteMode?
    public var action: String?
    public var x: Double?
    public var y: Double?
    public var button: Int?
    public var clickCount: Int?
    public var deltaX: Double?
    public var deltaY: Double?
    public var key: String?
    public var text: String?
    public var modifiers: [String]?
    public var strokeID: String?
    public var strokeIDs: [String]?
    public var tool: InkTool?
    public var color: String?
    public var width: Double?
    public var points: [InkPoint]?

    public init(type: String, state: HostState, operationID: String = UUID().uuidString) {
        self.type = type; self.sessionID = state.sessionID; self.controllerEpoch = state.controllerEpoch
        self.inputEpoch = state.inputEpoch; self.modeGeneration = state.modeGeneration
        self.surfaceID = state.surface.id; self.geometryRevision = state.surface.revision
        self.layerEpoch = state.layerEpoch; self.operationID = operationID
        self.sequence = state.nextSequence
    }
}
public struct InkStroke: Codable, Equatable, Sendable {
    public var id: String
    public var author: String
    public var tool: InkTool
    public var color: String
    public var width: Double
    public var points: [InkPoint]
    public var complete: Bool
    public init(id: String, author: String, tool: InkTool, color: String, width: Double, points: [InkPoint], complete: Bool = false) {
        self.id = id; self.author = author; self.tool = tool; self.color = color
        self.width = width; self.points = points; self.complete = complete
    }
}
public struct SessionEffects: Sendable {
    public var accepted = false
    public var releaseInput = false
    public var stateChanged = false
    public var inkChanged = false
    public var snapshot = false
    public var input: WireMessage?
    public var laser: InkPoint?
    public var error: String?
    /// A fixed label naming the check a rejected message failed, for diagnostics.
    public var rejected: String?
    public init() {}
}
