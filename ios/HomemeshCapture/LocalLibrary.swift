import HomemeshCore
import Foundation

/// The houses kept on this phone (docs/design-standalone-app.md): a folder per house under Application Support, behind the same API the
/// server has. Also the demo houses (the synthetic fixtures in the bundle) and files in and out (export and import).
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
