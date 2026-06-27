import Foundation
import Security

/// Minimal Keychain access (secrets — NOT UserDefaults, by plan). Used for the API token and
/// later for connector secrets.
enum KeychainStore {
    static let service = "gg.zbs.eye"

    /// CRITICAL: we use the MODERN data-protection keychain (like on iOS), NOT the legacy file keychain.
    /// The legacy login.keychain gates access with an ACL, and when reading an item created by a different
    /// signature (ad-hoc Debug → "ZBS Eye Dev" Release after a reinstall), it HANGS the main thread on a
    /// securityd dialog → bootstrap hangs forever (caught via sample: SecKeychainItemCopyContent → mach_msg).
    /// In the data-protection keychain an item is tied to the app's signature and is read by its OWN app without a prompt.
    private static let useDataProtection = kSecUseDataProtectionKeychain as String

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            useDataProtection: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            useDataProtection: true,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Local API token: takes the existing one or generates and stores it.
    static func apiToken() -> String {
        if let t = get("api-token"), !t.isEmpty { return t }
        let t = randomToken()
        set(t, account: "api-token")
        return t
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
