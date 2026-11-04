import Foundation

// Operations on zones, staircases and floors for the editor (docs/design-standalone-app.md section 4.3): pure, one undoable step each.

enum Ids {
    static func next(_ prefix: String, _ taken: Set<String>, from count: Int) -> String {
        var n = count + 1
        while taken.contains("\(prefix)\(n)") { n += 1 }
        return "\(prefix)\(n)"
    }
}

public enum ZoneOps {
    public static func defaults(_ kind: String) -> (requires: String, need: Need?, weight: Double) {
        switch kind {
        case "demand": ("none", Need(min_rssi: -65, min_throughput: nil, max_latency: nil, band_pref: nil, must: false, rx_height: 1), 1)
        case "allow": ("none", nil, 1)
        default: ("none", nil, 1)
        }
    }

    /// A zone of `kind` on `level` with the corners given (one point is a single spot). Returns the house and the new zone's id.
    public static func add(_ h: House, kind: String, level: String, polygon: [Vec2], name: String = "") -> (House, String)? {
        guard ["allow", "forbid", "demand"].contains(kind), !polygon.isEmpty, h.levels.contains(where: { $0.id == level }) else { return nil }
        let d = defaults(kind)
        let id = Ids.next("z", Set(h.zones.map(\.id)), from: h.zones.count)
        var z = Zone(id: id, level: level, polygon: polygon, kind: kind, name: name, weight: d.weight, need: d.need, requires: d.requires, mounts: [], heights: [], prov: .manual)
        if kind == "demand", z.need == nil { z.need = Need() }
        var out = h
        out.zones.append(z)
        return (out, id)
    }

    static func index(_ h: House, _ id: String) -> Int? { h.zones.firstIndex { $0.id == id } }

    public static func moveVertex(_ h: House, zone id: String, vertex i: Int, to p: Vec2) -> House? {
        guard let k = index(h, id), h.zones[k].polygon.indices.contains(i) else { return nil }
        var out = h
        out.zones[k].polygon[i] = p
        return out
    }

    /// A new corner after corner `i`, at `p` (default: the middle of that edge).
    public static func insertVertex(_ h: House, zone id: String, after i: Int, at p: Vec2? = nil) -> House? {
        guard let k = index(h, id), h.zones[k].polygon.count >= 3, h.zones[k].polygon.indices.contains(i) else { return nil }
        var out = h
        let a = h.zones[k].polygon[i], b = h.zones[k].polygon[(i + 1) % h.zones[k].polygon.count]
        out.zones[k].polygon.insert(p ?? (a + b) * 0.5, at: i + 1)
        return out
    }

    /// Drops a corner; an area keeps at least three.
    public static func removeVertex(_ h: House, zone id: String, vertex i: Int) -> House? {
        guard let k = index(h, id), h.zones[k].polygon.count > 3, h.zones[k].polygon.indices.contains(i) else { return nil }
        var out = h
        out.zones[k].polygon.remove(at: i)
        return out
    }

    public static func move(_ h: House, zone id: String, by d: Vec2) -> House? {
        guard let k = index(h, id) else { return nil }
        var out = h
        out.zones[k].polygon = out.zones[k].polygon.map { $0 + d }
        return out
    }

    /// A copy on another floor (the same outline), named as the original.
    public static func duplicate(_ h: House, zone id: String, to level: String) -> (House, String)? {
        guard let k = index(h, id), h.levels.contains(where: { $0.id == level }) else { return nil }
        var z = h.zones[k]
        z.id = Ids.next("z", Set(h.zones.map(\.id)), from: h.zones.count)
        z.level = level
        var out = h
        out.zones.append(z)
        return (out, z.id)
    }

    public static func delete(_ h: House, zone id: String) -> House? {
        guard index(h, id) != nil else { return nil }
        var out = h
        out.zones.removeAll { $0.id == id }
        return out
    }
}

