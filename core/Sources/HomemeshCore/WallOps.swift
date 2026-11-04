import Foundation

// The editor's wall and opening operations (docs/design-standalone-app.md section 4): pure functions from a house to a house, so each is
// testable without a screen and undo is exact (the document keeps the house before and after).

public enum WallOps {
    /// Endpoints closer than this are the same joint (the scan import's own tolerance for joining walls).
    public static let joint = 0.06

    static func dot(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.x + a.y * b.y }

    static func index(_ h: House, _ id: String) -> Int? { h.walls.firstIndex { $0.id == id } }

    // MARK: moving

    /// Moves one end of a wall. With `drag`, every other wall's end at the same joint (within `joint`) goes with it.
    public static func moveEndpoint(_ h: House, wall id: String, end: Int, to p: Vec2, drag: Bool = true) -> House? {
        guard let i = index(h, id) else { return nil }
        var out = h
        let old = end == 0 ? h.walls[i].a : h.walls[i].b
        if drag {
            for k in out.walls.indices where out.walls[k].level == h.walls[i].level {
                if (out.walls[k].a - old).length <= joint { out.walls[k].a = p }
                if (out.walls[k].b - old).length <= joint { out.walls[k].b = p }
            }
        }
        if end == 0 { out.walls[i].a = p } else { out.walls[i].b = p }
        return fitOpenings(out, ids: Set(out.walls.filter { $0.a == p || $0.b == p || $0.id == id }.map(\.id)))
    }

    /// Moves whole walls by `d`; walls joined to them at an end follow that end (`drag`), so rooms stay closed.
    public static func move(_ h: House, walls ids: Set<String>, by d: Vec2, drag: Bool = true) -> House {
        var out = h
        var oldEnds: [(level: String, p: Vec2)] = []
        for w in h.walls where ids.contains(w.id) { oldEnds.append((w.level, w.a)); oldEnds.append((w.level, w.b)) }
        for k in out.walls.indices {
            if ids.contains(out.walls[k].id) { out.walls[k].a = out.walls[k].a + d; out.walls[k].b = out.walls[k].b + d; continue }
            guard drag else { continue }
            for e in oldEnds where e.level == out.walls[k].level {
                if (out.walls[k].a - e.p).length <= joint { out.walls[k].a = e.p + d }
                if (out.walls[k].b - e.p).length <= joint { out.walls[k].b = e.p + d }
            }
        }
        return fitOpenings(out, ids: Set(out.walls.map(\.id)))
    }

    /// Every opening inside its wall after the wall changed length.
    static func fitOpenings(_ h: House, ids: Set<String>) -> House {
        var out = h
        for i in out.walls.indices where ids.contains(out.walls[i].id) {
            let (clamped, _, _) = ScanImport.clampOpenings([out.walls[i]])
            out.walls[i] = clamped[0]
        }
        return out
    }

    // MARK: splitting and merging

    /// Splits a wall at `p` (projected onto it) into two; openings go to the side their centre is on, trimmed to fit. Both halves keep the wall's properties.
    public static func split(_ h: House, wall id: String, at p: Vec2) -> House? {
        guard let i = index(h, id) else { return nil }
        let w = h.walls[i]
        let (q, t) = Snap.project(p, w.a, w.b)
        let ln = w.length
        if ln < 0.2 || t < 0.5 / ln * 0.2 || t > 1 - 0.1 / ln || min(t * ln, (1 - t) * ln) < 0.1 { return nil }
        var first = w, second = w
        first.b = q
        second.a = q
        let cut = t * ln
        first.openings = []; second.openings = []
        for o in w.openings {
            let centre = o.offset + o.width / 2
            if centre < cut { var n = o; n.width = min(n.width, cut - n.offset); if n.width >= 0.3 { first.openings.append(n) } }
            else { var n = o; n.offset = max(0, o.offset - cut); n.width = min(n.width, ln - cut - n.offset); if n.width >= 0.3 { second.openings.append(n) } }
        }
        let taken = Set(h.walls.map(\.id))
        var n = h.walls.count + 1
        while taken.contains("w\(n)") { n += 1 }
        second.id = "w\(n)"
        var out = h
        out.walls[i] = first
        out.walls.insert(second, at: i + 1)
        return out
    }

