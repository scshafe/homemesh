import Foundation

// The planner (a port of homemesh/planner.py; design section 5): candidate spots, search, ranking.
// Candidates come from the owner's `allow` zones minus `forbid` zones, honouring a zone's power requirement. Per (equipment, node count k):
// exhaustive over a pruned set of representative spots when C(R, k) is small, else greedy by marginal gain; both finish with swap refinement.

public struct PlanConfig: Sendable {
    public var gateway_equipment = "generic-router-ax"
    public var equipment: [String] = []          // shortlist; empty = every mesh_node/extender in the catalogue
    public var k_max = 5
    public var price_ceiling: Double?
    public var policy = Policy()
    public var candidate_step = 0.5
    public var gateway_height = 1.2
    public var max_representatives = 40
    public var exhaustive_limit = 12_000
    public var swap_rounds = 3
    public var top_n = 5
    public init() {}
}

public struct Scored: @unchecked Sendable {
    public var equipment: String
    public var extras: [NodePlacement]
    public var score: Double                     // weighted coverage utility at the median, 0..1
    public var score_margin: Double
    public var worst: Double
    public var cost: Double
    public var valid: Bool
    public var must_ok: Bool
    public var zones: [ZoneScore]
    public var evaluation: Evaluation?
    public var k: Int { extras.count }
    public var stable: Bool { score - score_margin <= 0.05 }
}

public struct PlanCancelled: Error {}

public enum Planner {
    static let defaultHeight = 1.5
    static let forbidRadius = 0.75

    static func inside(_ pt: Vec2, _ zone: Zone) -> Bool {
        zone.polygon.count >= 3 ? PropagationModel.inPolygon(pt.x, pt.y, zone.polygon) : hypot(pt.x - zone.polygon[0].x, pt.y - zone.polygon[0].y) <= forbidRadius
    }

    static func powered(_ house: House, _ zone: Zone, _ pt: Vec2) -> Bool {
        switch zone.requires {
        case "none": return true
        case "outlet": return house.outlets.contains { $0.level == zone.level && hypot($0.position.x - pt.x, $0.position.y - pt.y) <= 1.5 }
        default: return house.jacks.contains { $0.poe && $0.state != "dead" && $0.level == zone.level && hypot($0.position.x - pt.x, $0.position.y - pt.y) <= 0.6 }
        }
    }

    /// numpy's arange(start, stop, step) for positive steps.
    static func arange(_ start: Double, _ stop: Double, _ step: Double) -> [Double] {
        let n = max(0, Int(((stop - start) / step).rounded(.up)))
        return (0..<n).map { start + Double($0) * step }
    }

    public static func candidates(_ house: House, step: Double = 0.5) -> [NodePlacement] {
        let forbids = house.zones.filter { $0.kind == "forbid" }
        var out: [String: NodePlacement] = [:]
        func add(_ zone: Zone, _ p: Vec2) {
            let pt = Vec2(ScanImport.rnd(p.x, 3), ScanImport.rnd(p.y, 3))
            if forbids.contains(where: { $0.level == zone.level && inside(pt, $0) }) || !powered(house, zone, pt) { return }
            for h in zone.heights.isEmpty ? [defaultHeight] : zone.heights {
                let k = "\(pt.x),\(pt.y),\(zone.level),\(h)"
                if out[k] == nil { out[k] = NodePlacement(equipment: "", position: pt, level: zone.level, height: h) }
            }
        }
        for z in house.zones where z.kind == "allow" {
            if z.polygon.count < 3 { add(z, z.polygon[0]); continue }
            let xs = z.polygon.map(\.x), ys = z.polygon.map(\.y)
            let gx = arange(xs.min()! + step / 2, xs.max()!, step), gy = arange(ys.min()! + step / 2, ys.max()!, step)
            for x in gx { for y in gy where PropagationModel.inPolygon(x, y, z.polygon) { add(z, Vec2(x, y)) } }
            for j in house.jacks where j.level == z.level && inside(j.position, z) { add(z, j.position) }   // a jack in an allow zone may be a wired spot
        }
        return out.values.sorted { a, b in
            if a.level != b.level { return a.level < b.level }
            if a.position.x != b.position.x { return a.position.x < b.position.x }
            if a.position.y != b.position.y { return a.position.y < b.position.y }
            return a.height < b.height
        }
    }