public enum StairOps {
    /// A flight from `bottom` to `top`, `width` across, joining `level` and `target`: the lower of the two floors holds its footprint. Returns the house and the stair's id.
    public static func add(_ h: House, level: String, target: String, bottom: Vec2, top: Vec2, width: Double = 1.0) -> (House, String)? {
        guard level != target, let a = h.levels.first(where: { $0.id == level }), let b = h.levels.first(where: { $0.id == target }), width > 0, (top - bottom).length > 0.3 else { return nil }
        let up = b.elevation > a.elevation
        let id = Ids.next("s", Set(h.stairs.map(\.id)), from: h.stairs.count)
        let dx = top.x - bottom.x, dy = top.y - bottom.y, len = max((top - bottom).length, 0.001)
        let nx = -dy / len * width / 2, ny = dx / len * width / 2
        let poly = [Vec2(bottom.x + nx, bottom.y + ny), Vec2(top.x + nx, top.y + ny), Vec2(top.x - nx, top.y - ny), Vec2(bottom.x - nx, bottom.y - ny)]
        var out = h
        out.stairs.append(Stair(id: id, from_level: up ? level : target, to_level: up ? target : level, polygon: poly, void: true, steps: nil, low: bottom, prov: .manual))
        return (out, id)
    }

    /// Turns the flight round: the bottom end becomes the other end.
    public static func turn(_ h: House, stair id: String) -> House? {
        guard let k = h.stairs.firstIndex(where: { $0.id == id }), h.stairs[k].polygon.count == 4 else { return nil }
        let p = h.stairs[k].polygon
        let e1 = p[1] - p[0], e2 = p[2] - p[1]
        let ends = e2.length >= e1.length ? [(p[0] + p[1]) * 0.5, (p[2] + p[3]) * 0.5] : [(p[1] + p[2]) * 0.5, (p[3] + p[0]) * 0.5]
        var out = h
        let cur = h.stairs[k].low
        out.stairs[k].low = cur == nil ? ends[1] : ((cur! - ends[0]).length <= (cur! - ends[1]).length ? ends[1] : ends[0])
        return out
    }

    /// The owner's step count (2 to 60), or nil to go back to the count worked out from the rise.
    public static func setSteps(_ h: House, stair id: String, steps: Int?) -> House? {
        guard let k = h.stairs.firstIndex(where: { $0.id == id }) else { return nil }
        if let s = steps, !(2...60).contains(s) { return nil }
        var out = h
        out.stairs[k].steps = steps
        return out
    }

    public static func delete(_ h: House, stair id: String) -> House? {
        guard h.stairs.contains(where: { $0.id == id }) else { return nil }
        var out = h
        out.stairs.removeAll { $0.id == id }
        return out
    }
}

public enum FloorOps {
    /// Copies the walls (with their openings) of one floor to another as a starting point, with new ids. Returns the house and how many walls were copied.
    public static func copyWalls(_ h: House, from: String, to: String) -> (House, Int)? {
        guard from != to, h.levels.contains(where: { $0.id == from }), h.levels.contains(where: { $0.id == to }) else { return nil }
        let src = h.walls.filter { $0.level == from }
        if src.isEmpty { return nil }
        var out = h
        var taken = Set(h.walls.map(\.id))
        var n = h.walls.count
        for var w in src {
            repeat { n += 1 } while taken.contains("w\(n)")
            taken.insert("w\(n)")
            w.id = "w\(n)"; w.level = to
            w.prov = Provenance(source: "manual")
            out.walls.append(w)
        }
        return (out, src.count)
    }

    public static func setHeight(_ h: House, level: String, height: Double) -> House? {
        guard let k = h.levels.firstIndex(where: { $0.id == level }), (1.8...6.0).contains(height) else { return nil }
        var out = h
        out.levels[k].height = height
        out.levels[k].height_source = "default"
        return (try? Stack.restack(out, order: out.levels.map(\.id), belowGround: out.levels.filter(\.below_ground).map(\.id), measure: false)) ?? out
    }

    public static func setSlabThickness(_ h: House, level: String, thickness: Double) -> House? {
        guard let k = h.levels.firstIndex(where: { $0.id == level }), h.levels[k].slab != nil, (0.05...1.0).contains(thickness) else { return nil }
        var out = h
        out.levels[k].slab!.thickness = thickness
        return (try? Stack.restack(out, order: out.levels.map(\.id), belowGround: out.levels.filter(\.below_ground).map(\.id), measure: false)) ?? out
    }
}
