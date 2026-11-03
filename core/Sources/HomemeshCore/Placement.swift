import Foundation

// Placing a scan on the plan (a port of homemesh/place.py, without the candidate search: the standalone app places by labelled doors only,
// docs/design-standalone-app.md section 13 Q4). A door of this scan labelled "leads to B" and a door already on the plan, in room B,
// labelled "leads to <this room>" are two sides of one doorway: the scan's door is laid on the plan's, centres coinciding (apart from
// the wall's thickness), walls parallel, the two rooms on opposite sides. Several connections are fitted together (least squares).
// Nothing is stored; the caller shows the proposal and imports with the accepted transform.

public enum Confidence: String, Sendable { case auto, confirm, manual, labelled, unlabelled }

public struct PlaceEvidence: Sendable {
    public var connections = 0
    public var residualCm = 0.0
    public var roomOverlapM2 = 0.0
    public var wallOverlapM = 0.0
    public var stairs = 0
    public var source = ""
    public var missing: [String] = []
}

public struct Proposal: Sendable {
    public var confidence: Confidence
    public var reason: String
    public var transform: Similarity2D          // rotation (degrees), tx, ty; scale 1
    public var evidence: PlaceEvidence
    public var preview: [(a: Vec2, b: Vec2)]
}

public enum Placement {
    static let insetM = 0.25
    typealias Rooms = [(name: String, poly: [Vec2])]

    static func rot(_ deg: Double, _ p: Vec2) -> Vec2 { let c = cos(deg * .pi / 180), s = sin(deg * .pi / 180); return Vec2(c * p.x - s * p.y, s * p.x + c * p.y) }
    static func normDeg(_ d: Double) -> Double { var x = (d + 180).truncatingRemainder(dividingBy: 360); if x < 0 { x += 360 }; return x - 180 }
    static func dot(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.x + a.y * b.y }
    static func mean(_ p: [Vec2]) -> Vec2 { Vec2(p.map(\.x).reduce(0, +) / Double(p.count), p.map(\.y).reduce(0, +) / Double(p.count)) }
    static func side(_ v: Double) -> Int { v > 1e-6 ? 1 : v < -1e-6 ? -1 : 0 }

    static func fold(_ name: String) -> String {
        let f = name.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // the importer's placeholder "Room N" is not a name the owner gave
        let parts = f.split(separator: " ")
        if parts.count == 2, parts[0] == "room", parts[1].allSatisfy(\.isNumber) { return "" }
        return f
    }