    /// Indices of up to n spots that differ most in what they cover (farthest point on 5 GHz loss signatures).
    static func representatives(_ ctx: PlanContext, _ cands: [NodePlacement], _ n: Int, keep: Set<Int>) -> [Int] {
        if cands.count <= n { return Array(0..<cands.count) }
        let ok = (0..<ctx.cells.count).filter { ctx.cellOk[$0] }
        let stride = max(1, ok.count / 400)
        let sub = Swift.stride(from: 0, to: ok.count, by: stride).map { ok[$0] }
        let sig: [[Double]] = cands.map { c in let l = ctx.lossToCells(c, .b5); return sub.map { min(l[$0], 110) } }
        func dist(_ a: [Double], _ b: [Double]) -> Double { var s = 0.0; for i in 0..<a.count { let d = a[i] - b[i]; s += d * d }; return s.squareRoot() }
        var chosen = Array(keep.sorted().prefix(n))
        if chosen.isEmpty {
            let means = sig.map { $0.reduce(0, +) / Double(max($0.count, 1)) }
            chosen = [means.firstIndex(of: means.min()!)!]
        }
        var d = (0..<cands.count).map { i in chosen.map { dist(sig[i], sig[$0]) }.min()! }
        while chosen.count < n {
            let m = d.max()!
            let i = d.firstIndex(of: m)!
            if d[i] <= 1e-9 { break }
            chosen.append(i)
            for j in 0..<d.count { d[j] = min(d[j], dist(sig[j], sig[i])) }
        }
        return chosen.sorted()
    }

    public static func score(_ ctx: PlanContext, gateway: NodePlacement, extras: [NodePlacement], equipment: String, cfg: PlanConfig, robust: Bool = true) -> Scored {
        let ev = Backhaul.evaluate(ctx, gateway: gateway, extras: extras, policy: cfg.policy)
        let evm = robust ? Backhaul.evaluate(ctx, gateway: gateway, extras: extras, policy: cfg.policy, margin: cfg.policy.margin_db) : ev
        let zs = Backhaul.zoneScores(ctx, ev, evm, cfg.policy)
        let w = ctx.house.zones.filter { $0.kind == "demand" }.map { max($0.weight, 0) }
        let tot = w.reduce(0, +) == 0 ? 1.0 : w.reduce(0, +)
        var s = 0.0, sm = 0.0
        for (wi, z) in zip(w, zs) { s += wi * z.utility; sm += wi * z.utility_margin }
        if zs.isEmpty { s = 0; sm = 0 } else { s /= tot; sm /= tot }
        let worst = zs.map(\.utility).min() ?? 0
        let must = zs.allSatisfy { $0.must_met != false }
        let valid = ev.valid && (cfg.price_ceiling == nil || ev.cost <= cfg.price_ceiling!)
        return Scored(equipment: equipment, extras: extras, score: s, score_margin: sm, worst: worst, cost: ev.cost, valid: valid, must_ok: must, zones: zs, evaluation: ev)
    }

    /// Sort key, best first: valid, `must` zones met, score, margin score, cheaper.
    static func less(_ a: Scored, _ b: Scored) -> Bool {
        if a.valid != b.valid { return a.valid }
        if a.must_ok != b.must_ok { return a.must_ok }
        if a.score != b.score { return a.score > b.score }
        if a.score_margin != b.score_margin { return a.score_margin > b.score_margin }
        return a.cost < b.cost
    }

    /// A stable sort best first (Python's sort is stable; ties keep their order).
    static func sortedBest(_ x: [Scored]) -> [Scored] { x.enumerated().sorted { less($0.element, $1.element) || (!less($1.element, $0.element) && $0.offset < $1.offset) }.map(\.element) }

    static func place(_ c: NodePlacement, _ equipment: String) -> NodePlacement { NodePlacement(equipment: equipment, position: c.position, level: c.level, height: c.height) }

    static func nearLiveJack(_ house: House, _ c: NodePlacement, near: Double = 0.6) -> Bool {
        house.jacks.contains { $0.level == c.level && $0.state != "dead" && hypot($0.position.x - c.position.x, $0.position.y - c.position.y) <= near }
    }

    static func combinations(_ n: Int, _ k: Int, _ body: ([Int]) throws -> Void) rethrows {
        var idx = Array(0..<k)
        if k > n { return }
        while true {
            try body(idx)
            var i = k - 1
            while i >= 0 && idx[i] == i + n - k { i -= 1 }
            if i < 0 { return }
            idx[i] += 1
            for j in (i + 1)..<k { idx[j] = idx[j - 1] + 1 }
        }
    }

    static func comb(_ n: Int, _ k: Int) -> Int {
        if k < 0 || k > n { return 0 }
        var r = 1
        for i in 0..<min(k, n - k) { r = r * (n - i) / (i + 1); if r > 1_000_000_000 { return r } }
        return r
    }

