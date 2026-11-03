import Foundation

// RoomPlan import (a port of homemesh/roomplan.py; docs/design.md section 10.1). Reads the JSON Apple's `CapturedRoom` encodes, in the
// wrapper the capture app writes ({"format": "homemesh-capture-1", "rooms": [...]}), and turns surfaces into plan walls, openings,
// rooms, stairs and furniture. A scan gives no wall thickness or material: walls get the class defaults, flagged as defaulted.
// The Python module is the oracle: the golden tests compare this port with its output.

public struct ImportError: Error, CustomStringConvertible {
    public var message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

public typealias JObject = [String: Any]

public struct Similarity2D: Sendable, Hashable {
    public var scale = 1.0
    public var rotation = 0.0       // degrees
    public var tx = 0.0
    public var ty = 0.0
    public init(scale: Double = 1, rotation: Double = 0, tx: Double = 0, ty: Double = 0) { self.scale = scale; self.rotation = rotation; self.tx = tx; self.ty = ty }
    public func apply(_ p: Vec2) -> Vec2 {
        let c = cos(rotation * .pi / 180), s = sin(rotation * .pi / 180)
        return Vec2(scale * (c * p.x - s * p.y) + tx, scale * (s * p.x + c * p.y) + ty)
    }
}

public struct ImportDefaults: Sendable {
    public var thickness = 0.1
    public var material = "drywall"
    public var merge_max_gap = 0.6
    public var merge_min_overlap = 0.3
    public init() {}
}

public struct ImportReport: Sendable {
    public var walls = 0, paired_walls = 0, openings = 0, skipped_openings = 0, rooms = 0, replaced = 0
    public var curved_walls = 0, profile_walls = 0, folded_jogs = 0, furniture = 0
    public var stairs: [StairFootprint] = []
    public var notes: [String] = []
    public init() {}
}

public struct StairFootprint: Sendable, Hashable {
    public var room: Int
    public var polygon: [Vec2]
    public var rise: Double
    public var width: Double
    public var run: Double
    public var level: String?
}

public struct ImportOptions {
    public var transform: Similarity2D?
    public var defaults = ImportDefaults()
    public var names: [String]?
    public var descriptions: [String]?
    public var makeRooms = true
    public var roomLevels: [String?]?
    public init(transform: Similarity2D? = nil, names: [String]? = nil, descriptions: [String]? = nil, makeRooms: Bool = true, roomLevels: [String?]? = nil) {
        self.transform = transform; self.names = names; self.descriptions = descriptions; self.makeRooms = makeRooms; self.roomLevels = roomLevels
    }
}

public enum ScanImport {
    static let parallelSin = sin(3.0 * .pi / 180)
    static let conf: [String: Double] = ["low": 0.4, "medium": 0.7, "high": 0.95]
    static let fixed: Set<String> = ["sink", "toilet", "bathtub", "stove", "oven", "dishwasher", "fireplace"]
    static let minOpening = 0.3

    // MARK: rounding as Python does it (round half to even on the decimal)
    /// Python's round(x, d): the decimal nearest the exact binary value (printf rounds exactly, unlike multiplying by 10^d first).
    static func rnd(_ x: Double, _ d: Int) -> Double { x.isFinite ? Double(String(format: "%.\(d)f", x)) ?? x : x }

    // MARK: JSON access
    static func num(_ v: Any?) throws -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        throw ImportError("expected a number")
    }
    static func truthy(_ v: Any?) -> Bool {
        if let n = v as? NSNumber { return n.doubleValue != 0 }
        if let s = v as? String { return !s.isEmpty }
        return false
    }
    static func str(_ v: Any?, _ fallback: String) -> String {
        guard let v else { return fallback }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return fallback
    }

    /// The four columns of a transform (column k is `[k]`): a flat list of 16 or a 4 x 4 nested list.
    static func transform(_ t: Any?) throws -> [[Double]] {
        guard let arr = t as? [Any] else { throw ImportError("unreadable transform") }
        if arr.count == 16 {
            let f = try arr.map { try num($0) }
            return (0..<4).map { Array(f[$0 * 4..<$0 * 4 + 4]) }
        }
        if arr.count == 4, let rows = arr as? [[Any]], rows.allSatisfy({ $0.count == 4 }) { return try rows.map { try $0.map { try num($0) } } }
        throw ImportError("unreadable transform")
    }

    static func kind(_ category: Any?) throws -> (String, JObject) {
        if let s = category as? String { return (s, [:]) }
        if let d = category as? JObject, d.count == 1, let (k, v) = d.first { return (k, v as? JObject ?? [:]) }
        throw ImportError("unreadable category")
    }

    static func confidence(_ c: Any?) -> Double {
        var key = "high"
        if let s = c as? String { key = s } else if let d = c as? JObject, let k = d.keys.first { key = k }
        return conf[key] ?? 0.7
    }

    struct Curve { var radius: Double, start: Double, end: Double }

    struct Surf {
        var ident: String
        var parent: String?
        var kind: String
        var opts: JObject
        var centre: Vec3
        var axis: Vec3
        var w: Double, h: Double
        var conf: Double
        var corners: [Vec2]?
        var curve: Curve?
    }

