import SwiftUI

/// `POST /api/houses/<id>/calibrate` (homemesh/calibration.py): what the measurements say about the walls.
struct ParamFitDTO: Decodable, Hashable, Sendable {
    let mean: Double
    let sd: Double
    let prior_mean: Double
    let prior_sd: Double
    let identified: Bool
}

struct BandFitDTO: Decodable, Hashable, Sendable {
    let band: String
    let n_meas: Int
    let n: ParamFitDTO
    let extra_loss: ParamFitDTO
    let materials: [String: ParamFitDTO]
    let sigma: Double
    let rmse_train: Double
    let rmse_cv: Double?
    let bias_cv: Double?
    let residuals: [String: Double]
    let note: String
}

struct SuggestedSpot: Decodable, Hashable, Sendable {
    let material: String
    let level: String
    let x: Double
    let y: Double
}

struct FitResponse: Decodable, Sendable {
    let fits: [String: BandFitDTO]
    let suggestions: [String: [SuggestedSpot]]
    let access_points: Int
    let measurements: Int
}

enum Margin {
    /// The planner's shadowing margin: the worst held-out error clamped to 3...10 dB, else the 6 dB default (calibration.margin_for).
    static func db(_ cv: [Double?]) -> Double {
        let errs = cv.compactMap { $0 }
        return errs.isEmpty ? 6 : min(10, max(3, errs.max()!))
    }
}

extension Client {
    func calibrate(house: String) -> FitCall { FitCall(client: self, house: house) }
}

struct FitCall {
    let client: Client
    let house: String

    /// The fit, and the house with it applied (as raw JSON, ready to be saved).
    func run() async throws -> (fit: FitResponse, applied: Data?) {
        let data = try await client.call("POST", "/api/houses/\(house)/calibrate", body: Data(), timeout: 120)
        let fit = try JSONDecoder().decode(FitResponse.self, from: data)
        var applied: Data?
        if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let h = obj["calibrated"], JSONSerialization.isValidJSONObject(h) {
            applied = try JSONSerialization.data(withJSONObject: h)
        }
        return (fit, applied)
    }
}

/// Calibrate the model to the owner's measurements: walk with the existing access point, measure, fit, check, apply.
struct CalibrateView: View {
    let houseId: String
    @EnvironmentObject var model: AppModel
    @State private var plan: PlanHouse?
    @State private var level = ""
    @State private var fit: FitResponse?
    @State private var applied: Data?
    @State private var revision = 0
    @State private var busy = false
    @State private var status = ""

    private var perBand: [(String, Int)] {
        Dictionary(grouping: (plan?.measurements ?? []).filter { $0.rssi != nil }, by: \.band).map { ($0.key, $0.value.count) }.sorted { $0.0 < $1.0 }
    }

    var body: some View {
        List {
            Section("What you have") {
                Text("\(plan?.access_points.count ?? 0) access point(s) on the plan, \(plan?.measurements.count ?? 0) measurement(s).").font(.footnote)
                ForEach(perBand, id: \.0) { Text("\($0.0) GHz: \($0.1) reading(s)").font(.footnote) }
                if (plan?.access_points.isEmpty ?? true) { Text("Put your existing access point on the plan first (the Access point tool), then walk the house and use the Measure tool: tap where you stand and type the signal you read.").font(.footnote).foregroundStyle(.orange) }
                else if perBand.allSatisfy({ $0.1 < 8 }) { Text("Take at least 8 readings per band, in different rooms and behind different walls.").font(.footnote).foregroundStyle(.orange) }
            }
            if let plan, !plan.levels.isEmpty {
                Section {
                    Picker("Floor", selection: $level) { ForEach(plan.levels, id: \.id) { Text($0.name).tag($0.id) } }.pickerStyle(.segmented)
                    PlanCanvas(walls: plan.walls.filter { $0.level == level }, rooms: plan.rooms.filter { $0.level == level },
                               bounds: Geometry.bounds(plan.walls.filter { $0.level == level }.flatMap { [$0.a, $0.b] }),
                               markers: markers(plan))
                        .frame(height: 260)
                    Text("Pink: your readings. Dashed purple: good places to measure next.").font(.footnote)
                }
            }
            Section("Fit") {
                Button(busy ? "Fitting…" : "Fit the model to my readings") { Task { await run() } }.disabled(busy)
                if let fit {
                    if fit.fits.isEmpty { Text("Not enough readings yet to fit any band.").font(.footnote) }
                    ForEach(fit.fits.keys.sorted(), id: \.self) { band in
                        if let f = fit.fits[band] { bandBlock(band, f) }
                    }
                }
            }
            if let fit, !fit.fits.isEmpty {
                Section("Planning margin") {
                    let before = Margin.db(calibratedCV())
                    let after = Margin.db(fit.fits.values.map(\.rmse_cv))
                    Text(String(format: "Now %.0f dB, after applying %.0f dB (the planner keeps this much spare signal).", before, after)).font(.footnote)
                    Button("Apply to the house") { Task { await apply() } }.disabled(applied == nil || busy)
                }
            }
            if !status.isEmpty { Section { Text(status).font(.footnote) } }
        }
        .navigationTitle("Calibrate")
        .task { await load() }
    }