    /// Joins two walls that meet end to end in a straight line and share thickness, material and height. Openings keep their places.
    public static func merge(_ h: House, _ aId: String, _ bId: String) -> House? {
        guard let ia = index(h, aId), let ib = index(h, bId), ia != ib else { return nil }
        var a = h.walls[ia], b = h.walls[ib]
        guard a.level == b.level, a.material == b.material, abs(a.thickness - b.thickness) < 1e-6, abs(a.height - b.height) < 1e-6, abs(a.base_z - b.base_z) < 1e-6 else { return nil }
        // orient b so a.b meets b.a (flip a or b as needed)
        if (a.a - b.a).length <= joint || (a.a - b.b).length <= joint { swap(&a.a, &a.b); a.openings = flipOpenings(a.openings, length: a.length) }
        if (a.b - b.b).length <= joint { swap(&b.a, &b.b); b.openings = flipOpenings(b.openings, length: b.length) }
        guard (a.b - b.a).length <= joint else { return nil }
        let u = (a.b - a.a) * (1 / a.length), v = (b.b - b.a) * (1 / b.length)
        guard abs(u.x * v.y - u.y * v.x) < sin(3 * .pi / 180), dot(u, v) > 0 else { return nil }
        var merged = a
        merged.b = b.b
        merged.openings = a.openings + b.openings.map { var o = $0; o.offset += a.length; return o }
        var out = h
        out.walls[ia] = merged
        out.walls.remove(at: ib)
        return out
    }

    static func flipOpenings(_ os: [Opening], length: Double) -> [Opening] { os.map { var o = $0; o.offset = max(0, length - o.offset - o.width); return o } }

    // MARK: repairs

    /// Wall ends within `tol` of another wall's end (and not already at the same point) are joined at their midpoint. Returns the house and how many joints were made.
    public static func closeGaps(_ h: House, level: String, tol: Double = 0.15) -> (House, Int) {
        var out = h
        var joined = 0
        struct End { var wall: Int; var end: Int; var p: Vec2 }
        var ends: [End] = []
        for (i, w) in out.walls.enumerated() where w.level == level { ends.append(End(wall: i, end: 0, p: w.a)); ends.append(End(wall: i, end: 1, p: w.b)) }
        var used = Set<Int>()
        for (x, e) in ends.enumerated() where !used.contains(x) {
            var best: (Int, Double)?
            for (y, f) in ends.enumerated() where y != x && !used.contains(y) && f.wall != e.wall {
                let d = (e.p - f.p).length
                if d > joint && d <= tol, best == nil || d < best!.1 { best = (y, d) }
            }
            guard let (y, _) = best else { continue }
            let f = ends[y], mid = (e.p + f.p) * 0.5
            if e.end == 0 { out.walls[e.wall].a = mid } else { out.walls[e.wall].b = mid }
            if f.end == 0 { out.walls[f.wall].a = mid } else { out.walls[f.wall].b = mid }
            used.insert(x); used.insert(y)
            joined += 1
        }
        return (fitOpenings(out, ids: Set(out.walls.filter { $0.level == level }.map(\.id))), joined)
    }

