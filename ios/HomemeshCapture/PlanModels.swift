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
    let height: Double?
    let base_z: Double?
    let profile: [[Double]]?   // non-rectangular outline: (offset along a to b, height above base_z)
    let openings: [PlanOpening]
    let prov: PlanProv?

    /// Walls an import of this scan added earlier (the next import replaces them).
    var length: Double { hypot(b.x - a.x, b.y - a.y) }

    func isFromCapture(_ blob: String) -> Bool { (prov?.ref ?? "").hasPrefix(blob + "#") }
}

struct PlanRoom: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let level: String
    let name: String
    let polygon: [Pt]
}

struct PlanOutlet: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let level: String
    let position: Pt
}

struct PlanJack: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let level: String
    let position: Pt
    let type: String
    let state: String
}

struct PlanAP: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let level: String
    let position: Pt
    let name: String
}

struct PlanStair: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let from_level: String
    let to_level: String
    let polygon: [Pt]
    var steps: Int? = nil   // the owner's count of steps; round(rise / 0.18 m) when nil
    var low: Pt? = nil      // a point at the bottom end of the flight, when known
}

struct PlanZone: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let level: String
    let polygon: [Pt]
    let kind: String      // allow, forbid, demand
    let name: String
}

struct PlanEntry: Codable, Hashable, Sendable {
    let position: Pt
    let level: String
    let kind: String
}

struct PlanMeasurement: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let level: String
    let position: Pt
    let band: String
    let rssi: Double?
}

struct PlanCalibration: Codable, Hashable, Sendable {
    let rmse_cv: [String: Double?]
}

/// What the plan screens read from `GET /api/houses/<id>` (the rest of the house stays on the server).
/// A thing RoomPlan saw in a room (homemesh/model.py `Furniture`); the Wi-Fi model ignores it.
struct PlanFurniture: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let level: String
    let room: String?
    let category: String
    let name: String
    let center: Pt
    let width: Double
    let depth: Double
    let height: Double
    let base_z: Double?
    let rotation: Double
    let attributes: [String: String]?
    let movable: Bool
    let movable_default: Bool?

    /// What the owner sees: the name they gave, else the category (and the type RoomPlan guessed).
    var title: String {
        if !name.isEmpty { return name }
        let kind = attributes?.values.sorted().first.map { " (\($0))" } ?? ""
        return category.prefix(1).uppercased() + category.dropFirst() + kind
    }

    /// The category's default: built-in appliances are fixed, furniture is movable.
    static func defaultMovable(_ category: String) -> Bool {
        !["sink", "toilet", "bathtub", "stove", "oven", "dishwasher", "fireplace"].contains(category)
    }

    /// The four corners of the item's footprint in plan metres.
    var corners: [Pt] {
        let c = cos(rotation * .pi / 180), s = sin(rotation * .pi / 180)
        return [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)].map { sx, sy in
            let x = sx * width / 2, y = sy * depth / 2
            return Pt(center.x + x * c - y * s, center.y + x * s + y * c)
        }
    }

    func contains(_ p: Pt) -> Bool { Geometry.contains(p, polygon: corners) }
}

struct PlanHouse: Codable, Sendable {
    let id: String
    let name: String
    let revision: Int
    let levels: [HouseLite.Level]
    let walls: [PlanWall]
    let rooms: [PlanRoom]
    let outlets: [PlanOutlet]
    let jacks: [PlanJack]
    let access_points: [PlanAP]
    let stairs: [PlanStair]
    let zones: [PlanZone]
    let furniture: [PlanFurniture]
    let entry: PlanEntry?
    let measurements: [PlanMeasurement]
    let calibration: PlanCalibration?

    enum CodingKeys: String, CodingKey { case id, name, revision, levels, walls, rooms, outlets, jacks, access_points, stairs, zones, furniture, entry, measurements, calibration }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        revision = try c.decode(Int.self, forKey: .revision)
        levels = try c.decode([HouseLite.Level].self, forKey: .levels)
        walls = try c.decodeIfPresent([PlanWall].self, forKey: .walls) ?? []
        rooms = try c.decodeIfPresent([PlanRoom].self, forKey: .rooms) ?? []
        outlets = try c.decodeIfPresent([PlanOutlet].self, forKey: .outlets) ?? []
        jacks = try c.decodeIfPresent([PlanJack].self, forKey: .jacks) ?? []
        access_points = try c.decodeIfPresent([PlanAP].self, forKey: .access_points) ?? []
        stairs = try c.decodeIfPresent([PlanStair].self, forKey: .stairs) ?? []
        zones = try c.decodeIfPresent([PlanZone].self, forKey: .zones) ?? []
        furniture = try c.decodeIfPresent([PlanFurniture].self, forKey: .furniture) ?? []
        entry = try c.decodeIfPresent(PlanEntry.self, forKey: .entry)
        measurements = try c.decodeIfPresent([PlanMeasurement].self, forKey: .measurements) ?? []
        calibration = try c.decodeIfPresent(PlanCalibration.self, forKey: .calibration)
    }
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

    static func distance(from p: Pt, toSegment a: Pt, _ b: Pt) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func contains(_ p: Pt, polygon: [Pt]) -> Bool {
        var inside = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        }
        return inside
    }

    /// A stair flight drawn as its centre line from `a` to `b`: a rectangle `width` metres across.
    static func stairRectangle(_ a: Pt, _ b: Pt, width: Double) -> [Pt] {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.001)
        let nx = -dy / len * width / 2, ny = dx / len * width / 2
        return [Pt(a.x + nx, a.y + ny), Pt(b.x + nx, b.y + ny), Pt(b.x - nx, b.y - ny), Pt(a.x - nx, a.y - ny)]
    }

    static func bounds(_ pts: [Pt]) -> CGRect {
        guard let first = pts.first else { return CGRect(x: -1, y: -1, width: 2, height: 2) }
        var lo = first, hi = first
        for p in pts { lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y); hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y) }
        return CGRect(x: lo.x, y: lo.y, width: max(hi.x - lo.x, 1), height: max(hi.y - lo.y, 1))
    }
}
