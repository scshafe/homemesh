import HomemeshCore
import Foundation

/// Saves a scan into a house on this phone: the capture JSON first, then the USDZ (kept for display; the engine reads the JSON).
struct Uploader: Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let house: String   // trimmed by the caller
    let local: LocalAPI

    /// Returns the capture id the library assigned.
    func upload(json: Data, usdz: URL?, name: String, level: String = "", replaces: String = "", purpose: String = "", stairFrom: String = "", stairTo: String = "",
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let path = "/api/houses/\(house.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? house)/captures"
        var q = URLComponents()
        var items = [URLQueryItem(name: "name", value: name)]
        if !level.isEmpty { items.append(URLQueryItem(name: "level", value: level)) }
        if !replaces.isEmpty { items.append(URLQueryItem(name: "replaces", value: replaces)) }
        if !purpose.isEmpty { items.append(URLQueryItem(name: "purpose", value: purpose)) }
        if !stairFrom.isEmpty && !stairTo.isEmpty { items += [URLQueryItem(name: "stair_from", value: stairFrom), URLQueryItem(name: "stair_to", value: stairTo)] }
        q.queryItems = items
        let created: Data
        do { created = try local.handle("POST", path + "?" + (q.percentEncodedQuery ?? ""), body: json) } catch let e as APIError { throw Failure(message: e.detail) }
        guard let blob = (try JSONSerialization.jsonObject(with: created) as? [String: Any])?["blob"] as? String else { throw Failure(message: "Unexpected answer") }
        progress?(0.1)
        if let usdz {
            do { _ = try local.handle("POST", "\(path)/\(blob)/usdz", body: try Data(contentsOf: usdz)) } catch let e as APIError { throw Failure(message: e.detail) }
        }
        progress?(1)
        return blob
    }
}
