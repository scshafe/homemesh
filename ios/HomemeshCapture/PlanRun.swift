import SwiftUI

/// `GET /api/jobs/<id>` and the plan result (homemesh/jobs.py `serialise`). Fields the server may leave null are optional.
struct JobState: Decodable, Sendable {
    let state: String               // running, done, error
    let progress: [String]
    let error: String?
    let result: PlanResult?
}

struct PlanResult: Decodable, Sendable {
    struct Gateway: Decodable, Sendable {
        let equipment: String
        let level: String
        let position: [Double]
    }
    let gateway: Gateway
    let results: [Arrangement]
}

struct PlacedNode: Codable, Hashable, Sendable {
    let equipment: String
    let position: [Double]
    let level: String
    let height: Double
}

struct ZoneResult: Decodable, Hashable, Sendable {
    let zone: String
    let utility: Double
    let mean_rate: Double?
    let frac_target: Double?
    let must_met: Bool?
}

struct BackhaulLink: Decodable, Hashable, Sendable {
    let index: Int
    let kind: String                // wired or wireless
    let parent: Int?
    let mbps: Double?
    let hops: Int?
    let band: String?
}

struct ZoneLimit: Decodable, Hashable, Sendable {
    let zone: String
    let limiter: String
    let detail: String
}

struct Explanation: Decodable, Hashable, Sendable {
    let lines: [String]
    let stability: String?
    let zones: [ZoneLimit]
}

/// One ranked arrangement of extra nodes.
struct Arrangement: Decodable, Hashable, Identifiable, Sendable {
    let equipment: String
    let k: Int
    let score: Double
    let worst: Double?
    let cost: Double?
    let valid: Bool
    let must_ok: Bool?
    let stable: Bool?
    let nodes: [PlacedNode]
    let zones: [ZoneResult]
    let backhaul: [BackhaulLink]
    let problems: [String]
    let pareto: Bool?
    let explanation: Explanation?
    var id: String { "\(equipment)|\(k)|" + nodes.map { "\($0.level):\($0.position.map { String(format: "%.2f", $0) }.joined(separator: ","))" }.joined(separator: ";") }

    var title: String { k == 0 ? "No extra nodes" : "\(k) × \(equipment)" }
}

struct PlanRequest: Encodable, Sendable {
    let equipment: [String]
    let gateway_equipment: String
    let client: String
    let k_max: Int
}

struct JobStarted: Decodable, Sendable { let job: String }

extension Client {
    func startPlan(house: String, _ req: PlanRequest) async throws -> String {
        let r: JobStarted = try await send("POST", "/api/houses/\(house)/plans", req)
        return r.job
    }

    func job(_ id: String) async throws -> JobState { try await get("/api/jobs/\(id)") }
}

/// Start a plan with the shortlist, watch it run, and read the ranked arrangements.
struct PlanRunView: View {
    let houseId: String
    @EnvironmentObject var model: AppModel
    @State private var plan: PlanHouse?
    @State private var catalogue: CatalogueData?
    @State private var list = Shortlist()
    @State private var running = false
    @State private var progress: [String] = []
    @State private var result: PlanResult?
    @State private var status = ""
    @State private var picks: [String] = []          // ids of the two arrangements chosen to compare

    private var problems: [String] {
        guard let plan else { return ["Loading…"] }
        var out: [String] = []
        if plan.entry == nil { out.append("Mark where the internet comes in (the Internet tool on the plan).") }
        if !plan.zones.contains(where: { $0.kind == "allow" }) { out.append("Draw at least one zone where a node may go.") }
        if !plan.zones.contains(where: { $0.kind == "demand" }) { out.append("Draw at least one zone that needs signal.") }
        return out
    }