    public static func search(_ ctx: PlanContext, _ cfg: PlanConfig, progress: (String) -> Void = { _ in }, cancelled: () -> Bool = { false }) throws -> [Scored] {
        let house = ctx.house, catalogue = ctx.catalogue
        guard let entry = house.entry else { throw ImportError("the house has no internet entry: the gateway needs somewhere to sit") }
        let cands = candidates(house, step: cfg.candidate_step)
        if cands.isEmpty { throw ImportError("no candidate spots: mark at least one allow zone") }
        let gateway = NodePlacement(equipment: cfg.gateway_equipment, position: entry.position, level: entry.level, height: cfg.gateway_height)
        let names = cfg.equipment.isEmpty ? catalogue.filter { $0.value.kind == "mesh_node" || $0.value.kind == "extender" }.map(\.key).sorted() : cfg.equipment
        for n in [cfg.gateway_equipment] + names where catalogue[n] == nil { throw ImportError("unknown equipment \(n)") }

        var results = [score(ctx, gateway: gateway, extras: [], equipment: cfg.gateway_equipment, cfg: cfg)]
        let wired = Set(cands.indices.filter { nearLiveJack(house, cands[$0]) })
        let reps = representatives(ctx, cands, cfg.max_representatives, keep: wired)
        progress("\(cands.count) candidate spots, \(reps.count) representatives")

        for name in names {
            for k in stride(from: 1, through: cfg.k_max, by: 1) {
                if cancelled() { throw PlanCancelled() }
                if k > cands.count { break }  // more nodes than spots to put them on
                var kept: [Scored]
                let how: String
                let c = comb(reps.count, k)
                if c > 0 && c <= cfg.exhaustive_limit { kept = exhaustive(ctx, gateway, cands, reps, k, name, cfg, cancelled); how = "exhaustive" }
                else { kept = greedy(ctx, gateway, cands, k, name, cfg); how = "greedy" }
                kept = kept.map { swap(ctx, gateway, cands, $0, cfg) }
                kept = sortedBest(kept)
                var final = dedupe(kept).prefix(cfg.top_n).map { score(ctx, gateway: gateway, extras: $0.extras, equipment: $0.equipment, cfg: cfg) }
                final = sortedBest(final)
                if final.isEmpty { continue }
                results += final
                progress("\(name) k=\(k): \(how), best score \(String(format: "%.3f", final[0].score))")
            }
        }
        return sortedBest(results)
    }

    static func exhaustive(_ ctx: PlanContext, _ gateway: NodePlacement, _ cands: [NodePlacement], _ reps: [Int], _ k: Int, _ name: String, _ cfg: PlanConfig, _ cancelled: () -> Bool) -> [Scored] {
        var best: [Scored] = []
        combinations(reps.count, k) { combo in
            var sc = score(ctx, gateway: gateway, extras: combo.map { place(cands[reps[$0]], name) }, equipment: name, cfg: cfg, robust: false)
            sc.evaluation = nil
            best.append(sc)
            if best.count > 200 { best = Array(sortedBest(best).prefix(cfg.top_n * 4)) }
        }
        return Array(sortedBest(best).prefix(cfg.top_n * 2))
    }

    static func greedy(_ ctx: PlanContext, _ gateway: NodePlacement, _ cands: [NodePlacement], _ k: Int, _ name: String, _ cfg: PlanConfig) -> [Scored] {
        var chosen: [NodePlacement] = []
        for _ in 0..<k {
            var bestSc: Scored?, bestP: NodePlacement?
            for c in cands {
                let p = place(c, name)
                if chosen.contains(p) { continue }
                let sc = score(ctx, gateway: gateway, extras: chosen + [p], equipment: name, cfg: cfg, robust: false)
                if bestSc == nil || less(sc, bestSc!) { bestSc = sc; bestP = p }
            }
            chosen.append(bestP!)
        }
        return [score(ctx, gateway: gateway, extras: chosen, equipment: name, cfg: cfg)]
    }

    static func swap(_ ctx: PlanContext, _ gateway: NodePlacement, _ cands: [NodePlacement], _ sc: Scored, _ cfg: PlanConfig) -> Scored {
        var cur = score(ctx, gateway: gateway, extras: sc.extras, equipment: sc.equipment, cfg: cfg, robust: false)
        for _ in 0..<cfg.swap_rounds {
            var improved = false
            for i in 0..<cur.extras.count {
                for c in cands {
                    let p = place(c, cur.equipment)
                    if cur.extras.contains(p) { continue }
                    var ex = cur.extras
                    ex[i] = p
                    let trial = score(ctx, gateway: gateway, extras: ex, equipment: cur.equipment, cfg: cfg, robust: false)
                    if less(trial, cur) { cur = trial; improved = true }
                }
            }
            if !improved { break }
        }
        return cur
    }

    static func dedupe(_ items: [Scored]) -> [Scored] {
        var seen = Set<String>(), out: [Scored] = []
        for sc in items {
            let key = sc.extras.map { "\($0.position.x),\($0.position.y),\($0.level),\($0.height)" }.sorted().joined(separator: "|") + "#" + sc.equipment
            if seen.insert(key).inserted { out.append(sc) }
        }
        return out
    }

    /// Arrangements no other valid one beats on (score, worst zone, cost) at once.
    public static func pareto(_ items: [Scored]) -> [Scored] {
        var pool = items.filter { $0.valid && $0.must_ok }
        if pool.isEmpty { pool = items.filter(\.valid) }
        var front: [Scored] = []
        for a in pool {
            let dominated = pool.contains { b in (b.score >= a.score && b.worst >= a.worst && b.cost <= a.cost) && (b.score > a.score || b.worst > a.worst || b.cost < a.cost) }
            if !dominated { front.append(a) }
        }
        return front.enumerated().sorted { l, r in
            if l.element.cost != r.element.cost { return l.element.cost < r.element.cost }
            if l.element.score != r.element.score { return l.element.score > r.element.score }
            return l.offset < r.offset
        }.map(\.element)
    }
}
