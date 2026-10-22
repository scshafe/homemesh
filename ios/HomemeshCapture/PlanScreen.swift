import SwiftUI

/// The plan of one floor: tap a wall to see and edit its thickness, material and openings.
struct PlanScreen: View {
    let houseId: String
    let level: String
    @EnvironmentObject var model: AppModel
    @State private var doc: HouseDoc?
    @State private var plan: PlanHouse?
    @State private var selected: String?
    @State private var status = ""
    @State private var bounds = CGRect(x: -1, y: -1, width: 2, height: 2)

    var body: some View {
        VStack(spacing: 8) {
            if let plan {
                PlanCanvas(walls: plan.walls.filter { $0.level == level }, rooms: plan.rooms.filter { $0.level == level },
                           selected: selected, bounds: bounds, onTapPlan: { p, tol in selected = nearestWall(p, tol: tol, plan: plan) })
                    .background(Color(.secondarySystemBackground))
                if let id = selected, let wall = plan.walls.first(where: { $0.id == id }), let doc {
                    WallInspector(houseId: houseId, wall: wall, doc: doc, level: level,
                                  onSaved: { new in Task { await save(new) } }, status: $status)
                        .frame(maxHeight: 360)
                } else {
                    Text("Tap a wall.").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
            }
            if !status.isEmpty { Text(status).font(.footnote).padding(.horizontal) }
        }
        .navigationTitle(plan?.levels.first { $0.id == level }?.name ?? "Plan")
        .task { await load() }
    }

    private func nearestWall(_ p: Pt, tol: Double, plan: PlanHouse) -> String? {
        var best: (String, Double)?
        for w in plan.walls where w.level == level {
            let d = Geometry.distance(from: p, toSegment: w.a, w.b)
            if d <= tol, best == nil || d < best!.1 { best = (w.id, d) }
        }
        return best?.0
    }

    private func load() async {
        do {
            let data = try await model.client().call("GET", "/api/houses/\(houseId)")
            doc = try HouseDoc(data: data)
            let p = try JSONDecoder().decode(PlanHouse.self, from: data)
            plan = p
            let pts = p.walls.filter { $0.level == level }.flatMap { [$0.a, $0.b] }
            bounds = Geometry.bounds(pts)
        } catch {
            status = "Could not load the plan: \(error.localizedDescription)"
        }
    }

    private func save(_ new: HouseDoc) async {
        do {
            try await model.client().saveHouse(house: houseId, json: try new.data(), expectRevision: new.revision)
            status = "Saved."
            await load()
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }
}

struct WallInspector: View {
    let houseId: String
    let wall: PlanWall
    let doc: HouseDoc
    let level: String
    let onSaved: (HouseDoc) -> Void
    @Binding var status: String
    @State private var thickness = ""
    @State private var material = ""
    @State private var kinds: [String] = []
    @State private var widths: [String] = []
    @State private var tape = ""
    @State private var what = ""

    var body: some View {
        Form {
            Section("Wall \(wall.id): \(String(format: "%.2f", wall.length)) m long") {
                HStack {
                    Text("Thickness (m)")
                    TextField("0.12", text: $thickness).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                }
                if doc.thicknessDefaulted(wall.id) { Text("The scan gave no thickness: this is a guess.").font(.footnote).foregroundStyle(.orange) }
                Picker("Material", selection: $material) { ForEach(doc.materials, id: \.id) { Text($0.name).tag($0.id) } }
                Button("Save this wall") { apply(all: false) }
                Button("Use for every wall on this floor still on the defaults") { apply(all: true) }
            }
            if !kinds.isEmpty {
                Section("Openings") {
                    ForEach(kinds.indices, id: \.self) { i in
                        HStack {
                            Picker("", selection: $kinds[i]) { ForEach(["door", "window", "arch", "hole"], id: \.self) { Text($0).tag($0) } }.labelsHidden()
                            TextField("width", text: $widths[i]).keyboardType(.decimalPad).frame(width: 70)
                            Button("Save") { saveOpening(i) }.buttonStyle(.borderless)
                            Button("Delete", role: .destructive) { deleteOpening(i) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            MeasureCheckSection(houseId: houseId, wall: wall, level: level, doc: doc, onSaved: onSaved, status: $status)
        }
        .onAppear(perform: load)
        .onChange(of: wall.id) { load() }
    }

    private func load() {
        thickness = String(format: "%.3f", wall.thickness)
        material = doc.material(of: wall.id) ?? doc.materials.first?.id ?? ""
        let o = doc.openings(of: wall.id)
        kinds = o.map(\.kind)
        widths = o.map { String(format: "%.2f", $0.width) }
    }

    private func apply(all: Bool) {
        var d = doc
        let t = Double(thickness.replacingOccurrences(of: ",", with: "."))
        if all {
            let n = d.applyToDefaults(level: level, thickness: t, material: material)
            status = "\(n) wall(s) updated."
        } else {
            d.update(wall: wall.id, thickness: t, material: material)
        }
        onSaved(d)
    }

    private func saveOpening(_ i: Int) {
        var d = doc
        guard let w = Double(widths[i].replacingOccurrences(of: ",", with: ".")), w > 0 else { status = "Give the width in metres."; return }
        d.setOpening(wall: wall.id, index: i, kind: kinds[i], width: w)
        onSaved(d)
    }

    private func deleteOpening(_ i: Int) {
        var d = doc
        d.removeOpening(wall: wall.id, index: i)
        onSaved(d)
    }
}
