import Foundation

// The floor stack (a port of homemesh/stack.py): levels in order from the bottom, elevations derived from that order and the
// measured heights. Ground is the first level that is not below ground and sits at 0.

public enum StackError: Error, Equatable { case invalid(String) }

public enum Stack {
    public static let slab = 0.3

    static func round2(_ x: Double) -> Double { (x * 100).rounded(.toNearestOrEven) / 100 }
    static func round3(_ x: Double) -> Double { (x * 1000).rounded(.toNearestOrEven) / 1000 }

    public static func measuredHeight(_ house: House, _ level: String) -> Double? {
        let hs = house.walls.filter { $0.level == level && $0.height > 0 }.map(\.height).sorted()
        if hs.isEmpty { return nil }
        let m = hs.count % 2 == 1 ? hs[hs.count / 2] : (hs[hs.count / 2 - 1] + hs[hs.count / 2]) / 2
        return round2(m)
    }

    private static func slabThickness(_ l: Level) -> Double { l.slab?.thickness ?? slab }

    /// `order` lists every level id, bottom to top; `belowGround` the basements (a prefix of the order).
    public static func restack(_ house: House, order: [String], belowGround: [String]? = nil, measure: Bool = true) throws -> House {
        let byId = Dictionary(house.levels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if order.sorted() != byId.keys.sorted() || Set(order).count != order.count { throw StackError.invalid("the order must list every level exactly once") }
        let below = Set(belowGround ?? house.levels.filter(\.below_ground).map(\.id))
        if !below.isSubset(of: Set(byId.keys)) { throw StackError.invalid("unknown level in below_ground") }
        let flags = order.map { below.contains($0) }
        if flags != flags.sorted(by: { $0 && !$1 }) { throw StackError.invalid("basements must be the lowest levels in the stack") }
        var lvls: [Level] = []
        for i in order {
            var lv = byId[i]!
            let walls = measure && lv.height_source != "stair" ? measuredHeight(house, i) : nil
            lv.below_ground = below.contains(i)
            if let w = walls { lv.height = w; lv.height_source = "walls" }
            lvls.append(lv)
        }
        guard let ground = lvls.firstIndex(where: { !$0.below_ground }) else { throw StackError.invalid("at least one level must be above ground") }
        let mat = lvls.compactMap { $0.slab?.material }.first ?? house.materials.first { $0.id == "slab-wood" }?.id ?? house.materials.first?.id
        var elev = [Double](repeating: 0, count: lvls.count)
        if ground + 1 < lvls.count { for n in (ground + 1)..<lvls.count { elev[n] = round3(elev[n - 1] + lvls[n - 1].height + slabThickness(lvls[n])) } }
        if ground > 0 { for n in stride(from: ground - 1, through: 0, by: -1) { elev[n] = round3(elev[n + 1] - slabThickness(lvls[n + 1]) - lvls[n].height) } }
        var out: [Level] = []
        for (n, var lv) in lvls.enumerated() {
            lv.slab = n == 0 ? nil : (lv.slab ?? mat.map { Slab(material: $0, thickness: slab) })
            lv.elevation = elev[n]
            out.append(lv)
        }
        var h = house
        h.levels = out
        return h
    }

    /// A staircase's measured rise is the floor-to-floor distance of two neighbouring levels: the lower one's height becomes rise minus the slab.
    public static func withRise(_ house: House, _ a: String, _ b: String, rise: Double) -> House {
        let order = house.levels.map(\.id)
        guard let ia = order.firstIndex(of: a), let ib = order.firstIndex(of: b), abs(ia - ib) == 1 else { return house }
        let lo = min(ia, ib), hi = max(ia, ib)
        let height = round2(rise - slabThickness(house.levels[hi]))
        if !(1.8...6.0).contains(height) { return house }
        var h = house
        h.levels[lo].height = height
        h.levels[lo].height_source = "stair"
        return (try? restack(h, order: order, belowGround: h.levels.filter(\.below_ground).map(\.id))) ?? house
    }
}

public enum DefaultMaterials {
    static let unsourced = "unsourced: spread of vendor/survey tables; see module docstring"
    static func m(_ id: String, _ name: String, _ l: (Double, Double, Double), _ ref: Double, _ sd: Double) -> Material {
        Material(id: id, name: name, loss: ["2.4": l.0, "5": l.1, "6": l.2], ref_thickness: ref, prior_sd: sd, source: unsourced)
    }
    public static let all: [Material] = [
        m("drywall", "Drywall partition", (3, 4, 5), 0.10, 2), m("wood-door", "Wooden door", (3, 4, 5), 0.04, 2), m("glass", "Plain glass", (2, 3, 4), 0.01, 2),
        m("brick", "Brick", (7, 9, 11), 0.20, 3), m("concrete", "Poured concrete", (12, 17, 20), 0.20, 5), m("slab-wood", "Wood joist floor", (9, 12, 14), 0.30, 4),
        m("slab-concrete", "Concrete floor slab", (15, 20, 24), 0.20, 6),
    ]
}
