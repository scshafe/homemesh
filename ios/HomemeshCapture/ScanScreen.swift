import RoomPlan
import SwiftUI

/// Scan one or more rooms, name each right after it is scanned, then upload with the names.
/// One scan view and AR session serve all rooms of one scan (they share a frame); after an upload or a discard
/// the scan view is replaced by a fresh one, so the next scan starts a new session and never a paused one.
struct ScanScreen: View {
    let houseId: String
    let initialLevel: String
    let replacing: RoomItem?   // set when this re-scans a room: it replaces that room's geometry
    let onUploaded: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var controller = ScanController()
    @State private var generation = 0
    @State private var level = ""
    @State private var levelReason = ""
    @State private var levelTouched = false          // the owner chose a floor: suggestions stop changing it
    @State private var earlierRooms: [RoomItem] = []
    @State private var baro: BaroReading?            // at the start of the running session's first room
    @State private var earlierBaro: [BaroReading?] = []
    @State private var rooms: [CapturedRoom] = []          // the rooms of the running session (one frame)
    @State private var earlier: [[CapturedRoom]] = []      // sessions that ended: each is its own frame and its own scan
    @State private var names: [String: String] = [:]   // by the room's identifier
    @State private var phase = ScanController.Phase.idle
    @State private var busy = false
    @State private var status = ""
    @State private var hint = ""
    @FocusState private var focused: String?
    @Environment(\.dismiss) private var dismiss

