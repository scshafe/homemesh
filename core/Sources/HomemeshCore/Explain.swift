import Foundation

// Deterministic explanation of a planner result (a port of homemesh/explain.py; design 5.5). Everything is computed from the numbers:
// per-zone limiting factor, each node's leave-one-out contribution, the comparison with the runner-up, and the rank stability when the
// material losses move within their prior uncertainty. The stability draws use this package's own seeded generator, not numpy's, so the
// percentage differs slightly from the Python figure; everything else matches.

public struct ZoneNote: Sendable {
    public var zone: String
    public var mean_rate: Double
    public var frac_target: Double
    public var utility: Double
    public var limiter: String                 // no signal | access | backhaul | wan
    public var detail: String
}

public struct Explanation: Sendable {
    public var zones: [ZoneNote]
    public var node_contribution: [(node: Int, drop: Double)]
    public var vs_runner_up: [String]
    public var stability: Double?
    public var depends_on_jacks: [String]
    public var lines: [String]
}

/// A small seeded generator (SplitMix64) with normal draws (Box-Muller): repeatable on every platform.
public struct SeededNormal: Sendable {
    var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func normal(_ sd: Double) -> Double {
        let u = max(uniform(), 1e-300), v = uniform()
        return sd * (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

public enum Explain {
    static func f0(_ x: Double) -> String { String(format: "%.0f", x) }

    static func zoneNote(_ ctx: PlanContext, _ ev: Evaluation, _ zone: Zone, _ nodes: [NodePlacement], _ cfg: PlanConfig) -> ZoneNote {
        let mask = ctx.zoneMask(zone)
        let idx = (0..<ctx.cells.count).filter { mask[$0] && ctx.cellOk[$0] }
        var target = zone.need?.min_throughput ?? 0
        if target == 0 { target = cfg.policy.floor_mbps }
        if idx.isEmpty { return ZoneNote(zone: zone.id, mean_rate: 0, frac_target: 0, utility: 0, limiter: "no signal", detail: "the zone covers no receiver cell") }
        let rate = idx.map { ev.rate[$0] }
        let mean = rate.reduce(0, +) / Double(rate.count)
        let frac = Double(rate.filter { $0 >= target }.count) / Double(rate.count)
        if mean <= 0 { return ZoneNote(zone: zone.id, mean_rate: mean, frac_target: frac, utility: 0, limiter: "no signal", detail: "no node reaches this zone") }
        var counts = [Int: Int]()
        for i in idx where ev.serving[i] >= 0 { counts[ev.serving[i], default: 0] += 1 }
        let top = counts.values.max()!
        let node = counts.filter { $0.value == top }.keys.min()!
        let nr = ev.nodes[node]
        let limited = Double(idx.map { Double(ev.limitedBy[$0]) }.reduce(0, +)) / Double(idx.count) > 0.5
        let wan = ctx.house.entry?.wan_down
        if limited {
            if let wan, abs(nr.backhaul_mbps - wan) < 1e-6 { return ZoneNote(zone: zone.id, mean_rate: mean, frac_target: frac, utility: 0, limiter: "wan", detail: "capped by the internet plan (\(f0(wan)) Mbit/s)") }
            var how: String
            if nr.kind == "wired" { how = "wired through jack \(nr.jack ?? "?")" }
            else if nr.kind == "gateway" { how = "the gateway itself" }
            else { how = "\(nr.hops) wireless hop(s) to the gateway on \(nr.link_band?.rawValue ?? "?") GHz" + (nr.shared_radio ? ", sharing that radio with clients" : "") }
            return ZoneNote(zone: zone.id, mean_rate: mean, frac_target: frac, utility: 0, limiter: "backhaul", detail: "node \(node) is limited by its backhaul (\(f0(nr.backhaul_mbps)) Mbit/s): \(how)")
        }
        // access limited: the biggest wall or slab term between the serving node and the zone's median cell
        let order = rate.enumerated().sorted { $0.element != $1.element ? $0.element < $1.element : $0.offset < $1.offset }.map(\.offset)
        let cell = ctx.cells[idx[order[rate.count / 2]]]
        let p = nodes[node]
        let tx = Vec3(p.position.x, p.position.y, (ctx.elevation[p.level] ?? 0) + p.height)
        let terms = ctx.model.explainPoint(tx: tx, rx: cell, band: .b5)
        let mats = Dictionary(ctx.house.walls.map { ($0.id, $0.material) }, uniquingKeysWith: { a, _ in a })
        var detail: String
        if let t = terms.first {
            let what = t.kind == "wall" ? "wall \(t.id) (\(mats[t.id] ?? "?"))" : "the floor slab of level \(t.id)"
            detail = "node \(node): signal limited by distance and \(what), \(String(format: "%.1f", t.db)) dB at 5 GHz, the largest obstruction"
        } else { detail = "node \(node): signal limited by distance (no walls between)" }
        return ZoneNote(zone: zone.id, mean_rate: mean, frac_target: frac, utility: 0, limiter: "access", detail: detail)
    }

    /// A context whose material losses moved by a draw within each material's prior spread.
    static func perturbed(_ ctx: PlanContext, _ rng: inout SeededNormal) throws -> PlanContext {
        var h = ctx.house
        for i in h.materials.indices {
            let d = rng.normal(h.materials[i].prior_sd)
            h.materials[i].loss = h.materials[i].loss.mapValues { max(0, $0 + d) }
        }
        let g = ctx.grids.first
        return try PlanContext(house: h, catalogue: ctx.catalogue, client: ctx.client, params: ctx.params, step: g?.step ?? 0.5, rxHeight: g.map { $0.z - (ctx.elevation[$0.level] ?? 0) } ?? 1.0)
    }

    public static func explain(_ ctx: PlanContext, gateway: NodePlacement, best: Scored, runnerUp: Scored?, cfg: PlanConfig, samples: Int = 20, seed: UInt64 = 0) throws -> Explanation {
        let ev = best.evaluation!
        let nodes = [gateway] + best.extras
        var notes: [ZoneNote] = []
        let scored = Dictionary(best.zones.map { ($0.zone, $0) }, uniquingKeysWith: { a, _ in a })
        for z in ctx.house.zones where z.kind == "demand" {
            var n = zoneNote(ctx, ev, z, nodes, cfg)
            n.utility = scored[z.id]?.utility ?? 0
            notes.append(n)
        }
        var contrib: [(Int, Double)] = []
        for i in 0..<best.extras.count {
            var without = best.extras
            without.remove(at: i)
            contrib.append((i + 1, best.score - Planner.score(ctx, gateway: gateway, extras: without, equipment: best.equipment, cfg: cfg).score))
        }
        var vs: [String] = []
        if let ru = runnerUp {
            let r = Dictionary(ru.zones.map { ($0.zone, $0) }, uniquingKeysWith: { a, _ in a })
            for z in best.zones {
                guard let o = r[z.zone] else { continue }
                let d = z.utility - o.utility
                if abs(d) >= 0.02 { vs.append("zone \(z.zone): \(d > 0 ? "wins" : "loses") by \(f0(abs(d) * 100)) points of utility") }
            }
            let dc = best.cost - ru.cost
            vs.append("cost \(dc >= 0 ? "+" : "-")\(f0(abs(dc))) against the runner-up")
        }
        var stability: Double?
        if let ru = runnerUp {
            var rng = SeededNormal(seed: seed)
            var wins = 0
            for _ in 0..<samples {
                let c2 = try perturbed(ctx, &rng)
                let a = Planner.score(c2, gateway: gateway, extras: best.extras, equipment: best.equipment, cfg: cfg)
                let b = Planner.score(c2, gateway: gateway, extras: ru.extras, equipment: ru.equipment, cfg: cfg)
                if a.score >= b.score { wins += 1 }
            }
            stability = Double(wins) / Double(samples)
        }
        var lines: [String] = []
        for n in notes {
            let met = n.frac_target >= 0.99 ? "target met" : "\(f0(n.frac_target * 100))% of cells at target"
            lines.append("\(n.zone): \(f0(n.mean_rate)) Mbit/s mean, \(met); \(n.detail)")
        }
        for (i, d) in contrib { lines.append("node \(i): removing it costs \(String(format: "%.1f", d * 100)) points of score") }
        lines += vs
        if let s = stability { lines.append("rank stability: still ahead of the runner-up in \(f0(s * 100))% of material-loss draws") }
        if !ev.jacksUnverified.isEmpty { lines.append("depends on jacks not yet verified live: " + ev.jacksUnverified.joined(separator: ", ")) }
        return Explanation(zones: notes, node_contribution: contrib.map { ($0.0, $0.1) }, vs_runner_up: vs, stability: stability, depends_on_jacks: ev.jacksUsed, lines: lines)
    }
}
