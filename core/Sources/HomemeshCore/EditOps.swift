import Foundation

// The editor's operations (docs/design-standalone-app.md section 4.2): every change is a value applied to the document, with an
// inverse, so undo and redo are exact and testable without a screen.

public indirect enum Edit: Sendable {
    case addWall(Wall)
    case removeWall(Wall)                 // carries the wall so the inverse can put it back
    case replaceWall(old: Wall, new: Wall)
    case group([Edit])

    public var inverse: Edit {
        switch self {
        case .addWall(let w): .removeWall(w)
        case .removeWall(let w): .addWall(w)
        case .replaceWall(let o, let n): .replaceWall(old: n, new: o)
        case .group(let es): .group(es.reversed().map(\.inverse))
        }
    }
}

public struct Document: Sendable {
    public private(set) var house: House
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public init(_ house: House) { self.house = house }

    /// Applies an edit and records it for undo (a new edit clears redo).
    public mutating func apply(_ e: Edit) {
        Self.run(e, on: &house)
        undoStack.append(e)
        redoStack.removeAll()
    }

    public mutating func undo() {
        guard let e = undoStack.popLast() else { return }
        Self.run(e.inverse, on: &house)
        redoStack.append(e)
    }

    public mutating func redo() {
        guard let e = redoStack.popLast() else { return }
        Self.run(e, on: &house)
        undoStack.append(e)
    }

    static func run(_ e: Edit, on h: inout House) {
        switch e {
        case .addWall(let w): h.walls.append(w)
        case .removeWall(let w): h.walls.removeAll { $0.id == w.id }
        case .replaceWall(_, let n):
            if let i = h.walls.firstIndex(where: { $0.id == n.id }) { h.walls[i] = n }
        case .group(let es): for x in es { run(x, on: &h) }
        }
    }

    /// The next free wall id with the given prefix (w1, w2, ...).
    public func nextWallId(prefix: String = "w") -> String {
        let used = Set(house.walls.map(\.id))
        var n = house.walls.count + 1
        while used.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }
}

public enum Draw {
    /// The walls of a traced polyline on one level; `closed` joins the last point to the first.
    public static func trace(points: [Vec2], closed: Bool, level: String, material: String, thickness: Double, height: Double, ids: () -> String) -> [Wall] {
        guard points.count >= 2 else { return [] }
        let pairs = (0..<(points.count - 1)).map { (points[$0], points[$0 + 1]) } + (closed && points.count > 2 ? [(points[points.count - 1], points[0])] : [])
        return pairs.filter { ($0.1 - $0.0).length > 1e-6 }.map {
            Wall(id: ids(), level: level, a: $0.0, b: $0.1, thickness: thickness, height: height, base_z: 0, material: material, openings: [])
        }
    }
}
