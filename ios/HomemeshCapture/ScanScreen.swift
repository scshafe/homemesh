import RoomPlan
import SwiftUI

/// Scan one or more rooms, name each right after it is scanned, then upload with the names.
struct ScanScreen: View {
    let houseId: String
    let onUploaded: () -> Void
    @EnvironmentObject var model: AppModel
    @State private var controller = ScanController()
    @State private var scanName = ""
    @State private var rooms: [CapturedRoom] = []
    @State private var names: [String: String] = [:]   // by the room's identifier
    @State private var phase = ScanController.Phase.idle
    @State private var busy = false
    @State private var status = ""
    @State private var naming: CapturedRoom?
    @State private var roomName = ""

    var body: some View {
        VStack(spacing: 0) {
        ScanView(controller: controller).frame(height: 360).clipped()
        Form {
            Section("Scan") {
                TextField("Name of this scan (for example Ground floor)", text: $scanName)
                Button(phase == .running ? "Done with this room" : phase == .stopping ? "Processing the room…" : "Start scanning a room") { toggle() }
                    .disabled(!RoomCaptureSession.isSupported || phase == .stopping)
                if !RoomCaptureSession.isSupported { Text("This device has no LiDAR scanner.").foregroundStyle(.red) }
                ForEach(rooms.indices, id: \.self) { i in
                    Text(names[rooms[i].identifier.uuidString].flatMap { $0.isEmpty ? nil : $0 } ?? "Room \(i + 1) (unnamed)")
                }
                Button("Upload to \(model.summary(houseId)?.name ?? houseId)") { Task { await upload() } }
                    .disabled(rooms.isEmpty || busy)
                if !rooms.isEmpty { Button("Discard scan", role: .destructive) { rooms = []; names = [:]; status = "" } }
            }
            if !status.isEmpty { Section { Text(status) } }
        }
        }
        .navigationTitle("Scan")
        .alert("Name this room", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("For example Kitchen", text: $roomName)
            Button("Save") { if let r = naming { names[r.identifier.uuidString] = roomName.trimmed } }
            Button("Skip", role: .cancel) {}
        } message: {
            Text(Naming.suggestions.prefix(6).joined(separator: ", "))
        }
        .onAppear {
            controller.onProcessed = { room in
                rooms.append(room)
                roomName = ""
                naming = room
                status = "Room added."
            }
            controller.onError = { msg in status = "Scan failed: \(msg)" }
            controller.onPhase = { phase = $0 }
        }
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
                .upload(json: json, usdz: usdz, name: scanName.trimmed.isEmpty ? Naming.defaultScanName() : scanName.trimmed)
            rooms = []
            names = [:]
            scanName = ""
            try? FileManager.default.removeItem(at: docs.appendingPathComponent("\(stamp).json"))  // uploaded: keep nothing on the device
            status = "Uploaded (scan \(id.prefix(8))). The rooms are named; place them on the plan in homemesh."
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
            for i in roomObjects.indices {
                if let id = roomObjects[i]["identifier"] as? String, let n = names[id], !n.isEmpty { roomObjects[i]["name"] = n }
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
