import SwiftUI

/// Two arrangements side by side: their signal maps (A, B, or where one is faster) and how each zone fares.
struct CompareView: View {
    enum Mode: String, CaseIterable, Identifiable { case a = "A", b = "B", diff = "Difference"; var id: String { rawValue } }

    let houseId: String
    let plan: PlanHouse?
    let request: PlanRequest
    let a: Arrangement
    let b: Arrangement
    let rankA: Int
    let rankB: Int
    @EnvironmentObject var model: AppModel
    @State private var mapA: RateMapResult?
    @State private var mapB: RateMapResult?
    @State private var level = ""
    @State private var mode = Mode.diff
    @State private var status = ""

    var body: some View {
        List {
            if let plan, let mapA, let mapB {
                Section {
                    Picker("Floor", selection: $level) { ForEach(plan.levels, id: \.id) { Text($0.name).tag($0.id) } }.pickerStyle(.segmented)
                    Picker("Show", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    PlanCanvas(walls: plan.walls.filter { $0.level == level }, rooms: plan.rooms.filter { $0.level == level },
                               bounds: Geometry.bounds(plan.walls.filter { $0.level == level }.flatMap { [$0.a, $0.b] }),
                               heat: mode == .b ? mapB.grids.first { $0.level == level } : mapA.grids.first { $0.level == level },
                               heatB: mode == .diff ? mapB.grids.first { $0.level == level } : nil)
                        .frame(height: 320)
                    Text(mode == .diff ? "Blue: B is faster here. Red: A is faster. White: about the same." : "Client speed, 5 to 1000 Mbit/s.").font(.footnote)
                }
            } else {
                ProgressView()
            }
            Section("A is #\(rankA) \(a.title); B is #\(rankB) \(b.title)") {
                row("Score", fmt(a.score), fmt(b.score))
                row("Cost", a.cost.map { String(format: "$%.0f", $0) } ?? "-", b.cost.map { String(format: "$%.0f", $0) } ?? "-")
                row("Worst zone", a.worst.map(fmt) ?? "-", b.worst.map(fmt) ?? "-")
                row("Extra nodes", "\(a.k)", "\(b.k)")
            }
            Section("Zones (utility)") {
                ForEach(zoneIds, id: \.self) { z in
                    row(zoneName(z), a.zones.first { $0.zone == z }.map { fmt($0.utility) } ?? "-", b.zones.first { $0.zone == z }.map { fmt($0.utility) } ?? "-")
                }
            }
            if !status.isEmpty { Text(status).font(.footnote) }
        }
        .navigationTitle("Compare")
        .task { await load() }
    }

    private var zoneIds: [String] {
        var seen: [String] = []
        for z in a.zones + b.zones where !seen.contains(z.zone) { seen.append(z.zone) }
        return seen
    }

    private func zoneName(_ id: String) -> String { plan?.zones.first { $0.id == id }.map { $0.name.isEmpty ? $0.id : $0.name } ?? id }
    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    private func row(_ k: String, _ x: String, _ y: String) -> some View {
        HStack { Text(k); Spacer(); Text(x).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).frame(minWidth: 60, alignment: .trailing); Text(y).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).frame(minWidth: 60, alignment: .trailing) }
    }

    private func load() async {
        do {
            let c = model.client()
            async let ra = c.rateMap(house: houseId, nodes: a.nodes, request: request)
            async let rb = c.rateMap(house: houseId, nodes: b.nodes, request: request)
            (mapA, mapB) = try await (ra, rb)
            level = plan?.levels.first { l in mapA?.grids.contains { $0.level == l.id } ?? false }?.id ?? plan?.levels.first?.id ?? ""
        } catch {
            status = "Could not draw the comparison: \(error.localizedDescription)"
        }
    }
}
