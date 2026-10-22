import RoomPlan
import SwiftUI

/// Scan one or more rooms, name each right after it is scanned, then upload with the names.
/// One scan view and AR session serve all rooms of one scan (they share a frame); after an upload or a discard
/// the scan view is replaced by a fresh one, so the next scan starts a new session and never a paused one.
struct ScanScreen: View {
    let houseId: String
    let onUploaded: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var controller = ScanController()
    @State private var generation = 0
    @State private var scanName = ""
    @State private var level = ""
    @State private var rooms: [CapturedRoom] = []
    @State private var names: [String: String] = [:]   // by the room's identifier
    @State private var phase = ScanController.Phase.idle
    @State private var busy = false
    @State private var status = ""
    @State private var hint = ""
    @State private var nameTarget: String?              // the identifier being named; not cleared when the alert closes
    @State private var showNaming = false
    @State private var roomName = ""

    private var levels: [LevelRef] { model.summary(houseId)?.levels ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScanView(controller: controller).id(generation).frame(height: 360).clipped()
            Form {
                Section("Scan") {
                    TextField("Name of this scan (for example Ground floor)", text: $scanName)
                    if levels.count > 1 {
                        Picker("Level", selection: $level) { ForEach(levels) { Text($0.name).tag($0.id) } }
                    }
                    Button(phase == .running ? "Done with this room" : phase == .stopping ? "Processing the room…" : "Start scanning a room") { toggle() }
                        .disabled(!RoomCaptureSession.isSupported || phase == .stopping || busy)
                    if !RoomCaptureSession.isSupported { Text("This device has no LiDAR scanner.").foregroundStyle(.red) }
                    if !hint.isEmpty { Text(hint).font(.footnote).foregroundStyle(.orange) }
                    ForEach(rooms.indices, id: \.self) { i in
                        Button(label(i)) { rename(rooms[i]) }
                    }
                    Button("Upload to \(model.summary(houseId)?.name ?? houseId)") { Task { await upload() } }
                        .disabled(rooms.isEmpty || busy || phase != .idle)
                    if !rooms.isEmpty { Button("Discard scan", role: .destructive) { resetScan(); status = "" }.disabled(phase != .idle) }
                }
                if !status.isEmpty { Section { Text(status) } }
            }
        }
        .navigationTitle("Scan")
        .alert("Name this room", isPresented: $showNaming) {
            TextField("For example Kitchen", text: $roomName)
            Button("Save") { if let id = nameTarget { names[id] = roomName.trimmed } }
            Button("Skip", role: .cancel) {}
        } message: {
            Text(Naming.suggestions.prefix(6).joined(separator: ", "))
        }
        .onAppear {
            bind()
            if level.isEmpty { level = levels.first?.id ?? "" }
        }
        .onDisappear { controller.shutdown() }
    }

    private func label(_ i: Int) -> String {
        let n = names[rooms[i].identifier.uuidString] ?? ""
        return n.isEmpty ? "Room \(i + 1): tap to name" : "Room \(i + 1): \(n)"
    }

    private func rename(_ room: CapturedRoom) {
        nameTarget = room.identifier.uuidString
        roomName = names[room.identifier.uuidString] ?? ""
        showNaming = true
    }

    private func bind() {
        controller.onProcessed = { room in
            rooms.append(room)
            status = "Room added."
            rename(room)
        }
        controller.onError = { msg in status = "Scan failed: \(msg)" }
        controller.onPhase = { phase = $0 }
        controller.onHint = { hint = $0 }
        phase = controller.phase
    }

    /// A fresh scan view and session for the next scan.
    private func resetScan() {
        controller.shutdown()
        controller = ScanController()
        generation += 1
        rooms = []
        names = [:]
        hint = ""
        bind()
    }

    private func toggle() {
        if phase == .running { controller.stop() } else { controller.start() }
    }

    private func upload() async {
        busy = true
        defer { busy = false }
        do {
            status = "Preparing…"
            let (json, usdz) = try await ScanPayload.build(rooms: rooms, names: names)
            // keep a copy in Files > homemesh > Scans, so a failed upload loses nothing
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Scans", isDirectory: true)
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try json.write(to: docs.appendingPathComponent("\(stamp).json"))
            status = "Uploading…"
            let id = try await model.uploader(house: houseId)
                .upload(json: json, usdz: usdz, name: scanName.trimmed.isEmpty ? Naming.defaultScanName() : scanName.trimmed, level: level)
            scanName = ""
            resetScan()
            try? FileManager.default.removeItem(at: docs.appendingPathComponent("\(stamp).json"))  // uploaded: keep nothing on the device
            status = "Uploaded (scan \(id.prefix(8))). The rooms are named; place them on the plan next."
            onUploaded()
        } catch {
            status = "Upload failed: \(error.localizedDescription). The scan is still here; try again."
        }
    }
}

/// Building the upload (combining rooms, encoding, USDZ export) is heavy: it runs off the main actor so the UI
/// and the camera view never wait for it. Logged and signposted for Console (subsystem `homemesh.capture`).
enum ScanPayload {
    /// The capture JSON in the app's wrapper, each room carrying its name, and the exported USDZ.
    /// One room: that room. Several: combined by StructureBuilder so all share one coordinate frame.
    nonisolated static func build(rooms: [CapturedRoom], names: [String: String]) async throws -> (json: Data, usdz: URL) {
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
            let wrapper: [String: Any] = ["format": "homemesh-capture-1", "rooms": roomObjects]
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
