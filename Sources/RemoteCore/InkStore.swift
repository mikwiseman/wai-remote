import Foundation

public final class InkStore {
    public static let colors = ["#E05A47", "#2B77D1", "#E3AE32", "#4A9B71"]
    public private(set) var epoch = 1
    public private(set) var committed: [InkStroke] = []
    public private(set) var pending: [String: InkStroke] = [:]
    private var undoHistory: [String: [[InkStroke]]] = [:]
    private var redoHistory: [String: [[InkStroke]]] = [:]
    public var visible: [InkStroke] { committed + pending.values.sorted { $0.id < $1.id } }
    public init() {}

    public func apply(_ m: WireMessage, author: String) -> Bool {
        guard let id = m.strokeID, !id.isEmpty, id.utf8.count <= 128 else { return false }
        switch m.type {
        case "strokeBegin":
            guard pending[id] == nil, !committed.contains(where: { $0.id == id }),
                  pending.values.filter({ $0.author == author }).isEmpty,
                  committed.count < 500, totalPoints < 100_000,
                  let tool = m.tool, let color = m.color, Self.colors.contains(color),
                  let width = m.width, [2.0, 4.0, 8.0].contains(width),
                  let points = m.points, points.count == 1, points[0].isValid else { return false }
            pending[id] = InkStroke(id: id, author: author, tool: tool, color: color, width: width, points: points, complete: false)
        case "strokeAppend":
            guard var stroke = pending[id], stroke.author == author,
                  let points = m.points, !points.isEmpty, points.count <= 256,
                  points.allSatisfy(\.isValid), stroke.points.count + points.count <= 32_768,
                  totalPoints + points.count <= 100_000 else { return false }
            if stroke.tool == .arrow { stroke.points = [stroke.points[0], points.last!] }
            else { stroke.points.append(contentsOf: points) }
            pending[id] = stroke
        case "strokeEnd":
            guard var stroke = pending[id], stroke.author == author else { return false }
            saveUndo(author); pending.removeValue(forKey: id); stroke.complete = true; committed.append(stroke)
        case "strokeCancel":
            guard pending[id]?.author == author else { return false }
            pending.removeValue(forKey: id)
        default: return false
        }
        return true
    }
    public func erase(_ ids: [String], author: String) -> Bool {
        let requested = Set(ids)
        guard !ids.isEmpty, ids.count <= 50, requested.count == ids.count,
              ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }),
              committed.filter({ requested.contains($0.id) && $0.author == author }).count == ids.count else { return false }
        saveUndo(author)
        committed.removeAll { requested.contains($0.id) }
        epoch += 1; cancelAll(); return true
    }
    public func edit(_ action: String, author: String) -> Bool {
        let own = committed.filter { $0.author == author }
        switch action {
        case "clear":
            guard !own.isEmpty || pending.values.contains(where: { $0.author == author }) else { return false }
            saveUndo(author); committed.removeAll { $0.author == author }
        case "undo":
            guard let previous = undoHistory[author]?.popLast() else { return false }
            redoHistory[author, default: []].append(own)
            committed.removeAll { $0.author == author }; committed.append(contentsOf: previous)
        case "redo":
            guard let next = redoHistory[author]?.popLast() else { return false }
            undoHistory[author, default: []].append(own)
            committed.removeAll { $0.author == author }; committed.append(contentsOf: next)
        default: return false
        }
        epoch += 1; cancelAll(); return true
    }
    public func cancelAll() { pending.removeAll() }
    public func clearAll() {
        committed.removeAll(); pending.removeAll(); undoHistory.removeAll(); redoHistory.removeAll(); epoch += 1
    }
    private var totalPoints: Int { committed.reduce(0) { $0 + $1.points.count } + pending.values.reduce(0) { $0 + $1.points.count } }
    private func saveUndo(_ author: String) {
        undoHistory[author, default: []].append(committed.filter { $0.author == author })
        if undoHistory[author]!.count > 16 { undoHistory[author]!.removeFirst() }
        redoHistory[author] = []
    }
}
