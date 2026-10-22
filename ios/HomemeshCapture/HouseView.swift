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
    @State private var choosingStaircase = false
    @State private var staircase: StairPair?
    @State private var askStairs: CaptureMeta?
    @State private var note = ""
    @State private var waiting: [PendingUpload] = []
    @State private var sending = false

    private var levels: [LevelRef] { model.summary(houseId)?.levels ?? [] }

    var body: some View {
        List {
            if !note.isEmpty { Section { Text(note).font(.footnote) } }
            Section {
                Button { scanLevel = ""; scanning = true } label: {
                    Label("Add room scan", systemImage: "camera.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                Button { choosingStaircase = true } label: {
                    Label("Scan a staircase", systemImage: "figure.stairs").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .disabled(levels.count < 2)
            }
            let stairScans = captures.filter(\.isStairsScan)
            let unasked = captures.filter { $0.needsStairFloors && !$0.isStairsScan }
            if !stairScans.isEmpty || !unasked.isEmpty {
                Section("Staircases") {
                    ForEach(unasked) { c in
                        Button { askStairs = c } label: {
                            VStack(alignment: .leading) {
                                Text("Staircase found in \(c.name)").foregroundStyle(.primary)
                                Text("Rises \(String(format: "%.1f", c.stairs_found?.first?.rise ?? 0)) m. Tap to say which floors it joins.").font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    ForEach(stairScans) { c in
                        NavigationLink {
                            PlaceView(houseId: houseId, capture: c)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(c.name)
                                Text("\(levels.first { $0.id == c.stair?.from_level }?.name ?? "?") to \(levels.first { $0.id == c.stair?.to_level }?.name ?? "?"): place on the plan").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !waiting.isEmpty {
                Section("Waiting to upload (saved on this phone)") {
                    ForEach(waiting) { p in
                        HStack {
                            VStack(alignment: .leading) { Text(p.name); Text(p.created, style: .relative).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Upload") { Task { await sendWaiting() } }.buttonStyle(.borderless).disabled(sending)
                            Button("Delete", role: .destructive) { UploadQueue.remove(p); waiting = UploadQueue.all(house: houseId) }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            ForEach(levels.reversed()) { lv in   // the top floor first
                Section {
                    let here = rooms.filter { $0.level == lv.id }
                    NavigationLink("Plan of \(lv.name): walls and materials") { PlanScreen(houseId: houseId, level: lv.id) }
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
            Section {
                NavigationLink("Floors: order and ground level") { FloorsView(houseId: houseId) }
                Button("Add a floor") { newLevel = ""; addingLevel = true }
                NavigationLink("3D view of the house") { House3DView(houseId: houseId) }
                NavigationLink("Calibrate to my measurements") { CalibrateView(houseId: houseId) }
                NavigationLink("Plan a mesh") { PlanRunView(houseId: houseId) }
                NavigationLink("Equipment to plan with") { CatalogueView(houseId: houseId) }
                NavigationLink("Accuracy: scan against tape") { AccuracyView(houseId: houseId) }
            }
        }
        .navigationTitle(model.summary(houseId)?.name ?? houseId)
        .sheet(isPresented: $choosingStaircase) {
            ScanStaircaseSheet(levels: levels) { from, to in staircase = StairPair(from: from, to: to) }
        }
        .navigationDestination(item: $staircase) { pair in
            ScanScreen(houseId: houseId, initialLevel: pair.from, replacing: nil, onUploaded: { Task { await load() } }, staircase: pair)
        }
        .sheet(item: $askStairs) { c in
            StairFloorsSheet(houseId: houseId, capture: c, levels: levels) { Task { await load() } }.environmentObject(model)
        }
        .navigationDestination(isPresented: $scanning) {
            ScanScreen(houseId: houseId, initialLevel: scanLevel, replacing: nil, onUploaded: { Task { await load() } })
        }
        .alert("New floor", isPresented: $addingLevel) {
            TextField("Name (for example First floor)", text: $newLevel)
            Button("Add") { Task { await model.addLevel(house: houseId, name: newLevel) } }
            Button("Cancel", role: .cancel) {}
        }
        .task { waiting = UploadQueue.all(house: houseId); await sendWaiting(); await load() }
        .refreshable { await model.refresh(); await sendWaiting(); await load() }
    }

    /// Tries the queued scans of this house in order; stops at the first failure and keeps the rest.
    private func sendWaiting() async {
        waiting = UploadQueue.all(house: houseId)
        guard !waiting.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        for p in waiting {
            do { _ = try await UploadQueue.send(p, with: model.uploader(house: houseId)) } catch { note = "A saved scan is not uploaded yet: \(error.localizedDescription)"; break }
        }
        waiting = UploadQueue.all(house: houseId)
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
            let all = try await r
            rooms = all.filter { $0.replaced_by == nil }   // earlier scans of re-scanned rooms stay stored as history
            captures = try await c
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
                NavigationLink("Re-scan this room") {
                    ScanScreen(houseId: houseId, initialLevel: room.level ?? "", replacing: room, onUploaded: { onChanged() })
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
