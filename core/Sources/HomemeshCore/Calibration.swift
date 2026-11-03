import Foundation

// Calibration from the owner's measurements (a port of homemesh/calibration.py; design section 7).
// Path loss is linear in the unknowns once the geometry is fixed:  EIRP - PL0 - RSSI = extra + n * 10 log10(d) + sum_m exposure_m * L_m.
// A regularised, robust (Huber by reweighting) linear regression with the literature values as Gaussian priors: a material the walk
// never crossed keeps its prior and is reported as not identified. Leave-one-area-out cross-validation gives the held-out RMSE the
// planner's margin uses.

public struct ParamFit: Sendable {
    public var mean: Double, sd: Double, prior_mean: Double, prior_sd: Double
    public var identified: Bool
}

public struct BandFit: Sendable {
    public var band: Band
    public var n_meas: Int
    public var n: ParamFit
    public var extra_loss: ParamFit
    public var materials: [String: ParamFit]
    public var sigma: Double
    public var rmse_train: Double
    public var rmse_cv: Double?
    public var bias_cv: Double?
    public var residuals: [String: Double]         // measurement id -> observed - predicted, dB
    public var note: String
}

public enum Calibrate {
    public static let minMeasurements = 8
    static let rxHeight = 1.0
    static let nPrior = 2.0, nPriorSd = 0.7, nBounds = (1.2, 5.0)
    static let extraPriorSd = 8.0, extraBounds = (-10.0, 40.0)
    static let areaBlock = 4.0
    static let minSigma = 2.0

