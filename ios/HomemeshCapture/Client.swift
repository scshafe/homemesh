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

    func call(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        var r = URLRequest(url: try url(path))
        r.httpMethod = method
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 60
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

    func addLevel(house: String, name: String) async throws -> HouseLite { try await send("POST", "/api/houses/\(house)/levels", NewLevelBody(name: name)) }

    func captures(house: String) async throws -> [CaptureMeta] { try await get("/api/houses/\(house)/captures") }

    func nameRooms(house: String, blob: String, names: [String]) async throws -> CaptureMeta {
        try await send("PUT", "/api/houses/\(house)/captures/\(blob)/rooms", RoomNamesBody(names: names))
    }
}
