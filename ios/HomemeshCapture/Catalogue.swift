import SwiftUI

/// `GET /api/catalogue`: the equipment and client devices the planner can use.
struct CatalogueEquipment: Codable, Hashable, Identifiable, Sendable {
    struct Radio: Codable, Hashable, Sendable {
        let band: String
        let chains: Int
        let tx_dbm: Double
        let standard: String
        let dedicated_backhaul: Bool
        let assumed: Bool
    }
    struct Port: Codable, Hashable, Sendable { let rate: Double }
    let id: String
    let name: String
    let kind: String
    let system: String
    let radios: [Radio]
    let ports: [Port]
    let poe_in: Bool
    let max_nodes: Int?
    let price: Double?
    let notes: String
    let origin: String
    let assumed: Bool
}

struct CatalogueClient: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct CatalogueData: Codable, Sendable {
    let equipment: [CatalogueEquipment]
    let clients: [CatalogueClient]
}

/// What the owner wants planned: kept on the phone per house and sent with the plan request (P7).
struct Shortlist: Codable, Equatable {
    var equipment: [String] = []
    var gateway = "generic-router-ax"
    var allCatalogue = false
    var kMax = 5
    var client = "phone-2x2-ax"

    private static func key(_ house: String) -> String { "shortlist.\(house)" }

    static func load(house: String, defaults: UserDefaults = .standard) -> Shortlist {
        defaults.data(forKey: key(house)).flatMap { try? JSONDecoder().decode(Shortlist.self, from: $0) } ?? Shortlist()
    }

    func save(house: String, defaults: UserDefaults = .standard) {
        if let d = try? JSONEncoder().encode(self) { defaults.set(d, forKey: Shortlist.key(house)) }
    }

    /// The `equipment` list of the plan request: the shortlist, or every non-router item of the catalogue.
    func requestEquipment(in catalogue: [CatalogueEquipment]) -> [String] {
        allCatalogue ? catalogue.filter { $0.kind != "router" }.map(\.id) : equipment
    }
}

/// Browse the catalogue and choose what to plan with.
struct CatalogueView: View {
    let houseId: String
    @EnvironmentObject var model: AppModel
    @State private var data: CatalogueData?
    @State private var list = Shortlist()
    @State private var note = ""

    var body: some View {
        List {
            if !note.isEmpty { Text(note).font(.footnote) }
            if let data {
                Section("Plan with") {
                    Toggle("Every mesh system in the catalogue", isOn: $list.allCatalogue)
                    Picker("Router (the gateway)", selection: $list.gateway) {
                        ForEach(data.equipment.filter { $0.kind == "router" }) { Text($0.name).tag($0.id) }
                    }
                    Picker("Client device", selection: $list.client) { ForEach(data.clients) { Text($0.name).tag($0.id) } }
                    Stepper("Up to \(list.kMax) extra node(s)", value: $list.kMax, in: 0...8)
                }
                Section(list.allCatalogue ? "Catalogue (all will be tried)" : "Your shortlist: tick what you are considering") {
                    ForEach(data.equipment.filter { $0.kind != "router" }) { e in
                        let on = list.equipment.contains(e.id) || list.allCatalogue
                        HStack {
                            Button { toggle(e.id) } label: {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Color.accentColor : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .disabled(list.allCatalogue)
                            .accessibilityLabel(on ? "\(e.name) is on the shortlist" : "Add \(e.name) to the shortlist")
                            NavigationLink {
                                EquipmentDetail(item: e)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(e.name)
                                    Text([e.system, e.price.map { String(format: "$%.0f", $0) }, e.assumed ? "numbers assumed" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Equipment")
        .task { await load() }
        .onChange(of: list) { list.save(house: houseId) }
    }

    private func toggle(_ id: String) {
        if let i = list.equipment.firstIndex(of: id) { list.equipment.remove(at: i) } else { list.equipment.append(id) }
    }

    private func load() async {
        list = Shortlist.load(house: houseId)
        do { data = try await model.client().get("/api/catalogue") } catch { note = "Could not load the catalogue: \(error.localizedDescription)" }
    }
}

struct EquipmentDetail: View {
    let item: CatalogueEquipment

    var body: some View {
        List {
            Section("About") {
                row("Kind", item.kind.replacingOccurrences(of: "_", with: " "))
                if !item.system.isEmpty { row("System", item.system) }
                if let p = item.price { row("Price", String(format: "$%.0f", p)) }
                if let n = item.max_nodes { row("Most nodes", "\(n)") }
                row("Power over Ethernet in", item.poe_in ? "yes" : "no")
                row("Where the numbers come from", item.assumed ? "assumed, not measured" : item.origin)
                if !item.notes.isEmpty { Text(item.notes).font(.footnote) }
            }
            Section("Radios") {
                ForEach(item.radios, id: \.self) { r in
                    Text("\(r.band) GHz · \(r.standard) · \(r.chains)x\(r.chains) · \(String(format: "%.0f", r.tx_dbm)) dBm\(r.dedicated_backhaul ? " · backhaul" : "")")
                }
            }
            Section("Ports") { Text(item.ports.map { String(format: "%g", $0.rate) + " Mbit/s" }.joined(separator: ", ")) }
        }
        .navigationTitle(item.name)
    }

    private func row(_ k: String, _ v: String) -> some View { HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary) } }
}
