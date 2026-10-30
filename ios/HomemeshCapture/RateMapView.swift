import SwiftUI

struct RateMapBody: Encodable, Sendable {
    let nodes: [PlacedNode]
    let gateway_equipment: String
    let client: String
}

struct RateMapResult: Decodable, Sendable {
    let grids: [HeatLayer]
    let problems: [String]
}

extension Client {
    func rateMap(house: String, nodes: [PlacedNode], request: PlanRequest) async throws -> RateMapResult {
        try await send("POST", "/api/houses/\(house)/ratemap", RateMapBody(nodes: nodes, gateway_equipment: request.gateway_equipment, client: request.client))
    }
}

/// The client speed over the plan for one arrangement, floor by floor, with its nodes marked.
struct RateMapView: View {
    let houseId: String
    let plan: PlanHouse?
    let request: PlanRequest
    let arrangement: Arrangement
    let gateway: PlanResult.Gateway
    @EnvironmentObject var model: AppModel
    @State private var map: RateMapResult?
    @State private var level = ""
    @State private var status = ""

    var body: some View {
        VStack(spacing: 8) {
            if let plan, let map {
                Picker("Floor", selection: $level) { ForEach(plan.levels, id: \.id) { Text($0.name).tag($0.id) } }.pickerStyle(.segmented)
                PlanCanvas(walls: plan.walls.filter { $0.level == level }, rooms: plan.rooms.filter { $0.level == level }, bounds: bounds(plan),
                           markers: nodeMarkers(), heat: map.grids.first { $0.level == level })
                    .background(Color(.secondarySystemBackground))
                legend
                ForEach(map.problems, id: \.self) { SuiNote(.warning, $0) }
            } else {
                ProgressView()
            }
            if !status.isEmpty { Text(status).font(.footnote) }
        }
        .padding()
        .navigationTitle("Signal: \(arrangement.title)")
        .task { await load() }
    }

    private var legend: some View {
        HStack(spacing: 2) {
            Text("5").font(.caption2)
            ForEach([5.0, 15, 50, 150, 500, 1000], id: \.self) { Rectangle().fill(RateColor.color($0)).frame(height: 10) }
            Text("1000 Mbit/s").font(.caption2)
        }
    }

    private func bounds(_ plan: PlanHouse) -> CGRect {
        Geometry.bounds(plan.walls.filter { $0.level == level }.flatMap { [$0.a, $0.b] })
    }

    /// The router (at the internet entry) and the extra nodes on this floor, shown as access points.
    private func nodeMarkers() -> [PlanMarker] {
        var out = arrangement.nodes.enumerated().filter { $0.element.level == level }
            .map { PlanMarker(id: "n\($0.offset)", kind: .accessPoint, at: Pt($0.element.position[0], $0.element.position[1])) }
        if gateway.level == level { out.append(PlanMarker(id: "gw", kind: .entry, at: Pt(gateway.position[0], gateway.position[1]))) }
        return out
    }

    private func load() async {
        do {
            map = try await model.client().rateMap(house: houseId, nodes: arrangement.nodes, request: request)
            level = plan?.levels.first { l in map?.grids.contains { $0.level == l.id } ?? false }?.id ?? plan?.levels.first?.id ?? ""
        } catch {
            status = "Could not draw the signal: \(error.localizedDescription)"
        }
    }
}
