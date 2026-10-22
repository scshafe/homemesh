import CoreGraphics
import Foundation

/// A plan point: the backend writes points as `[x, y]` (metres).
struct Pt: Codable, Hashable, Sendable {
    var x: Double
    var y: Double

    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }
}

struct PlanOpening: Codable, Hashable, Sendable {
    let kind: String
    let offset: Double
    let width: Double
}

struct PlanProv: Codable, Hashable, Sendable {
    let ref: String?
}

struct PlanWall: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let level: String
    let a: Pt
    let b: Pt
    let thickness: Double
    let openings: [PlanOpening]
    let prov: PlanProv?

    /// Walls an import of this scan added earlier (the next import replaces them).
    func isFromCapture(_ blob: String) -> Bool { (prov?.ref ?? "").hasPrefix(blob + "#") }
}

struct PlanRoom: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let level: String
    let name: String
    let polygon: [Pt]
}

/// What the plan screens read from `GET /api/houses/<id>` (the rest of the house stays on the server).
struct PlanHouse: Codable, Sendable {
    let id: String
    let name: String
    let revision: Int
    let levels: [HouseLite.Level]
    let walls: [PlanWall]
    let rooms: [PlanRoom]
}

struct Seg: Codable, Hashable, Sendable {
    var a: Pt
    var b: Pt
}

struct Transform2D: Codable, Hashable, Sendable {
    var rotation: Double   // degrees
    var tx: Double
    var ty: Double
}

struct Alternative: Codable, Hashable, Sendable {
    let transform: Transform2D
    let score: Double
    let source: String
}

/// `POST .../captures/<blob>/place` (homemesh/place.py).
struct Placement: Codable, Sendable {
    let confidence: String       // auto, confirm, manual
    let reason: String
    let transform: Transform2D
    let alternatives: [Alternative]
    let preview: [Seg]
}

enum Geometry {
    static func rotate(_ p: Pt, degrees: Double) -> Pt {
        let c = cos(degrees * .pi / 180), s = sin(degrees * .pi / 180)
        return Pt(c * p.x - s * p.y, s * p.x + c * p.y)
    }

    static func centroid(_ segs: [Seg]) -> Pt {
        let pts = segs.flatMap { [$0.a, $0.b] }
        guard !pts.isEmpty else { return Pt(0, 0) }
        return Pt(pts.map(\.x).reduce(0, +) / Double(pts.count), pts.map(\.y).reduce(0, +) / Double(pts.count))
    }

    /// The preview moved by hand: turned by `delta` degrees about `centre`, then shifted by `d`.
    static func adjust(_ segs: [Seg], centre c: Pt, delta: Double, d: Pt) -> [Seg] {
        func f(_ p: Pt) -> Pt {
            let r = rotate(Pt(p.x - c.x, p.y - c.y), degrees: delta)
            return Pt(r.x + c.x + d.x, r.y + c.y + d.y)
        }
        return segs.map { Seg(a: f($0.a), b: f($0.b)) }
    }

    /// The scan-frame to plan transform after the owner nudged the proposal (the same turn and shift as `adjust`).
    static func compose(_ t: Transform2D, centre c: Pt, delta: Double, d: Pt) -> Transform2D {
        let r = rotate(Pt(t.tx - c.x, t.ty - c.y), degrees: delta)
        return Transform2D(rotation: t.rotation + delta, tx: r.x + c.x + d.x, ty: r.y + c.y + d.y)
    }

    static func bounds(_ pts: [Pt]) -> CGRect {
        guard let first = pts.first else { return CGRect(x: -1, y: -1, width: 2, height: 2) }
        var lo = first, hi = first
        for p in pts { lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y); hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y) }
        return CGRect(x: lo.x, y: lo.y, width: max(hi.x - lo.x, 1), height: max(hi.y - lo.y, 1))
    }
}
