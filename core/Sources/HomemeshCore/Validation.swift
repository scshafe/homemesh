import Foundation

extension House {
    /// Referential integrity and field rules (a port of `House.validate_refs` and the pydantic validators); empty when sound.
    public func validate() -> [String] {
        var errs: [String] = []
        let levelIds = Set(levels.map(\.id)), mats = Set(materials.map(\.id))
        let wallIds = Set(walls.map(\.id)), switchIds = Set(switches.map(\.id)), jackIds = Set(jacks.map(\.id))

        func dupes(_ kind: String, _ ids: [String]) {
            var seen = Set<String>()
            for i in ids { if !seen.insert(i).inserted { errs.append("duplicate \(kind) id \(i)") } }
        }
        dupes("level", levels.map(\.id)); dupes("material", materials.map(\.id)); dupes("wall", walls.map(\.id)); dupes("room", rooms.map(\.id))
        dupes("switch", switches.map(\.id)); dupes("jack", jacks.map(\.id)); dupes("outlet", outlets.map(\.id)); dupes("zone", zones.map(\.id))
        dupes("furniture", furniture.map(\.id)); dupes("measure check", measure_checks.map(\.id))
        dupes("access point", access_points.map(\.id)); dupes("measurement", measurements.map(\.id))

        func lv(_ what: String, _ level: String) { if !levelIds.contains(level) { errs.append("\(what): unknown level \(level)") } }
        func mat(_ what: String, _ m: String) { if !mats.contains(m) && m != "air" { errs.append("\(what): unknown material \(m)") } }

        if levels.isEmpty { errs.append("a house needs at least one level") }
        for l in levels { if let s = l.slab { mat("level \(l.id) slab", s.material) } }
        for f in furniture { lv("furniture \(f.id)", f.level) }
        for w in walls {
            lv("wall \(w.id)", w.level); mat("wall \(w.id)", w.material)
            if w.length == 0 { errs.append("wall \(w.id): zero length") }
            for o in w.openings {
                mat("wall \(w.id) opening", o.material)
                if o.offset + o.width > w.length + 1e-3 { errs.append("wall \(w.id): opening runs past the wall end") }
            }
        }
        for r in rooms { lv("room \(r.id)", r.level); if r.polygon.count < 3 { errs.append("room \(r.id): needs at least 3 points") } }
        for h in slab_holes { lv("slab hole \(h.id)", h.level) }
        for s in stairs { lv("stair \(s.id)", s.from_level); lv("stair \(s.id)", s.to_level) }
        if let e = entry { lv("entry", e.level) }
        for s in switches {
            lv("switch \(s.id)", s.level)
            if let u = s.uplink, u != "entry", !jackIds.contains(u), !switchIds.contains(u) { errs.append("switch \(s.id): unknown uplink \(u)") }
        }
        for j in jacks {
            lv("jack \(j.id)", j.level)
            if let w = j.wall, !wallIds.contains(w) { errs.append("jack \(j.id): unknown wall \(w)") }
            if let s = j.switch, !switchIds.contains(s) { errs.append("jack \(j.id): unknown switch \(s)") }
        }
        for o in outlets { lv("outlet \(o.id)", o.level) }
        for z in zones {
            lv("zone \(z.id)", z.level)
            if z.polygon.isEmpty { errs.append("zone \(z.id): needs at least 1 point") }
            if z.kind == "demand", z.need == nil { errs.append("zone \(z.id): a demand zone needs `need`") }
            if z.kind != "demand", z.need != nil { errs.append("zone \(z.id): only a demand zone has `need`") }
        }
        for a in access_points { lv("access point \(a.id)", a.level) }
        for m in measurements { lv("measurement \(m.id)", m.level) }
        for a in arrangements {
            for n in a.nodes {
                lv("arrangement \(a.id)", n.level)
                if let j = n.jack, !jackIds.contains(j) { errs.append("arrangement \(a.id): unknown jack \(j)") }
                if let p = n.parent, !(0..<a.nodes.count).contains(p) { errs.append("arrangement \(a.id): bad parent index") }
            }
        }
        return errs
    }
}
