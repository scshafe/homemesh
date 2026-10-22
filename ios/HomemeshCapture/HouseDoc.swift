import Foundation

/// The house as the server sent it, edited in place. Only the fields the app edits are touched; everything else
/// (and anything a newer backend adds) goes back unchanged, so the app can never drop data it does not know.
struct HouseDoc {
    struct Opening: Hashable {
        var kind: String
        var width: Double
    }

    private(set) var root: [String: Any]

    init(data: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Uploader.Failure(message: "Unexpected answer from the server")
        }
        root = o
    }

    var revision: Int { root["revision"] as? Int ?? 0 }

    var materials: [(id: String, name: String)] {
        (root["materials"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return (id, $0["name"] as? String ?? id)
        }
    }

    private var walls: [[String: Any]] { root["walls"] as? [[String: Any]] ?? [] }

    func data() throws -> Data { try JSONSerialization.data(withJSONObject: root) }

    func material(of wall: String) -> String? { walls.first { $0["id"] as? String == wall }?["material"] as? String }

    func thicknessDefaulted(_ wall: String) -> Bool { walls.first { $0["id"] as? String == wall }?["thickness_defaulted"] as? Bool ?? false }

    func openings(of wall: String) -> [Opening] {
        ((walls.first { $0["id"] as? String == wall }?["openings"] as? [[String: Any]]) ?? []).map {
            Opening(kind: $0["kind"] as? String ?? "door", width: $0["width"] as? Double ?? 0)
        }
    }

    private mutating func edit(wall id: String, _ change: (inout [String: Any]) -> Void) {
        var all = walls
        guard let i = all.firstIndex(where: { $0["id"] as? String == id }) else { return }
        change(&all[i])
        var prov = all[i]["prov"] as? [String: Any] ?? ["source": "manual"]
        prov["edited"] = true
        all[i]["prov"] = prov
        root["walls"] = all
    }

    /// Sets what the owner measured or chose for one wall. A thickness or material set by hand is no longer "defaulted".
    mutating func update(wall id: String, thickness: Double? = nil, material: String? = nil) {
        edit(wall: id) { w in
            if let thickness, thickness > 0 { w["thickness"] = thickness; w["thickness_defaulted"] = false }
            if let material { w["material"] = material; w["material_defaulted"] = false }
        }
    }

    /// Changes the kind and width of the `index`th opening of a wall (its position and sill are kept).
    mutating func setOpening(wall id: String, index: Int, kind: String, width: Double) {
        edit(wall: id) { w in
            var o = w["openings"] as? [[String: Any]] ?? []
            guard o.indices.contains(index), width > 0 else { return }
            o[index]["kind"] = kind
            o[index]["width"] = width
            w["openings"] = o
        }
    }

    mutating func removeOpening(wall id: String, index: Int) {
        edit(wall: id) { w in
            var o = w["openings"] as? [[String: Any]] ?? []
            guard o.indices.contains(index) else { return }
            o.remove(at: index)
            w["openings"] = o
        }
    }

    /// The same material and/or thickness for every wall of `level` still carrying the importer's default for it.
    mutating func applyToDefaults(level: String, thickness: Double?, material: String?) -> Int {
        var n = 0
        for w in walls where w["level"] as? String == level {
            guard let id = w["id"] as? String else { continue }
            let needsT = thickness != nil && (w["thickness_defaulted"] as? Bool ?? false)
            let needsM = material != nil && (w["material_defaulted"] as? Bool ?? false)
            if needsT || needsM {
                update(wall: id, thickness: needsT ? thickness : nil, material: needsM ? material : nil)
                n += 1
            }
        }
        return n
    }

    // MARK: measure checks (tape readings against the scan)

    struct Check: Hashable {
        let id: String
        let what: String
        let scanned: Double
        let measured: Double
        var error: Double { scanned - measured }               // metres, + = the scan is longer than the tape
        var percent: Double { measured == 0 ? 0 : 100 * error / measured }
    }

    var checks: [Check] {
        (root["measure_checks"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, let s = $0["scanned"] as? Double, let m = $0["measured"] as? Double else { return nil }
            return Check(id: id, what: $0["what"] as? String ?? "", scanned: s, measured: m)
        }
    }

    @discardableResult
    mutating func addCheck(what: String, level: String?, wall: String?, scanned: Double, measured: Double, at: Date = Date()) -> Check? {
        guard scanned > 0, measured > 0, !what.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var all = root["measure_checks"] as? [[String: Any]] ?? []
        let used = Set(all.compactMap { $0["id"] as? String })
        var n = all.count + 1
        while used.contains("m\(n)") { n += 1 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        var entry: [String: Any] = ["id": "m\(n)", "what": what.trimmingCharacters(in: .whitespaces), "scanned": scanned, "measured": measured, "at": f.string(from: at)]
        if let level { entry["level"] = level }
        if let wall { entry["wall"] = wall }
        all.append(entry)
        root["measure_checks"] = all
        return Check(id: "m\(n)", what: what, scanned: scanned, measured: measured)
    }
}

/// How well the scan agrees with the tape: the numbers behind "is the LiDAR good enough to drop blueprints".
struct Accuracy: Equatable {
    let count: Int
    let meanAbsPercent: Double
    let meanSignedPercent: Double
    let worstPercent: Double
    let meanAbsMetres: Double

    init(_ checks: [HouseDoc.Check]) {
        count = checks.count
        let n = Double(max(checks.count, 1))
        meanAbsPercent = checks.map { abs($0.percent) }.reduce(0, +) / n
        meanSignedPercent = checks.map(\.percent).reduce(0, +) / n
        worstPercent = checks.map { abs($0.percent) }.max() ?? 0
        meanAbsMetres = checks.map { abs($0.error) }.reduce(0, +) / n
    }

    /// The design's bar: below about 2 percent or 3 cm is better than a hand-traced blueprint.
    var passes: Bool { count >= 5 && (meanAbsPercent <= 2 || meanAbsMetres <= 0.03) }
}
