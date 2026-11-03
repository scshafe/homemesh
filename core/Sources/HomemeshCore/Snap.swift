import Foundation

// Snapping for the touch editor (docs/design-standalone-app.md section 4). Pure geometry: the gesture layer passes a point and a
// tolerance in metres (screen tolerance divided by scale) and draws what comes back, including the label that says what it snapped to.

public enum SnapKind: String, Sendable { case endpoint, midpoint, onWall, perpendicular, parallel, axis, grid, none }

public struct SnapResult: Sendable, Equatable {
    public var point: Vec2
    public var kind: SnapKind
    public var label: String          // "end of wall w12", "90 degrees", "5 cm grid"; empty when nothing snapped
}

public struct SnapOptions: Sendable {
    public var grid = 0.05            // metres; 0 turns the grid off
    public var axisToleranceDeg = 3.0
    public init(grid: Double = 0.05, axisToleranceDeg: Double = 3) { self.grid = grid; self.axisToleranceDeg = axisToleranceDeg }
}

public enum Snap {
    /// The closest point on a segment and its parameter along it.
    public static func project(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> (point: Vec2, t: Double) {
        let e = b - a, ee = e.x * e.x + e.y * e.y
        let t = ee > 0 ? min(1, max(0, ((p.x - a.x) * e.x + (p.y - a.y) * e.y) / ee)) : 0
        return (a + e * t, t)
    }

    /// Resolves `p` against the walls of one level. `from` is the previous point of the line being drawn, which turns on the
    /// axis, perpendicular and parallel snaps. Priority: endpoint, midpoint, on a wall, then direction snaps, then the grid.
    public static func resolve(_ p: Vec2, walls: [Wall], tolerance: Double, from: Vec2? = nil, options: SnapOptions = SnapOptions()) -> SnapResult {
        var best: (d: Double, r: SnapResult)?
        func offer(_ d: Double, _ r: SnapResult) { if d <= tolerance, best == nil || d < best!.d { best = (d, r) } }
        for w in walls {
            offer((p - w.a).length, SnapResult(point: w.a, kind: .endpoint, label: "end of wall \(w.id)"))
            offer((p - w.b).length, SnapResult(point: w.b, kind: .endpoint, label: "end of wall \(w.id)"))
        }
        if let b = best { return b.r }
        for w in walls {
            let mid = (w.a + w.b) * 0.5
            offer((p - mid).length, SnapResult(point: mid, kind: .midpoint, label: "middle of wall \(w.id)"))
        }
        if let b = best { return b.r }
        for w in walls {
            let (q, _) = project(p, w.a, w.b)
            offer((p - q).length, SnapResult(point: q, kind: .onWall, label: "on wall \(w.id)"))
        }
        if let b = best { return b.r }
        if let from {
            let v = p - from
            if v.length > 1e-9 {
                let ang = atan2(v.y, v.x)
                var candidates: [(Double, String, SnapKind)] = []
                for k in 0..<4 { candidates.append((Double(k) * .pi / 2, "\(k % 2 == 0 ? "horizontal" : "vertical"), 90 degrees", .axis)) }
                for w in walls {
                    let wa = atan2(w.b.y - w.a.y, w.b.x - w.a.x)
                    candidates.append((wa, "parallel to wall \(w.id)", .parallel))
                    candidates.append((wa + .pi, "parallel to wall \(w.id)", .parallel))
                    candidates.append((wa + .pi / 2, "perpendicular to wall \(w.id)", .perpendicular))
                    candidates.append((wa - .pi / 2, "perpendicular to wall \(w.id)", .perpendicular))
                }
                let tol = options.axisToleranceDeg * .pi / 180
                var pick: (diff: Double, angle: Double, label: String, kind: SnapKind)?
                for (a, label, kind) in candidates {
                    var d = ang - a
                    while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
                    // axes win ties against wall-relative directions: they are listed first and only a strictly smaller difference replaces them
                    if abs(d) <= tol, pick == nil || abs(d) < pick!.diff - 1e-12 { pick = (abs(d), a, label, kind) }
                }
                if let pick {
                    let q = from + Vec2(cos(pick.angle), sin(pick.angle)) * v.length
                    return SnapResult(point: q, kind: pick.kind, label: pick.label)
                }
            }
        }
        if options.grid > 0 {
            let g = options.grid
            let q = Vec2((p.x / g).rounded() * g, (p.y / g).rounded() * g)
            return SnapResult(point: q, kind: .grid, label: "\(Int((g * 100).rounded())) cm grid")
        }
        return SnapResult(point: p, kind: .none, label: "")
    }
}