    private func bandBlock(_ band: String, _ f: BandFitDTO) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(band) GHz: \(f.n_meas) readings").bold()
            Text(String(format: "Typical error on readings it has not seen: %@", f.rmse_cv.map { String(format: "%.1f dB", $0) } ?? "not known (too few separate areas)"))
                .font(.footnote)
            Text(String(format: "Fits its own readings to %.1f dB. Distance exponent %.2f (was %.2f).", f.rmse_train, f.n.mean, f.n.prior_mean)).font(.footnote)
            let found = f.materials.filter { $0.value.identified }.sorted { $0.key < $1.key }
            if found.isEmpty { Text("No wall material is pinned down yet: measure on both sides of more walls.").font(.footnote).foregroundStyle(.orange) }
            ForEach(found, id: \.key) { k, p in
                Text(String(format: "%@: %.1f dB (was %.1f)", k, p.mean, p.prior_mean)).font(.footnote)
            }
            let worst = f.residuals.sorted { abs($0.value) > abs($1.value) }.prefix(3).filter { abs($0.value) > 6 }
            ForEach(Array(worst), id: \.key) { Text("Reading \($0.key) is \(String(format: "%+.0f", $0.value)) dB off: check it.").font(.footnote).foregroundStyle(.orange) }
            if !f.note.isEmpty { Text(f.note).font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private func markers(_ plan: PlanHouse) -> [PlanMarker] {
        var out: [PlanMarker] = []
        for m in plan.measurements where m.level == level { out.append(PlanMarker(id: m.id, kind: .measurement, at: m.position)) }
        for a in plan.access_points where a.level == level { out.append(PlanMarker(id: a.id, kind: .accessPoint, at: a.position)) }
        var n = 0
        for spots in (fit?.suggestions ?? [:]).values {
            for s in spots where s.level == level { out.append(PlanMarker(id: "s\(n)", kind: .suggestion, at: Pt(s.x, s.y))); n += 1 }
        }
        return out
    }

    /// The held-out errors already applied to the house, if it was calibrated before.
    private func calibratedCV() -> [Double?] { plan?.calibration.map { Array($0.rmse_cv.values) } ?? [] }

    private func load() async {
        do {
            let data = try await model.client().call("GET", "/api/houses/\(houseId)")
            let p = try JSONDecoder().decode(PlanHouse.self, from: data)
            plan = p
            revision = p.revision
            if level.isEmpty { level = p.levels.first?.id ?? "" }
        } catch {
            status = "Could not load: \(error.localizedDescription)"
        }
    }

    private func run() async {
        busy = true
        defer { busy = false }
        status = ""
        do {
            let r = try await model.client().calibrate(house: houseId).run()
            fit = r.fit
            applied = r.applied
        } catch {
            status = "Could not fit: \(error.localizedDescription)"
        }
    }

    private func apply() async {
        guard let applied else { return }
        busy = true
        defer { busy = false }
        do {
            try await model.client().saveHouse(house: houseId, json: applied, expectRevision: revision)
            status = "Applied: the walls' losses and the planning margin now follow your readings. Plans you run from now on use them."
            self.applied = nil
            await load()
        } catch {
            status = "Could not apply: \(error.localizedDescription)"
        }
    }
}
