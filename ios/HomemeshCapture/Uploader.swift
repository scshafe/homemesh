import Foundation

/// Uploads a scan to the homemesh backend: the capture JSON first, then the USDZ, both with the Pocket ID id token as the bearer token
/// (a fresh one is fetched before each request, so a long first upload cannot outlive the second's token).
/// The server reads the JSON (homemesh/roomplan.py); the USDZ is kept for display only.
/// Success means the server answered 2xx with the expected JSON for **both** requests; anything else throws.
struct Uploader: Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let server: String   // for example https://homemesh.<tailnet>  (no trailing slash needed)
    let house: String
    /// Returns a token with at least two minutes left; signs in again if it has to.
    let token: @Sendable () async throws -> String

    private var houseId: String { house.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard var c = URLComponents(string: base + path), c.scheme == "https" else {
            throw Failure(message: "The server address must start with https://")
        }
        c.queryItems = query.isEmpty ? nil : query
        guard let u = c.url else { throw Failure(message: "Bad server address") }
        return u
    }

    /// Refuses redirects: the door answers an unaccepted token with a redirect to its login page,
    /// and following it would turn a refusal into a 200 HTML page.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private func send(_ r: URLRequest, body: Data?) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await body.map { try await session.upload(for: r, from: $0) } ?? session.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw Failure(message: "No response from the server") }
        return (data, http)
    }

    private func check(_ http: HTTPURLResponse, _ data: Data) throws {
        switch http.statusCode {
        case 200..<300: return
        case 301...308, 401, 403:
            Auth.signOut()
            throw Failure(message: "The door did not accept the sign-in (\(http.statusCode)); sign in again")
        case 404:
            throw Failure(message: "House \"\(houseId)\" not found: create it in homemesh first")
        default:
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String ?? ""
            throw Failure(message: "Server said \(http.statusCode) \(detail)")
        }
    }

    private func request(_ u: URL, method: String, type: String? = nil) async throws -> URLRequest {
        var r = URLRequest(url: u)
        r.httpMethod = method
        if let type { r.setValue(type, forHTTPHeaderField: "Content-Type") }
        r.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 300
        return r
    }

    private func post(_ u: URL, body: Data, type: String) async throws -> [String: Any] {
        let (data, http) = try await send(try await request(u, method: "POST", type: type), body: body)
        try check(http, data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Unexpected answer from the server (not JSON)")
        }
        return obj
    }

    /// The ids of the houses the server has (for the picker).
    func houses() async throws -> [String] {
        let (data, http) = try await send(try await request(try url("/api/houses"), method: "GET"), body: nil)
        try check(http, data)
        guard let ids = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            throw Failure(message: "Unexpected answer from the server (not a house list)")
        }
        return ids
    }

    /// Returns the capture id the server assigned.
    func upload(json: Data, usdz: URL?, name: String) async throws -> String {
        let id = houseId
        guard !id.isEmpty else { throw Failure(message: "Choose a house first") }
        let path = "/api/houses/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/captures"
        let created = try await post(try url(path, query: [URLQueryItem(name: "name", value: name)]), body: json, type: "application/json")
        guard let blob = created["blob"] as? String else { throw Failure(message: "Unexpected answer from the server (no scan id)") }
        if let usdz {
            let attached = try await post(try url("\(path)/\(blob)/usdz"), body: try Data(contentsOf: usdz), type: "model/vnd.usdz+zip")
            guard attached["usdz"] is String else { throw Failure(message: "The server did not confirm the 3D model") }
        }
        return blob
    }
}
