import Foundation
import Security

/// Server address and house id live in UserDefaults; the sign-in tokens live in the Keychain.
/// Nothing else is stored on the device after a successful upload except the copy in Documents/Scans.
enum Settings {
    private static var d: UserDefaults { .standard }

    static var server: String {
        get { d.string(forKey: "server") ?? "" }
        set { d.set(newValue, forKey: "server") }
    }
    static var house: String {
        get { d.string(forKey: "house") ?? "" }
        set { d.set(newValue, forKey: "house") }
    }

    /// Pocket ID's address and the capture client's id (a public client: no secret exists).
    static var issuer: String {
        get { d.string(forKey: "issuer") ?? "" }
        set { d.set(newValue, forKey: "issuer") }
    }
    static var clientId: String {
        get { d.string(forKey: "clientId") ?? "homemesh-capture" }  // the public client; not a secret
        set { d.set(newValue, forKey: "clientId") }
    }

    private static let account = "oidc-tokens"

    /// The id token (and refresh token, if Pocket ID issued one), as JSON in the Keychain.
    static var tokens: Data? {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
            return out as? Data
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard let newValue else { return }
            var add = base
            add[kSecValueData as String] = newValue
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
