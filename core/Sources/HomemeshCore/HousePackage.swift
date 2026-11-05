import Foundation

/// A house as one file, for the Files app and for keeping a second copy: the current document, the index of every scan, and every stored
/// file (scan JSON and USDZ), with a manifest at the end that lists each file's size and SHA-256 and the counts the house had.
///
/// Layout: the magic `HOMEMESHPKG1\n`; then entries, each a 4-byte name length, the name, an 8-byte size and the bytes (big endian);
/// the last entry is `manifest.json`, followed by the magic `HMPKGEND`. A file cut short therefore has no manifest and is refused.
/// Entry names: `house.json`, `captures/<digest>.json`, `blobs/<digest>`. The revision history is not part of the package.
public enum HousePackage {
    public struct Manifest: Codable, Equatable, Sendable {
        public struct File: Codable, Equatable, Sendable { public var name: String; public var size: Int; public var sha256: String }
        public var format: Int
        public var id: String
        public var counts: [String: Int]
        public var files: [File]
    }

    static let magic = Data("HOMEMESHPKG1\n".utf8)
    static let end = Data("HMPKGEND".utf8)
    static let manifestName = "manifest.json"

    public struct Report: Sendable {
        public var id: String
        public var files: Int
        public var bytes: Int
        /// What differs between the house as it is (or was) and the package: empty when they agree.
        public var differences: [String]
    }

    // MARK: writing

    private static func be(_ v: UInt64, bytes n: Int) -> Data { Data((0..<n).reversed().map { UInt8((v >> (UInt64($0) * 8)) & 0xff) }) }

    private static func put(_ h: FileHandle, _ name: String, _ data: Data) throws {
        let n = Data(name.utf8)
        try h.write(contentsOf: be(UInt64(n.count), bytes: 4) + n + be(UInt64(data.count), bytes: 8))
        try h.write(contentsOf: data)
    }

    /// Writes house `id` of the library to `url` (replacing a file there), then reads the file back and checks it. Returns what it holds.
    @discardableResult
    public static func export(house id: String, from api: LocalAPI, to url: URL) throws -> Report {
        let (store, house) = try api.get(id)
        let counts = try api.counts(of: id)
        let fm = FileManager.default
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
        try? fm.removeItem(at: tmp)
        guard fm.createFile(atPath: tmp.path, contents: nil) else { throw APIError(500, "cannot write \(url.lastPathComponent)") }
        var files: [Manifest.File] = []
        do {
            let h = try FileHandle(forWritingTo: tmp)
            defer { try? h.close() }
            try h.write(contentsOf: magic)
            func add(_ name: String, _ data: Data) throws {
                try put(h, name, data)
                files.append(.init(name: name, size: data.count, sha256: SHA256.hex(data)))
            }
            try add("house.json", try house.encoded())
            var done = Set<String>()
            for meta in Captures.list(store) {
                guard let digest = meta["blob"] as? String, Captures.validDigest(digest) else { throw APIError(422, "a scan has no stored file") }
                try add("captures/\(digest).json", try Data(contentsOf: Captures.file(store, digest)))
                for key in ["blob", "usdz"] {
                    guard let d = meta[key] as? String, !d.isEmpty, done.insert(d).inserted else { continue }
                    do { try add("blobs/\(d)", try store.blob(d)) } catch { throw APIError(422, "a file the house refers to is missing (\(d.prefix(8)))") }
                }
            }
            let manifest = Manifest(format: 1, id: id, counts: counts, files: files)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try put(h, manifestName, try enc.encode(manifest))
            try h.write(contentsOf: end)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: tmp, to: url)
        let back = try verify(url)
        var diffs = back.differences
        if back.id != id { diffs.append("id: \(back.id) in the file, \(id) in the library") }
        return Report(id: id, files: back.files, bytes: back.bytes, differences: diffs)
    }

    // MARK: reading

    private static func take(_ h: FileHandle, _ n: Int) throws -> Data {
        if n == 0 { return Data() }
        var out = Data()
        while out.count < n {
            guard let d = try h.read(upToCount: min(n - out.count, 1 << 22)), !d.isEmpty else { throw APIError(422, "the file ends too soon: it is not complete") }
            out.append(d)
        }
        return out
    }