    static func edgeDist(_ p: Vec2, _ poly: [Vec2]) -> Double {
        var best = Double.infinity
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count], ab = b - a
            let t = min(1, max(0, dot(p - a, ab) / max(dot(ab, ab), 1e-12)))
            best = min(best, (p - (a + ab * t)).length)
        }
        return best
    }

    /// A door or opening as the plan sees it.
    struct Door { var mid: Vec2, angle: Double, width: Double, thickness: Double, ref: String }

    static func doors(_ walls: [Wall]) -> [Door] {
        var out: [Door] = []
        for w in walls {
            let ln = w.length
            if ln < 1e-6 { continue }
            let d = (w.b - w.a) * (1 / ln)
            for o in w.openings where o.kind == "door" || o.kind == "arch" {
                out.append(Door(mid: w.a + d * (o.offset + o.width / 2), angle: atan2(d.y, d.x), width: o.width, thickness: w.thickness, ref: o.prov.ref ?? ""))
            }
        }
        return out
    }

    static func dominant(_ walls: [Wall]) -> Double? {
        if walls.isEmpty { return nil }
        var re = 0.0, im = 0.0
        for w in walls where w.length > 0 { let a = 4 * atan2(w.b.y - w.a.y, w.b.x - w.a.x); re += w.length * cos(a); im += w.length * sin(a) }
        var d = atan2(im, re) / 4
        d = d.truncatingRemainder(dividingBy: .pi / 2)
        if d < 0 { d += .pi / 2 }
        return d
    }

    static func longestAngle(_ poly: [Vec2]) -> Double {
        var best = -1.0, ang = 0.0
        for i in 0..<poly.count { let d = poly[(i + 1) % poly.count] - poly[i]; if d.length > best { best = d.length; ang = atan2(d.y, d.x) } }
        return ang
    }

    static func preview(_ walls: [Wall], _ sim: Similarity2D) -> [(a: Vec2, b: Vec2)] {
        walls.map { (Vec2(ScanImport.rnd(sim.apply($0.a).x, 3), ScanImport.rnd(sim.apply($0.a).y, 3)), Vec2(ScanImport.rnd(sim.apply($0.b).x, 3), ScanImport.rnd(sim.apply($0.b).y, 3))) }
    }

    // MARK: convex overlap (rooms are hulls, so the area is exact)

    static func clip(_ subject: [Vec2], _ clipper: [Vec2]) -> [Vec2] {
        func inside(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Bool { (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= 0 }
        func cut(_ p: Vec2, _ q: Vec2, _ a: Vec2, _ b: Vec2) -> Vec2 {
            let d1 = p - q, d2 = a - b
            let n1 = p.x * q.y - p.y * q.x, n2 = a.x * b.y - a.y * b.x
            let den = d1.x * d2.y - d1.y * d2.x
            return Vec2((n1 * d2.x - d1.x * n2) / den, (n1 * d2.y - d1.y * n2) / den)
        }
        var out = subject
        for i in 0..<clipper.count {
            let a = clipper[i], b = clipper[(i + 1) % clipper.count]
            let input = out
            out = []
            if input.isEmpty { break }
            var s = input[input.count - 1]
            for e in input {
                if inside(e, a, b) { if !inside(s, a, b) { out.append(cut(s, e, a, b)) }; out.append(e) } else if inside(s, a, b) { out.append(cut(s, e, a, b)) }
                s = e
            }
        }
        return out
    }

    static func ccw(_ poly: [Vec2]) -> [Vec2] {
        var s = 0.0
        for i in 0..<poly.count { let a = poly[i], b = poly[(i + 1) % poly.count]; s += a.x * b.y - b.x * a.y }
        return s < 0 ? poly.reversed() : poly
    }

    /// Area of the scan's rooms (placed by `sim`) lying inside plan rooms of another name, in square metres, after pulling each plan room in by `insetM`.
    static func roomOverlap(_ scan: Rooms, _ plan: Rooms, _ sim: Similarity2D) -> Double {
        var total = 0.0
        for (name, poly) in scan {
            let moved = ccw(poly.map(sim.apply))
            for (pn, pp) in plan where !(Connections.fold(pn) == Connections.fold(name) && !Placement.fold(name).isEmpty) {
                let c = mean(pp)
                let shrunk = ccw(pp).map { c + ($0 - c) * max(0, 1 - insetM / max(edgeDist(c, pp), 1e-6)) }
                let inter = clip(moved, shrunk)
                if inter.count >= 3 { total += ScanImport.area(inter) }
            }
        }
        return total
    }

    /// Metres of the scan's walls (placed by `sim`) lying on parallel plan walls: samples every 0.1 m, within 0.12 m and 4 degrees.
    static func wallOverlap(_ scan: [Wall], _ plan: [Wall], _ sim: Similarity2D) -> Double {
        let sample = 0.1, tol = 0.12, angTol = 4.0 * .pi / 180
        var covered = 0
        for w in scan {
            let ln = w.length
            if ln < 1e-6 { continue }
            let ang = (atan2(w.b.y - w.a.y, w.b.x - w.a.x) + sim.rotation * .pi / 180).truncatingRemainder(dividingBy: .pi)
            let n = max(1, Int(ln / sample))
            for i in 0..<n {
                let q = sim.apply(w.a + (w.b - w.a) * ((Double(i) + 0.5) / Double(n)))
                let a = ang < 0 ? ang + .pi : ang
                let hit = plan.contains { pw in
                    guard pw.length > 1e-6 else { return false }
                    let ab = pw.b - pw.a
                    let t = min(1, max(0, dot(q - pw.a, ab) / max(dot(ab, ab), 1e-12)))
                    if (q - (pw.a + ab * t)).length > tol { return false }
                    var pa = atan2(ab.y, ab.x).truncatingRemainder(dividingBy: .pi)
                    if pa < 0 { pa += .pi }
                    let dq = abs(a - pa)
                    return min(dq, .pi - dq) <= angTol
                }
                if hit { covered += 1 }
            }
        }
        return Double(covered) * sample
    }

    // MARK: propose

    /// The proposal for placing capture `blob` (`data`) on `level` of `house`. `doorLabels` are this scan's labels (door id -> room name),
    /// `planLabels` those of the scans already on the plan, keyed "<capture>#<door id>".
    public static func propose(house: House, data: JObject, level: String, blob: String, names: [String]? = nil, retire: (data: JObject, blob: String, room: Int)? = nil,
                               roomLevels: [String?]? = nil, doorLabels: [String: String] = [:], planLabels: [String: String] = [:]) throws -> Proposal {
        var o = ImportOptions(transform: Similarity2D(), names: names)
        o.roomLevels = roomLevels
        let (scanned, _) = try ScanImport.importCapture(house: house, data: data, level: level, blob: blob, options: o)
        func mine(_ ref: String?) -> Bool { (ref ?? "").hasPrefix("\(blob)#") }
        let scanWalls = scanned.walls.filter { $0.level == level && mine($0.prov.ref) }
        var base = house
        if let r = retire {
            let (lighter, _) = try ScanImport.retireRoom(house, data: r.data, blob: r.blob, index: r.room)
            if lighter.walls.contains(where: { $0.level == level && !mine($0.prov.ref) }) { base = lighter }
        }
        let planWalls = base.walls.filter { $0.level == level && !mine($0.prov.ref) }
        let scanRooms: Rooms = scanned.rooms.filter { $0.level == level && mine($0.prov.ref) }.map { ($0.name, $0.polygon) }
        let planRooms: Rooms = base.rooms.filter { $0.level == level && !mine($0.prov.ref) }.map { ($0.name, $0.polygon) }
        let scanStairs = try ScanImport.stairFootprints(data).map(\.polygon)
        let planStairs = base.stairs.filter { $0.from_level == level || $0.to_level == level }.map(\.polygon)

        if planWalls.isEmpty && !scanStairs.isEmpty && !planStairs.isEmpty {
            // the first scan of a floor: lined up by the staircase from the floor below or above
            var cands: [(rot: Double, t: Vec2)] = []
            for sp in scanStairs { for pp in planStairs {
                let baseAngle = longestAngle(pp) - longestAngle(sp)
                for k in 0..<2 {
                    let th = baseAngle + Double(k) * .pi, deg = normDeg(th * 180 / .pi)
                    cands.append((deg, mean(pp) - rot(deg, mean(sp))))
                }
            } }
            cands.sort { (ScanImport.rnd($0.rot, 1), ScanImport.rnd($0.t.x, 2), ScanImport.rnd($0.t.y, 2)) < (ScanImport.rnd($1.rot, 1), ScanImport.rnd($1.t.x, 2), ScanImport.rnd($1.t.y, 2)) }
            let best = cands[0]
            let sim = Similarity2D(rotation: best.rot, tx: best.t.x, ty: best.t.y)
            var ev = PlaceEvidence(); ev.stairs = 1; ev.source = "stair"
            return Proposal(confidence: .confirm, reason: "lined up by the staircase to the floor below or above: check the rotation", transform: sim, evidence: ev, preview: preview(scanWalls, sim))
        }

        if planWalls.isEmpty {   // nothing to line up with: keep the scan's frame, turned so its walls run along the axes
            let dom = dominant(scanWalls) ?? 0
            let deg = -((dom <= .pi / 4 ? dom : dom - .pi / 2) * 180 / .pi)
            let pts = scanWalls.flatMap { [$0.a, $0.b] }
            let centre = pts.isEmpty ? Vec2(0, 0) : mean(pts)
            let t = centre - rot(deg, centre)
            let sim = Similarity2D(rotation: deg, tx: t.x, ty: t.y)
            return Proposal(confidence: .auto, reason: "the level has no walls yet", transform: sim, evidence: PlaceEvidence(source: "empty plan"), preview: preview(scanWalls, sim))
        }
        return try byLabels(data: data, blob: blob, level: level, scanned: scanned, scanWalls: scanWalls, planWalls: planWalls, planRooms: planRooms, scanRooms: scanRooms,
                            names: names, labels: doorLabels, planLabels: planLabels)
    }

    static func byLabels(data: JObject, blob: String, level: String, scanned: House, scanWalls: [Wall], planWalls: [Wall], planRooms: Rooms, scanRooms: Rooms,
                         names: [String]?, labels: [String: String], planLabels: [String: String]) throws -> Proposal {
        let scanDoors = try ScanImport.scanDoors(data)
        let carried = try ScanImport.roomNames(data)
        func roomName(_ i: Int) -> String {
            if let names, i < names.count, !names[i].trimmingCharacters(in: .whitespaces).isEmpty { return names[i] }
            return i < carried.count ? carried[i] : ""
        }
        var scanPoly: [Int: [Vec2]] = [:]
        for r in scanned.rooms where r.level == level {
            if let ref = r.prov.ref, ref.hasPrefix("\(blob)#room/"), let i = Int(ref.split(separator: "/").last ?? "") { scanPoly[i] = r.polygon }
        }
        let planDoors = doors(planWalls)
        var pairs: [(d: ScanImport.ScanDoor, o: Door, poly: [Vec2])] = []
        var missing: [String] = []
        for d in scanDoors {
            let to = (labels[d.id] ?? "").trimmingCharacters(in: .whitespaces)
            if to.isEmpty || Connections.fold(to) == "outside" { continue }
            let mine = roomName(d.room)
            let targets = planRooms.filter { Connections.fold($0.name) == Connections.fold(to) }
            if targets.isEmpty { missing.append("\(to) is not on the plan yet"); continue }
            let found = planDoors.filter { o in
                // the plan door's label is looked up by "<capture>#<door id>" whatever its kind, so arches count as doors
                guard let key = labelKey(o.ref), !Placement.fold(mine).isEmpty, Connections.fold(planLabels[key] ?? "") == Connections.fold(mine) else { return false }
                return targets.contains { edgeDist(o.mid, $0.poly) <= 0.8 }
            }
            if found.isEmpty { missing.append("\(to) has no door labelled \(mine.isEmpty ? "this room" : mine)"); continue }
            for o in found {
                let poly = targets.min { edgeDist(o.mid, $0.poly) < edgeDist(o.mid, $1.poly) }!.poly
                pairs.append((d, o, poly))
            }
        }
        if pairs.isEmpty {
            return Proposal(confidence: .unlabelled, reason: "Label a door that connects to a placed room (and the matching door of that room back).", transform: Similarity2D(),
                            evidence: PlaceEvidence(missing: missing.isEmpty ? ["no door of this scan is labelled"] : missing), preview: preview(scanWalls, Similarity2D()))
        }

        /// (rotation deg, translation, landing point) laying door d on door o with the rooms on opposite sides.
        func pose(_ d: ScanImport.ScanDoor, _ o: Door, _ poly: [Vec2]) -> (Double, Vec2, Vec2) {
            let s = Vec2(d.x, d.y)
            let n = Vec2(-sin(o.angle), cos(o.angle))
            let sidePlan = side(dot(mean(poly) - o.mid, n))
            let cs = scanPoly[d.room]
            var best: (Double, Vec2, Vec2)?
            for flip in [0.0, Double.pi] {
                let th = o.angle - d.angle * .pi / 180 + flip
                let deg = normDeg(th * 180 / .pi)
                let sideScan = side(dot(rot(deg, (cs.map(mean) ?? s) - s), n))
                if cs != nil && sidePlan != 0 && sideScan != 0 && sideScan == sidePlan { continue }
                let land = o.mid - n * (Double(sidePlan) * o.thickness)
                if best == nil { best = (deg, land - rot(deg, s), land) }
            }
            let deg0 = normDeg((o.angle - d.angle * .pi / 180) * 180 / .pi)
            return best ?? (deg0, o.mid - rot(deg0, Vec2(d.x, d.y)), o.mid)
        }

        // every pair proposes a pose; the pose most other pairs agree with wins, and those pairs are fitted together
        var bestFit: (key: (Int, Double), deg: Double, t: Vec2, agree: [(d: ScanImport.ScanDoor, land: Vec2)])?
        for (d, o, poly) in pairs {
            let (deg, t, _) = pose(d, o, poly)
            var agree: [(ScanImport.ScanDoor, Vec2)] = [], gaps = 0.0
            var used = Set<String>()
            for (d2, o2, poly2) in pairs {
                let land2 = pose(d2, o2, poly2).2
                let gap = (rot(deg, Vec2(d2.x, d2.y)) + t - land2).length
                if gap <= 0.5 && !used.contains(d2.id) { used.insert(d2.id); agree.append((d2, land2)); gaps += gap }
            }
            let key = (agree.count, -gaps)
            if bestFit == nil || key.0 > bestFit!.key.0 || (key.0 == bestFit!.key.0 && key.1 > bestFit!.key.1) { bestFit = (key, deg, t, agree) }
        }
        var (deg, t) = (bestFit!.deg, bestFit!.t)
        let agree = bestFit!.agree
        if agree.count >= 2 {
            let sim = try ScanImport.register(agree.map { Vec2($0.d.x, $0.d.y) }, agree.map(\.land))
            (deg, t) = (sim.rotation, Vec2(sim.tx, sim.ty))
        }
        let resid = agree.map { (rot(deg, Vec2($0.d.x, $0.d.y)) + t - $0.land).length }.max() ?? 0
        let sim = Similarity2D(rotation: deg, tx: t.x, ty: t.y)
        let overlap = roomOverlap(scanRooms, planRooms, sim)
        let conf: Confidence = resid <= 0.15 && overlap <= 0.5 ? .labelled : .confirm
        var reason = "\(agree.count) labelled connection(s); fits to \(String(format: "%.0f", resid * 100)) cm"
        if conf != .labelled { reason += overlap > 0.5 ? " (rooms would overlap: check it)" : " (the connections disagree: check it)" }
        var ev = PlaceEvidence()
        ev.connections = agree.count; ev.residualCm = ScanImport.rnd(resid * 100, 1); ev.roomOverlapM2 = ScanImport.rnd(overlap, 2); ev.wallOverlapM = ScanImport.rnd(wallOverlap(scanWalls, planWalls, sim), 2); ev.source = "labelled doors"; ev.missing = missing
        return Proposal(confidence: conf, reason: reason, transform: sim, evidence: ev, preview: preview(scanWalls, sim))
    }

    /// "<capture>#door/<id8>" or "<capture>#opening/<id8>" -> "<capture>#<id8>".
    static func labelKey(_ ref: String) -> String? {
        guard let h = ref.firstIndex(of: "#") else { return nil }
        let blob = ref[..<h], rest = ref[ref.index(after: h)...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        return "\(blob)#\(rest[rest.index(after: slash)...])"
    }
}
