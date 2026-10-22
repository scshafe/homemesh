import QuickLook
import SwiftUI

/// A house: its floors, each with its rooms; one obvious button to add a room scan.
struct HouseView: View {
    let houseId: String
    @EnvironmentObject var model: AppModel
    @State private var rooms: [RoomItem] = []
    @State private var captures: [CaptureMeta] = []
    @State private var newLevel = ""
    @State private var addingLevel = false
    @State private var scanLevel = ""
    @State private var scanning = false
    @State private var note = ""

    private var levels: [LevelRef] { model.summary(houseId)?.levels ?? [] }

    var body: some View {
        List {
            if !note.isEmpty { Section { Text(note).font(.footnote) } }
            Section {
                Button { scanLevel = levels.last?.id ?? ""; scanning = true } label: {
                    Label("Add room scan", systemImage: "camera.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowBackground(Color.clear)
            }
            ForEach(levels) { lv in
                Section {
                    let here = rooms.filter { $0.level == lv.id }
                    ForEach(here) { r in row(r) }
                    if here.isEmpty { Text("No rooms on this floor yet.").font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    HStack {
                        Text(lv.name)
                        Spacer()
                        Button("Add room scan here") { scanLevel = lv.id; scanning = true }.font(.footnote)
                    }
                }
            }
            let loose = rooms.filter { r in !levels.contains { $0.id == r.level } }
            if !loose.isEmpty {
                Section("No floor") { ForEach(loose) { r in row(r) } }
            }
            Section { Button("Add a floor") { newLevel = ""; addingLevel = true } }
        }
        .navigationTitle(model.summary(houseId)?.name ?? houseId)
        .navigationDestination(isPresented: $scanning) {
            ScanScreen(houseId: houseId, initialLevel: scanLevel, onUploaded: { Task { await load() } })
        }
        .alert("New floor", isPresented: $addingLevel) {
            TextField("Name (for example First floor)", text: $newLevel)
            Button("Add") { Task { await model.addLevel(house: houseId, name: newLevel) } }
            Button("Cancel", role: .cancel) {}
        }
        .task { await load() }
        .refreshable { await model.refresh(); await load() }
    }

    private func row(_ r: RoomItem) -> some View {
        NavigationLink {
            RoomDetailView(houseId: houseId, room: r, siblings: rooms.filter { $0.capture == r.capture },
                           capture: captures.first { $0.blob == r.capture }, onChanged: { Task { await model.refresh(); await load() } })
        } label: {
            VStack(alignment: .leading) {
                Text(r.title).foregroundStyle(r.name.isEmpty ? .secondary : .primary)
                if !r.description.isEmpty { Text(r.description).font(.footnote).foregroundStyle(.secondary) }
                Text(r.placed == nil ? "not on the plan yet" : "on the plan").font(.caption).foregroundStyle(r.placed == nil ? .orange : .green)
            }
        }
    }

    private func load() async {
        do {
            async let r = model.client().rooms(house: houseId)
            async let c = model.client().captures(house: houseId)
            (rooms, captures) = try await (r, c)
            note = ""
        } catch {
            note = "Could not load the rooms: \(error.localizedDescription)"
        }
    }
}

/// One room: its name and description, its floor, its 3D model and its place on the plan.
struct RoomDetailView: View {
    let houseId: String
    let room: RoomItem
    let siblings: [RoomItem]          // the rooms of the same scan, in scan order
    let capture: CaptureMeta?
    let onChanged: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var name = ""
    @State private var about = ""
    @State private var level = ""
    @State private var status = ""
    @State private var preview: URL?
    @State private var busy = false

    private var levels: [LevelRef] { model.summary(houseId)?.levels ?? [] }

    var body: some View {
        Form {
            Section("Room") {
                TextField("Name (required)", text: $name)
                Menu("Suggest a name") {
                    ForEach(Naming.suggestions, id: \.self) { s in Button(s) { name = s } }
                }
                TextField("Description (optional)", text: $about, axis: .vertical)
                Button("Save") { Task { await save() } }.disabled(name.trimmed.isEmpty || busy)
            }
            Section {
                Picker("Floor", selection: Binding(get: { level }, set: { level = $0; Task { await moveFloor() } })) {
                    ForEach(levels) { Text($0.name).tag($0.id) }
                }
                if siblings.count > 1 {
                    Text("This room was scanned together with \(siblings.count - 1) other room(s); changing the floor moves them all.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Floor") }
            Section("Scan") {
                if room.usdz != nil {
                    Button("View the 3D model", systemImage: "cube") { Task { await show3D() } }.disabled(busy)
                } else {
                    Text("No 3D model was uploaded for this scan.").font(.footnote)
                }
                if let capture {
                    NavigationLink("Place on the plan") { PlaceView(houseId: houseId, capture: capture) }
                    Text(room.placed == nil ? "Not on the plan yet." : "On the plan.").font(.footnote)
                }
            }
            if !status.isEmpty { Text(status).font(.footnote) }
        }
        .navigationTitle(room.title)
        .quickLookPreview($preview)
        .onAppear {
            name = room.name
            about = room.description
            level = room.level ?? levels.first?.id ?? ""
        }
    }

    private func save() async {
        busy = true
        defer { busy = false }
        var names = siblings.map(\.name), about_ = siblings.map(\.description)
        if let i = siblings.firstIndex(where: { $0.index == room.index }) {
            names[i] = name.trimmed
            about_[i] = about.trimmed
        }
        do {
            _ = try await model.client().nameRooms(house: houseId, blob: room.capture, names: names, descriptions: about_)
            status = room.placed == nil ? "Saved." : "Saved. The plan picks the new name up the next time the scan is placed."
            onChanged()
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }

    private func moveFloor() async {
        guard level != (room.level ?? ""), !level.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await model.client().moveScan(house: houseId, blob: room.capture, level: level)
            status = "Moved to the new floor."
            onChanged()
        } catch {
            status = "Could not change the floor: \(error.localizedDescription)"
        }
    }

    private func show3D() async {
        guard let blob = room.usdz else { return }
        busy = true
        defer { busy = false }
        do {
            status = "Downloading the model…"
            preview = try await model.client().download(house: houseId, blob: blob, suffix: "usdz")
            status = ""
        } catch {
            status = "Could not load the model: \(error.localizedDescription)"
        }
    }
}
