import Foundation

// The planning routes of the in-process API: plan jobs (a worker task, polled for progress), rate maps, calibration.

final class PlanJob: @unchecked Sendable {
    let id: String
    let house: String
    var state = "running"                 // running | done | error
    var progress: [String] = []
    var error: String?
    var result: Any?
    var task: Task<Void, Never>?
    init(id: String, house: String) { self.id = id; self.house = house }
}

extension LocalAPI {
    static let explainTop = 5

    func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }

    func makeConfig(_ req: JObject, _ h: House) -> PlanConfig {
        var cfg = PlanConfig()
        cfg.gateway_equipment = req["gateway_equipment"] as? String ?? "generic-router-ax"
        cfg.equipment = req["equipment"] as? [String] ?? []
        cfg.k_max = Int(min(max((req["k_max"] as? NSNumber)?.doubleValue ?? 5, 0), 8))
        cfg.price_ceiling = (req["price_ceiling"] as? NSNumber)?.doubleValue
        cfg.policy = Policy(margin_db: Calibrate.marginFor(h), trust_unknown_jacks: (req["trust_unknown_jacks"] as? Bool) ?? false)
        cfg.candidate_step = clamp((req["candidate_step"] as? NSNumber)?.doubleValue ?? 1.0, 0.25, 3.0)
        return cfg
    }

    func makeContext(_ h: House, _ req: JObject) throws -> PlanContext {
        guard let client = Catalogue.genericClients()[req["client"] as? String ?? "phone-2x2-ax"] else { throw APIError(422, "unknown client") }
        let step = clamp((req["grid"] as? NSNumber)?.doubleValue ?? 1.0, 0.25, 2.0)
        return try PlanContext(house: h, catalogue: Catalogue.generic(), client: client, params: Calibrate.paramsFor(h), step: step)
    }

    static func serialise(_ sc: Scored) -> JObject {
        let ev = sc.evaluation
        return ["equipment": sc.equipment, "k": sc.k, "score": sc.score, "score_margin": sc.score_margin, "worst": sc.worst, "cost": sc.cost, "valid": sc.valid, "must_ok": sc.must_ok, "stable": sc.stable,
                "nodes": sc.extras.map { ["equipment": $0.equipment, "position": [$0.position.x, $0.position.y], "level": $0.level, "height": $0.height] as JObject },
                "zones": sc.zones.map { ["zone": $0.zone, "utility": $0.utility, "utility_margin": $0.utility_margin, "mean_rate": $0.mean_rate, "frac_target": $0.frac_target, "must_met": $0.must_met as Any? ?? NSNull()] as JObject },
                "backhaul": (ev?.nodes ?? []).map { ["index": $0.index, "kind": $0.kind, "parent": $0.parent as Any? ?? NSNull(), "mbps": $0.backhaul_mbps == .infinity ? NSNull() : $0.backhaul_mbps as Any,
                                                    "hops": $0.hops, "jack": $0.jack as Any? ?? NSNull(), "band": $0.link_band?.rawValue as Any? ?? NSNull(), "shared": $0.shared_radio] as JObject },
                "problems": ev?.problems ?? [], "jacks_used": ev?.jacksUsed ?? [], "jacks_unverified": ev?.jacksUnverified ?? []]
    }

    func startPlan(_ id: String, _ req: JObject) throws -> Any {
        let (_, h) = try get(id)
        if h.entry == nil { throw APIError(422, "mark the internet entry first") }
        if !h.zones.contains(where: { $0.kind == "allow" }) { throw APIError(422, "mark at least one allow zone first") }
        if !h.zones.contains(where: { $0.kind == "demand" }) { throw APIError(422, "mark at least one demand zone first") }
        let cfg = makeConfig(req, h)
        let cat = Catalogue.generic()
        for name in [cfg.gateway_equipment] + cfg.equipment where cat[name] == nil { throw APIError(422, "unknown equipment \(name)") }
        let ctx = try makeContext(h, req)
        let job = PlanJob(id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)), house: id)
        jobsLock.withLock { jobs[job.id] = job }
        let client = req["client"] as? String ?? "phone-2x2-ax"
        job.task = Task.detached(priority: .userInitiated) { [self] in
            do {
                let results = try Planner.search(ctx, cfg, progress: { m in jobsLock.withLock { job.progress.append(m) } }, cancelled: { Task.isCancelled })
                let front = Planner.pareto(results)
                let entry = h.entry!
                let gw = NodePlacement(equipment: cfg.gateway_equipment, position: entry.position, level: entry.level, height: cfg.gateway_height)
                var out: [Any] = []
                for (i, sc) in results.prefix(20).enumerated() {
                    var d = Self.serialise(sc)
                    d["pareto"] = front.contains { $0.equipment == sc.equipment && $0.extras == sc.extras }
                    if i < Self.explainTop && i + 1 < results.count {
                        jobsLock.withLock { job.progress.append("explaining #\(i + 1)") }
                        let ex = try Explain.explain(ctx, gateway: gw, best: sc, runnerUp: results[i + 1], cfg: cfg, samples: 12)
                        d["explanation"] = ["lines": ex.lines, "stability": ex.stability as Any? ?? NSNull(), "node_contribution": ex.node_contribution.map { [$0.node, $0.drop] as [Any] },
                                            "zones": ex.zones.map { ["zone": $0.zone, "limiter": $0.limiter, "detail": $0.detail] as JObject }] as JObject
                    }
                    out.append(d)
                }
                let result: JObject = ["gateway": ["equipment": gw.equipment, "position": [gw.position.x, gw.position.y], "level": gw.level, "height": gw.height] as JObject,
                                       "config": ["k_max": cfg.k_max, "equipment": cfg.equipment, "client": client, "trust_unknown_jacks": cfg.policy.trust_unknown_jacks] as JObject, "results": out]
                jobsLock.withLock { job.result = result; job.state = "done" }
            } catch is PlanCancelled {
                jobsLock.withLock { job.error = "cancelled"; job.state = "error" }
            } catch {
                jobsLock.withLock { job.error = "\(type(of: error)): \(error)"; job.state = "error" }
            }
        }
        return ["job": job.id]
    }

    func jobStatus(_ jobId: String) throws -> Any {
        jobsLock.lock(); defer { jobsLock.unlock() }
        guard let j = jobs[jobId] else { throw APIError(404, "no such job") }
        return ["state": j.state, "progress": Array(j.progress.suffix(20)), "error": j.error as Any? ?? NSNull(), "result": j.result as Any? ?? NSNull()] as JObject
    }

    public func cancelJob(_ jobId: String) { jobsLock.withLock { jobs[jobId]?.task?.cancel() } }

    func rateMap(_ id: String, _ req: JObject) throws -> Any {
        let (_, h) = try get(id)
        guard let entry = h.entry else { throw APIError(422, "the house has no internet entry") }
        let cat = Catalogue.generic()
        let ctx = try makeContext(h, req)
        let cfg = makeConfig(req, h)
        let gw = NodePlacement(equipment: cfg.gateway_equipment, position: entry.position, level: entry.level, height: cfg.gateway_height)
        var extras: [NodePlacement] = []
        for n in req["nodes"] as? [JObject] ?? [] {
            guard let eq = n["equipment"] as? String, cat[eq] != nil, let lv = n["level"] as? String, ctx.elevation[lv] != nil, let pos = n["position"] as? [Double], pos.count == 2, let hgt = (n["height"] as? NSNumber)?.doubleValue else { throw APIError(422, "bad node") }
            extras.append(NodePlacement(equipment: eq, position: Vec2(pos[0], pos[1]), level: lv, height: hgt))
        }
        let ev = Backhaul.evaluate(ctx, gateway: gw, extras: extras, policy: cfg.policy)
        var grids: [Any] = []
        for (gi, g) in ctx.grids.enumerated() {
            let idx = (0..<ctx.cells.count).filter { ctx.cellLevel[$0] == gi }
            grids.append(["level": g.level, "x0": g.x0, "y0": g.y0, "step": g.step, "nx": g.nx, "ny": g.ny,
                          "rate": idx.map { ctx.cellOk[$0] ? Double(Float(ev.rate[$0])) as Any : NSNull() }, "serving": idx.map { ev.serving[$0] }] as JObject)
        }
        return ["grids": grids, "problems": ev.problems] as JObject
    }

    static func paramFit(_ p: ParamFit) -> JObject { ["mean": p.mean, "sd": p.sd, "prior_mean": p.prior_mean, "prior_sd": p.prior_sd, "identified": p.identified] }

    func calibrate(_ id: String, _ raw: Data) throws -> Any {
        if raw.count > Self.maxBody { throw APIError(413, "house too large") }
        var h: House
        if !raw.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) {
            do { h = try House.load(lenient: raw) } catch { throw APIError(422, "the house does not read: \(error)") }
            if h.id != id { throw APIError(422, "id does not match the URL") }
            if !h.validate().isEmpty { throw APIError(422, "invalid house") }
        } else { h = try get(id).1 }
        let fits = Calibrate.fit(h)
        var out: JObject = [:], sug: JObject = [:]
        for b in Band.allCases {
            guard let f = fits[b] else { continue }
            out[b.rawValue] = ["band": b.rawValue, "n_meas": f.n_meas, "n": Self.paramFit(f.n), "extra_loss": Self.paramFit(f.extra_loss), "materials": f.materials.mapValues(Self.paramFit),
                               "sigma": f.sigma, "rmse_train": f.rmse_train, "rmse_cv": f.rmse_cv as Any? ?? NSNull(), "bias_cv": f.bias_cv as Any? ?? NSNull(), "residuals": f.residuals, "note": f.note] as JObject
            sug[b.rawValue] = Calibrate.suggest(h, b).map { ["material": $0.material, "level": $0.level, "x": $0.x, "y": $0.y, "units": $0.units] as JObject }
        }
        return ["fits": out, "suggestions": fits.isEmpty ? JObject() : sug, "calibrated": fits.isEmpty ? NSNull() : try houseJSON(Calibrate.apply(h, fits)),
                "access_points": h.access_points.count, "measurements": h.measurements.count] as JObject
    }
}
