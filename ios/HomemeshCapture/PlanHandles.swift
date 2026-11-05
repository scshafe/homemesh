import Foundation

/// A grab point on the selected thing: a wall's ends, an opening's middle and edges, a zone's corners. Dragging one on the plan
/// runs the matching operation of the engine when the finger lifts.
struct PlanHandle: Hashable, Identifiable {
    enum Kind: Hashable {
        case wallEnd(wall: String, end: Int)
        case openingMove(wall: String, index: Int)
        case openingEdge(wall: String, index: Int, far: Bool)
        case zoneCorner(zone: String, index: Int)
    }
    let kind: Kind
    let at: Pt
    var id: String { "\(kind)" }
}

enum PlanHandles {
    /// The point `s` metres along a wall from its `a` end.
    static func point(on w: PlanWall, at s: Double) -> Pt {
        let l = w.length
        guard l > 0 else { return w.a }
        return Pt(w.a.x + (w.b.x - w.a.x) * s / l, w.a.y + (w.b.y - w.a.y) * s / l)
    }

    /// How far along the wall (from `a`, in metres) the point `p` projects, kept within the wall.
    static func along(_ w: PlanWall, _ p: Pt) -> Double {
        let l = w.length
        guard l > 0 else { return 0 }
        let s = ((p.x - w.a.x) * (w.b.x - w.a.x) + (p.y - w.a.y) * (w.b.y - w.a.y)) / l
        return min(l, max(0, s))
    }

    static func forWall(_ w: PlanWall) -> [PlanHandle] {
        var out = [PlanHandle(kind: .wallEnd(wall: w.id, end: 0), at: w.a), PlanHandle(kind: .wallEnd(wall: w.id, end: 1), at: w.b)]
        for (k, o) in w.openings.enumerated() {
            out.append(PlanHandle(kind: .openingEdge(wall: w.id, index: k, far: false), at: point(on: w, at: o.offset)))
            out.append(PlanHandle(kind: .openingEdge(wall: w.id, index: k, far: true), at: point(on: w, at: o.offset + o.width)))
            out.append(PlanHandle(kind: .openingMove(wall: w.id, index: k), at: point(on: w, at: o.offset + o.width / 2)))
        }
        return out
    }

    static func forZone(_ z: PlanZone) -> [PlanHandle] {
        z.polygon.indices.map { PlanHandle(kind: .zoneCorner(zone: z.id, index: $0), at: z.polygon[$0]) }
    }

    /// The wall as drawn while one of its ends is being dragged.
    static func moved(_ w: PlanWall, end: Int, to p: Pt) -> PlanWall {
        PlanWall(id: w.id, level: w.level, a: end == 0 ? p : w.a, b: end == 1 ? p : w.b, thickness: w.thickness, height: w.height, base_z: w.base_z,
                 profile: w.profile, openings: w.openings, prov: w.prov)
    }

    static func moved(_ z: PlanZone, corner i: Int, to p: Pt) -> PlanZone {
        var poly = z.polygon
        if poly.indices.contains(i) { poly[i] = p }
        return PlanZone(id: z.id, level: z.level, polygon: poly, kind: z.kind, name: z.name)
    }

    /// The nearest handle within `radius` (in the same units as the points), if any.
    static func nearest(_ handles: [PlanHandle], to p: Pt, radius: Double) -> PlanHandle? {
        handles.map { ($0, hypot($0.at.x - p.x, $0.at.y - p.y)) }.filter { $0.1 <= radius }.min { $0.1 < $1.1 }?.0
    }
}
