import SwiftUI

struct HouseView: View {
    let houseId: String
    @EnvironmentObject var model: AppModel
    @State private var captures: [CaptureMeta] = []
    @State private var newLevel = ""
    @State private var addingLevel = false
    @State private var note = ""

    var body: some View {
        let house = model.summary(houseId)
        List {
            if !note.isEmpty { Section { Text(note).font(.footnote) } }
            Section("Levels") {
                ForEach(house?.levels ?? []) { Text($0.name) }
                Button("Add a level") { newLevel = ""; addingLevel = true }
            }
            Section("Scans") {
                NavigationLink("Scan rooms") { ScanScreen(houseId: houseId, onUploaded: { Task { await load() } }) }
                ForEach(captures) { c in
                    NavigationLink {
                        CaptureView(houseId: houseId, capture: c, onSaved: { Task { await load() } })
                    } label: {
                        VStack(alignment: .leading) {
                            Text(c.name.isEmpty ? "Scan" : c.name)
                            Text(c.roomNames.map { $0.isEmpty ? "unnamed" : $0 }.joined(separator: ", ")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(house?.name ?? houseId)
        .alert("New level", isPresented: $addingLevel) {
            TextField("Name (for example First floor)", text: $newLevel)
            Button("Add") { Task { await model.addLevel(house: houseId, name: newLevel) } }
            Button("Cancel", role: .cancel) {}
        }
        .task { await load() }
        .refreshable { await model.refresh(); await load() }
    }

    private func load() async {
        do {
            captures = try await model.client().captures(house: houseId)
            note = ""
        } catch {
            note = "Could not load the scans: \(error.localizedDescription)"
        }
    }
}

/// The names of a stored scan's rooms, editable after the fact.
struct CaptureView: View {
    let houseId: String
    let capture: CaptureMeta
    let onSaved: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var names: [String] = []
    @State private var status = ""

    var body: some View {
        Form {
            Section("Rooms in this scan") {
                ForEach(names.indices, id: \.self) { i in
                    HStack {
                        TextField("Room \(i + 1)", text: $names[i])
                        Menu("Suggest") {
                            ForEach(Naming.suggestions, id: \.self) { s in Button(s) { names[i] = s } }
                        }
                    }
                }
            }
            Button("Save names") { Task { await save() } }
            if !status.isEmpty { Text(status).font(.footnote) }
        }
        .navigationTitle(capture.name.isEmpty ? "Scan" : capture.name)
        .onAppear { names = capture.roomNames }
    }

    private func save() async {
        do {
            _ = try await model.client().nameRooms(house: houseId, blob: capture.blob, names: names.map { $0.trimmed })
            status = "Saved."
            onSaved()
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }
}
