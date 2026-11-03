import Foundation

// Stored scans (a port of homemesh/captures.py): the capture JSON and its USDZ are blobs, with a small index per scan.
//   blobs/<sha256>             the JSON as uploaded, and the USDZ
//   captures/<sha256>.json     {blob, name, at, counts, usdz, rooms, descriptions, level, replaces, baro, stairs_found, stair, purpose, stories, room_levels, door_labels, doors}
// The same layout the server wrote, so a house folder from the server opens as it is.

public struct CaptureError: Error, CustomStringConvertible {
    public var message: String
    public init(_ m: String) { message = m }
    public var description: String { message }
}

public enum Captures {
    public static let maxJSON = 30 * 1024 * 1024
    public static let maxUSDZ = 200 * 1024 * 1024

    static func dir(_ s: HouseStore) -> URL { s.root.appendingPathComponent("captures") }
    static func file(_ s: HouseStore, _ digest: String) -> URL { dir(s).appendingPathComponent("\(digest).json") }

    static func writeMeta(_ s: HouseStore, _ meta: JObject) throws {
        try FileManager.default.createDirectory(at: dir(s), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        try data.write(to: file(s, meta["blob"] as! String), options: .atomic)
    }

    static func validDigest(_ d: String) -> Bool { d.count == 64 && d.allSatisfy { "0123456789abcdef".contains($0) } }

    static func summarise(_ data: JObject) throws -> [String: Int] {
        var counts = ["rooms": 0, "walls": 0, "doors": 0, "windows": 0, "openings": 0]
        do {
            let rs = try ScanImport.rooms(data)
            counts["rooms"] = rs.count
            for r in rs { for s in try ScanImport.surfaces(r) { counts[s.kind + "s", default: 0] += 1 } }
        } catch let e as ImportError { throw CaptureError(e.message) }
        if counts["walls"] == 0 { throw CaptureError("the capture has no walls") }
        return counts
    }

    static func baroOf(_ data: JObject) -> JObject? {
        guard let b = data["baro"] as? JObject, let s = b["session"], let rel = b["rel_m"] as? NSNumber, let kpa = b["kpa"] as? NSNumber, let at = b["at"] as? NSNumber else { return nil }
        return ["session": String(String(describing: s).prefix(64)), "rel_m": rel.doubleValue, "kpa": kpa.doubleValue, "at": at.doubleValue]
    }

    static func stairsFound(_ data: JObject) throws -> [JObject] {
        try ScanImport.stairFootprints(data).map { ["rise": $0.rise, "width": $0.width, "run": $0.run] }
    }

    static func roomLevelsOf(_ data: JObject) -> [Any]? {
        let n = (data["rooms"] as? [Any])?.count ?? 1
        guard let rl = data["room_levels"] as? [Any], rl.count == n, rl.allSatisfy({ $0 is NSNull || $0 is String }) else { return nil }
        return rl.map { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } as Any? ?? NSNull() }
    }

