import Foundation

// One folder per house (docs/design-standalone-app.md section 6; the same shape as the server's store):
//   house.json               the current revision
//   revisions/<n>.json       history (the newest `keep` are kept)
//   blobs/<sha256>           content addressed, immutable (USDZ scans)
//   captures/<id>/...        scans and their labels (P1 later)
// Writes are atomic: a half-written edit never replaces house.json.

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case conflict(have: Int?, got: Int?)
    case invalid([String])
    case missing(String)
    case badId(String)

    public var description: String {
        switch self {
        case .conflict(let h, let g): "stale revision (have \(h.map(String.init) ?? "none"), got \(g.map(String.init) ?? "none"))"
        case .invalid(let p): "invalid house: " + p.joined(separator: "; ")
        case .missing(let w): "no such \(w)"
        case .badId(let w): "invalid \(w)"
        }
    }
}

public struct HouseStore: Sendable {
    public let root: URL
    public var keep: Int

    public init(root: URL, keep: Int = 20) { self.root = root; self.keep = keep }

    private var fm: FileManager { .default }
    private var houseFile: URL { root.appendingPathComponent("house.json") }
    private func revisionFile(_ n: Int) -> URL { root.appendingPathComponent("revisions").appendingPathComponent("\(n).json") }

    func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public var exists: Bool { fm.fileExists(atPath: houseFile.path) }

    public func load(revision: Int? = nil) throws -> House {
        let url = revision.map(revisionFile) ?? houseFile
        guard let data = try? Data(contentsOf: url) else { throw StoreError.missing(revision == nil ? "house" : "revision") }
        return try House.load(data)
    }

    /// Writes `house` as the next revision and returns it with `revision` set. `expect` is the revision the caller edited from
    /// (nil for a new house); a mismatch is a conflict, and a house that fails validation is refused.
    @discardableResult
    public func save(_ house: House, expect: Int?) throws -> House {
        let problems = house.validate()
        if !problems.isEmpty { throw StoreError.invalid(problems) }
        let current = exists ? try load().revision : nil
        if expect != current { throw StoreError.conflict(have: current, got: expect) }
        var next = house
        next.revision = (current ?? 0) + 1
        let data = try next.encoded()
        try write(data, to: revisionFile(next.revision))
        try write(data, to: houseFile)
        prune()
        return next
    }

    public func revisions() -> [Int] {
        let dir = root.appendingPathComponent("revisions")
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.compactMap { $0.hasSuffix(".json") ? Int($0.dropLast(5)) : nil }.sorted()
    }

    private func prune() {
        let all = revisions()
        for n in all.dropLast(max(keep, 1)) { try? fm.removeItem(at: revisionFile(n)) }
    }

    /// Undo: the content of an earlier revision becomes the next revision (history keeps what was undone).
    @discardableResult
    public func restore(revision: Int, expect: Int) throws -> House {
        try save(try load(revision: revision), expect: expect)
    }

    // MARK: blobs

    public func putBlob(_ data: Data) throws -> String {
        let digest = SHA256.hex(data)
        let url = root.appendingPathComponent("blobs").appendingPathComponent(digest)
        if !fm.fileExists(atPath: url.path) { try write(data, to: url) }
        return digest
    }

    public func blob(_ digest: String) throws -> Data {
        guard digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw StoreError.badId("blob id") }
        guard let d = try? Data(contentsOf: root.appendingPathComponent("blobs").appendingPathComponent(digest)) else { throw StoreError.missing("blob") }
        return d
    }
}