    static func median(_ x: [Double]) -> Double {
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    public static func apFor(_ house: House, _ m: Measurement) -> AccessPoint? {
        if let b = m.bssid, !b.isEmpty {
            let key = b.lowercased()
            return house.access_points.first { $0.bssids.contains { $0.lowercased() == key } }
        }
        return house.access_points.count == 1 ? house.access_points[0] : nil
    }

    struct Rows {
        var used: [Measurement] = []
        var y: [Double] = [], logd: [Double] = []
        var expo: [[String: Double]] = []
        var areas: [String] = []
    }

    static func rows(_ house: House, _ model: PropagationModel, _ ms: [Measurement], _ band: Band) -> Rows {
        let elev = Dictionary(house.levels.map { ($0.id, $0.elevation) }, uniquingKeysWith: { a, _ in a })
        var r = Rows()
        for m in ms where m.band == band.rawValue {
            guard let rssi = m.rssi, let ap = apFor(house, m), let mz = elev[m.level], let az = elev[ap.level] else { continue }
            let tx = Vec3(ap.position.x, ap.position.y, az + ap.height)
            let rx = Vec3(m.position.x, m.position.y, mz + rxHeight)
            let d = max(1, ((rx.x - tx.x) * (rx.x - tx.x) + (rx.y - tx.y) * (rx.y - tx.y) + (rx.z - tx.z) * (rx.z - tx.z)).squareRoot())
            let ex = model.exposures(tx: tx, rx: [rx], band: band)
            r.used.append(m)
            r.y.append(ap.eirp_dbm - model.freeSpace1m(band) - rssi)
            r.logd.append(10 * log10(d))
            r.expo.append(ex.mapValues { $0[0] })
            r.areas.append("\(m.level)/\(Int((m.position.x / areaBlock).rounded(.down)))/\(Int((m.position.y / areaBlock).rounded(.down)))")
        }
        return r
    }

    /// MAP with a Gaussian prior, Huber reweighting, box bounds by clamping. Returns (theta, covariance, sigma).
    static func solve(_ X: [[Double]], _ y: [Double], _ mu: [Double], _ sd: [Double], _ lo: [Double], _ hi: [Double], sigma0: Double) -> (theta: [Double], cov: [[Double]], sigma: Double) {
        let p = mu.count, nobs = y.count
        var w = [Double](repeating: 1, count: nobs)
        var theta = mu
        var sigma = sigma0
        var free = [Bool](repeating: true, count: p)
        func normal(_ sigma: Double) -> ([[Double]], [Double]) {
            var A = [[Double]](repeating: [Double](repeating: 0, count: p), count: p), b = [Double](repeating: 0, count: p)
            for k in 0..<nobs { for i in 0..<p { b[i] += w[k] * X[k][i] * y[k] / (sigma * sigma); for j in 0..<p { A[i][j] += w[k] * X[k][i] * X[k][j] / (sigma * sigma) } } }
            for i in 0..<p { A[i][i] += 1 / (sd[i] * sd[i]); b[i] += mu[i] / (sd[i] * sd[i]) }
            return (A, b)
        }
        for _ in 0..<30 {
            let (A, b) = normal(sigma)
            let idx = (0..<p).filter { free[$0] }, fx = (0..<p).filter { !free[$0] }
            var new = theta
            if !idx.isEmpty {
                var sub = [Double](repeating: 0, count: idx.count * idx.count), rhs = [Double](repeating: 0, count: idx.count)
                for (a, i) in idx.enumerated() {
                    var r = b[i]
                    for j in fx { r -= A[i][j] * theta[j] }
                    rhs[a] = r
                    for (c, j) in idx.enumerated() { sub[a * idx.count + c] = A[i][j] }
                }
                if let sol = Linalg.choleskySolve(sub, rhs, n: idx.count) { for (a, i) in idx.enumerated() { new[i] = sol[a] } }
            }
            var changedFree = [Bool](repeating: false, count: p)
            for i in 0..<p {
                let c = min(max(new[i], lo[i]), hi[i])
                if c != new[i] && free[i] { changedFree[i] = true; free[i] = false; new[i] = c }
            }
            let r = (0..<nobs).map { k in y[k] - (0..<p).reduce(0.0) { $0 + X[k][$1] * new[$1] } }
            if r.count > 3 {
                let med = median(r)
                sigma = max(minSigma, 1.4826 * median(r.map { abs($0 - med) }))
            } else { sigma = max(minSigma, sigma0) }
            let k = 1.345 * sigma
            w = r.map { abs($0) <= k ? 1 : k / max(abs($0), 1e-9) }
            let close = (0..<p).allSatisfy { abs(new[$0] - theta[$0]) <= 1e-7 + 1e-5 * abs(theta[$0]) }
            if close && !changedFree.contains(true) { theta = new; break }
            theta = new
        }
        let (A, _) = normal(sigma)
        let idx = (0..<p).filter { free[$0] }
        var cov = [[Double]](repeating: [Double](repeating: 0, count: p), count: p)
        if !idx.isEmpty {
            var sub = [Double](repeating: 0, count: idx.count * idx.count)
            for (a, i) in idx.enumerated() { for (c, j) in idx.enumerated() { sub[a * idx.count + c] = A[i][j] } }
            for (c, j) in idx.enumerated() {
                var e = [Double](repeating: 0, count: idx.count); e[c] = 1
                if let col = Linalg.choleskySolve(sub, e, n: idx.count) { for (a, i) in idx.enumerated() { cov[i][j] = col[a] } }
            }
        }
        return (theta, cov, sigma)
    }

    public static func fitBand(_ house: House, _ band: Band, measurements: [Measurement]? = nil) -> BandFit? {
        let ms = measurements ?? house.measurements
        let model = PropagationModel(house)
        let r = rows(house, model, ms, band)
        if r.used.count < minMeasurements { return nil }
        let mats = Dictionary(house.materials.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let crossed = Set(r.expo.flatMap { $0.filter { $0.value > 1e-9 && mats[$0.key] != nil }.map(\.key) }).sorted()
        let X = (0..<r.y.count).map { k in [1, r.logd[k]] + crossed.map { r.expo[k][$0] ?? 0 } }
        let mu = [0, nPrior] + crossed.map { mats[$0]!.loss(band) }
        let sd = [extraPriorSd, nPriorSd] + crossed.map { max(mats[$0]!.prior_sd, 0.25) }
        let lo = [extraBounds.0, nBounds.0] + crossed.map { _ in 0.0 }, hi = [extraBounds.1, nBounds.1] + crossed.map { _ in 60.0 }
        let (theta, cov, sigma) = solve(X, r.y, mu, sd, lo, hi, sigma0: 4)
        let resid = (0..<r.y.count).map { k in r.y[k] - zip(X[k], theta).map(*).reduce(0, +) }
        let post = (0..<theta.count).map { max(cov[$0][$0], 0).squareRoot() }
        func pf(_ i: Int) -> ParamFit { ParamFit(mean: theta[i], sd: post[i], prior_mean: mu[i], prior_sd: sd[i], identified: post[i] < 0.8 * sd[i]) }
        var fits: [String: ParamFit] = [:]
        for (i, k) in crossed.enumerated() { fits[k] = pf(2 + i) }
        for (k, m) in mats where fits[k] == nil { fits[k] = ParamFit(mean: m.loss(band), sd: m.prior_sd, prior_mean: m.loss(band), prior_sd: m.prior_sd, identified: false) }

        // leave one area out
        let groups = Array(Set(r.areas)).sorted()
        var cv: [Double] = []
        if groups.count >= 3 {
            for g in groups {
                let test = r.areas.map { $0 == g }
                let train = (0..<test.count).filter { !test[$0] }
                if test.allSatisfy({ $0 }) || train.count < minMeasurements / 2 { continue }
                let th = solve(train.map { X[$0] }, train.map { r.y[$0] }, mu, sd, lo, hi, sigma0: 4).theta
                for k in 0..<test.count where test[k] { cv.append(r.y[k] - zip(X[k], th).map(*).reduce(0, +)) }
            }
        }
        let note = cv.isEmpty ? "too few separate areas for cross-validation: the margin stays at its default" : ""
        var residuals: [String: Double] = [:]
        for (m, e) in zip(r.used, resid) { residuals[m.id] = -e }
        return BandFit(band: band, n_meas: r.y.count, n: pf(1), extra_loss: pf(0), materials: fits, sigma: sigma,
                       rmse_train: (resid.map { $0 * $0 }.reduce(0, +) / Double(resid.count)).squareRoot(),
                       rmse_cv: cv.isEmpty ? nil : (cv.map { $0 * $0 }.reduce(0, +) / Double(cv.count)).squareRoot(),
                       bias_cv: cv.isEmpty ? nil : -(cv.reduce(0, +) / Double(cv.count)), residuals: residuals, note: note)
    }

    public static func fit(_ house: House) -> [Band: BandFit] {
        var out: [Band: BandFit] = [:]
        for b in Band.allCases { if let f = fitBand(house, b) { out[b] = f } }
        return out
    }

    /// A copy of the house with the fitted materials and parameters (the owner accepts or discards it).
    public static func apply(_ house: House, _ fits: [Band: BandFit], now: String? = nil) -> House {
        var h = house
        var cal = house.calibration ?? Calibration()
        for band in Band.allCases {   // in band order, as Python's dict does: a later band's prior spread wins
            guard let f = fits[band] else { continue }
            let key = band.rawValue
            cal.n[key] = f.n.mean; cal.extra_loss_db[key] = f.extra_loss.mean; cal.rmse_cv[key] = .some(f.rmse_cv); cal.n_measurements[key] = f.n_meas
            for (mid, p) in f.materials where p.identified {
                guard let i = h.materials.firstIndex(where: { $0.id == mid }) else { continue }
                h.materials[i].loss[key] = p.mean
                h.materials[i].prior_sd = max(0.5, p.sd)
                h.materials[i].source = "calibrated from the owner's measurements"
            }
        }
        cal.at = now
        h.calibration = cal
        return h
    }

    public static func paramsFor(_ house: House) -> PropParams {
        var p = PropParams()
        guard let c = house.calibration else { return p }
        for (k, v) in c.n { if let b = Band(rawValue: k) { p.n[b] = v } }
        for (k, v) in c.extra_loss_db { if let b = Band(rawValue: k) { p.extraLoss[b] = v } }
        return p
    }

    /// The planner's shadowing margin: the held-out error when calibrated (3 to 10 dB), else the default.
    public static func marginFor(_ house: House, default d: Double = 6) -> Double {
        if let c = house.calibration {
            let errs = c.rmse_cv.values.compactMap { $0 }
            if let m = errs.max() { return min(10, max(3, m)) }
        }
        return d
    }

    public struct Suggestion: Sendable { public var material: String, level: String; public var x: Double, y: Double, units: Double }

    /// Where to measure next: cells of heavy exposure to materials the walk has not pinned down.
    public static func suggest(_ house: House, _ band: Band, k: Int = 5, step: Double = 1.0) -> [Suggestion] {
        guard let ap = house.access_points.first, let client = Catalogue.genericClients().values.sorted(by: { $0.id < $1.id }).first ?? nil else { return [] }
        let f = fitBand(house, band)
        let unidentified = f.map { $0.materials.filter { !$0.value.identified }.map(\.key).sorted() } ?? house.materials.map(\.id)
        if unidentified.isEmpty { return [] }
        guard let ctx = try? PlanContext(house: house, catalogue: Catalogue.generic(), client: Catalogue.genericClientList()[0], step: step, rxHeight: rxHeight) else { return [] }
        _ = client
        let tx = Vec3(ap.position.x, ap.position.y, (ctx.elevation[ap.level] ?? 0) + ap.height)
        let ex = ctx.model.exposures(tx: tx, rx: ctx.cells, band: band)
        let have = house.measurements.filter { $0.band == band.rawValue }.map { $0.position }
        var out: [Suggestion] = []
        for mid in unidentified {
            guard var e = ex[mid], e.contains(where: { $0 > 0 }) else { continue }
            for i in e.indices where !ctx.cellOk[i] { e[i] = 0 }
            let order = e.indices.sorted { e[$0] != e[$1] ? e[$0] > e[$1] : $0 < $1 }.prefix(200)
            for i in order {
                if e[i] <= 0 { break }
                let x = ctx.cells[i].x, y = ctx.cells[i].y
                let spots = out.map { Vec2($0.x, $0.y) } + have
                if spots.allSatisfy({ hypot(x - $0.x, y - $0.y) >= 3.0 }) {
                    out.append(Suggestion(material: mid, level: ctx.grids[ctx.cellLevel[i]].level, x: x, y: y, units: e[i]))
                    break
                }
            }
            if out.count >= k { break }
        }
        return out
    }
}
