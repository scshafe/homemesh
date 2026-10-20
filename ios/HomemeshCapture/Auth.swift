import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Sign-in through Pocket ID: OIDC authorization code with PKCE (S256), a public client, callback
/// `homemesh-capture://oauth`. The id token is what the door accepts as `Authorization: Bearer`
/// (docs/deploy.md, "The capture app's sign-in"). Nothing is kept except the tokens, in the Keychain.
final class Auth: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Stored: Codable {
        var idToken: String
        var refreshToken: String?
    }

    static let callbackScheme = "homemesh-capture"
    static let redirect = "homemesh-capture://oauth"
    /// A request is not started with less than this left on the token.
    static let margin: TimeInterval = 120

    let issuer: String
    let clientId: String
    private var session: ASWebAuthenticationSession?

    init(issuer: String, clientId: String) {
        self.issuer = issuer.trimmingCharacters(in: .whitespaces)
        self.clientId = clientId.trimmingCharacters(in: .whitespaces)
    }

    // MARK: pure helpers

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomString(_ bytes: Int = 32) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes, &b) == errSecSuccess)
        return base64url(Data(b))
    }

    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// The `exp` claim of a JWT, without verifying it (the door verifies; this only decides when to sign in again).
    static func expiry(of jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var p = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while p.count % 4 != 0 { p += "=" }
        guard let data = Data(base64Encoded: p),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func isFresh(_ jwt: String, now: Date = Date()) -> Bool {
        guard let e = expiry(of: jwt) else { return false }
        return e.timeIntervalSince(now) > margin
    }

    // MARK: flow

    private struct Discovery: Decodable {
        let authorization_endpoint: String
        let token_endpoint: String
    }

    private struct TokenResponse: Decodable {
        let id_token: String?
        let refresh_token: String?
    }

    private func discover() async throws -> Discovery {
        var base = issuer
        while base.hasSuffix("/") { base.removeLast() }
        guard base.hasPrefix("https://"), let u = URL(string: base + "/.well-known/openid-configuration") else {
            throw Failure(message: "The sign-in address must start with https://")
        }
        let (data, _) = try await URLSession.shared.data(from: u)
        guard let d = try? JSONDecoder().decode(Discovery.self, from: data) else {
            throw Failure(message: "Could not read the sign-in server's configuration")
        }
        return d
    }

    private func exchange(_ endpoint: String, _ form: [String: String]) async throws -> Stored {
        var r = URLRequest(url: URL(string: endpoint)!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        r.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let t = try? JSONDecoder().decode(TokenResponse.self, from: data), let id = t.id_token else {
            throw Failure(message: "The sign-in server refused the request")
        }
        return Stored(idToken: id, refreshToken: t.refresh_token ?? form["refresh_token"])
    }

    /// Interactive sign-in: Pocket ID's own login page (passkey) in a system browser sheet.
    @MainActor
    func signIn() async throws -> Stored {
        let d = try await discover()
        let verifier = Auth.randomString(), state = Auth.randomString(16)
        var c = URLComponents(string: d.authorization_endpoint)!
        c.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: Auth.redirect), .init(name: "scope", value: "openid profile email"),
            .init(name: "state", value: state), .init(name: "code_challenge", value: Auth.challenge(for: verifier)),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: c.url!, callbackURLScheme: Auth.callbackScheme) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? Failure(message: "Sign-in cancelled")) }
            }
            s.presentationContextProvider = self
            self.session = s
            if !s.start() { cont.resume(throwing: Failure(message: "Could not open the sign-in page")) }
        }
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw Failure(message: "The sign-in answer did not match the request")
        }
        let stored = try await exchange(d.token_endpoint, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": Auth.redirect,
            "client_id": clientId, "code_verifier": verifier,
        ])
        Settings.tokens = try JSONEncoder().encode(stored)
        return stored
    }

    /// A token good for at least `margin` more seconds: the stored one, a refreshed one, or a new sign-in.
    @MainActor
    func freshIdToken() async throws -> String {
        if let data = Settings.tokens, let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            if Auth.isFresh(stored.idToken) { return stored.idToken }
            if let refresh = stored.refreshToken, let d = try? await discover(),
               let renewed = try? await exchange(d.token_endpoint, [
                   "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientId]) {
                Settings.tokens = try JSONEncoder().encode(renewed)
                return renewed.idToken
            }
        }
        return try await signIn().idToken
    }

    static func signOut() { Settings.tokens = nil }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
