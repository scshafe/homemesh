import Foundation

// The server's API (homemesh/api.py), in process. The app talks to this the way it talked to the server: the same paths, the same JSON,
// the same status codes, with the data in a folder on the phone. Nothing here is a network call. Parity with the Python API is tested on a
// recorded session (scripts/golden writes it from FastAPI's test client).

public struct APIError: Error, CustomStringConvertible {
    public var status: Int
    public var detail: String
    public init(_ status: Int, _ detail: String) { self.status = status; self.detail = detail }
    public var description: String { "\(status) \(detail)" }
}

public final class LocalAPI: @unchecked Sendable {
    public let root: URL
    let now: @Sendable () -> Double
    private let lock = NSLock()
    static let maxBody = 8 * 1024 * 1024

    public init(root: URL, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) { self.root = root; self.now = now }

    // MARK: plumbing

    static func validId(_ s: String) -> Bool {
        guard let f = s.unicodeScalars.first, s.count <= 64, CharacterSet.alphanumerics.contains(f), f.isASCII else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
    }

    func store(_ id: String) throws -> HouseStore {
        if !Self.validId(id) { throw APIError(422, "invalid house id") }
        return HouseStore(root: root.appendingPathComponent("houses").appendingPathComponent(id))
    }

    public func houseIds() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("houses").path)) ?? []
        return names.filter { HouseStore(root: root.appendingPathComponent("houses").appendingPathComponent($0)).exists }.sorted()
    }

    func get(_ id: String) throws -> (HouseStore, House) {
        let s = try store(id)
        guard s.exists, let h = try? s.load() else { throw APIError(404, "no such house") }
        return (s, h)
    }

    static func obj<T: Encodable>(_ v: T) throws -> Any {
        let e = JSONEncoder()
        return try JSONSerialization.jsonObject(with: try e.encode(v))
    }

    static func json(_ v: Any) throws -> Data { try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed]) }

    func houseJSON(_ h: House) throws -> Any { try Self.obj(h) }

    func save(_ s: HouseStore, _ h: House, expect: Int?) throws -> House {
        do { return try s.save(h, expect: expect) }
        catch StoreError.conflict(let have, let got) { throw APIError(409, "stale revision (have \(have.map(String.init) ?? "none"), got \(got.map(String.init) ?? "none"))") }
        catch StoreError.invalid(let p) { throw APIError(422, "invalid house: " + p.joined(separator: "; ")) }
    }

    func body(_ data: Data) throws -> JObject {
        if data.isEmpty { return [:] }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? JObject else { throw APIError(422, "body is not JSON") }
        return o
    }

    static func query(_ items: [URLQueryItem]?) -> [String: String] {
        var q: [String: String] = [:]
        for i in items ?? [] { q[i.name] = i.value ?? "" }
        return q
    }

    // MARK: routing

    /// Handles one request. Returns the response body; throws `APIError` where the server would answer with an error status.
    public func handle(_ method: String, _ target: String, body raw: Data = Data()) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let comps = URLComponents(string: target) else { throw APIError(404, "no such route") }
        let q = Self.query(comps.queryItems)
        let p = comps.path.split(separator: "/").map(String.init)
        guard p.count >= 2, p[0] == "api" else { throw APIError(404, "no such route") }
        let m = method.uppercased()
        switch (m, Array(p.dropFirst())) {
        case ("GET", ["houses"]): return try Self.json(houseIds())
        case ("GET", ["houses", "summary"]): return try Self.json(try summary())
        case ("POST", ["houses"]): return try Self.json(try createHouse(try body(raw)))
        case ("GET", ["catalogue"]): return try Self.json(try catalogue())
        case ("GET", let r) where r.count == 2 && r[0] == "houses": return try Self.json(try houseJSON(try get(r[1]).1))
        case ("PUT", let r) where r.count == 2 && r[0] == "houses": return try Self.json(try saveHouse(r[1], raw, expect: q["expect_revision"]))
        case ("POST", let r) where r.count == 3 && r[0] == "houses" && r[2] == "levels": return try Self.json(try addLevel(r[1], try body(raw)))
        case ("PUT", let r) where r.count == 4 && r[0] == "houses" && r[2] == "levels" && r[3] == "order": return try Self.json(try orderLevels(r[1], try body(raw)))
        case ("POST", let r) where r.count == 3 && r[0] == "houses" && r[2] == "stairs": return try Self.json(try addStair(r[1], try body(raw)))
        case ("GET", let r) where r.count == 3 && r[0] == "houses" && r[2] == "rooms": return try Self.json(try roomList(r[1]))
        case ("GET", let r) where r.count == 3 && r[0] == "houses" && r[2] == "captures": _ = try get(r[1]); return try Self.json(Captures.list(try store(r[1])))
        case ("GET", let r) where r.count == 3 && r[0] == "houses" && r[2] == "doors": return try Self.json(try doorsChecklist(r[1], level: q["level"] ?? ""))
        case ("GET", let r) where r.count == 3 && r[0] == "houses" && r[2] == "revisions": _ = try get(r[1]); return try Self.json(try store(r[1]).revisions())
        case ("GET", let r) where r.count == 4 && r[0] == "houses" && r[2] == "blobs": return try blob(r[1], r[3])
        case ("POST", let r) where r.count == 5 && r[0] == "houses" && r[2] == "revisions" && r[4] == "restore": return try Self.json(try restore(r[1], r[3], expect: q["expect_revision"]))
        case ("POST", let r) where r.count == 3 && r[0] == "houses" && r[2] == "captures": return try Self.json(try uploadCapture(r[1], raw, q))
        case ("POST", let r) where r.count == 5 && r[0] == "houses" && r[2] == "captures" && r[4] == "usdz": return try Self.json(try uploadUSDZ(r[1], r[3], raw))
        case ("PUT", let r) where r.count == 5 && r[0] == "houses" && r[2] == "captures": return try Self.json(try putCapture(r[1], r[3], what: r[4], try body(raw)))
        case ("GET", let r) where r.count == 5 && r[0] == "houses" && r[2] == "captures" && r[4] == "doors": return try Self.json(try captureDoors(r[1], r[3]))
        case ("POST", let r) where r.count == 5 && r[0] == "houses" && r[2] == "captures" && r[4] == "place": return try Self.json(try place(r[1], r[3], level: q["level"] ?? ""))
        case ("POST", let r) where r.count == 5 && r[0] == "houses" && r[2] == "captures" && r[4] == "import": return try Self.json(try importScan(r[1], r[3], level: q["level"] ?? "", raw))
        default: throw APIError(404, "no such route")
        }
    }

    // MARK: houses

    func summary() throws -> [Any] {
        var out: [Any] = []
        for id in houseIds() {
            guard let (s, h) = try? get(id) else { continue }
            out.append(["id": h.id, "name": h.name, "revision": h.revision,
                        "levels": h.levels.map { ["id": $0.id, "name": $0.name, "below_ground": $0.below_ground, "elevation": $0.elevation] as JObject },
                        "walls": h.walls.count, "rooms": h.rooms.count, "access_points": h.access_points.count, "captures": Captures.list(s).count] as JObject)
        }
        return out
    }

    func createHouse(_ b: JObject) throws -> Any {
        guard let id = b["id"] as? String, let name = b["name"] as? String else { throw APIError(422, "id and name are required") }
        let s = try store(id)
        let h = House(id: id, name: name, levels: [Level(id: "L0", name: "Ground", elevation: 0, height: 2.5)], materials: DefaultMaterials.all)
        do { return try houseJSON(try s.save(h, expect: nil)) }
        catch StoreError.conflict { throw APIError(409, "house exists") }
        catch StoreError.invalid(let p) { throw APIError(422, "invalid house: " + p.joined(separator: "; ")) }
    }

    func addLevel(_ id: String, _ b: JObject) throws -> Any {
        let (s, h) = try get(id)
        let name = ((b["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw APIError(422, "a level needs a name") }
        let height = (b["height"] as? NSNumber)?.doubleValue ?? 2.5
        let ids = Set(h.levels.map(\.id))
        var n = ids.count
        while ids.contains("L\(n)") { n += 1 }
        if (b["below"] as? Bool) == true {
            let lv = Level(id: "L\(n)", name: name, elevation: 0, height: height, below_ground: true)
            var withNew = h
            withNew.levels.append(lv)
            do {
                let moved = try Stack.restack(withNew, order: [lv.id] + h.levels.map(\.id), belowGround: [lv.id] + h.levels.filter(\.below_ground).map(\.id))
                return try houseJSON(try save(s, moved, expect: h.revision))
            } catch let e as StackError { if case .invalid(let m) = e { throw APIError(422, m) }; throw e }
        }
        let top = h.levels.max { $0.elevation < $1.elevation }!
        let elevation = (b["elevation"] as? NSNumber)?.doubleValue ?? ScanImport.rnd(top.elevation + top.height + 0.3, 3)
        let slabMaterial = h.materials.contains { $0.id == "slab-wood" } ? "slab-wood" : h.materials.first?.id
        var nh = h
        nh.levels.append(Level(id: "L\(n)", name: name, elevation: elevation, height: height, slab: (slabMaterial != nil && elevation > top.elevation) ? Slab(material: slabMaterial!, thickness: 0.3) : nil))
        return try houseJSON(try save(s, nh, expect: h.revision))
    }

    func orderLevels(_ id: String, _ b: JObject) throws -> Any {
        let (s, h) = try get(id)
        guard let order = b["order"] as? [String] else { throw APIError(422, "order is required") }
        do { return try houseJSON(try save(s, try Stack.restack(h, order: order, belowGround: b["below_ground"] as? [String]), expect: h.revision)) }
        catch let e as StackError { if case .invalid(let m) = e { throw APIError(422, m) }; throw e }
    }

    func addStair(_ id: String, _ b: JObject) throws -> Any {
        let (s, h) = try get(id)
        guard let from = b["from_level"] as? String, let to = b["to_level"] as? String, let poly = b["polygon"] as? [[Double]], poly.count >= 3 else { throw APIError(422, "from_level, to_level and a polygon are required") }
        let ids = Set(h.levels.map(\.id))
        if !ids.contains(from) || !ids.contains(to) || from == to { throw APIError(422, "a stair joins two different, existing levels") }
        var n = h.stairs.count
        let taken = Set(h.stairs.map(\.id))
        while taken.contains("s\(n + 1)") { n += 1 }
        var nh = h
        nh.stairs.append(Stair(id: "s\(n + 1)", from_level: from, to_level: to, polygon: poly.map { Vec2($0[0], $0[1]) }, void: (b["void"] as? Bool) ?? true, prov: Provenance(source: "scan")))
        return try houseJSON(try save(s, nh, expect: h.revision))
    }

    func saveHouse(_ id: String, _ raw: Data, expect: String?) throws -> Any {
        if raw.count > Self.maxBody { throw APIError(413, "house too large") }
        let s = try store(id)
        guard let expect, let rev = Int(expect) else { throw APIError(422, "expect_revision is required") }
        let h: House
        do { h = try House.load(lenient: raw) } catch { throw APIError(422, "the house does not read: \(error)") }
        if h.id != id { throw APIError(422, "id does not match the URL") }
        return try houseJSON(try save(s, h, expect: rev))
    }

    func restore(_ id: String, _ rev: String, expect: String?) throws -> Any {
        let (s, _) = try get(id)
        guard let r = Int(rev), let e = expect.flatMap(Int.init) else { throw APIError(422, "revision and expect_revision are required") }
        guard let old = try? s.load(revision: r) else { throw APIError(404, "no such house or revision") }
        do { return try houseJSON(try s.save(old, expect: e)) }
        catch StoreError.conflict { throw APIError(409, "changed elsewhere; reload") }
        catch StoreError.invalid(let p) { throw APIError(422, "invalid house: " + p.joined(separator: "; ")) }
    }

    func blob(_ id: String, _ digest: String) throws -> Data {
        let s = try store(id)
        do { return try s.blob(digest) } catch { throw APIError(404, "no such blob") }
    }

    func catalogue() throws -> Any {
        let eq = try Catalogue.genericList().map { e -> Any in
            var o = try Self.obj(e) as! JObject
            o["origin"] = "generic"; o["assumed"] = e.radios.contains { $0.assumed }
            return o
        }
        let cl = try Catalogue.genericClientList().map { c -> Any in var o = try Self.obj(c) as! JObject; o["origin"] = "generic"; return o }
        return ["equipment": eq, "clients": cl]
    }
}