    static func corners(_ s: JObject, _ w: Double, _ h: Double) -> [Vec2]? {
        guard let raw = s["polygonCorners"] as? [Any], raw.count >= 3 else { return nil }
        var pts: [Vec2] = []
        for c in raw {
            guard let c = c as? [Any], c.count >= 2, let x = try? num(c[0]), let y = try? num(c[1]) else { return nil }
            pts.append(Vec2(x, y))
        }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let minx = xs.min()!, maxx = xs.max()!, miny = ys.min()!, maxy = ys.max()!
        let rect = pts.count == 4 && abs((maxx - minx) - w) < 0.05 && abs((maxy - miny) - h) < 0.05
            && pts.allSatisfy { min(abs($0.x - minx), abs($0.x - maxx)) < 0.05 && min(abs($0.y - miny), abs($0.y - maxy)) < 0.05 }
        return rect ? nil : pts
    }

    static func curve(_ s: JObject) -> Curve? {
        guard let c = s["curve"] as? JObject, let r = try? num(c["radius"]) else { return nil }
        let a0 = (try? num(c["startAngle"])) ?? 0, a1 = (try? num(c["endAngle"])) ?? 0
        return r > 0 && abs(a1 - a0) > 1e-3 ? Curve(radius: r, start: a0, end: a1) : nil
    }

    static func rooms(_ data: JObject) throws -> [JObject] {
        if let r = data["rooms"] as? [Any] { return r.compactMap { $0 as? JObject } }
        if data["walls"] != nil { return [data] }
        throw ImportError("no walls in the capture")
    }

    static func surfaces(_ room: JObject) throws -> [Surf] {
        var out: [Surf] = []
        for key in ["walls", "doors", "windows", "openings"] {
            let list = room[key] as? [Any] ?? []
            for (i, any) in list.enumerated() {
                guard let s = any as? JObject else { throw ImportError("\(key)[\(i)]: not an object") }
                let t: [[Double]], dims: [Double], k: String, opts: JObject
                do {
                    guard s["transform"] != nil, let d = s["dimensions"] as? [Any], d.count >= 2 else { throw ImportError("missing field") }
                    t = try transform(s["transform"])
                    dims = try d.map { try num($0) }
                    (k, opts) = try kind(s["category"] ?? String(key.dropLast()))
                } catch { throw ImportError("\(key)[\(i)]: \(error)") }
                let ax = Vec3(t[0][0], t[0][1], t[0][2])
                let n = (ax.x * ax.x + ax.y * ax.y + ax.z * ax.z).squareRoot()
                if n < 1e-6 || dims[0] <= 0 || dims[1] <= 0 { continue }
                out.append(Surf(ident: str(s["identifier"], "\(key)\(i)"), parent: s["parentIdentifier"] as? String, kind: k, opts: opts,
                                centre: Vec3(t[3][0], t[3][1], t[3][2]), axis: Vec3(ax.x / n, ax.y / n, ax.z / n), w: dims[0], h: dims[1],
                                conf: confidence(s["confidence"]), corners: key == "walls" ? corners(s, dims[0], dims[1]) : nil,
                                curve: key == "walls" ? curve(s) : nil))
            }
        }
        return out
    }

    /// ARKit (x, y up, z) to plan (x, y): X = x, Y = -z.
    static func plan(_ p: Vec3) -> Vec2 { Vec2(p.x, -p.z) }

    final class W {
        var a: Vec2, b: Vec2
        var bottom: Double, top: Double, conf: Double
        var ids: [String]
        var thickness: Double?
        var profile: [Vec2]?
        var curve: WallCurve?
        init(_ a: Vec2, _ b: Vec2, _ bottom: Double, _ top: Double, _ conf: Double, _ ids: [String], thickness: Double? = nil, profile: [Vec2]? = nil, curve: WallCurve? = nil) {
            self.a = a; self.b = b; self.bottom = bottom; self.top = top; self.conf = conf; self.ids = ids; self.thickness = thickness; self.profile = profile; self.curve = curve
        }
    }

    static func dot(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.x + a.y * b.y }
    static func cross(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.y - a.y * b.x }
    static func unit(_ a: Vec2) -> Vec2 { let l = a.length; return Vec2(a.x / l, a.y / l) }

    // MARK: merge, chords, jogs

    static func merge(_ ws: [W], _ d: ImportDefaults) -> [W] {
        var used = Set<Int>()
        var pairs: [(overlap: Double, i: Int, j: Int, gap: Double)] = []
        for i in 0..<ws.count {
            for j in (i + 1)..<max(ws.count, i + 1) {
                let ei = ws[i].b - ws[i].a, li = ei.length
                let ej = ws[j].b - ws[j].a, lj = ej.length
                if li < 1e-6 || lj < 1e-6 { continue }
                let ui = Vec2(ei.x / li, ei.y / li), uj = Vec2(ej.x / lj, ej.y / lj)
                if abs(cross(ui, uj)) > parallelSin { continue }
                let gap = ui.x * (ws[j].a.y - ws[i].a.y) - ui.y * (ws[j].a.x - ws[i].a.x)
                if abs(gap) > d.merge_max_gap { continue }
                let ti = [dot(ws[j].a - ws[i].a, ui), dot(ws[j].b - ws[i].a, ui)]
                let overlap = min(li, ti.max()!) - max(0, ti.min()!)
                if overlap >= d.merge_min_overlap && overlap >= 0.5 * min(li, lj) { pairs.append((overlap, i, j, gap)) }
            }
        }
        var out: [W] = []
        for p in pairs.enumerated().sorted(by: { $0.element.overlap != $1.element.overlap ? $0.element.overlap > $1.element.overlap : $0.offset < $1.offset }).map(\.element) {
            let (i, j, gap) = (p.i, p.j, p.gap)
            if used.contains(i) || used.contains(j) { continue }
            used.insert(i); used.insert(j)
            let ui = unit(ws[i].b - ws[i].a)
            let n = Vec2(-ui.y, ui.x) * gap
            let pts = [ws[i].a, ws[i].b, ws[j].a, ws[j].b].map { dot($0 - ws[i].a, ui) }
            let lo = pts.min()!, hi = pts.max()!
            let new = W(ws[i].a + ui * lo + n * 0.5, ws[i].a + ui * hi + n * 0.5, min(ws[i].bottom, ws[j].bottom), max(ws[i].top, ws[j].top),
                        min(ws[i].conf, ws[j].conf), ws[i].ids + ws[j].ids, thickness: abs(gap) >= 0.05 ? abs(gap) : nil, profile: nil, curve: ws[i].curve ?? ws[j].curve)
            out.append(new)
            let src = ws[i].profile != nil ? ws[i] : ws[j]
            if let prof = src.profile {
                let su = unit(src.b - src.a), nu = unit(new.b - new.a)
                new.profile = prof.map { Vec2(dot(src.a + su * $0.x - new.a, nu), $0.y + src.bottom - new.bottom) }
            }
        }
        for (k, w) in ws.enumerated() where !used.contains(k) { out.append(w) }
        return out
    }

