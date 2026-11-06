import HomemeshCore
import Foundation

/// Scans an earlier build saved on the phone while they waited for the server: everything a save needs, on disk. Nothing writes here
/// any more; at launch each one whose house is on this phone is saved into it and removed, and the rest stay (the folder shows in the Files app).
/// Documents/Uploads/<id>/{meta.json, scan.json, scan.usdz}
struct PendingUpload: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let house: String
    let name: String
    let level: String
    let replaces: String
    let created: Date
    var stairFrom: String? = nil     // the floors of the staircase the scan holds
    var stairTo: String? = nil
    var purpose: String? = nil       // "stairs" for a scan made for a staircase
}

enum LeftoverScans {
    nonisolated(unsafe) static var root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Uploads", isDirectory: true)

    static func all(house: String? = nil) -> [PendingUpload] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dirs.compactMap { try? dec.decode(PendingUpload.self, from: Data(contentsOf: $0.appendingPathComponent("meta.json"))) }
            .filter { house == nil || $0.house == house }
            .sorted { $0.created < $1.created }
    }

    private static func dir(_ p: PendingUpload) -> URL { root.appendingPathComponent(p.id, isDirectory: true) }

    static func json(_ p: PendingUpload) throws -> Data { try Data(contentsOf: dir(p).appendingPathComponent("scan.json")) }

    static func usdz(_ p: PendingUpload) -> URL? {
        let u = dir(p).appendingPathComponent("scan.usdz")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func remove(_ p: PendingUpload) { try? FileManager.default.removeItem(at: dir(p)) }

    /// Saves every leftover scan whose house is in the library; a scan leaves the folder only once it is saved. Returns how many were saved.
    @discardableResult
    static func adopt(into api: LocalAPI) async -> Int {
        var n = 0
        let houses = api.houseIds()
        for p in all() where houses.contains(p.house) {
            do {
                _ = try await Uploader(house: p.house, local: api).upload(json: try json(p), usdz: usdz(p), name: p.name, level: p.level, replaces: p.replaces, purpose: p.purpose ?? "", stairFrom: p.stairFrom ?? "", stairTo: p.stairTo ?? "")
                remove(p)
                n += 1
            } catch { Diagnostics.event("leftover-scan", ["ok": false]) }
        }
        return n
    }
}
