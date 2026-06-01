import Foundation
import OSLog
import Security

/// Errors from Keychain operations.
enum KeychainError: Error, CustomStringConvertible {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var description: String {
        switch self {
        case .saveFailed(let status):
            return "Keychain save failed (OSStatus \(status))"
        case .deleteFailed(let status):
            return "Keychain delete failed (OSStatus \(status))"
        }
    }
}

/// Secure storage for sensitive values (API keys) using the macOS Keychain.
///
/// Uses `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate` / `SecItemDelete`
/// with `kSecClassGenericPassword`. Keys are scoped by service + account.
///
/// **Thread safety**: All Keychain SecItem calls are thread-safe. This struct
/// is `Sendable` and can be used from any concurrency domain.
///
/// REQ-3.0-03, REQ-3.0-04, REQ-3.0-15: API key storage in Keychain (no plaintext).
struct KeychainStore: Sendable {

    /// The Keychain service identifier. Keys are namespaced within this service.
    let service: String

    private static let logger = Logger(subsystem: "com.nadav.deepfinder.ai", category: "keychain")

    init(service: String = "com.nadav.deepfinder") {
        self.service = service
    }

    /// Save a value to the Keychain. If the key already exists, updates it.
    func save(key: String, value: String) throws {
        let data = Data(value.utf8)

        // Try to delete existing first (upsert pattern).
        // If delete fails for a reason other than item-not-found, log a warning
        // and fall through to SecItemAdd (which will fail if the item exists,
        // giving a clear error).
        let deleteStatus = deleteRaw(key: key)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            Self.logger.warning("Keychain delete-before-save failed with OSStatus \(deleteStatus) for key \(key, privacy: .public)")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Load a value from the Keychain. Returns `nil` if the key doesn't exist.
    func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Self.logger.warning("Keychain load failed with OSStatus \(status) for key \(key, privacy: .public)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a value from the Keychain. No-op if the key doesn't exist.
    @discardableResult
    func delete(key: String) -> Bool {
        deleteRaw(key: key) == errSecSuccess
    }

    /// Internal delete that returns the raw OSStatus for diagnostics.
    private func deleteRaw(key: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        return SecItemDelete(query as CFDictionary)
    }
}
