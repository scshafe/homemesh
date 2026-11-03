import Foundation
import Testing
@testable import HomemeshCore

/// The first difference between two JSON values (numbers within `tol`), or nil when they match; nulls and underlays are ignored.
func firstDifference(_ a: Any, _ b: Any, tol: Double, path: String = "$") -> String? {
    if let x = a as? [String: Any], let y = b as? [String: Any] {
        let kx = Set(x.filter { !($0.value is NSNull) && $0.key != "underlays" }.keys), ky = Set(y.filter { !($0.value is NSNull) && $0.key != "underlays" }.keys)
        if kx != ky { return "\(path): keys differ: only swift \(kx.subtracting(ky).sorted()), only python \(ky.subtracting(kx).sorted())" }
        for k in kx.sorted() { if let d = firstDifference(x[k]!, y[k]!, tol: tol, path: "\(path).\(k)") { return d } }
        return nil
    }
    if let x = a as? [Any], let y = b as? [Any] {
        if x.count != y.count { return "\(path): \(x.count) items, python has \(y.count)" }
        for (i, (p, q)) in zip(x, y).enumerated() { if let d = firstDifference(p, q, tol: tol, path: "\(path)[\(i)]") { return d } }
        return nil
    }
    if let x = a as? NSNumber, let y = b as? NSNumber, type(of: a) != Bool.self || type(of: b) != Bool.self {
        return abs(x.doubleValue - y.doubleValue) <= tol ? nil : "\(path): \(x) vs python \(y)"
    }
    if let x = a as? Bool, let y = b as? Bool { return x == y ? nil : "\(path): \(x) vs python \(y)" }
    if let x = a as? String, let y = b as? String { return x == y ? nil : "\(path): \"\(x)\" vs python \"\(y)\"" }
    return "\(path): different kinds (\(type(of: a)) vs \(type(of: b)))"
}

func obj(_ v: Any?) -> JObject { v as! JObject }

@Test func importsMatchThePythonOracle() throws {
    let scenarios = try JSONSerialization.jsonObject(with: golden("imports")) as! [JObject]
    #expect(scenarios.count >= 15)
    for sc in scenarios {
        let name = sc["name"] as! String
        var house = try House.load(JSONSerialization.data(withJSONObject: sc["house"]!))
        for (n, st) in (sc["steps"] as! [JObject]).enumerated() {
            let data = obj(st["data"]), blob = st["blob"] as! String
            var report: ImportReport?
            switch st["op"] as! String {
            case "import":
                var o = ImportOptions()
                if let t = st["transform"] as? JObject { o.transform = Similarity2D(scale: t["scale"] as! Double, rotation: t["rotation"] as! Double, tx: t["tx"] as! Double, ty: t["ty"] as! Double) }
                o.names = st["names"] as? [String]
                o.descriptions = st["descriptions"] as? [String]
                o.roomLevels = (st["room_levels"] as? [Any])?.map { $0 as? String }
                (house, report) = try ScanImport.importCapture(house: house, data: data, level: st["level"] as! String, blob: blob, options: o)
            case "apply_stair":
                var notes: [String] = []
                let found = try ScanImport.stairFootprints(data)
                house = try ScanImport.applyStair(house, data: data, blob: blob, meta: obj(st["meta"]), sim: nil, found: found, notes: &notes)
                #expect(notes == (st["notes"] as! [String]), "\(name) step \(n): notes")
            case "retire":
                let (h, gone) = try ScanImport.retireRoom(house, data: data, blob: blob, index: st["index"] as! Int)
                house = h
                #expect(gone == st["gone"] as! Int, "\(name) step \(n): walls removed")
            default: Issue.record("unknown step")
            }
            let got = try JSONSerialization.jsonObject(with: house.encoded())
            if let d = firstDifference(got, st["expect"]!, tol: 2e-4) { Issue.record("\(name), step \(n): \(d)") }
            if let report, let want = st["report"] as? JObject {
                let counts: [(String, Int)] = [("walls", report.walls), ("paired_walls", report.paired_walls), ("openings", report.openings), ("skipped_openings", report.skipped_openings),
                                               ("rooms", report.rooms), ("replaced", report.replaced), ("curved_walls", report.curved_walls), ("profile_walls", report.profile_walls),
                                               ("folded_jogs", report.folded_jogs), ("furniture", report.furniture)]
                for (k, v) in counts { #expect(v == want[k] as! Int, "\(name): report.\(k)") }
                #expect(report.notes == (want["notes"] as! [String]), "\(name): notes")
                let stairs = want["stairs"] as! [JObject]
                #expect(report.stairs.count == stairs.count, "\(name): stairs")
            }
        }
    }
}
