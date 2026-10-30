import Foundation

/// A scan waiting for the server: everything an upload needs, on disk, so it survives a failed upload, no signal or the app
/// being closed. It is removed only after the server answered 2xx for both the scan and its 3D model.
/// Documents/Uploads/<id>/{meta.json, scan.json, scan.usdz}; the folder shows in the Files app.
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

enum UploadQueue {
    nonisolated(unsafe) static var root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Uploads", isDirectory: true)

    static func enqueue(house: String, name: String, level: String, replaces: String, json: Data, usdz: URL?,
                        stair: (from: String, to: String)? = nil, purpose: String? = nil) throws -> PendingUpload {
        let item = PendingUpload(id: UUID().uuidString, house: house, name: name, level: level, replaces: replaces, created: Date(),
                                 stairFrom: stair?.from, stairTo: stair?.to, purpose: purpose)
        let dir = root.appendingPathComponent(item.id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("scan.json"))
        if let usdz { try FileManager.default.moveItem(at: usdz, to: dir.appendingPathComponent("scan.usdz")) }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(item).write(to: dir.appendingPathComponent("meta.json"))   // last: a folder without meta is not a queued upload
        return item
    }

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

    /// Uploads one queued scan; it leaves the queue only when the server confirmed it.
    static func send(_ p: PendingUpload, with uploader: Uploader, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let id = try await uploader.upload(json: try json(p), usdz: usdz(p), name: p.name, level: p.level, replaces: p.replaces, purpose: p.purpose ?? "", stairFrom: p.stairFrom ?? "", stairTo: p.stairTo ?? "", progress: progress)
        remove(p)
        return id
    }
}
