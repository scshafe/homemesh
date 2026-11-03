import Foundation
import Testing
@testable import HomemeshCore

@Test func placementMatchesThePythonOracle() throws {
    let root = try JSONSerialization.jsonObject(with: golden("places")) as! JObject
    let scenarios = root["scenarios"] as! [JObject]
    #expect(scenarios.count == 8)
    for sc in scenarios {
        let name = sc["name"] as! String
        let house = try House.load(JSONSerialization.data(withJSONObject: sc["house"]!))
        let want = obj(sc["expect"])
        let p = try Placement.propose(house: house, data: obj(sc["scan"]), level: sc["level"] as! String, blob: sc["blob"] as! String,
                                      names: sc["names"] as? [String], doorLabels: sc["door_labels"] as! [String: String], planLabels: sc["plan_labels"] as! [String: String])
        #expect(p.confidence.rawValue == want["confidence"] as! String, "\(name): confidence")
        let t = obj(want["transform"])
        #expect(abs(p.transform.rotation - (t["rotation"] as! Double)) < 0.01, "\(name): rotation \(p.transform.rotation) vs \(t["rotation"]!)")
        #expect(abs(p.transform.tx - (t["tx"] as! Double)) < 0.001, "\(name): tx")
        #expect(abs(p.transform.ty - (t["ty"] as! Double)) < 0.001, "\(name): ty")
        let ev = obj(want["evidence"])
        if let m = ev["missing"] as? [String] { #expect(p.evidence.missing == m, "\(name): missing \(p.evidence.missing)") }
        if let c = ev["connections"] as? Int { #expect(p.evidence.connections == c, "\(name): connections") }
        if let r = ev["residual_cm"] as? Double { #expect(abs(p.evidence.residualCm - r) < 0.2, "\(name): residual") }
        if let s = ev["stairs"] as? Int { #expect(p.evidence.stairs == s, "\(name): stairs") }
        #expect(p.preview.count == (want["preview"] as! [Any]).count, "\(name): preview")
        #expect(p.reason == want["reason"] as! String, "\(name): reason \"\(p.reason)\"")
    }
}

@Test func checklistMatchesThePythonOracle() throws {
    let root = try JSONSerialization.jsonObject(with: golden("places")) as! JObject
    let c = obj(root["checklist"])
    let metas = (c["metas"] as! [JObject]).map { m in
        CaptureInfo(blob: m["blob"] as! String, name: m["name"] as! String, level: m["level"] as? String, at: m["at"] as! Double, rooms: m["rooms"] as! [String],
                    doors: (m["doors"] as! [JObject]).map { DoorEntry(id: $0["id"] as! String, room: $0["room"] as! Int, number: $0["number"] as! Int) },
                    doorLabels: m["door_labels"] as? [String: String] ?? [:], purpose: m["purpose"] as? String, replaces: m["replaces"] as? String)
    }
    let got = Connections.checklist(metas)
    let want = c["expect"] as! [JObject]
    #expect(got.count == want.count)
    for (g, w) in zip(got, want) {
        #expect(g.capture == w["capture"] as! String)
        #expect(g.issues == w["issues"] as! [String])
        #expect(g.complete == w["complete"] as! Bool)
        #expect(g.doors.map(\.status.rawValue) == (w["doors"] as! [JObject]).map { $0["status"] as! String })
    }
}
