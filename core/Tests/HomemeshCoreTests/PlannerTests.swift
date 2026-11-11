import Foundation
import Testing
@testable import HomemeshCore

@Test func plannerMatchesThePythonOracle() throws {
    let scenarios = try JSONSerialization.jsonObject(with: golden("plans")) as! [JObject]
    #expect(scenarios.count == 4)
    for sc in scenarios {
        let name = sc["name"] as! String
        let house = try House.load(JSONSerialization.data(withJSONObject: sc["house"]!))
        let n = sc["n"] as! [String: Double], extra = sc["extra_loss"] as! [String: Double]
        let params = PropParams(n: Dictionary(uniqueKeysWithValues: n.map { (Band(rawValue: $0.key)!, $0.value) }), extraLoss: Dictionary(uniqueKeysWithValues: extra.map { (Band(rawValue: $0.key)!, $0.value) }))
        let ctx = try PlanContext(house: house, catalogue: Catalogue.generic(), client: Catalogue.genericClients()[sc["client"] as! String]!, params: params, step: sc["grid"] as! Double)
        var cfg = PlanConfig()
        cfg.equipment = sc["equipment"] as! [String]
        cfg.k_max = sc["k_max"] as! Int
        cfg.candidate_step = sc["candidate_step"] as! Double
        cfg.policy.trust_unknown_jacks = sc["trust_unknown_jacks"] as! Bool
        let results = try Planner.search(ctx, cfg)
        #expect(results.count == sc["count"] as! Int, "\(name): result count")
        let want = sc["results"] as! [JObject]
        for (i, w) in want.enumerated() where i < results.count {
            let r = results[i]
            let tag = "\(name) #\(i + 1)"
            #expect(r.equipment == w["equipment"] as! String, "\(tag): equipment")
            let nodes = w["nodes"] as! [JObject]
            #expect(r.extras.count == nodes.count, "\(tag): node count")
            for (p, q) in zip(r.extras, nodes) {
                let pos = q["position"] as! [Double]
                #expect(abs(p.position.x - pos[0]) < 1e-9 && abs(p.position.y - pos[1]) < 1e-9 && p.level == q["level"] as! String && abs(p.height - (q["height"] as! Double)) < 1e-9, "\(tag): node position")
            }
            #expect(abs(r.score - (w["score"] as! Double)) < 1e-6, "\(tag): score \(r.score) vs \(w["score"]!)")
            #expect(abs(r.score_margin - (w["score_margin"] as! Double)) < 1e-6, "\(tag): margin score")
            #expect(abs(r.worst - (w["worst"] as! Double)) < 1e-6, "\(tag): worst")
            #expect(abs(r.cost - (w["cost"] as! Double)) < 1e-9, "\(tag): cost")
            #expect(r.valid == w["valid"] as! Bool && r.must_ok == w["must_ok"] as! Bool, "\(tag): valid / must")
            for (z, y) in zip(r.zones, w["zones"] as! [JObject]) {
                #expect(abs(z.utility - (y["utility"] as! Double)) < 1e-6 && abs(z.mean_rate - (y["mean_rate"] as! Double)) < 1e-4 && abs(z.frac_target - (y["frac_target"] as! Double)) < 1e-9, "\(tag): zone \(z.zone)")
            }
            let bh = w["backhaul"] as! [JObject]
            let ev = r.evaluation!
            #expect(ev.nodes.count == bh.count, "\(tag): backhaul count")
            for (a, b) in zip(ev.nodes, bh) {
                #expect(a.kind == b["kind"] as! String && a.parent == b["parent"] as? Int && a.hops == b["hops"] as! Int && a.jack == b["jack"] as? String, "\(tag): node kind/parent")
                if let m = b["mbps"] as? Double { #expect(abs(a.backhaul_mbps - m) < 1e-6, "\(tag): backhaul mbps") } else { #expect(a.backhaul_mbps == .infinity, "\(tag): backhaul inf") }
            }
            #expect(ev.problems == w["problems"] as! [String], "\(tag): problems")
        }
    }
}

@Test func explanationsMatchThePythonOracleExceptTheStabilityDraws() throws {
    let scenarios = try JSONSerialization.jsonObject(with: golden("plans")) as! [JObject]
    for sc in scenarios {
        let name = sc["name"] as! String
        let house = try House.load(JSONSerialization.data(withJSONObject: sc["house"]!))
        let n = sc["n"] as! [String: Double], extra = sc["extra_loss"] as! [String: Double]
        let params = PropParams(n: Dictionary(uniqueKeysWithValues: n.map { (Band(rawValue: $0.key)!, $0.value) }), extraLoss: Dictionary(uniqueKeysWithValues: extra.map { (Band(rawValue: $0.key)!, $0.value) }))
        let ctx = try PlanContext(house: house, catalogue: Catalogue.generic(), client: Catalogue.genericClients()["phone-2x2-ax"]!, params: params, step: 1.0)
        var cfg = PlanConfig()
        cfg.equipment = sc["equipment"] as! [String]; cfg.k_max = sc["k_max"] as! Int; cfg.candidate_step = sc["candidate_step"] as! Double
        cfg.policy.trust_unknown_jacks = sc["trust_unknown_jacks"] as! Bool
        let results = try Planner.search(ctx, cfg)
        let gw = NodePlacement(equipment: cfg.gateway_equipment, position: house.entry!.position, level: house.entry!.level, height: cfg.gateway_height)
        for w in sc["explanations"] as! [JObject] {
            let i = w["index"] as! Int
            let ex = try Explain.explain(ctx, gateway: gw, best: results[i], runnerUp: results[i + 1], cfg: cfg, samples: 12)
            let tag = "\(name) #\(i + 1)"
            for (z, y) in zip(ex.zones, w["zones"] as! [JObject]) {
                #expect(z.limiter == y["limiter"] as! String, "\(tag): \(z.zone) limiter")
                #expect(abs(z.mean_rate - (y["mean_rate"] as! Double)) < 1e-4 && abs(z.frac_target - (y["frac_target"] as! Double)) < 1e-9 && abs(z.utility - (y["utility"] as! Double)) < 1e-6, "\(tag): \(z.zone) numbers")
                if z.limiter != "access" { #expect(z.detail == y["detail"] as! String, "\(tag): \(z.zone) detail \"\(z.detail)\"") }
            }
            let contrib = w["node_contribution"] as! [[Double]]
            #expect(ex.node_contribution.count == contrib.count, "\(tag): contributions")
            for (a, b) in zip(ex.node_contribution, contrib) { #expect(a.node == Int(b[0]) && abs(a.drop - b[1]) < 1e-6, "\(tag): contribution") }
            #expect(ex.vs_runner_up == w["vs"] as! [String], "\(tag): vs runner-up")
            #expect(ex.depends_on_jacks == w["depends_on_jacks"] as! [String], "\(tag): jacks")
            if let s = ex.stability { #expect((0...1).contains(s), "\(tag): stability") }
        }
    }
}

private func boxContext(zones: [Zone]) throws -> PlanContext {
    let scenarios = try JSONSerialization.jsonObject(with: golden("plans")) as! [JObject]
    var obj = scenarios.last!["house"] as! JObject
    obj["zones"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(zones))
    let house = try House.load(JSONSerialization.data(withJSONObject: obj))
    return try PlanContext(house: house, catalogue: Catalogue.generic(), client: Catalogue.genericClients()["phone-2x2-ax"]!, params: PropParams(), step: 1.0)
}

@Test func moreNodesThanSpotsSkipsThoseCounts() throws {
    let ctx = try boxContext(zones: ctxZones())
    var cfg = PlanConfig()
    cfg.k_max = 4
    cfg.candidate_step = 3.0
    let results = try Planner.search(ctx, cfg)
    #expect(!results.isEmpty)
    #expect(results.allSatisfy { $0.extras.count <= Planner.candidates(ctx.house, step: 3.0).count })
}

@Test func anUnknownGatewayIsRefusedNotTrapped() throws {
    let ctx = try boxContext(zones: ctxZones())
    var cfg = PlanConfig()
    cfg.gateway_equipment = "no-such-router"
    #expect(throws: ImportError.self) { try Planner.search(ctx, cfg) }
}

@Test func aZeroThroughputTargetMeansUnset() throws {
    var zones = ctxZones()
    var want = zones
    for i in zones.indices where zones[i].kind == "demand" { zones[i].need = Need(min_throughput: 0, must: true); want[i].need = Need(min_throughput: nil, must: true) }
    var cfg = PlanConfig()
    cfg.k_max = 1
    cfg.candidate_step = 3.0
    let a = try Planner.search(boxContext(zones: zones), cfg), b = try Planner.search(boxContext(zones: want), cfg)
    #expect(a.count == b.count && a.allSatisfy { $0.score.isFinite })
    #expect(zip(a, b).allSatisfy { abs($0.score - $1.score) < 1e-12 })
}

private func ctxZones() -> [Zone] {
    var allow = Zone(id: "z-allow", level: "L0", polygon: [Vec2(8, 6)], kind: "allow")
    allow.requires = "none"
    var demand = Zone(id: "z-office", level: "L0", polygon: [Vec2(6, 4), Vec2(9.5, 4), Vec2(9.5, 7.5), Vec2(6, 7.5)], kind: "demand")
    demand.need = Need(min_throughput: 900, must: true)
    return [allow, demand]
}
