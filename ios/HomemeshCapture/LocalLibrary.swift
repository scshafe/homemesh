import HomemeshCore
import Foundation

/// The houses kept on this phone (docs/design-standalone-app.md): a folder per house under Application Support, behind the same API the
/// server has. Also the demo houses (the synthetic fixtures in the bundle) and copying a house over from the server.
enum LocalLibrary {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("homemesh", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static let api = LocalAPI(root: root)

    /// The synthetic houses that ship in the app: for exploring, and for App Review. Never written to the bundle, copied into the library.
    static let demoFiles = ["one_floor_box", "two_floor_stairwell"]

    /// Copies the demo houses that are not in the library yet; returns the ids added.
    static func addDemoHouses(into api: LocalAPI = LocalLibrary.api, bundle: Bundle = .main) throws -> [String] {
        var added: [String] = []
        for name in demoFiles {
            guard let url = bundle.url(forResource: name, withExtension: "json") else { continue }
            let data = try Data(contentsOf: url)
            guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else { continue }
            if api.houseIds().contains(id) { continue }
            try api.restoreHouse(id: id, house: data, captures: [], blobs: [:])
            added.append(id)
        }
        return added
    }

    struct CopyReport: Sendable {
        var scans: Int
        var files: Int
        var bytes: Int
        /// What differs between the copy and the server's own count of the house: empty when they agree.
        var differences: [String]
    }

    /// Copies house `id` from the server to this phone: the document, every scan's index, and the stored files (scan JSON and USDZ). Then
    /// opens the copy the way the app will and compares what it holds with what the server says it has.
    static func copy(house id: String, from server: Client, into api: LocalAPI = LocalLibrary.api, progress: @Sendable (String) -> Void = { _ in }) async throws -> CopyReport {
        progress("Reading the house")
        let houseData = try await server.call("GET", "/api/houses/\(id)")
        let summary = try await server.houses().first { $0.id == id }
        progress("Reading the scans")
        let capturesData = try await server.call("GET", "/api/houses/\(id)/captures")
        guard let metas = try JSONSerialization.jsonObject(with: capturesData) as? [[String: Any]] else { throw Uploader.Failure(message: "Unexpected answer from the server") }
        var digests: [String] = []
        for m in metas { for key in ["blob", "usdz"] { if let d = m[key] as? String, !d.isEmpty, !digests.contains(d) { digests.append(d) } } }
        var blobs: [String: Data] = [:]
        var bytes = 0
        for (i, d) in digests.enumerated() {
            progress("Copying file \(i + 1) of \(digests.count)")
            let data = try await server.call("GET", "/api/houses/\(id)/blobs/\(d)", timeout: 600)
            blobs[d] = data
            bytes += data.count
        }
        progress("Saving on this phone")
        do { try api.restoreHouse(id: id, house: houseData, captures: try metas.map { try JSONSerialization.data(withJSONObject: $0) }, blobs: blobs) }
        catch let e as APIError { throw Uploader.Failure(message: e.detail) }
        var diffs: [String] = []
        if let s = summary {
            let mine = try api.counts(of: id)
            let theirs: [String: Int] = ["levels": s.levels.count, "walls": s.walls, "rooms": s.rooms, "access_points": s.access_points, "captures": s.captures]
            for (k, v) in theirs.sorted(by: { $0.key < $1.key }) where mine[k] != v { diffs.append("\(k): \(mine[k] ?? -1) here, \(v) on the server") }
            if mine["revision"] != s.revision { diffs.append("revision: \(mine["revision"] ?? -1) here, \(s.revision) on the server") }
        } else { diffs.append("the server did not list this house, so it could not be compared") }
        return CopyReport(scans: metas.count, files: blobs.count, bytes: bytes, differences: diffs)
    }
}