    static func doorLabelsOf(_ data: JObject) -> [String: String] {
        guard let raw = data["door_labels"] as? JObject else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in raw { if let s = v as? String, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out[String(k.prefix(8))] = String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) } }
        return out
    }

    static func storiesOf(_ data: JObject) throws -> [Any] {
        try ScanImport.rooms(data).map { ($0["story"] as? Int).map { $0 as Any } ?? NSNull() }
    }

    static func doorSummary(_ data: JObject) throws -> [JObject] {
        try ScanImport.scanDoors(data).enumerated().map { ["id": $1.id, "kind": $1.kind, "room": $1.room, "number": $0 + 1] }
    }

    public static func saveCapture(_ s: HouseStore, raw: Data, name: String = "", level: String = "", replaces: String = "", purpose: String = "", stair: JObject? = nil, now: Double) throws -> JObject {
        if raw.count > maxJSON { throw CaptureError("capture too large") }
        guard let any = try? JSONSerialization.jsonObject(with: raw) else { throw CaptureError("not JSON") }
        guard let data = any as? JObject else { throw CaptureError("not a capture") }
        let counts = try summarise(data)
        let digest = try s.putBlob(raw)
        var meta: JObject = ["blob": digest, "name": String(name.prefix(80)), "at": Int(now), "counts": counts, "usdz": NSNull(), "rooms": try ScanImport.roomNames(data),
                             "level": level.isEmpty ? NSNull() : level, "replaces": replaces.isEmpty ? NSNull() : replaces, "baro": baroOf(data) ?? NSNull(),
                             "stairs_found": try stairsFound(data), "stair": stair ?? NSNull(), "purpose": purpose.isEmpty ? NSNull() : purpose,
                             "stories": try storiesOf(data), "room_levels": roomLevelsOf(data) ?? NSNull(), "door_labels": doorLabelsOf(data), "doors": try doorSummary(data)]
        if let old = try? JSONSerialization.jsonObject(with: Data(contentsOf: file(s, digest))) as? JObject {   // the same scan uploaded twice: keep what is known
            func has(_ v: Any?) -> Bool { !(v == nil || v is NSNull) }
            meta["usdz"] = old["usdz"] ?? NSNull()
            meta["name"] = (old["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? meta["name"]!
            meta["at"] = old["at"]
            if let r = old["rooms"] as? [String], r.contains(where: { !$0.isEmpty }) { meta["rooms"] = r }
            meta["level"] = level.isEmpty ? (old["level"] ?? NSNull()) : level
            meta["replaces"] = replaces.isEmpty ? (old["replaces"] ?? NSNull()) : replaces
            if !has(meta["baro"]) { meta["baro"] = old["baro"] ?? NSNull() }
            if stair == nil { meta["stair"] = old["stair"] ?? NSNull() }
            if purpose.isEmpty { meta["purpose"] = old["purpose"] ?? NSNull() }
            if !has(meta["room_levels"]) { meta["room_levels"] = old["room_levels"] ?? NSNull() }
            if (meta["door_labels"] as? [String: String])?.isEmpty ?? true { meta["door_labels"] = old["door_labels"] ?? [String: String]() }
            if let d = old["descriptions"] { meta["descriptions"] = d }
        }
        try writeMeta(s, meta)
        return meta
    }

    public static func meta(_ s: HouseStore, _ digest: String) throws -> JObject {
        if !validDigest(digest) { throw CaptureError("invalid capture id") }
        guard let d = try? Data(contentsOf: file(s, digest)), var m = try JSONSerialization.jsonObject(with: d) as? JObject else { throw CaptureError("no such capture") }
        if m["stairs_found"] == nil || m["doors"] == nil {   // stored before staircases and doors were summarised: derive them once
            if let raw = try? s.blob(m["blob"] as! String), let data = try? JSONSerialization.jsonObject(with: raw) as? JObject {
                m["stairs_found"] = (try? stairsFound(data)) ?? [JObject]()
                m["doors"] = (try? doorSummary(data)) ?? [JObject]()
                if (m["rooms"] as? [String])?.isEmpty ?? true { m["rooms"] = (try? ScanImport.roomNames(data)) ?? [String]() }
            } else { if m["stairs_found"] == nil { m["stairs_found"] = [JObject]() }; if m["doors"] == nil { m["doors"] = [JObject]() } }
            try writeMeta(s, m)
        }
        return m
    }

    public static func list(_ s: HouseStore) -> [JObject] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir(s).path)) ?? []
        let metas = names.filter { $0.hasSuffix(".json") }.compactMap { try? meta(s, String($0.dropLast(5))) }
        return metas.sorted { ($0["at"] as? Double ?? Double($0["at"] as? Int ?? 0)) > ($1["at"] as? Double ?? Double($1["at"] as? Int ?? 0)) }
    }

    public static func load(_ s: HouseStore, _ digest: String) throws -> JObject {
        _ = try meta(s, digest)
        guard let o = try JSONSerialization.jsonObject(with: try s.blob(digest)) as? JObject else { throw CaptureError("not a capture") }
        return o
    }

    public static func attachUSDZ(_ s: HouseStore, _ digest: String, raw: Data) throws -> JObject {
        var m = try meta(s, digest)
        if raw.count > maxUSDZ { throw CaptureError("USDZ too large") }
        if raw.prefix(2) != Data([0x50, 0x4b]) { throw CaptureError("not a USDZ (zip) file") }
        m["usdz"] = try s.putBlob(raw)
        try writeMeta(s, m)
        return m
    }

    public static func setRoomNames(_ s: HouseStore, _ digest: String, names: [String], descriptions: [String]?) throws -> JObject {
        var m = try meta(s, digest)
        let n = (m["counts"] as? [String: Int])?["rooms"] ?? 0
        if names.count != n || (descriptions != nil && descriptions!.count != n) { throw CaptureError("the capture has \(n) room(s); give one name\(descriptions != nil ? " and one description" : "") for each") }
        m["rooms"] = names.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
        if let d = descriptions { m["descriptions"] = d.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)) } }
        try writeMeta(s, m)
        return m
    }

    public static func setLevel(_ s: HouseStore, _ digest: String, _ level: String) throws -> JObject {
        var m = try meta(s, digest)
        m["level"] = level
        m["room_levels"] = NSNull()
        try writeMeta(s, m)
        return m
    }

    public static func setStair(_ s: HouseStore, _ digest: String, _ stair: JObject?) throws -> JObject {
        var m = try meta(s, digest)
        m["stair"] = stair ?? NSNull()
        try writeMeta(s, m)
        return m
    }

    public static func setDoorLabels(_ s: HouseStore, _ digest: String, _ labels: [String: String]) throws -> JObject {
        var m = try meta(s, digest)
        let ids = Set((m["doors"] as? [JObject] ?? []).compactMap { $0["id"] as? String })
        var out: [String: String] = [:]
        for (k, v) in labels where ids.contains(k) { let t = v.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { out[k] = String(t.prefix(80)) } }
        m["door_labels"] = out
        try writeMeta(s, m)
        return m
    }
}
