import SwiftUI

/// The floors as an ordered stack, shown top first. The ground floor is the one you mark; every floor beneath it is a
/// basement. The server derives the elevations from this order and the heights measured from the scans.
enum FloorStack {
    /// Floors below `ground` in `order` (bottom to top).
    static func belowGround(order: [String], ground: String) -> [String] {
        guard let i = order.firstIndex(of: ground) else { return [] }
        return Array(order[..<i])
    }

    /// The ground floor of a stack: the lowest one that is not below ground.
    static func ground(of levels: [LevelRef]) -> String? {
        levels.first { !($0.below_ground ?? false) }?.id ?? levels.first?.id
    }

    /// Moves the rows of a top-first list (as `onMove` gives them) and returns the stack bottom to top.
    static func reordered(topFirst: [String], from: IndexSet, to: Int) -> [String] {
        var rows = topFirst
        rows.move(fromOffsets: from, toOffset: to)
        return rows.reversed()
    }
}

struct FloorsView: View {
    let houseId: String
    @EnvironmentObject var model: AppModel
    @State private var order: [String] = []     // bottom to top
    @State private var ground = ""
    @State private var newName = ""
    @State private var adding = false
    @State private var addBelow = false
    @State private var note = ""
    @State private var busy = false

    private var levels: [LevelRef] { model.summary(houseId)?.levels ?? [] }
    private func level(_ id: String) -> LevelRef? { levels.first { $0.id == id } }

    var body: some View {
        List {
            Section {
                Text("Drag to put the floors in order, top floor first. Mark the ground floor; floors beneath it are basements. Heights between floors come from your scans.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                ForEach(Array(order.reversed()), id: \.self) { id in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(level(id)?.name ?? id)
                            if let e = level(id)?.elevation { Text(String(format: "floor at %+.2f m", e)).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if id == ground { SuiChip(.success, "Ground floor") }
                        else if FloorStack.belowGround(order: order, ground: ground).contains(id) { Text("Below ground").font(.footnote).foregroundStyle(.secondary) }
                        else { Button("Ground") { ground = id }.buttonStyle(.borderless).font(.footnote) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: "Make this the ground floor") { ground = id }
                }
                .onMove { from, to in order = FloorStack.reordered(topFirst: order.reversed(), from: from, to: to) }
            }
            Section {
                Button("Add a floor above") { addBelow = false; newName = ""; adding = true }
                Button("Add a basement below") { addBelow = true; newName = ""; adding = true }
            }
            if !note.isEmpty { Section { Text(note).font(.footnote) } }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Floors")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save order") { Task { await save() } }.disabled(busy || !changed) } }
        .alert(addBelow ? "New basement" : "New floor", isPresented: $adding) {
            TextField("Name", text: $newName)
            Button("Add") { Task { await model.addLevel(house: houseId, name: newName, below: addBelow); load() } }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear { load() }
    }

    private func load() {
        order = levels.map(\.id)
        ground = FloorStack.ground(of: levels) ?? ""
    }

    private var changed: Bool {
        order != levels.map(\.id) || ground != (FloorStack.ground(of: levels) ?? "")
    }

    private func save() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await model.client().orderLevels(house: houseId, order: order, belowGround: FloorStack.belowGround(order: order, ground: ground))
            await model.refresh()
            load()
            note = "Saved: elevations follow the new order."
        } catch {
            note = "Could not save the floors: \(error.localizedDescription)"
        }
    }
}
