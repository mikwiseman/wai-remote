import Foundation

public struct SavedComputer: Codable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public let invitation: String

    public init(invitation: String, name: String) throws {
        let parsed = try RemoteInvite(invitation)
        id = parsed.hostID
        self.invitation = parsed.savedURL.absoluteString
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = cleaned.isEmpty ? "Мой Mac" : String(cleaned.prefix(60))
    }
}

/// Aspect-fit geometry shared by video layout and pointer mapping. Coordinates start at the top left.
public struct RemoteViewport {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double, sourceWidth: Double, sourceHeight: Double) {
        guard [width, height, sourceWidth, sourceHeight].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            x = 0; y = 0; self.width = 0; self.height = 0; return
        }
        let scale = min(width / sourceWidth, height / sourceHeight)
        self.width = min(width, sourceWidth * scale); self.height = min(height, sourceHeight * scale)
        x = (width - self.width) / 2; y = (height - self.height) / 2
    }

    public func point(x: Double, y: Double) -> InkPoint? {
        guard width > 0, height > 0 else { return nil }
        let point = InkPoint((x - self.x) / width, (y - self.y) / height)
        return point.isValid ? point : nil
    }
}