    private var levels: [LevelRef] { model.summary(houseId)?.levels ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScanView(controller: controller).id(generation)
                .frame(height: focused == nil ? 400 : 160).clipped()   // the keyboard gets the room the preview gave up
                .animation(.easeOut(duration: 0.2), value: focused == nil)
                .overlay(alignment: .top) { floatingBar }
            Form {
                Section("Scan") {
                    Button(phase == .running ? "Done with this room" : phase == .stopping ? "Processing the room…" : "Start scanning a room") { toggle() }
                        .disabled(!RoomCaptureSession.isSupported || phase == .stopping || busy)
                    if !RoomCaptureSession.isSupported { Text("This device has no LiDAR scanner.").foregroundStyle(.red) }
                    if !hint.isEmpty { Text(hint).font(.footnote).foregroundStyle(.orange) }
                    ForEach(allRooms.indices, id: \.self) { i in
                        let id = allRooms[i].identifier.uuidString
                        TextField("Name room \(i + 1) (required)", text: Binding(get: { names[id] ?? "" }, set: { names[id] = $0 }))
                            .focused($focused, equals: id)
                            .submitLabel(.done)
                    }
                }
                if !allRooms.isEmpty {   // chosen with the name, after the scan, starting from a suggestion
                    Section {
                        floorPicker
                        if !levelReason.isEmpty { Text("Suggested: \(levelReason).").font(.footnote).foregroundStyle(.secondary) }
                    } header: { Text("Floor") }
                }
                if !status.isEmpty { Section { Text(status) } }
                if !allRooms.isEmpty {   // last in the form: out of the way of the keyboard and of the room fields
                    Section { Button("Discard scan", role: .destructive) { resetScan(); status = "" }.disabled(phase != .idle || busy) }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            BaroSampler.shared.start()
            suggestFloor()   // at once from what is known here; refined when the earlier rooms arrive
            bind()
        }
        .task {
            earlierRooms = (try? await model.client().rooms(house: houseId)) ?? []
            suggestFloor()
        }

        .onDisappear { controller.shutdown() }
    }

    /// Back on the left, Save on the right, floating over the preview (no navigation bar row).
    private var floatingBar: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.backward").font(.headline).padding(12) }
                .background(.regularMaterial, in: Circle())
                .accessibilityLabel("Back")
            Spacer()
            if !allRooms.isEmpty {
                Button { Task { await upload() } } label: { Text("Save").font(.headline).padding(.horizontal, 18).padding(.vertical, 10) }
                    .background(.regularMaterial, in: Capsule())
                    .disabled(busy || phase != .idle || !allNamed)
                    .accessibilityHint("Saves the scan to \(model.summary(houseId)?.name ?? houseId) and uploads it")
            }
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    /// The floor to start the picker on, from the floor asked for, the rooms scanned at the same height, or the last used.
    private func suggestFloor() {
        guard !levelTouched else { return }
        let others = earlierRooms.compactMap { r in r.level.flatMap { l in r.baro.map { (room: r.name, level: l, baro: $0) } } }
        let asked = replacing?.level ?? (initialLevel.isEmpty ? nil : initialLevel)
        let why = replacing != nil ? "the floor of the room you are re-scanning" : "the floor you started from"
        let s = FloorSuggestion.suggest(levels: levels, current: baro, others: others, preferred: asked, preferredReason: why,
                                        lastUsed: FloorSuggestion.lastUsed(house: houseId))
        level = s?.level ?? levels.first?.id ?? ""
        levelReason = s?.reason ?? ""
    }

    @ViewBuilder private var floorPicker: some View {
        let choice = Binding(get: { level }, set: { level = $0; levelTouched = true; levelReason = "" })
        if levels.count <= 4 {
            Picker("Floor", selection: choice) { ForEach(levels.reversed()) { Text($0.name).tag($0.id) } }.pickerStyle(.segmented)
        } else {
            Picker("Floor", selection: choice) { ForEach(levels.reversed()) { Text($0.name).tag($0.id) } }.pickerStyle(.menu)
        }
    }

    private var allRooms: [CapturedRoom] { earlier.flatMap { $0 } + rooms }

    private var allNamed: Bool { allRooms.allSatisfy { !(names[$0.identifier.uuidString] ?? "").trimmed.isEmpty } }

    /// The scan's own name is the names of its rooms; there is one name field per room and no other.
    private func scanTitle(_ group: [CapturedRoom]) -> String {
        let joined = group.compactMap { names[$0.identifier.uuidString]?.trimmed }.filter { !$0.isEmpty }.joined(separator: ", ")
        return joined.isEmpty ? Naming.defaultScanName() : String(joined.prefix(80))
    }

    private func bind() {
        controller.onProcessed = { room in
            rooms.append(room)
            suggestFloor()
            status = "Room added: name it below."
            if rooms.count == 1, let old = replacing, names[room.identifier.uuidString] == nil { names[room.identifier.uuidString] = old.name }
            focused = room.identifier.uuidString
        }
        controller.onError = { msg in status = "Scan failed: \(msg)" }
        controller.onSessionLost = { message, salvaged in
            if let salvaged {
                rooms.append(salvaged)
                status = message + " The room scanned so far was kept: name it below."
                focused = salvaged.identifier.uuidString
            } else {
                status = message
            }
            newSession()
        }
        controller.onPhase = { phase = $0 }
        controller.onHint = { hint = $0 }
        phase = controller.phase
    }

    /// A fresh scan view and session for the next scan.
    private func resetScan() {
        rooms = []
        earlier = []
        earlierBaro = []
        baro = nil
        levelTouched = false
        names = [:]
        replaceController()
    }

    private func replaceController() {
        controller.shutdown()
        controller = ScanController()
        generation += 1
        hint = ""
        bind()
    }

    /// The running session is over (it hit RoomPlan's limits, failed, or is simply long): what it scanned is kept as
    /// its own scan, and the next room gets a brand-new session, camera view and world frame.
    private func newSession() {
        if !rooms.isEmpty { earlier.append(rooms); earlierBaro.append(baro); rooms = []; baro = nil }
        replaceController()
    }

    private func toggle() {
        if phase == .running { controller.stop(); return }
        if controller.wantsFreshSession {   // before RoomPlan's scene size limit, not after it
            Diagnostics.event("renewal", ["rooms": controller.roomsDone, "seconds": Int(controller.scanSeconds)])
            newSession()
            status = "To stay under RoomPlan's size limit this room starts a new session: a new frame, placed by the usual placement step. Tap start again."
            return
        }
        if baro == nil { baro = BaroSampler.shared.reading }
        controller.start()
    }

    /// The scan is first saved on the phone (so nothing is lost if the upload fails or there is no signal), then sent.
    private func upload() async {
        busy = true
        defer { busy = false }
        do {
            status = "Preparing…"
            let groups = earlier + (rooms.isEmpty ? [] : [rooms])
            let baros = earlierBaro + (rooms.isEmpty ? [] : [baro])
            var items: [(PendingUpload, [String])] = []
            FloorSuggestion.remember(level, house: houseId)
            for (gi, g) in groups.enumerated() {   // one scan per session: each session has its own frame
                let (json, usdz) = try await ScanPayload.build(rooms: g, names: names.mapValues { $0.trimmed }, baro: gi < baros.count ? baros[gi] : nil)
                let item = try UploadQueue.enqueue(house: houseId, name: scanTitle(g), level: level, replaces: items.isEmpty ? (replacing?.key ?? "") : "", json: json, usdz: usdz)
                items.append((item, g.map { names[$0.identifier.uuidString]?.trimmed ?? "" }))
            }
            let first = replacing.flatMap { $0.description.isEmpty ? nil : $0.description }
            resetScan()
            status = "Saved on this phone. Uploading…"
            var last = ""
            for (n, (item, roomNames)) in items.enumerated() {
                let id = try await UploadQueue.send(item, with: model.uploader(house: houseId))
                last = id
                if n == 0, let first {   // the description carries over to the new scan's room
                    _ = try? await model.client().nameRooms(house: houseId, blob: id, names: roomNames, descriptions: roomNames.indices.map { $0 == 0 ? first : "" })
                }
            }
            status = items.count > 1
                ? "Uploaded \(items.count) scans (they are separate frames). Place each on the plan next."
                : "Uploaded (scan \(last.prefix(8))). Place the rooms on the plan next."
            Diagnostics.event("upload", ["ok": true, "scans": items.count])
            await DiagnosticsUploader.shared.flush()
            onUploaded()
        } catch {
            Diagnostics.event("upload", ["ok": false, "error": (error as NSError).domain + " " + String((error as NSError).code)])
            status = "Not uploaded yet: \(error.localizedDescription). The scan is saved on this phone; the house screen has it under \"Waiting to upload\"."
        }
    }
}

/// Building the upload (combining rooms, encoding, USDZ export) is heavy: it runs off the main actor so the UI
/// and the camera view never wait for it. Logged and signposted for Console (subsystem `homemesh.capture`).
enum ScanPayload {
    /// The capture JSON in the app's wrapper, each room carrying its name, and the exported USDZ.
    /// One room: that room. Several: combined by StructureBuilder so all share one coordinate frame.
    nonisolated static func build(rooms: [CapturedRoom], names: [String: String], baro: BaroReading? = nil) async throws -> (json: Data, usdz: URL) {
        try await Task.detached(priority: .userInitiated) {
            let log = ScanController.log, sp = ScanController.signposter
            let total = sp.beginInterval("build payload")
            defer { sp.endInterval("build payload", total) }
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let usdz = tmp.appendingPathComponent("scan.usdz")
            let enc = JSONEncoder()
            var roomObjects: [[String: Any]]
            if rooms.count == 1 {
                roomObjects = [try object(try enc.encode(rooms[0]))]
                log.notice("exporting USDZ (1 room)")
                try rooms[0].export(to: usdz)
            } else {
                log.notice("combining \(rooms.count) rooms")
                let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
                roomObjects = try object(try enc.encode(structure))["rooms"] as? [[String: Any]] ?? []
                log.notice("exporting USDZ (\(rooms.count) rooms)")
                try structure.export(to: usdz)
            }
            // names ride on the room identifiers; if the combined structure gave its rooms new identifiers,
            // fall back to the order the rooms were scanned in
            let known = Set(rooms.map { $0.identifier.uuidString })
            let ids = roomObjects.compactMap { $0["identifier"] as? String }
            let byOrder = ids.allSatisfy { !known.contains($0) } && roomObjects.count == rooms.count
            if byOrder { log.notice("room identifiers changed in the structure: naming by scan order") }
            for i in roomObjects.indices {
                let key = byOrder ? rooms[i].identifier.uuidString : (roomObjects[i]["identifier"] as? String ?? "")
                if let n = names[key], !n.isEmpty { roomObjects[i]["name"] = n }
            }
            var wrapper: [String: Any] = ["format": "homemesh-capture-1", "rooms": roomObjects]
            if let baro {
                wrapper["baro"] = ["session": baro.session, "rel_m": baro.rel_m, "kpa": baro.kpa, "at": baro.at]
            }
            let json = try JSONSerialization.data(withJSONObject: wrapper)
            log.notice("payload ready: \(json.count) bytes")
            return (json, usdz)
        }.value
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Uploader.Failure(message: "Could not read the scan")
        }
        return o
    }
}
