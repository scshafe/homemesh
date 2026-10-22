import Foundation

/// Barometer and altimeter at the start of a scan. Relative altitude is only comparable inside one session (one
/// launch of the app); pressure drifts with the weather, so it is only compared across sessions an hour apart at most.
struct BaroReading: Codable, Hashable, Sendable {
    var session: String
    var rel_m: Double
    var kpa: Double
    var at: Double   // epoch seconds
}

/// Which floor a scan is probably on, and why (shown next to the picker). The owner always confirms it.
struct FloorSuggestion: Equatable {
    let level: String
    let reason: String

    static let within = 1.0              // metres: "the same height"
    static let horizon: Double = 12 * 3600
    static let kpaToMetres = 84.0

    /// Height difference between two readings, or nil when they cannot be compared.
    static func distance(_ a: BaroReading, _ b: BaroReading) -> Double? {
        if a.session == b.session { return abs(a.rel_m - b.rel_m) }
        guard abs(a.at - b.at) < 3600 else { return nil }
        return abs(a.kpa - b.kpa) * kpaToMetres
    }

    /// In order: a floor asked for (re-scan, or "add a room scan here"); the floor of the nearest earlier room from the
    /// last 12 hours when it is within a metre; the last floor used in this house; the ground floor.
    static func suggest(levels: [LevelRef], current: BaroReading?, others: [(room: String, level: String, baro: BaroReading)],
                        preferred: String?, preferredReason: String = "the floor you started from", lastUsed: String?) -> FloorSuggestion? {
        let ids = Set(levels.map(\.id))
        if let p = preferred, ids.contains(p) { return FloorSuggestion(level: p, reason: preferredReason) }
        if let now = current {
            let near = others
                .filter { ids.contains($0.level) && abs(now.at - $0.baro.at) < horizon }
                .compactMap { o in distance(now, o.baro).map { (o, $0) } }
                .filter { $0.1 <= within }
                .min { $0.1 < $1.1 }
            if let (o, _) = near {
                let name = o.room.isEmpty ? "an earlier room" : o.room
                return FloorSuggestion(level: o.level, reason: "same height as \(name)")
            }
        }
        if let l = lastUsed, ids.contains(l) { return FloorSuggestion(level: l, reason: "the last floor you scanned") }
        guard let g = FloorStack.ground(of: levels) else { return nil }
        return FloorSuggestion(level: g, reason: "the ground floor")
    }

    private static func key(_ house: String) -> String { "lastFloor.\(house)" }
    static func lastUsed(house: String, defaults: UserDefaults = .standard) -> String? { defaults.string(forKey: key(house)) }
    static func remember(_ level: String, house: String, defaults: UserDefaults = .standard) { defaults.set(level, forKey: key(house)) }
}
