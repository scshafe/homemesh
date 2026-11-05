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
        let copy: HouseImport
        do { copy = try api.beginImport(id: id, house: houseData) } catch let e as APIError { throw Uploader.Failure(message: e.detail) }
        var bytes = 0
        do {
            for (i, d) in digests.enumerated() {   // one file at a time: a copy never holds every scan in memory
                progress("Copying file \(i + 1) of \(digests.count)")
                let data = try await server.call("GET", "/api/houses/\(id)/blobs/\(d)", timeout: 600)
                try copy.addFile(d, data)
                bytes += data.count
            }
            progress("Saving on this phone")
            for m in metas { try copy.addScan(try JSONSerialization.data(withJSONObject: m)) }
            try copy.finish()
        } catch let e as APIError {
            copy.abort()
            throw Uploader.Failure(message: e.detail)
        } catch {
            copy.abort()
            throw error
        }
        var diffs: [String] = []
        if let s = summary {
            let mine = try api.counts(of: id)
            let theirs: [String: Int] = ["levels": s.levels.count, "walls": s.walls, "rooms": s.rooms, "access_points": s.access_points, "captures": s.captures]
            for (k, v) in theirs.sorted(by: { $0.key < $1.key }) where mine[k] != v { diffs.append("\(k): \(mine[k] ?? -1) here, \(v) on the server") }
            if mine["revision"] != s.revision { diffs.append("revision: \(mine["revision"] ?? -1) here, \(s.revision) on the server") }
        } else { diffs.append("the server did not list this house, so it could not be compared") }
        return CopyReport(scans: metas.count, files: digests.count, bytes: bytes, differences: diffs)
    }

    /// A summary of a package written or read, in words.
    static func describe(_ r: HousePackage.Report) -> String {
        "\(r.files) file(s), " + String(format: "%.1f MB", Double(r.bytes) / 1_048_576)
    }

    /// Writes house `id` as one file in the temporary folder (to be moved to Files), reads it back and checks it.
    static func export(house id: String, api: LocalAPI = LocalLibrary.api) async throws -> (url: URL, report: HousePackage.Report) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).homemesh")
        do { return (url, try await Task.detached { try HousePackage.export(house: id, from: api, to: url) }.value) }
        catch let e as APIError { throw Uploader.Failure(message: e.detail) }
    }

    /// Copies the house in a package file into the library (never over a house with the same id) and compares it with what the file says.
    static func importPackage(from url: URL, api: LocalAPI = LocalLibrary.api) async throws -> HousePackage.Report {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { return try await Task.detached { try HousePackage.importPackage(from: url, into: api) }.value }
        catch let e as APIError { throw Uploader.Failure(message: e.detail) }
    }
}
