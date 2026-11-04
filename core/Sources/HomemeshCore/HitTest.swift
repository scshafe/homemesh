import Foundation

// What is under a touch (docs/design-standalone-app.md section 4.2). `tolerance` is metres: the screen tolerance (about 24 points) divided by the plan's scale.

public enum Hit: Equatable, Sendable {
    case vertex(wall: String, end: Int)
    case opening(wall: String, index: Int)
    case wall(String)
    case furniture(String)
    case outlet(String), jack(String), accessPoint(String), switchBox(String), measurement(String)
    case stair(String)
    case zone(String)
    case room(String)
    case none
}

public enum HitTest {
    /// The nearest thing within reach: wall ends first (to be dragged), then openings, things placed on the plan, walls, then areas (stairs, furniture, zones, rooms).
    public static func at(_ p: Vec2, in h: House, level: String, tolerance tol: Double) -> Hit {
        let walls = h.walls.filter { $0.level == level }
        var bestVertex: (Hit, Double)?
        for w in walls {
            for (e, q) in [(0, w.a), (1, w.b)] { let d = (p - q).length; if d <= tol, bestVertex == nil || d < bestVertex!.1 { bestVertex = (.vertex(wall: w.id, end: e), d) } }
        }
        if let v = bestVertex { return v.0 }
        var bestOpening: (Hit, Double)?
        for w in walls where w.length > 1e-6 {
            let u = (w.b - w.a) * (1 / w.length)
            for (k, o) in w.openings.enumerated() {
                let mid = w.a + u * (o.offset + o.width / 2)
                let (q, _) = Snap.project(p, w.a + u * o.offset, w.a + u * (o.offset + o.width))
                let d = min((p - mid).length, (p - q).length)
                if d <= max(tol, w.thickness), bestOpening == nil || d < bestOpening!.1 { bestOpening = (.opening(wall: w.id, index: k), d) }
            }
        }
        if let o = bestOpening { return o.0 }
        var best: (Hit, Double)?
        func offer(_ hit: Hit, _ d: Double) { if d <= tol, best == nil || d < best!.1 { best = (hit, d) } }
        for o in h.outlets where o.level == level { offer(.outlet(o.id), (p - o.position).length) }
        for j in h.jacks where j.level == level { offer(.jack(j.id), (p - j.position).length) }
        for a in h.access_points where a.level == level { offer(.accessPoint(a.id), (p - a.position).length) }
        for s in h.switches where s.level == level { offer(.switchBox(s.id), (p - s.position).length) }
        for m in h.measurements where m.level == level { offer(.measurement(m.id), (p - m.position).length) }
        if let b = best { return b.0 }
        var bestWall: (Hit, Double)?
        for w in walls {
            let (q, _) = Snap.project(p, w.a, w.b)
            let d = (p - q).length
            if d <= max(tol / 2, w.thickness / 2), bestWall == nil || d < bestWall!.1 { bestWall = (.wall(w.id), d) }
        }
        // furniture and stairs sit inside rooms: a wall within half the tolerance wins over them
        if let w = bestWall { return w.0 }
        for s in h.stairs where (s.from_level == level || s.to_level == level) && PropagationModel.inPolygon(p.x, p.y, s.polygon) { return .stair(s.id) }
        for f in h.furniture where f.level == level && contains(f, p) { return .furniture(f.id) }
        for w in walls {
            let (q, _) = Snap.project(p, w.a, w.b)
            if (p - q).length <= tol { return .wall(w.id) }
        }
        // areas overlap (an allow zone round a demand zone): the smallest one under the touch is the one meant
        var zone: (String, Double)?
        for z in h.zones where z.level == level {
            let hit = z.polygon.count >= 3 ? PropagationModel.inPolygon(p.x, p.y, z.polygon) : (p - z.polygon[0]).length <= max(tol, 0.3)
            let area = z.polygon.count >= 3 ? ScanImport.area(z.polygon) : 0
            if hit, zone == nil || area < zone!.1 { zone = (z.id, area) }
        }
        if let z = zone { return .zone(z.0) }
        var room: (String, Double)?
        for r in h.rooms where r.level == level && PropagationModel.inPolygon(p.x, p.y, r.polygon) {
            let area = ScanImport.area(r.polygon)
            if room == nil || area < room!.1 { room = (r.id, area) }
        }
        if let r = room { return .room(r.0) }
        return .none
    }

    static func contains(_ f: Furniture, _ p: Vec2) -> Bool {
        let a = f.rotation * .pi / 180
        let d = p - f.center
        let x = d.x * cos(a) + d.y * sin(a), y = -d.x * sin(a) + d.y * cos(a)
        return abs(x) <= f.width / 2 && abs(y) <= f.depth / 2
    }
}

extension Document {
    /// Runs a change on the house as one undoable step: undo puts the house back exactly as it was. Nothing is recorded when the change leaves it as it was.
    public mutating func perform(_ change: (House) -> House?) {
        guard let new = change(house) else { return }
        record(house, new)
    }
}