    /// Turns every wall of the level within `tol` degrees of the house's main directions (the dominant direction and its right angles) onto them,
    /// each about its own midpoint, keeping joined ends together. Returns the house and the number of walls turned.
    public static func squareUp(_ h: House, level: String, tolDeg: Double = 4) -> (House, Int) {
        let walls = h.walls.filter { $0.level == level }
        guard let dom = mainDirection(walls) else { return (h, 0) }
        var out = h
        var turned = 0
        var moves: [(old: Vec2, new: Vec2)] = []
        for i in out.walls.indices where out.walls[i].level == level {
            let w = out.walls[i]
            guard w.length > 1e-6 else { continue }
            let ang = atan2(w.b.y - w.a.y, w.b.x - w.a.x)
            var d = (ang - dom).truncatingRemainder(dividingBy: .pi / 2)
            if d > .pi / 4 { d -= .pi / 2 }
            if d < -.pi / 4 { d += .pi / 2 }
            if abs(d) > tolDeg * .pi / 180 || abs(d) < 1e-9 { continue }
            let mid = (w.a + w.b) * 0.5, half = w.length / 2
            let target = ang - d
            let u = Vec2(cos(target), sin(target))
            let na = mid - u * half, nb = mid + u * half
            moves.append((w.a, na)); moves.append((w.b, nb))
            out.walls[i].a = na; out.walls[i].b = nb
            turned += 1
        }
        // walls that were joined to a turned wall's end follow it, unless they were turned themselves
        for k in out.walls.indices where out.walls[k].level == level {
            let w0 = h.walls[k]
            for m in moves {
                if out.walls[k].a == w0.a, (w0.a - m.old).length <= joint, out.walls[k].a != m.new, !(moves.contains { $0.new == out.walls[k].a }) { out.walls[k].a = m.new }
                if out.walls[k].b == w0.b, (w0.b - m.old).length <= joint, out.walls[k].b != m.new, !(moves.contains { $0.new == out.walls[k].b }) { out.walls[k].b = m.new }
            }
        }
        return (fitOpenings(out, ids: Set(out.walls.filter { $0.level == level }.map(\.id))), turned)
    }

    /// The direction (radians, modulo a right angle) most of the wall length agrees on: the one with the most wall within a degree of it, refined by their mean.
    /// Robust to a few skewed walls, unlike a plain average.
    static func mainDirection(_ walls: [Wall]) -> Double? {
        let items = walls.filter { $0.length > 1e-6 }.map { w -> (Double, Double) in
            var a = atan2(w.b.y - w.a.y, w.b.x - w.a.x).truncatingRemainder(dividingBy: .pi / 2)
            if a < 0 { a += .pi / 2 }
            return (a, w.length)
        }
        if items.isEmpty { return nil }
        func gap(_ a: Double, _ b: Double) -> Double { var d = (a - b).truncatingRemainder(dividingBy: .pi / 2); if d > .pi / 4 { d -= .pi / 2 }; if d < -.pi / 4 { d += .pi / 2 }; return d }
        let window = 1.0 * .pi / 180
        var best: (Double, Double)?
        for (a, _) in items {
            let near = items.filter { abs(gap($0.0, a)) <= window }
            let total = near.map(\.1).reduce(0, +)
            if best == nil || total > best!.1 + 1e-9 { best = (a, total) }
        }
        let a0 = best!.0
        let near = items.filter { abs(gap($0.0, a0)) <= window }
        let mean = near.map { gap($0.0, a0) * $0.1 }.reduce(0, +) / near.map(\.1).reduce(0, +)
        return a0 + mean
    }

    /// Thickness, material and height for several walls at once; nil leaves a value as it is.
    public static func setProperties(_ h: House, walls ids: Set<String>, thickness: Double? = nil, material: String? = nil, height: Double? = nil) -> House {
        var out = h
        for i in out.walls.indices where ids.contains(out.walls[i].id) {
            if let t = thickness, t > 0 { out.walls[i].thickness = t; out.walls[i].thickness_defaulted = false }
            if let m = material { out.walls[i].material = m; out.walls[i].material_defaulted = false }
            if let hh = height, hh > 0 { out.walls[i].height = hh }
        }
        return out
    }

    public static func delete(_ h: House, walls ids: Set<String>) -> House {
        var out = h
        out.walls.removeAll { ids.contains($0.id) }
        return out
    }

    // MARK: openings