    static func chords(_ s: Surf, centroid: Vec2, a: Vec2, b: Vec2, bottom: Double, top: Double) -> [W]? {
        let r = s.curve?.radius ?? 0
        let c = (b - a).length
        if r <= c / 2 + 1e-6 || c < 0.2 { return nil }
        let mid = (a + b) * 0.5, u = (b - a) * (1 / c)
        var nrm = Vec2(-u.y, u.x)
        if dot(mid - centroid, nrm) < 0 { nrm = nrm * -1 }
        let half = asin(c / 2 / r)
        let centre = mid - nrm * (r * r - c * c / 4).squareRoot()
        let a0 = atan2((a - centre).y, (a - centre).x)
        let a1 = atan2((b - centre).y, (b - centre).x)
        var sweep = (a1 - a0 + .pi).truncatingRemainder(dividingBy: 2 * .pi)
        if sweep < 0 { sweep += 2 * .pi }
        sweep -= .pi
        let n = max(2, min(12, Int((r * abs(sweep) / 0.5).rounded(.up))))
        let pts = (0...n).map { k in centre + Vec2(cos(a0 + sweep * Double(k) / Double(n)), sin(a0 + sweep * Double(k) / Double(n))) * r }
        let group = String(s.ident.prefix(8))
        let cv = WallCurve(group: group, cx: centre.x, cy: centre.y, radius: r, a0: a0 * 180 / .pi, a1: (a0 + sweep) * 180 / .pi)
        return half > 0 ? (0..<n).map { W(pts[$0], pts[$0 + 1], bottom, top, s.conf, [s.ident], thickness: nil, profile: nil, curve: cv) } : nil
    }

    static func floorMillimetres(_ x: Double) -> Double { (x * 1000 + 1e-6).rounded(.down) / 1000 }

    /// Every opening inside its wall (millimetres): rounding can leave an opening a hair past the wall end. Narrower than
    /// `minOpening` afterwards: dropped. Returns the walls, how many openings were trimmed and how many dropped.
    public static func clampOpenings(_ walls: [Wall]) -> (walls: [Wall], trimmed: Int, dropped: Int) {
        var out: [Wall] = [], trimmed = 0, dropped = 0
        for var w in walls {
            let ln = floorMillimetres(w.length)
            var keep: [Opening] = []
            for var o in w.openings {
                var width = o.width, offset = max(0, o.offset)
                if offset + width > ln {
                    width = min(width, ln)
                    offset = max(0, floorMillimetres(ln - width))
                    width = min(width, floorMillimetres(ln - offset))
                }
                if width < minOpening && width < o.width { dropped += 1; continue }
                if width != o.width || offset != o.offset {
                    trimmed += 1
                    o.width = rnd(width, 3); o.offset = rnd(offset, 3)
                }
                keep.append(o)
            }
            if keep != w.openings { w.openings = keep }
            out.append(w)
        }
        return (out, trimmed, dropped)
    }

    static func scaledProfile(_ w: W, _ sim: Similarity2D) -> [Vec2]? {
        guard let prof = w.profile else { return nil }
        let length = (w.b - w.a).length, height = w.top - w.bottom
        let pts = prof.map { Vec2(rnd(min(length, max(0, $0.x)) * sim.scale, 3), rnd(min(height, max(0, $0.y)) * sim.scale, 3)) }
        return pts.count >= 3 ? pts : nil
    }

    static func foldJogs(_ input: [W], _ thr: Double) -> ([W], Int) {
        var ws = input
        var folded = 0
        let tol = 0.06
        var changed = true
        while changed && thr > 0 {
            changed = false
            for (si, sw) in ws.enumerated() {
                if sw.curve != nil || (sw.b - sw.a).length >= thr { continue }
                var nearA: [(Int, Int)] = [], nearB: [(Int, Int)] = []
                for (k, w) in ws.enumerated() where k != si {
                    if (w.a - sw.a).length < tol { nearA.append((k, 0)) } else if (w.b - sw.a).length < tol { nearA.append((k, 1)) }
                    if (w.a - sw.b).length < tol { nearB.append((k, 0)) } else if (w.b - sw.b).length < tol { nearB.append((k, 1)) }
                }
                if nearA.count != 1 || nearB.count != 1 || nearA[0].0 == nearB[0].0 { continue }
                let (ka, ea) = nearA[0], (kb, eb) = nearB[0]
                let a = ws[ka], b = ws[kb]
                if a.curve != nil || b.curve != nil { continue }
                let mid = (sw.a + sw.b) * 0.5
                var j = mid
                let da = a.b - a.a, db = b.b - b.a
                let den = da.x * db.y - da.y * db.x
                if abs(den) > 1e-6 * (da.length * db.length) {
                    let t = ((b.a.x - a.a.x) * db.y - (b.a.y - a.a.y) * db.x) / den
                    let p = a.a + da * t
                    if (p - mid).length <= 2 * thr + (sw.b - sw.a).length { j = p }
                }
                if ea == 0 { a.a = j } else { a.b = j }
                if eb == 0 { b.a = j } else { b.b = j }
                a.ids += sw.ids
                a.profile = nil; b.profile = nil
                ws.remove(at: si)
                folded += 1
                changed = true
                break
            }
        }
        return (ws, folded)
    }

