import Foundation

/// Uploads a scan to the homemesh backend: the capture JSON first, then the USDZ, both with the Pocket ID id token as the bearer token
/// (a fresh one is fetched before each request, so a long first upload cannot outlive the second's token).
/// The server reads the JSON (homemesh/roomplan.py); the USDZ is kept for display only.
struct Uploader: Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let server: String   // for example https://homemesh.<tailnet>  (no trailing slash needed)
    let house: String   // trimmed by the caller
    /// Returns a token with at least two minutes left; signs in again if it has to.
    let token: @Sendable () async throws -> String

    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var base = server.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard var c = URLComponents(string: base + path), c.scheme == "https" else {
            throw Failure(message: "The server address must start with https://")
        }
        c.queryItems = query.isEmpty ? nil : query
        guard let u = c.url else { throw Failure(message: "Bad server address") }
        return u
    }

    /// The ids of the houses the server has (for the picker).
    func houses() async throws -> [String] {
        var r = URLRequest(url: try url("/api/houses"))
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let ids = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            throw Failure(message: "The server did not give a house list")
        }
        return ids
    }

    /// Reports how many bytes of the body the network has taken.
    private final class SendProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let report: @Sendable (Int64) -> Void
        init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            report(totalBytesSent)
        }
    }

    private func post(_ u: URL, body: Data, type: String, sent: (@Sendable (Int64) -> Void)? = nil) async throws -> Data {
        var r = URLRequest(url: u)
        r.httpMethod = "POST"
        r.setValue(type, forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 300
        let (data, resp) = try await URLSession.shared.upload(for: r, from: body, delegate: sent.map { SendProgress($0) })
        guard let http = resp as? HTTPURLResponse else { throw Failure(message: "No response") }
        if http.statusCode == 401 || http.statusCode == 302 {
            Auth.signOut()
            throw Failure(message: "The door did not accept the sign-in; sign in again")
        }
        if http.statusCode == 404 {
            throw Failure(message: "Server said 404: house \"\(house)\" not found. Create it in homemesh first.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String ?? ""
            throw Failure(message: "Server said \(http.statusCode) \(detail)")
        }
        return data
    }

    /// Returns the capture id the server assigned.
    func upload(json: Data, usdz: URL?, name: String, level: String = "", replaces: String = "", purpose: String = "", stairFrom: String = "", stairTo: String = "",
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let path = "/api/houses/\(house.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? house)/captures"
        let usdzSize = usdz.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
        let total = Double(max(1, json.count + usdzSize))   // real bytes: the model is most of the upload
        let jsonSize = json.count
        let created = try await post(try url(path, query: [URLQueryItem(name: "name", value: name)] + (level.isEmpty ? [] : [URLQueryItem(name: "level", value: level)]) + (replaces.isEmpty ? [] : [URLQueryItem(name: "replaces", value: replaces)]) + (purpose.isEmpty ? [] : [URLQueryItem(name: "purpose", value: purpose)]) + (stairFrom.isEmpty || stairTo.isEmpty ? [] : [URLQueryItem(name: "stair_from", value: stairFrom), URLQueryItem(name: "stair_to", value: stairTo)])), body: json, type: "application/json", sent: progress.map { p in { @Sendable n in p(Double(n) / total) } })
        guard let blob = (try JSONSerialization.jsonObject(with: created) as? [String: Any])?["blob"] as? String else {
            throw Failure(message: "Unexpected answer from the server")
        }
        if let usdz {
            _ = try await post(try url("\(path)/\(blob)/usdz"), body: try Data(contentsOf: usdz), type: "model/vnd.usdz+zip",
                              sent: progress.map { p in { @Sendable n in p(Double(jsonSize + Int(n)) / total) } })
        }
        return blob
    }
}