    var body: some View {
        List {
            Section("Plan") {
                ForEach(problems, id: \.self) { SuiNote(.warning, $0) }
                Text(summary).font(.footnote).foregroundStyle(.secondary)
                Button(running ? "Planning…" : "Find the best arrangements") { Task { await start() } }
                    .disabled(running || !problems.isEmpty || catalogue == nil)
                NavigationLink("Change the equipment") { CatalogueView(houseId: houseId) }
            }
            if running || !progress.isEmpty {
                Section("Progress") { ForEach(Array(progress.enumerated()), id: \.offset) { Text($0.element).font(.footnote) } }
            }
            if !status.isEmpty { Section { Text(status).font(.footnote) } }
            if let result {
                Section("Ranked: best first") {
                    Text("Tap the circle on two rows to compare them.").font(.footnote).foregroundStyle(.secondary)
                    if picks.count == 2, let ia = result.results.firstIndex(where: { $0.id == picks[0] }), let ib = result.results.firstIndex(where: { $0.id == picks[1] }) {
                        NavigationLink("Compare #\(ia + 1) and #\(ib + 1)") {
                            CompareView(houseId: houseId, plan: plan, request: request(), a: result.results[ia], b: result.results[ib], rankA: ia + 1, rankB: ib + 1)
                        }
                    }
                    ForEach(Array(result.results.enumerated()), id: \.element.id) { i, a in
                        HStack {
                            Button { pick(a.id) } label: {
                                Image(systemName: picks.contains(a.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picks.contains(a.id) ? Color.accentColor : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(picks.contains(a.id) ? "Chosen for comparison: number \(i + 1)" : "Choose number \(i + 1) for comparison")
                            NavigationLink { ArrangementView(houseId: houseId, arrangement: a, rank: i + 1, plan: plan, request: request(), gateway: result.gateway) } label: {
                                ArrangementRow(rank: i + 1, a: a)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Plan a mesh")
        .task { await load() }
    }

    private func pick(_ id: String) {
        if let i = picks.firstIndex(of: id) { picks.remove(at: i) } else { picks.append(id); if picks.count > 2 { picks.removeFirst() } }
    }

    private var summary: String {
        let n = list.allCatalogue ? "every mesh system in the catalogue" : "\(list.equipment.count) shortlisted system(s)"
        return "Router: \(list.gateway). Trying \(n), up to \(list.kMax) extra node(s), for \(list.client)."
    }

    private func request() -> PlanRequest {
        PlanRequest(equipment: catalogue.map { list.requestEquipment(in: $0.equipment) } ?? list.equipment,
                    gateway_equipment: list.gateway, client: list.client, k_max: list.kMax)
    }

    private func load() async {
        list = Shortlist.load(house: houseId)
        do {
            let data = try await model.client().call("GET", "/api/houses/\(houseId)")
            plan = try JSONDecoder().decode(PlanHouse.self, from: data)
            catalogue = try await model.client().get("/api/catalogue")
        } catch {
            status = "Could not load: \(error.localizedDescription)"
        }
    }

    private func start() async {
        running = true
        progress = []
        result = nil
        status = ""
        defer { running = false }
        do {
            let c = model.client()
            let id = try await c.startPlan(house: houseId, request())
            while true {
                try await Task.sleep(for: .seconds(1.5))
                let s = try await c.job(id)
                progress = s.progress
                if s.state == "error" { status = "The plan failed: \(s.error ?? "unknown error")"; return }
                if s.state == "done" { result = s.result; return }
            }
        } catch {
            status = "Could not plan: \(error.localizedDescription)"
        }
    }
}

struct ArrangementRow: View {
    let rank: Int
    let a: Arrangement

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("#\(rank)").bold()
                Text(a.title)
                Spacer()
                Text(String(format: "score %.2f", a.score)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if a.pareto == true { badge("best trade-off", .success) }
                if !a.valid { badge("invalid", .danger) } else if a.must_ok == false { badge("misses a must-have", .warning) }
                if a.stable == false { badge("unstable ranking", .warning) }
                if let c = a.cost { Text(String(format: "$%.0f", c)).font(.footnote).foregroundStyle(.secondary) }
                if let w = a.worst { Text(String(format: "worst zone %.2f", w)).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private func badge(_ t: String, _ tone: SuiTone) -> some View { SuiChip(tone, t) }
}

/// One arrangement: why it ranks where it does, where its nodes go, how each zone fares, how nodes connect.
struct ArrangementView: View {
    let houseId: String
    let arrangement: Arrangement
    let rank: Int
    let plan: PlanHouse?
    let request: PlanRequest
    let gateway: PlanResult.Gateway

    var body: some View {
        let a = arrangement
        List {
            Section("Why #\(rank)") {
                if let e = a.explanation {
                    ForEach(e.lines, id: \.self) { Text($0).font(.callout) }
                    if let s = e.stability { Text(s).font(.footnote).foregroundStyle(.secondary) }
                } else {
                    Text("No explanation was computed for this one (only the top few get one).").font(.footnote)
                }
                ForEach(a.problems, id: \.self) { SuiNote(.warning, $0) }
            }
            Section("Where the nodes go") {
                Text("Router at the internet entry (\(gateway.equipment), \(levelName(gateway.level)))").font(.footnote)
                ForEach(Array(a.nodes.enumerated()), id: \.offset) { i, n in
                    Text("Node \(i + 1): \(n.equipment) on \(levelName(n.level)) at (\(String(format: "%.1f, %.1f", n.position[0], n.position[1]))) m, \(String(format: "%.1f", n.height)) m high")
                }
                NavigationLink("Show the signal on the plan") { RateMapView(houseId: houseId, plan: plan, request: request, arrangement: a, gateway: gateway) }
            }
            Section("Zones") {
                ForEach(a.zones, id: \.zone) { z in
                    VStack(alignment: .leading) {
                        Text(zoneName(z.zone))
                        Text([String(format: "utility %.2f", z.utility), z.mean_rate.map { String(format: "%.0f Mbit/s typical", $0) },
                              z.must_met == false ? "must-have not met" : nil].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(z.must_met == false ? SuiColor.warning : .secondary)
                        if let lim = a.explanation?.zones.first(where: { $0.zone == z.zone }) {
                            Text("\(lim.limiter): \(lim.detail)").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !a.backhaul.isEmpty {
                Section("How the nodes connect") {
                    ForEach(a.backhaul, id: \.index) { b in
                        Text("Node \(b.index + 1): \(b.kind)" + (b.mbps.map { String(format: ", about %.0f Mbit/s", $0) } ?? "") + (b.hops.map { ", \($0) hop(s)" } ?? ""))
                            .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("#\(rank) \(a.title)")
    }

    private func levelName(_ id: String) -> String { plan?.levels.first { $0.id == id }?.name ?? id }
    private func zoneName(_ id: String) -> String { plan?.zones.first { $0.id == id }.map { $0.name.isEmpty ? $0.id : $0.name } ?? id }
}