    private static func int(_ d: Data) -> Int { d.reduce(0) { $0 << 8 | Int($1) } }

    /// Reads every entry in order, handing each to `each`. Checks the magic, the end, and the manifest against what was read.
    /// Blob entries are only hashed when `verifyBlobs` (the import path stores them under their digest, which checks them).
    static func read(_ url: URL, verifyBlobs: Bool, each: (String, Data) throws -> Void) throws -> Manifest {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw APIError(422, "the file cannot be opened") }
        defer { try? h.close() }
        guard try take(h, magic.count) == magic else { throw APIError(422, "this is not a homemesh house file") }
        var seen: [String: (size: Int, sha: String?)] = [:]
        var manifest: Manifest?
        while manifest == nil {
            let nameLen = int(try take(h, 4))
            guard nameLen > 0, nameLen < 512, let name = String(data: try take(h, nameLen), encoding: .utf8) else { throw APIError(422, "the file is damaged") }
            let size = int(try take(h, 8))
            let data = try take(h, size)
            if name == manifestName {
                do { manifest = try JSONDecoder().decode(Manifest.self, from: data) } catch { throw APIError(422, "the file's manifest does not read") }
            } else {
                guard !name.contains(".."), seen[name] == nil else { throw APIError(422, "the file is damaged (\(name))") }
                let isBlob = name.hasPrefix("blobs/")
                seen[name] = (size, isBlob && !verifyBlobs ? nil : SHA256.hex(data))
                try each(name, data)
            }
        }
        guard try take(h, end.count) == end, (try h.read(upToCount: 1) ?? Data()).isEmpty else { throw APIError(422, "the file is damaged at its end") }
        guard let m = manifest, m.format == 1 else { throw APIError(422, "this file is from a newer version of homemesh") }
        guard Set(m.files.map(\.name)) == Set(seen.keys) else { throw APIError(422, "the file does not hold what its manifest lists") }
        for f in m.files {
            guard let s = seen[f.name], s.size == f.size, s.sha == nil || s.sha == f.sha256 else { throw APIError(422, "\(f.name) does not match its checksum") }
        }
        return m
    }

    /// Reads a package through and checks it, without keeping anything.
    @discardableResult
    public static func verify(_ url: URL) throws -> (id: String, files: Int, bytes: Int, differences: [String]) {
        let m = try read(url, verifyBlobs: true) { _, _ in }
        return (m.id, m.files.count, m.files.reduce(0) { $0 + $1.size }, [])
    }

    /// Copies a house from a package into the library. Refuses to overwrite a house with the same id; leaves nothing behind on a failure.
    /// Afterwards compares the counts the house had when it was exported with the copy's.
    public static func importPackage(from url: URL, into api: LocalAPI) throws -> Report {
        var imp: HouseImport?
        var id = ""
        do {
            let m = try read(url, verifyBlobs: false) { name, data in
                if name == "house.json" {
                    guard let i = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else { throw APIError(422, "the house in the file does not read") }
                    id = i
                    imp = try api.beginImport(id: i, house: data)
                } else if let i = imp {
                    if name.hasPrefix("blobs/") { try i.addFile(String(name.dropFirst(6)), data) }
                    else if name.hasPrefix("captures/") { try i.addScan(data) }
                } else { throw APIError(422, "the file is damaged: the house comes first") }
            }
            guard let i = imp, m.id == id else { throw APIError(422, "the file is damaged: the house does not match its manifest") }
            try i.finish()
            let mine = try api.counts(of: id)
            var diffs: [String] = []
            for (k, v) in m.counts.sorted(by: { $0.key < $1.key }) where mine[k] != v { diffs.append("\(k): \(mine[k] ?? -1) here, \(v) in the file") }
            return Report(id: id, files: m.files.count, bytes: m.files.reduce(0) { $0 + $1.size }, differences: diffs)
        } catch {
            imp?.abort()
            throw error
        }
    }
}
