import Foundation
import Security

/// Minimal Keychain access (secrets — NOT UserDefaults, by plan). Used for the API token and
/// later for connector secrets.
enum KeychainStore {
    enum SetAction: Equatable {
        case complete
        case add
        case fail
    }

    enum SecretReadAction: Equatable {
        case use(String)
        case create
        case fail
    }

    enum SecretError: Error, Sendable, Equatable {
        case readFailed
        case writeFailed
    }

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

    static func secretReadAction(status: OSStatus, data: Data?) -> SecretReadAction {
        if status == errSecItemNotFound { return .create }
        guard status == errSecSuccess,
              let data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return .fail }
        return .use(value)
    }

    /// A missing webhook secret is initialized once. Any other Keychain read failure is terminal:
    /// replacing an unreadable stable secret would make retries unverifiable by the receiver.
    static func callAutomationSigningSecret() throws -> String {
        let account = "call-automation-signing-secret-v1"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            useDataProtection: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch secretReadAction(status: status, data: item as? Data) {
        case .use(let value):
            return value
        case .create:
            let value = try randomTokenOrThrow()
            guard set(value, account: account) else { throw SecretError.writeFailed }
            return value
        case .fail:
            throw SecretError.readFailed
        }
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
        let update: [String: Any] = [kSecValueData as String: data]
        switch setAction(for: SecItemUpdate(
            base as CFDictionary,
            update as CFDictionary
        )) {
        case .complete:
            return true
        case .add:
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        case .fail:
            return false
        }
    }

    static func setAction(for updateStatus: OSStatus) -> SetAction {
        switch updateStatus {
        case errSecSuccess: .complete
        case errSecItemNotFound: .add
        default: .fail
        }
    }

    /// Removes a stored secret (e.g. a cloud provider's API key the user revokes).
    /// An already-missing item is a completed deletion; every other Keychain
    /// error leaves absence unproven and must be surfaced by the caller.
    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            useDataProtection: true,
        ]
        return isSuccessfulDeletion(SecItemDelete(query as CFDictionary))
    }

    static func isSuccessfulDeletion(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    /// Local API token: takes the existing one or generates and stores it.
    static func apiToken() -> String {
        if let t = get("api-token"), !t.isEmpty { return t }
        let t = randomToken()
        set(t, account: "api-token")
        return t
    }

    /// Write-only Browser Bridge token. It can authorize only the two browser
    /// ingest routes and can never read Timeline, Search, frames, or audio.
    static func browserIngestToken() -> String {
        if let token = get("browser-ingest-token"), !token.isEmpty { return token }
        let token = randomToken()
        set(token, account: "browser-ingest-token")
        return token
    }

    private static func randomToken() -> String {
        (try? randomTokenOrThrow()) ?? UUID().uuidString.lowercased()
    }

    private static func randomTokenOrThrow() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SecretError.writeFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
