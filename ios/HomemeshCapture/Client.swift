import Foundation

/// JSON calls to the backend through the door, with the Pocket ID id token as the bearer token.
/// (Uploads of scans stay in `Uploader`.)
struct Client: Sendable {
    let server: String
    let token: @Sendable () async throws -> String

    private func url(_ path: String) throws -> URL {
        var base = server.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        guard let u = URL(string: base + path), u.scheme == "https" else {
            throw Uploader.Failure(message: "The server address must start with https://")
        }
        return u
    }

    func call(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 60) async throws -> Data {
        var r = URLRequest(url: try url(path))
        r.httpMethod = method
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = timeout
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw Uploader.Failure(message: "No response") }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403:
            Auth.signOut()
            throw Uploader.Failure(message: "The door did not accept the sign-in; try again to sign in")
        case 409:
            throw Uploader.Failure(message: "Changed elsewhere; reload and try again")
        default:
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String ?? ""
            throw Uploader.Failure(message: "Server said \(http.statusCode) \(detail)")
        }
    }

    func get<T: Decodable & Sendable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        try decode(try await call("GET", path))
    }

    func send<B: Encodable & Sendable, T: Decodable & Sendable>(_ method: String, _ path: String, _ body: B, as type: T.Type = T.self) async throws -> T {
        try decode(try await call(method, path, body: try JSONEncoder().encode(body)))
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw Uploader.Failure(message: "Unexpected answer from the server")
        }
    }

    // MARK: the calls the app makes

    func houses() async throws -> [HouseSummary] { try await get("/api/houses/summary") }

    func createHouse(id: String, name: String) async throws -> HouseLite { try await send("POST", "/api/houses", NewHouseBody(id: id, name: name)) }

    func addLevel(house: String, name: String, below: Bool = false) async throws -> HouseLite {
        try await send("POST", "/api/houses/\(house)/levels", NewLevelBody(name: name, below: below))
    }

    /// Reorders the floors (bottom to top); the server re-derives elevations from the order.
    func orderLevels(house: String, order: [String], belowGround: [String]) async throws -> HouseLite {
        try await send("PUT", "/api/houses/\(house)/levels/order", LevelOrderBody(order: order, below_ground: belowGround))
    }

    /// Which two floors the staircase in a scan joins (nil clears it); applied when the scan is placed.
    func setCaptureStair(house: String, blob: String, from: String?, to: String?) async throws -> CaptureMeta {
        try await send("PUT", "/api/houses/\(house)/captures/\(blob)/stair", StairFloorsBody(from_level: from, to_level: to))
    }

    /// The doors of a scan (in its own frame) with where each was said to lead, and its walls.
    func doors(house: String, blob: String) async throws -> ScanDoorsInfo { try await get("/api/houses/\(house)/captures/\(blob)/doors") }

    func setDoorLabels(house: String, blob: String, labels: [String: String]) async throws -> CaptureMeta {
        try await send("PUT", "/api/houses/\(house)/captures/\(blob)/doors", DoorLabelsBody(labels: labels))
    }

    func captures(house: String) async throws -> [CaptureMeta] { try await get("/api/houses/\(house)/captures") }

    /// Imports the scan at `transform` and returns the resulting house as JSON (a preview: nothing is stored yet).
    func importScan(house: String, blob: String, level: String, transform: Transform2D) async throws -> (house: Data, stairs: [StairSuggestion]) {
        let body = try JSONEncoder().encode(["transform": transform])
        let data = try await call("POST", "/api/houses/\(house)/captures/\(blob)/import?level=\(level)", body: body)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let h = obj["house"],
              JSONSerialization.isValidJSONObject(h) else { throw Uploader.Failure(message: "Unexpected answer from the server") }
        var stairs: [StairSuggestion] = []
        if let rep = obj["report"] as? [String: Any], let raw = rep["stairs"], JSONSerialization.isValidJSONObject(raw) {
            stairs = (try? JSONDecoder().decode([StairSuggestion].self, from: JSONSerialization.data(withJSONObject: raw))) ?? []
        }
        return (try JSONSerialization.data(withJSONObject: h), stairs)
    }

    /// Saves a staircase between two floors (a new revision of the house).
    func addStair(house: String, from: String, to: String, polygon: [Pt]) async throws {
        let _: HouseLite = try await send("POST", "/api/houses/\(house)/stairs", NewStairBody(from_level: from, to_level: to, polygon: polygon))
    }

    /// Saves a whole house as the next revision (409 if someone changed it meanwhile).
    func saveHouse(house: String, json: Data, expectRevision: Int) async throws {
        _ = try await call("PUT", "/api/houses/\(house)?expect_revision=\(expectRevision)", body: json)
    }

    func rooms(house: String) async throws -> [RoomItem] { try await get("/api/houses/\(house)/rooms") }

    /// Undo: the house as it was at `revision`, saved as the next revision (history is kept).
    func restore(house: String, revision: Int, expect: Int) async throws {
        _ = try await call("POST", "/api/houses/\(house)/revisions/\(revision)/restore?expect_revision=\(expect)")
    }

    func nameRooms(house: String, blob: String, names: [String], descriptions: [String]? = nil) async throws -> CaptureMeta {
        try await send("PUT", "/api/houses/\(house)/captures/\(blob)/rooms", RoomNamesBody(names: names, descriptions: descriptions))
    }

    /// Moves a scan (all its rooms; and its walls if it is on the plan) to another floor.
    func moveScan(house: String, blob: String, level: String) async throws -> CaptureMeta {
        try await send("PUT", "/api/houses/\(house)/captures/\(blob)/level", LevelBody(level: level))
    }

    /// A stored file (the scan's USDZ) as a local temporary file.
    func download(house: String, blob: String, suffix: String) async throws -> URL {
        let data = try await call("GET", "/api/houses/\(house)/blobs/\(blob)", timeout: 600)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(blob.prefix(12)).\(suffix)")
        try data.write(to: url)
        return url
    }
}
