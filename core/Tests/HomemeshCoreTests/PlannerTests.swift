import Foundation
import Testing
@testable import HomemeshCore

@Test func plannerMatchesThePythonOracle() throws {
    let scenarios = try JSONSerialization.jsonObject(with: golden("plans")) as! [JObject]
    #expect(scenarios.count == 3)
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
