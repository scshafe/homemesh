import RoomPlan
import SwiftUI

/// Deliberately small: set the server, house and sign-in once; scan one or more rooms; upload.
/// No editing, no viewing of the house, no accounts, no analytics.
struct ContentView: View {
    @State private var server = Settings.server
    @State private var house = Settings.house
    @State private var issuer = Settings.issuer
    @State private var clientId = Settings.clientId
    @State private var name = ""
    @State private var rooms: [CapturedRoom] = []
    @State private var scanning = false
    @State private var status = ""
    @State private var busy = false
    private let controller = ScanController()

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://homemesh.<tailnet>", text: $server).textInputAutocapitalization(.never).keyboardType(.URL)
                    TextField("House id", text: $house).textInputAutocapitalization(.never)
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
                        .disabled(rooms.isEmpty || busy || server.isEmpty || house.isEmpty || issuer.isEmpty || clientId.isEmpty)
                    if !rooms.isEmpty { Button("Discard scan", role: .destructive) { rooms = []; status = "" } }
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
        .onChange(of: server) { Settings.server = server }
        .onChange(of: house) { Settings.house = house }
        .onChange(of: issuer) { Settings.issuer = issuer }
        .onChange(of: clientId) { Settings.clientId = clientId }
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

    private func upload() async {
        busy = true
        defer { busy = false }
        do {
            status = "Preparing…"
            let (json, usdz) = try await payload()
            // keep a copy in Files > homemesh capture > Scans, so a failed upload loses nothing
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Scans", isDirectory: true)
            try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try json.write(to: docs.appendingPathComponent("\(stamp).json"))
            status = "Uploading…"
            let auth = Auth(issuer: issuer, clientId: clientId)
            _ = try await auth.freshIdToken()  // sign in first, before the long upload
            let id = try await Uploader(server: server, house: house, token: { try await auth.freshIdToken() }).upload(json: json, usdz: usdz, name: name)
            rooms = []
            try? FileManager.default.removeItem(at: docs.appendingPathComponent("\(stamp).json"))  // uploaded: keep nothing on the device
            status = "Uploaded (scan \(id.prefix(8))). Import it in homemesh: Plan editor, Scans."
        } catch {
            status = "Upload failed: \(error.localizedDescription). The scan is still here; try again."
        }
    }
}
