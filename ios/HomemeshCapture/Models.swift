import Foundation

/// The parts of the backend's JSON the app reads. Field names follow the backend (homemesh/model.py,
/// homemesh/api.py); a contract test decodes the committed synthetic fixtures with these types.
struct LevelRef: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}

/// `GET /api/houses/summary`
struct HouseSummary: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let revision: Int
    let levels: [LevelRef]
    let walls: Int
    let rooms: Int
    let access_points: Int
    let captures: Int
}

/// The few fields of a full house the app needs so far (`GET /api/houses/<id>`); the rest stays on the server.
struct HouseLite: Codable, Sendable {
    struct Level: Codable, Sendable {
        let id: String
        let name: String
        let elevation: Double
        let height: Double
    }
    let id: String
    let name: String
    let revision: Int
    let levels: [Level]
}

/// One stored scan (`GET /api/houses/<id>/captures`).
struct CaptureMeta: Codable, Hashable, Identifiable, Sendable {
    let blob: String
    let name: String
    let at: Double
    let counts: [String: Int]
    let usdz: String?
    let rooms: [String]?
    var id: String { blob }

    var roomCount: Int { counts["rooms"] ?? 0 }
    /// One name per room, "" where the owner has not named it yet.
    var roomNames: [String] {
        let have = rooms ?? []
        return (0..<roomCount).map { $0 < have.count ? have[$0] : "" }
    }
}

struct NewHouseBody: Encodable, Sendable {
    let id: String
    let name: String
}

struct NewLevelBody: Encodable, Sendable {
    let name: String
}

struct RoomNamesBody: Encodable, Sendable {
    let names: [String]
}

enum Naming {
    /// A house id the backend accepts (letters, digits, - and _; at most 64) from a display name.
    static func slug(_ name: String) -> String {
        var out = ""
        for ch in name.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber { out.append(ch) } else if !out.hasSuffix("-") { out.append("-") }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(64))
    }

    /// "Scan 2026-10-21 23:30" when the name field is empty.
    static func defaultScanName(_ now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Scan " + f.string(from: now)
    }

    /// Typical room names offered while naming; the house's own names come first in the UI.
    static let suggestions = ["Kitchen", "Living room", "Dining room", "Hall", "Bathroom", "Bedroom", "Office", "Laundry", "Garage", "Closet"]
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
