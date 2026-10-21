import RoomPlan
import SwiftUI

/// Deliberately small: set the server, house and sign-in once; scan one or more rooms; upload.
/// No editing, no viewing of the house, no accounts, no analytics.
struct ContentView: View {
    @State private var server = Settings.server.trimmed
    @State private var house = Settings.house.trimmed
    @State private var issuer = Settings.issuer.trimmed
    @State private var clientId = Settings.clientId.trimmed
    @State private var name = ""
    @State private var rooms: [CapturedRoom] = []
    @State private var scanning = false
    @State private var status = ""
    @State private var busy = false
    @State private var houses: [String] = []
    @State private var pending: [PendingScan] = PendingScan.all()
    private let controller = ScanController()

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://homemesh.<tailnet>", text: $server).textInputAutocapitalization(.never).keyboardType(.URL)
                    if houses.isEmpty {
                        TextField("House id", text: $house).textInputAutocapitalization(.never)
                    } else {
                        Picker("House", selection: $house) {
                            ForEach(houses, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Button("List the houses on the server") { Task { await loadHouses() } }
                        .disabled(busy || server.trimmed.isEmpty || issuer.trimmed.isEmpty || clientId.trimmed.isEmpty)
                    TextField("Pocket ID address (https://…)", text: $issuer).textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("Capture client id", text: $clientId).textInputAutocapitalization(.never)
                    Button("Sign out") { Auth.signOut(); status = "Signed out." }
                }
                Section("Scan") {
                    TextField("Name of this scan (for example Ground floor)", text: $name)
                    Button(scanning ? "Done with this room" : "Start scanning a room") { toggle() }
                        .disabled(!RoomCaptureSession.isSupported)
                    if !RoomCaptureSession.isSupported { Text("This device has no LiDAR scanner.").foregroundStyle(.red) }
                    Text("\(rooms.count) room(s) captured")
                    Button("Upload", action: { Task { await upload() } })
                        .disabled(rooms.isEmpty || busy || server.trimmed.isEmpty || house.trimmed.isEmpty || issuer.trimmed.isEmpty || clientId.trimmed.isEmpty)
                    if !rooms.isEmpty { Button("Discard scan", role: .destructive) { rooms = []; status = "" } }
                }
                if !pending.isEmpty {
                    Section("Waiting to upload (kept on this phone until the server confirms)") {
                        ForEach(pending) { p in
                            HStack {
                                Text(p.name)
                                Spacer()
                                Button("Upload") { Task { await send(p) } }.disabled(busy || house.trimmed.isEmpty)
                                Button("Delete", role: .destructive) { p.remove(); pending = PendingScan.all() }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
                if !status.isEmpty { Section { Text(status) } }
            }
            .navigationTitle("homemesh capture")
            .fullScreenCover(isPresented: $scanning) {
                ScanView(controller: controller).ignoresSafeArea().overlay(alignment: .bottom) {
                    Button("Done") { controller.stop() }.buttonStyle(.borderedProminent).padding()
                }
            }
        }
        .onChange(of: server) { Settings.server = server.trimmed }
        .onChange(of: house) { Settings.house = house.trimmed }
        .onChange(of: issuer) { Settings.issuer = issuer.trimmed }
        .onChange(of: clientId) { Settings.clientId = clientId.trimmed }
        .onAppear {
            controller.onProcessed = { room in rooms.append(room); scanning = false; status = "Room added." }
            controller.onError = { msg in scanning = false; status = "Scan failed: \(msg)" }
        }
    }

    private func toggle() {
        scanning = true
        DispatchQueue.main.async { controller.start() }
    }

    /// One room: its JSON. Several: combined by StructureBuilder so all share one coordinate frame.
    private func payload() async throws -> (json: Data, usdz: URL?) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        let usdz = tmp.appendingPathComponent("scan.usdz")
        if rooms.count == 1 {
            let json = try enc.encode(rooms[0])
            try rooms[0].export(to: usdz)
            return (json, usdz)
        }
        let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
        let json = try enc.encode(structure)
        try structure.export(to: usdz)
        return (json, usdz)
    }

    private func loadHouses() async {
        busy = true
        defer { busy = false }
        do {
            let auth = Auth(issuer: issuer.trimmed, clientId: clientId.trimmed)
            let list = try await Uploader(server: server, house: house, token: { try await auth.freshIdToken() }).houses()
            houses = list
            if !list.contains(house.trimmed) { house = list.first ?? "" }
            status = list.isEmpty ? "The server has no houses yet: create one in homemesh first." : "\(list.count) house(s) on the server."
        } catch {
            status = "Could not list the houses: \(error.localizedDescription)"
        }
    }

    /// Keep the scan on the phone first, then upload it; it is removed only after the server confirmed both parts.
    private func upload() async {
        busy = true
        defer { busy = false }
        do {
            status = "Preparing…"
            let (json, usdz) = try await payload()
            let label = name.trimmed.isEmpty ? PendingScan.defaultName() : name.trimmed
            let saved = try PendingScan.save(name: label, json: json, usdz: usdz)
            rooms = []
            name = ""
            pending = PendingScan.all()
            await send(saved, alreadyBusy: true)
        } catch {
            status = "Could not prepare the scan: \(error.localizedDescription). The rooms are still here."
        }
    }

    private func send(_ p: PendingScan, alreadyBusy: Bool = false) async {
        if !alreadyBusy { busy = true }
        defer { if !alreadyBusy { busy = false } }
        status = "Uploading…"
        do {
            let auth = Auth(issuer: issuer.trimmed, clientId: clientId.trimmed)
            let id = try await Uploader(server: server, house: house, token: { try await auth.freshIdToken() })
                .upload(json: try p.json(), usdz: p.usdzURL, name: p.name)
            p.remove()
            pending = PendingScan.all()
            status = "Uploaded to \"\(house.trimmed)\" (scan \(id.prefix(8))); the server confirmed the scan and its 3D model. Import it in homemesh: Plan editor, Scans."
        } catch {
            pending = PendingScan.all()
            status = "NOT uploaded: \(error.localizedDescription). The scan is kept on this phone under \"Waiting to upload\"."
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