    // MARK: queries on a scan

    public static func roomNames(_ data: JObject) throws -> [String] {
        try rooms(data).map { String(((($0["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).prefix(80)) }
    }

    public static func stairFootprints(_ data: JObject, _ sim: Similarity2D = Similarity2D()) throws -> [StairFootprint] {
        var out: [StairFootprint] = []
        for (i, room) in try rooms(data).enumerated() {
            for any in room["objects"] as? [Any] ?? [] {
                guard let obj = any as? JObject, let (k, _) = try? kind(obj["category"]), k == "stairs",
                      let t = try? transform(obj["transform"]), let d = obj["dimensions"] as? [Any], d.count >= 3,
                      let w = try? num(d[0]), let h = try? num(d[1]), let dd = try? num(d[2]) else { continue }
                let a0 = Vec3(t[0][0], t[0][1], t[0][2]), a2 = Vec3(t[2][0], t[2][1], t[2][2])
                let n0 = (a0.x * a0.x + a0.y * a0.y + a0.z * a0.z).squareRoot(), n2 = (a2.x * a2.x + a2.y * a2.y + a2.z * a2.z).squareRoot()
                if n0 < 1e-6 || n2 < 1e-6 || w <= 0 || dd <= 0 { continue }
                let u0 = Vec3(a0.x / n0, a0.y / n0, a0.z / n0), u2 = Vec3(a2.x / n2, a2.y / n2, a2.z / n2), c = Vec3(t[3][0], t[3][1], t[3][2])
                let corners = [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { (sx, sz) in
                    Vec3(c.x + u0.x * sx * w / 2 + u2.x * sz * dd / 2, c.y + u0.y * sx * w / 2 + u2.y * sz * dd / 2, c.z + u0.z * sx * w / 2 + u2.z * sz * dd / 2)
                }
                let poly = corners.map { sim.apply(plan($0)) }.map { Vec2(rnd($0.x, 4), rnd($0.y, 4)) }
                out.append(StairFootprint(room: i, polygon: poly, rise: rnd(h, 3), width: rnd(w, 3), run: rnd(dd, 3), level: nil))
            }
        }
        return out
    }

    static func wallEndsOfScan(_ data: JObject, _ sim: Similarity2D) throws -> [Vec2] {
        var ends: [Vec2] = []
        for r in try rooms(data) { ends += try wallEnds(r, sim) }
        return ends
    }

    static func wallEnds(_ room: JObject, _ sim: Similarity2D) throws -> [Vec2] {
        var ends: [Vec2] = []
        for sf in try surfaces(room) where sf.kind == "wall" {
            let half = Vec3(sf.axis.x * sf.w / 2, sf.axis.y * sf.w / 2, sf.axis.z * sf.w / 2)
            ends.append(sim.apply(plan(Vec3(sf.centre.x - half.x, sf.centre.y - half.y, sf.centre.z - half.z))))
            ends.append(sim.apply(plan(Vec3(sf.centre.x + half.x, sf.centre.y + half.y, sf.centre.z + half.z))))
        }
        return ends
    }

    public static func hull(_ pts: [Vec2]) -> [Vec2] {
        let p = Array(Set(pts)).sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        if p.count < 3 { return p }
        func half(_ seq: [Vec2]) -> [Vec2] {
            var out: [Vec2] = []
            for q in seq {
                while out.count >= 2 && (out[out.count - 1].x - out[out.count - 2].x) * (q.y - out[out.count - 2].y) - (out[out.count - 1].y - out[out.count - 2].y) * (q.x - out[out.count - 2].x) <= 0 { out.removeLast() }
                out.append(q)
            }
            return Array(out.dropLast())
        }
        return half(p) + half(p.reversed())
    }

    static func area(_ poly: [Vec2]) -> Double {
        var s = 0.0
        for i in 0..<poly.count { let a = poly[i], b = poly[(i + 1) % poly.count]; s += a.x * b.y - b.x * a.y }
        return abs(s) / 2
    }

    public static func scanFootprint(_ data: JObject, _ sim: Similarity2D = Similarity2D()) throws -> [Vec2] {
        hull(try wallEndsOfScan(data, sim)).map { Vec2(rnd($0.x, 4), rnd($0.y, 4)) }
    }

    public struct ScanDoor: Sendable, Hashable { public var id: String, kind: String; public var room: Int; public var x: Double, y: Double, angle: Double, width: Double }

    public static func scanDoors(_ data: JObject) throws -> [ScanDoor] {
        var out: [ScanDoor] = []
        for (i, r) in try rooms(data).enumerated() {
            for sf in try surfaces(r) where sf.kind == "door" || sf.kind == "opening" {
                let mid = plan(sf.centre), ax = plan(sf.axis)
                out.append(ScanDoor(id: String(sf.ident.prefix(8)), kind: sf.kind, room: i, x: rnd(mid.x, 4), y: rnd(mid.y, 4),
                                    angle: rnd(atan2(ax.y, ax.x) * 180 / .pi, 3), width: rnd(sf.w, 3)))
            }
        }
        return out
    }

    public static func scanWallSegments(_ data: JObject) throws -> [(a: Vec2, b: Vec2)] {
        var out: [(Vec2, Vec2)] = []
        for r in try rooms(data) {
            for sf in try surfaces(r) where sf.kind == "wall" {
                let half = Vec3(sf.axis.x * sf.w / 2, sf.axis.y * sf.w / 2, sf.axis.z * sf.w / 2)
                let a = plan(Vec3(sf.centre.x - half.x, sf.centre.y - half.y, sf.centre.z - half.z)), b = plan(Vec3(sf.centre.x + half.x, sf.centre.y + half.y, sf.centre.z + half.z))
                out.append((Vec2(rnd(a.x, 3), rnd(a.y, 3)), Vec2(rnd(b.x, 3), rnd(b.y, 3))))
            }
        }
        return out
    }

    struct FurnitureItem { var ref: String, category: String; var center: Vec2; var width: Double, depth: Double, height: Double, base_z: Double, rotation: Double; var attributes: [String: String] }

    static func furnitureItems(_ data: JObject, _ sim: Similarity2D, floorY: Double) throws -> [FurnitureItem] {
        var out: [FurnitureItem] = []
        for room in try rooms(data) {
            for (k, any) in (room["objects"] as? [Any] ?? []).enumerated() {
                guard let obj = any as? JObject, let (kind, opts) = try? kind(obj["category"]), kind != "stairs",
                      let t = try? transform(obj["transform"]), let d = obj["dimensions"] as? [Any], d.count >= 3,
                      let w = try? num(d[0]), let h = try? num(d[1]), let dd = try? num(d[2]) else { continue }
                let ax = Vec3(t[0][0], t[0][1], t[0][2])
                if w <= 0 || h <= 0 || dd <= 0 || (ax.x * ax.x + ax.y * ax.y + ax.z * ax.z).squareRoot() < 1e-6 { continue }
                let c = Vec3(t[3][0], t[3][1], t[3][2])
                let ctr = sim.apply(plan(c))
                let rot = atan2(-ax.z, ax.x) * 180 / .pi + sim.rotation
                var attrs: [String: String] = [:]
                for src in [opts, obj["attributes"] as? JObject ?? [:]] {
                    for key in src.keys.sorted() {
                        let v = src[key]!
                        if let s = v as? String { attrs[key] = s }
                        else if type(of: v) == Bool.self { attrs[key] = (v as? Bool) == true ? "True" : "False" }
                        else if v is NSNumber { attrs[key] = String(describing: v) }
                        else if let o = v as? JObject, let first = o.keys.sorted().first { attrs[key] = first }
                    }
                }
                out.append(FurnitureItem(ref: String(str(obj["identifier"], "\(kind)\(k)").prefix(8)), category: kind, center: Vec2(rnd(ctr.x, 4), rnd(ctr.y, 4)),
                                         width: rnd(w * sim.scale, 3), depth: rnd(dd * sim.scale, 3), height: rnd(h * sim.scale, 3),
                                         base_z: rnd(max(0, (c.y - h / 2 - floorY) * sim.scale), 3), rotation: rnd(rot, 2), attributes: attrs))
            }
        }
        return out
    }

    static func inPoly(_ p: Vec2, _ poly: [Vec2]) -> Bool {
        var inside = false
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            if (a.y > p.y) != (b.y > p.y) && p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }
}

extension ScanImport {
    /// Least-squares similarity (Umeyama) taking `src` points onto `dst`. The scale stays 1 unless `allowScale`: scans are metric.
    public static func register(_ src: [Vec2], _ dst: [Vec2], allowScale: Bool = false) throws -> Similarity2D {
        if src.count != dst.count || src.count < 2 { throw ImportError("registration needs at least two matching point pairs") }
        let n = Double(src.count)
        let ca = Vec2(src.map(\.x).reduce(0, +) / n, src.map(\.y).reduce(0, +) / n), cb = Vec2(dst.map(\.x).reduce(0, +) / n, dst.map(\.y).reduce(0, +) / n)
        var sxx = 0.0, sxy = 0.0, saa = 0.0
        for (s, d) in zip(src, dst) { let a = s - ca, b = d - cb; sxx += dot(a, b); sxy += cross(a, b); saa += dot(a, a) }
        if saa < 1e-12 { throw ImportError("the picked points coincide") }
        let ang = atan2(sxy, sxx)
        let scale = allowScale ? (sxx * sxx + sxy * sxy).squareRoot() / saa : 1
        let c = cos(ang), sn = sin(ang)
        let t = Vec2(cb.x - scale * (c * ca.x - sn * ca.y), cb.y - scale * (sn * ca.x + c * ca.y))
        return Similarity2D(scale: scale, rotation: ang * 180 / .pi, tx: t.x, ty: t.y)
    }

    // MARK: stairs

    static func lowEnd(_ house: House, _ poly: [Vec2], blob: String) -> Vec2? {
        if poly.count != 4 { return nil }
        let e1 = poly[1] - poly[0], e2 = poly[2] - poly[1]
        let ends = e2.length >= e1.length ? [(poly[0] + poly[1]) * 0.5, (poly[2] + poly[3]) * 0.5] : [(poly[1] + poly[2]) * 0.5, (poly[3] + poly[0]) * 0.5]
        var spots: [Vec2] = []
        for w in house.walls where (w.prov.ref ?? "").hasPrefix("\(blob)#") {
            let ln = (w.b - w.a).length
            for o in w.openings where ln > 0 { spots.append(w.a + (w.b - w.a) * (1 / ln) * (o.offset + o.width / 2)) }
        }
        if spots.isEmpty { return nil }
        let d = ends.map { e in spots.map { (e - $0).length }.min()! }
        if abs(d[0] - d[1]) < 0.3 { return nil }
        let low = d[0] < d[1] ? ends[0] : ends[1]
        return Vec2(rnd(low.x, 4), rnd(low.y, 4))
    }

    /// The staircase the owner said this scan holds (`meta["stair"]` = from/to floors), added to `house` as a Stair, replacing the one an
    /// earlier import of this scan made. Its footprint is the biggest stairs object RoomPlan found, else, for a scan made for the
    /// stairs, the scan's footprint. The measured rise refines the floor-to-floor height.
    public static func applyStair(_ house: House, data: JObject, blob: String, meta: JObject, sim: Similarity2D?, found: [StairFootprint], notes: inout [String]) throws -> House {
        guard let st = meta["stair"] as? JObject else { return house }
        let ids = Set(house.levels.map(\.id))
        guard let a = st["from_level"] as? String, let b = st["to_level"] as? String, ids.contains(a), ids.contains(b), a != b else { return house }
        var rise: Double?
        var poly: [Vec2]
        if let best = found.max(by: { $0.width * $0.run < $1.width * $1.run }) {
            poly = best.polygon; rise = best.rise
            notes.append("staircase from the stairs object RoomPlan found (rises \(String(format: "%.2f", best.rise)) m)")
        } else if (meta["purpose"] as? String) == "stairs" {
            poly = try scanFootprint(data, sim ?? Similarity2D())
            notes.append("RoomPlan found no stairs object in this scan: the scan's footprint is used as the staircase")
        } else { return house }
        if poly.count < 3 { return house }
        var h = house
        let keep = house.stairs.filter { !($0.prov.ref ?? "").hasPrefix("\(blob)#stair") }
        var n = keep.count
        let taken = Set(keep.map(\.id))
        while taken.contains("s\(n + 1)") { n += 1 }
        let new = Stair(id: "s\(n + 1)", from_level: a, to_level: b, polygon: poly, void: true, steps: nil, low: lowEnd(house, poly, blob: blob), prov: Provenance(source: "scan", ref: "\(blob)#stair"))
        h.stairs = keep + [new]
        if let rise { h = Stack.withRise(h, a, b, rise: rise) }
        return h
    }

    // MARK: re-scan

    /// `house` without room `index` of the earlier import of capture `blob`: its room, its furniture, and the walls whose source
    /// surfaces all belong to that room. A wall paired with a face of another room, or from another scan, is kept.
    public static func retireRoom(_ house: House, data: JObject, blob: String, index: Int) throws -> (House, Int) {
        let rs = try rooms(data)
        guard rs.indices.contains(index) else { return (house, 0) }
        let own = Set(try surfaces(rs[index]).filter { $0.kind == "wall" }.map { String($0.ident.prefix(8)) })
        let prefix = "\(blob)#wall/"
        var keep: [Wall] = [], gone = 0
        for w in house.walls {
            let ref = w.prov.ref ?? ""
            if ref.hasPrefix(prefix), Set(ref.dropFirst(prefix.count).split(separator: "+").map(String.init)).isSubset(of: own) { gone += 1 } else { keep.append(w) }
        }
        var h = house
        h.walls = keep
        h.rooms = house.rooms.filter { ($0.prov.ref ?? "") != "\(blob)#room/\(index)" }
        let objs = Set((rs[index]["objects"] as? [Any] ?? []).compactMap { $0 as? JObject }.map { "\(blob)#obj/\(String(str($0["identifier"], "").prefix(8)))" })
        h.furniture = house.furniture.filter { !objs.contains($0.prov.ref ?? "") }
        return (h, gone)
    }
}

extension ScanImport {
    /// `roomLevels` (one level id per room, nil for `level`) splits a scan whose rooms are on different stories: each level's rooms are
    /// imported on it, all with the one placement transform.
    public static func importCapture(house: House, data: JObject, level: String, blob: String, options: ImportOptions = ImportOptions()) throws -> (House, ImportReport) {
        let ids = Set(house.levels.map(\.id))
        let all = try rooms(data)
        if let rl = options.roomLevels, rl.count == all.count, rl.contains(where: { $0 != nil && $0 != level }) {
            let per = rl.map { ($0 != nil && ids.contains($0!)) ? $0! : level }
            var order: [String] = []
            var groups: [String: [Int]] = [:]
            for (i, lv) in per.enumerated() { if groups[lv] == nil { order.append(lv) }; groups[lv, default: []].append(i) }
            var cur = house, total = ImportReport()
            for (g, lv) in order.enumerated() {
                let idx = groups[lv]!
                var sub = data
                sub["rooms"] = idx.map { all[$0] }
                let (h, r) = try importOne(cur, sub, lv, blob, options, roomIdx: idx, append: g > 0)
                cur = h
                total.replaced += r.replaced; total.walls += r.walls; total.paired_walls += r.paired_walls; total.openings += r.openings
                total.skipped_openings += r.skipped_openings; total.rooms += r.rooms; total.curved_walls += r.curved_walls
                total.profile_walls += r.profile_walls; total.folded_jogs += r.folded_jogs; total.furniture += r.furniture
                total.stairs += r.stairs
                for n in r.notes where !total.notes.contains(n) { total.notes.append(n) }
            }
            total.notes.append("the scan's rooms are on " + order.sorted().joined(separator: ", ") + ": each was imported on its own floor")
            return (cur, total)
        }
        return try importOne(house, data, level, blob, options, roomIdx: Array(0..<all.count), append: false)
    }

    static func importOne(_ house: House, _ data: JObject, _ level: String, _ blob: String, _ opt: ImportOptions, roomIdx: [Int], append: Bool) throws -> (House, ImportReport) {
        if !house.levels.contains(where: { $0.id == level }) { throw ImportError("unknown level \(level)") }
        var rep = ImportReport()
        let defaults = opt.defaults
        let dataRooms = try rooms(data)
        var surfs: [Surf] = []
        for r in dataRooms { surfs += try surfaces(r) }
        if !surfs.contains(where: { $0.kind == "wall" }) { throw ImportError("the capture has no walls") }
        let sim = opt.transform ?? Similarity2D()

        var raw: [W] = []
        for r in dataRooms {
            let rs = try surfaces(r).filter { $0.kind == "wall" }
            var cen = Vec2(0, 0)
            if !rs.isEmpty { let ps = rs.map { plan($0.centre) }; cen = Vec2(ps.map(\.x).reduce(0, +) / Double(ps.count), ps.map(\.y).reduce(0, +) / Double(ps.count)) }
            for s in rs {
                let half = Vec3(s.axis.x * s.w / 2, s.axis.y * s.w / 2, s.axis.z * s.w / 2)
                let a = plan(Vec3(s.centre.x - half.x, s.centre.y - half.y, s.centre.z - half.z)), b = plan(Vec3(s.centre.x + half.x, s.centre.y + half.y, s.centre.z + half.z))
                let bottom = s.centre.y - s.h / 2, top = s.centre.y + s.h / 2
                if s.curve != nil, let cs = chords(s, centroid: cen, a: a, b: b, bottom: bottom, top: top) {
                    raw += cs
                    rep.curved_walls += 1
                    continue
                }
                let w = W(a, b, bottom, top, s.conf, [s.ident])
                if let corners = s.corners {
                    w.profile = corners.map { Vec2(min(s.w, max(0, $0.x + s.w / 2)), min(s.h, max(0, $0.y + s.h / 2))) }
                    rep.profile_walls += 1
                }
                raw.append(w)
            }
        }
        let floorY = raw.map(\.bottom).min()!
        var merged = merge(raw, defaults)
        rep.paired_walls = merged.filter { $0.ids.count > 1 }.count
        (merged, rep.folded_jogs) = foldJogs(merged, house.jog_fold)

        let have = Set(house.materials.map(\.id))
        let extra = DefaultMaterials.all.filter { !have.contains($0.id) && [defaults.material, "wood-door", "glass"].contains($0.id) }
        let houseMats = house.materials + extra

        let kept = append ? house.walls : house.walls.filter { !($0.prov.ref ?? "").hasPrefix("\(blob)#") }
        rep.replaced = house.walls.count - kept.count
        var taken = Set(kept.map(\.id))
        var new: [Wall] = []
        var n = 0
        let sorted = merged.enumerated().sorted { l, r in
            let lk = (rnd(l.element.a.x, 2), rnd(l.element.a.y, 2)), rk = (rnd(r.element.a.x, 2), rnd(r.element.a.y, 2))
            if lk.0 != rk.0 { return lk.0 < rk.0 }
            if lk.1 != rk.1 { return lk.1 < rk.1 }
            return l.offset < r.offset
        }.map(\.element)
        for w in sorted {
            while taken.contains("w\(n + 1)") { n += 1 }
            n += 1
            taken.insert("w\(n)")
            let a = sim.apply(w.a), b = sim.apply(w.b)
            var curve: WallCurve?
            if let c = w.curve {
                let ctr = sim.apply(Vec2(c.cx, c.cy))
                curve = WallCurve(group: c.group, cx: rnd(ctr.x, 4), cy: rnd(ctr.y, 4), radius: rnd(c.radius * sim.scale, 4), a0: rnd(c.a0 + sim.rotation, 3), a1: rnd(c.a1 + sim.rotation, 3))
            }
            var wall = Wall(id: "w\(n)", level: level, a: Vec2(rnd(a.x, 4), rnd(a.y, 4)), b: Vec2(rnd(b.x, 4), rnd(b.y, 4)),
                            thickness: w.thickness.map { rnd($0 * sim.scale, 3) } ?? defaults.thickness, height: rnd((w.top - w.bottom) * sim.scale, 3),
                            base_z: rnd(max(0, (w.bottom - floorY) * sim.scale), 3), material: defaults.material,
                            prov: Provenance(source: "scan", ref: "\(blob)#wall/\(w.ids.map { String($0.prefix(8)) }.joined(separator: "+"))", confidence: w.conf))
            wall.thickness_defaulted = w.thickness == nil
            wall.material_defaulted = true
            wall.profile = scaledProfile(w, sim)
            wall.curve = curve
            new.append(wall)
        }
        rep.walls = new.count

        // doors, windows and openings land on the nearest wall; the same door seen from two rooms is kept once
        let kindMap: [String: (String, String)] = ["door": ("door", "wood-door"), "window": ("window", "glass"), "opening": ("arch", "air")]
        for s in surfs {
            guard let (kind, mat) = kindMap[s.kind] else { continue }
            let c = sim.apply(plan(s.centre))
            var best: Int?
            var bd = 0.45, along = 0.0
            for (i, w) in new.enumerated() {
                let ex = w.b.x - w.a.x, ey = w.b.y - w.a.y
                let ln = hypot(ex, ey)
                let t = ((c.x - w.a.x) * ex + (c.y - w.a.y) * ey) / ln
                let dist = abs((c.x - w.a.x) * ey - (c.y - w.a.y) * ex) / ln
                if t >= 0 && t <= ln && dist < bd { best = i; bd = dist; along = t }
            }
            guard let bi = best else { rep.skipped_openings += 1; continue }
            let width = s.w * sim.scale, height = s.h * sim.scale
            let wl = hypot(new[bi].b.x - new[bi].a.x, new[bi].b.y - new[bi].a.y)
            if width > wl { rep.skipped_openings += 1; continue }
            let offset = min(wl - width, max(0, along - width / 2))
            if new[bi].openings.contains(where: { offset < $0.offset + $0.width && $0.offset < offset + width }) { rep.skipped_openings += 1; continue }
            let sill = max(0, (s.centre.y - s.h / 2 - floorY) * sim.scale - new[bi].base_z)
            new[bi].openings.append(Opening(kind: kind, offset: rnd(offset, 3), width: rnd(width, 3), height: rnd(height, 3), sill: rnd(sill, 3), material: mat,
                                            state: truthy(s.opts["isOpen"]) ? "open" : "closed",
                                            prov: Provenance(source: "scan", ref: "\(blob)#\(s.kind)/\(String(s.ident.prefix(8)))", confidence: s.conf)))
            rep.openings += 1
        }
        let (clamped, trimmed, dropped) = clampOpenings(new)
        new = clamped
        if trimmed > 0 || dropped > 0 {
            rep.notes.append("\(trimmed) opening(s) trimmed to fit their wall" + (dropped > 0 ? ", \(dropped) too narrow after trimming and left out" : ""))
            rep.openings -= dropped
        }

        // one Room per scanned room: the convex hull of its wall ends, named by the owner, else by the capture, else "Room N"
        let keptRooms = append ? house.rooms : house.rooms.filter { !($0.prov.ref ?? "").hasPrefix("\(blob)#") }
        var takenR = Set(keptRooms.map(\.id))
        var newRooms: [Room] = []
        let carried = try roomNames(data)
        n = 0
        if opt.makeRooms {
            for (k, r) in dataRooms.enumerated() {
                let i = roomIdx[k]
                let poly = hull(try wallEnds(r, sim))
                if poly.count < 3 || area(poly) < 0.5 { continue }
                while takenR.contains("r\(n + 1)") { n += 1 }
                n += 1
                takenR.insert("r\(n)")
                var label = carried[k]
                if let names = opt.names, i < names.count, !names[i].trimmingCharacters(in: .whitespaces).isEmpty { label = names[i] }
                if label.isEmpty { label = "Room \(i + 1)" }
                var about = ""
                if let d = opt.descriptions, i < d.count { about = String(d[i].trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)) }
                newRooms.append(Room(id: "r\(n)", level: level, name: String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)), description: about,
                                     polygon: poly.map { Vec2(rnd($0.x, 4), rnd($0.y, 4)) }, prov: Provenance(source: "scan", ref: "\(blob)#room/\(i)")))
            }
        }
        rep.rooms = newRooms.count
        rep.stairs = try stairFootprints(data, sim).map { var s = $0; s.level = level; return s }

        // furniture: this scan's earlier items are replaced, keeping what the owner named or overrode (matched by object id)
        var out = house
        if opt.makeRooms {
            var before: [String: Furniture] = [:]
            for f in house.furniture { if let r = f.prov.ref, r.hasPrefix("\(blob)#") { before[r] = f } }
            let keptF = append ? house.furniture : house.furniture.filter { !($0.prov.ref ?? "").hasPrefix("\(blob)#") }
            var takenF = Set(keptF.map(\.id))
            let levelRooms = (keptRooms + newRooms).filter { $0.level == level }
            n = 0
            var newF: [Furniture] = []
            for it in try furnitureItems(data, sim, floorY: floorY) {
                while takenF.contains("f\(n + 1)") { n += 1 }
                n += 1
                takenF.insert("f\(n)")
                let ref = "\(blob)#obj/\(it.ref)"
                let old = before[ref]
                let isDefault = !fixed.contains(it.category)
                let keep = old != nil && !old!.movable_default
                let roomId = levelRooms.first { inPoly(it.center, $0.polygon) }?.id
                var f = Furniture(id: "f\(n)", level: level, room: roomId, category: it.category, name: old?.name ?? "", center: it.center, width: it.width, depth: it.depth,
                                  height: it.height, base_z: it.base_z, rotation: it.rotation, attributes: it.attributes, movable: keep ? old!.movable : isDefault,
                                  movable_default: !keep, obstacle: old?.obstacle ?? false, prov: Provenance(source: "scan", ref: ref))
                f.room = roomId
                newF.append(f)
            }
            rep.furniture = newF.count
            out.furniture = keptF + newF
        }
        rep.notes.append("thickness and material are not measured by a scan: walls carry the class defaults until you set them")
        out.walls = kept + new
        out.rooms = keptRooms + newRooms
        out.materials = houseMats
        return (out, rep)
    }
}
