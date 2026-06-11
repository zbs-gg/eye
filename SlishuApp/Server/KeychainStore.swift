import Foundation
import Security

/// Минимальный Keychain-доступ (секреты — НЕ UserDefaults, по плану). Используется для API-токена и
/// позже для секретов коннекторов.
enum KeychainStore {
    static let service = "gg.zbs.eye"

    /// КРИТИЧНО: используем СОВРЕМЕННЫЙ data-protection keychain (как на iOS), а НЕ legacy file-keychain.
    /// Legacy login.keychain гейтит доступ ACL'ом и при чтении item'а, созданного другой подписью
    /// (ad-hoc Debug → «ZBS Eye Dev» Release после переустановки), ВЕШАЕТ main-thread на securityd-диалоге
    /// → bootstrap зависает навечно (поймано sample: SecKeychainItemCopyContent → mach_msg). В data-
    /// protection keychain item привязан к подписи приложения и читается СВОИМ приложением без промпта.
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

    /// Токен локального API: берёт существующий или генерирует и сохраняет.
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
