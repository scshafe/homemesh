import Foundation
import Testing
@testable import HomemeshCore

@Test func calibrationMatchesThePythonOracle() throws {
    let scenarios = try JSONSerialization.jsonObject(with: golden("calibrations")) as! [JObject]
    for sc in scenarios {
        let name = sc["name"] as! String
        let house = try House.load(JSONSerialization.data(withJSONObject: sc["house"]!))
        let fits = Calibrate.fit(house)
        let want = sc["fits"] as! [String: JObject]
        #expect(Set(fits.keys.map(\.rawValue)) == Set(want.keys), "\(name): bands fitted")
        for (b, w) in want {
            let f = fits[Band(rawValue: b)!]!
            let tag = "\(name) \(b) GHz"
            #expect(f.n_meas == w["n_meas"] as! Int, "\(tag): n_meas")
            func close(_ p: ParamFit, _ q: JObject, _ what: String) {
                #expect(abs(p.mean - (q["mean"] as! Double)) < 1e-5, "\(tag): \(what) mean \(p.mean) vs \(q["mean"]!)")
                #expect(abs(p.sd - (q["sd"] as! Double)) < 1e-5, "\(tag): \(what) sd")
                #expect(p.identified == q["identified"] as! Bool, "\(tag): \(what) identified")
            }
            close(f.n, obj(w["n"]), "n"); close(f.extra_loss, obj(w["extra_loss"]), "extra loss")
            for (k, q) in obj(w["materials"]) { close(f.materials[k]!, obj(q), k) }
            #expect(abs(f.sigma - (w["sigma"] as! Double)) < 1e-6, "\(tag): sigma")
            #expect(abs(f.rmse_train - (w["rmse_train"] as! Double)) < 1e-6, "\(tag): rmse_train")
            #expect(abs((f.rmse_cv ?? -1) - ((w["rmse_cv"] as? Double) ?? -1)) < 1e-6, "\(tag): rmse_cv")
            #expect(abs((f.bias_cv ?? -1) - ((w["bias_cv"] as? Double) ?? -1)) < 1e-6, "\(tag): bias_cv")
            for (id, r) in obj(w["residuals"]) { #expect(abs(f.residuals[id]! - (r as! Double)) < 1e-5, "\(tag): residual \(id)") }
        }
        if let materials = sc["applied_materials"] as? [JObject] {
            let applied = Calibrate.apply(house, fits)
            for (m, w) in zip(applied.materials, materials) {
                for (band, v) in obj(w["loss"]) { #expect(abs(m.loss[band]! - (v as! Double)) < 1e-5, "\(name): applied \(m.id) \(band)") }
                #expect(abs(m.prior_sd - (w["prior_sd"] as! Double)) < 1e-5 && m.source == w["source"] as! String, "\(name): applied \(m.id) prior and source")
            }
            #expect(abs(Calibrate.marginFor(applied) - (sc["margin"] as! Double)) < 1e-6, "\(name): margin")
            let p = Calibrate.paramsFor(applied), wp = obj(sc["params"])
            for (b, v) in obj(wp["n"]) { #expect(abs(p.n[Band(rawValue: b)!]! - (v as! Double)) < 1e-5, "\(name): params n \(b)") }
        } else {
            #expect(Calibrate.marginFor(house) == sc["margin"] as! Double, "\(name): default margin")
        }
    }
}