    public struct OpeningKind { public var kind: String, width: Double, height: Double, sill: Double, material: String, state: String
        public static func standard(_ kind: String) -> OpeningKind {
            switch kind {
            case "window": OpeningKind(kind: "window", width: 1.2, height: 1.2, sill: 0.9, material: "glass", state: "closed")
            case "arch": OpeningKind(kind: "arch", width: 1.0, height: 2.0, sill: 0, material: "air", state: "closed")
            default: OpeningKind(kind: "door", width: 0.9, height: 2.0, sill: 0, material: "wood-door", state: "closed")
            }
        }
    }

    /// Puts an opening on a wall with its centre `along` metres from end a (snapped to the wall's middle or an end within 0.15 m), clear of the other openings.
    /// Returns the house and the new opening's index, or nil when it does not fit.
    public static func addOpening(_ h: House, wall id: String, kind: String, along: Double, snap: Bool = true) -> (House, Int)? {
        guard let i = index(h, id) else { return nil }
        var w = h.walls[i]
        let spec = OpeningKind.standard(kind)
        let ln = w.length
        guard ln >= spec.width else { return nil }
        var centre = along
        if snap {
            for s in [ln / 2, spec.width / 2, ln - spec.width / 2] where abs(centre - s) <= 0.15 { centre = s; break }
        }
        var offset = min(ln - spec.width, max(0, centre - spec.width / 2))
        // shift past any opening in the way, toward the side the centre is on
        for _ in 0..<w.openings.count + 1 {
            guard let clash = w.openings.first(where: { offset < $0.offset + $0.width && $0.offset < offset + spec.width }) else { break }
            let right = clash.offset + clash.width, left = clash.offset - spec.width
            offset = centre >= clash.offset + clash.width / 2 ? right : left
            if offset < 0 || offset + spec.width > ln { return nil }
        }
        let material = h.materials.contains { $0.id == spec.material } || spec.material == "air" ? spec.material : (h.materials.first?.id ?? w.material)
        w.openings.append(Opening(kind: spec.kind, offset: ScanImport.rnd(offset, 3), width: spec.width, height: spec.height, sill: spec.sill, material: material, state: spec.state, prov: .manual))
        w.openings.sort { $0.offset < $1.offset }
        var out = h
        out.walls[i] = w
        return (out, w.openings.firstIndex { $0.offset == ScanImport.rnd(offset, 3) && $0.kind == spec.kind } ?? 0)
    }

    /// Slides an opening so its centre is at `along`, kept inside the wall and clear of its neighbours.
    public static func slideOpening(_ h: House, wall id: String, index k: Int, to along: Double) -> House? {
        guard let i = index(h, id), h.walls[i].openings.indices.contains(k) else { return nil }
        var w = h.walls[i]
        let o = w.openings[k]
        var offset = min(w.length - o.width, max(0, along - o.width / 2))
        for (j, other) in w.openings.enumerated() where j != k {
            if offset < other.offset + other.width && other.offset < offset + o.width {
                offset = (along >= other.offset + other.width / 2) ? other.offset + other.width : other.offset - o.width
            }
        }
        guard offset >= 0, offset + o.width <= w.length + 1e-9 else { return nil }
        if w.openings.enumerated().contains(where: { $0.offset != k && offset < $0.element.offset + $0.element.width - 1e-9 && $0.element.offset < offset + o.width - 1e-9 }) { return nil }
        w.openings[k].offset = ScanImport.rnd(offset, 3)
        var out = h
        out.walls[i] = w
        return out
    }

    public static func resizeOpening(_ h: House, wall id: String, index k: Int, width: Double) -> House? {
        guard let i = index(h, id), h.walls[i].openings.indices.contains(k), width >= 0.3 else { return nil }
        var w = h.walls[i]
        let o = w.openings[k]
        let centre = o.offset + o.width / 2
        let offset = min(w.length - width, max(0, centre - width / 2))
        guard width <= w.length else { return nil }
        for (j, other) in w.openings.enumerated() where j != k { if offset < other.offset + other.width - 1e-9 && other.offset < offset + width - 1e-9 { return nil } }
        w.openings[k].width = ScanImport.rnd(width, 3)
        w.openings[k].offset = ScanImport.rnd(offset, 3)
        var out = h
        out.walls[i] = w
        return out
    }

