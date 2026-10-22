import SwiftUI

/// A zone: where a mesh node may go (allow), where it must not (forbid), or where signal is needed (demand).
struct ZoneInspector: View {
    let zone: PlanZone
    let doc: HouseDoc
    let onSaved: (HouseDoc) -> Void
    let onRemoved: () -> Void
    @State private var kind = "allow"
    @State private var name = ""
    @State private var weight = "1"
    @State private var minRssi = "-65"
    @State private var minRate = ""
    @State private var must = false
    @State private var rxHeight = "1.0"
    @State private var requires = "none"
    @State private var mounts: Set<String> = []
    @State private var heights = ""

    var body: some View {
        Form {
            Section("Zone \(zone.id)") {
                Picker("Kind", selection: $kind) {
                    Text("Allow").tag("allow"); Text("Forbid").tag("forbid"); Text("Demand").tag("demand")
                }.pickerStyle(.segmented)
                TextField("Name (for example Home office)", text: $name)
                if kind == "demand" {
                    field("Weight", $weight)
                    field("Minimum signal (dBm)", $minRssi)
                    field("Minimum speed (Mbit/s, optional)", $minRate)
                    field("Receiver height (m)", $rxHeight)
                    Toggle("Must be met", isOn: $must)
                }
                if kind == "allow" {
                    Picker("Needs", selection: $requires) { Text("Nothing").tag("none"); Text("An outlet").tag("outlet"); Text("PoE").tag("poe") }
                    ForEach(["floor", "shelf", "ceiling", "wall"], id: \.self) { m in
                        Toggle(m.capitalized, isOn: Binding(get: { mounts.contains(m) }, set: { if $0 { mounts.insert(m) } else { mounts.remove(m) } }))
                    }
                    TextField("Allowed heights in metres, comma separated", text: $heights).keyboardType(.numbersAndPunctuation)
                }
                Button("Save") { save() }
                Button("Delete", role: .destructive) { var d = doc; d.remove("zones", zone.id); onSaved(d); onRemoved() }
            }
        }
        .onAppear(perform: load)
        .onChange(of: zone.id) { load() }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack { Text(label); TextField("", text: text).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
    }

    private func num(_ s: String) -> Double? { Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) }

    private func load() {
        let z = doc.item("zones", zone.id) ?? [:]
        kind = z["kind"] as? String ?? zone.kind
        name = z["name"] as? String ?? ""
        weight = String(format: "%g", z["weight"] as? Double ?? 1)
        let n = z["need"] as? [String: Any] ?? [:]
        minRssi = n["min_rssi"].flatMap { $0 as? Double }.map { String(format: "%g", $0) } ?? "-65"
        minRate = n["min_throughput"].flatMap { $0 as? Double }.map { String(format: "%g", $0) } ?? ""
        must = n["must"] as? Bool ?? false
        rxHeight = String(format: "%g", n["rx_height"] as? Double ?? 1.0)
        requires = z["requires"] as? String ?? "none"
        mounts = Set(z["mounts"] as? [String] ?? [])
        heights = (z["heights"] as? [Double] ?? []).map { String(format: "%g", $0) }.joined(separator: ", ")
    }

    private func save() {
        var d = doc
        var f: [String: Any?] = ["kind": kind, "name": name.trimmed]
        switch kind {
        case "demand":
            var need: [String: Any] = ["must": must, "rx_height": num(rxHeight) ?? 1.0]
            if let r = num(minRssi) { need["min_rssi"] = r }
            if let t = num(minRate), t > 0 { need["min_throughput"] = t }
            f["need"] = need
            f["weight"] = max(num(weight) ?? 1, 0)
            f["requires"] = "none"; f["mounts"] = [String](); f["heights"] = [Double]()
        case "allow":
            f.updateValue(nil, forKey: "need")
            f["requires"] = requires
            f["mounts"] = ["floor", "shelf", "ceiling", "wall"].filter { mounts.contains($0) }
            f["heights"] = heights.split(separator: ",").compactMap { num(String($0)) }.filter { $0 >= 0 }
        default:
            f.updateValue(nil, forKey: "need"); f["requires"] = "none"; f["mounts"] = [String](); f["heights"] = [Double]()
        }
        d.set("zones", zone.id, f)
        onSaved(d)
    }
}
