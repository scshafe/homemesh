import Foundation
import Security

/// Server address and house id live in UserDefaults; the upload token lives in the Keychain.
/// Nothing else is stored on the device after a successful upload except the copy in Documents/Scans.
enum Settings {
    private static let d = UserDefaults.standard

    static var server: String {
        get { d.string(forKey: "server") ?? "" }
        set { d.set(newValue, forKey: "server") }
    }
    static var house: String {
        get { d.string(forKey: "house") ?? "" }
        set { d.set(newValue, forKey: "house") }
    }

    private static let account = "upload-token"

    static var token: String {
        get {
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        set {
            let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
            SecItemDelete(base as CFDictionary)
            guard !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