    public static func removeOpening(_ h: House, wall id: String, index k: Int) -> House? {
        guard let i = index(h, id), h.walls[i].openings.indices.contains(k) else { return nil }
        var out = h
        out.walls[i].openings.remove(at: k)
        return out
    }

    // MARK: drawing by numbers

    public enum Heading: Sendable { case east, north, west, south, angle(Double) }

    /// A traced line from typed measurements: from `start`, each step goes `length` metres along its heading (an angle is in degrees from east, counter-clockwise).
    public static func byNumbers(start: Vec2, steps: [(heading: Heading, length: Double)]) -> [Vec2] {
        var pts = [start]
        for s in steps {
            let a: Double
            switch s.heading { case .east: a = 0; case .north: a = .pi / 2; case .west: a = .pi; case .south: a = -.pi / 2; case .angle(let d): a = d * .pi / 180 }
            pts.append(pts[pts.count - 1] + Vec2(cos(a), sin(a)) * s.length)
        }
        return pts
    }

    // MARK: filling a gap

    /// An outline for an unscanned space bounded by the given walls: where their free ends (ends that meet no other of these walls) can be joined,
    /// the closing walls are proposed, nearest ends first. Returns the new walls (ids unset) and the outline of the closed loop, or nil when the walls do not enclose a space.
    public static func fillGap(_ h: House, walls ids: Set<String>) -> (closing: [Wall], outline: [Vec2])? {
        let ws = h.walls.filter { ids.contains($0.id) }
        guard ws.count >= 2, let template = ws.first else { return nil }
        struct E { var p: Vec2; var wall: Int; var end: Int }
        var all: [E] = []
        for (i, w) in ws.enumerated() { all.append(E(p: w.a, wall: i, end: 0)); all.append(E(p: w.b, wall: i, end: 1)) }
        var free: [E] = []
        for (x, e) in all.enumerated() where !all.enumerated().contains(where: { $0.offset != x && ($0.element.p - e.p).length <= joint }) { free.append(e) }
        if free.count % 2 != 0 { return nil }
        if free.isEmpty { return loop(ws).map { (closing: [Wall](), outline: $0) } }
        var closing: [Wall] = []
        var left = free
        while !left.isEmpty {
            let e = left.removeFirst()
            guard let k = left.indices.min(by: { (left[$0].p - e.p).length < (left[$1].p - e.p).length }) else { return nil }
            let f = left.remove(at: k)
            if (e.p - f.p).length < 0.05 { continue }
            closing.append(Wall(id: "", level: template.level, a: e.p, b: f.p, thickness: template.thickness, height: template.height, base_z: template.base_z, material: template.material, openings: [], prov: Provenance(source: "manual")))
        }
        guard let outline = loop(ws + closing) else { return nil }
        return (closing, outline)
    }

    /// The vertices of the closed loop the walls form (following ends from wall to wall), or nil if they do not close into one loop.
    static func loop(_ ws: [Wall]) -> [Vec2]? {
        guard var cur = ws.first else { return nil }
        var pts = [cur.a, cur.b]
        var used: Set<Int> = [0]
        while used.count < ws.count {
            let tip = pts[pts.count - 1]
            guard let (k, flip) = ws.indices.lazy.filter({ !used.contains($0) }).compactMap({ i -> (Int, Bool)? in
                if (ws[i].a - tip).length <= joint { return (i, false) }
                if (ws[i].b - tip).length <= joint { return (i, true) }
                return nil
            }).first else { return nil }
            cur = ws[k]
            pts.append(flip ? cur.a : cur.b)
            used.insert(k)
        }
        guard (pts[pts.count - 1] - pts[0]).length <= joint else { return nil }
        pts.removeLast()
        return pts.count >= 3 ? pts : nil
    }
}
