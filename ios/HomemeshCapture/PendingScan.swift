import Foundation

/// A scan that has not been confirmed by the server yet: Documents/Scans/<id>/{scan.json, scan.usdz, name.txt}.
/// It stays (and shows in the Files app) until an upload succeeded for both parts, so a failed
/// upload is retried without scanning again.
struct PendingScan: Identifiable {
    let id: String
    let name: String
    let dir: URL

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Scans", isDirectory: true)
    }

    static func defaultName(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Scan " + f.string(from: now)
    }

    static func save(name: String, json: Data, usdz: URL?) throws -> PendingScan {
        let id = UUID().uuidString
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("scan.json"))
        try name.write(to: dir.appendingPathComponent("name.txt"), atomically: true, encoding: .utf8)
        if let usdz { try FileManager.default.moveItem(at: usdz, to: dir.appendingPathComponent("scan.usdz")) }
        return PendingScan(id: id, name: name, dir: dir)
    }

    static func all() -> [PendingScan] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in
            guard FileManager.default.fileExists(atPath: d.appendingPathComponent("scan.json").path) else { return nil }
            let name = (try? String(contentsOf: d.appendingPathComponent("name.txt"), encoding: .utf8)) ?? d.lastPathComponent
            return PendingScan(id: d.lastPathComponent, name: name, dir: d)
        }.sorted { $0.name < $1.name }
    }

    func json() throws -> Data { try Data(contentsOf: dir.appendingPathComponent("scan.json")) }

    var usdzURL: URL? {
        let u = dir.appendingPathComponent("scan.usdz")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}
