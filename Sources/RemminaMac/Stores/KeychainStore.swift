import Foundation
import Security

/// Manages secure storage of passwords and keys in macOS Keychain.
final class KeychainStore {
    static let shared = KeychainStore()

    private let serviceName = "com.remmina-mac.credentials"

    private init() {}

    // MARK: - Password Operations

    /// Saves a password for a given profile ID.
    func savePassword(_ password: String, for profileId: UUID) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        // Delete existing item first
        _ = deletePassword(for: profileId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: profileId.uuidString,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            AppLogger.shared.log("Keychain save failed: \(status)", level: .error)
        }
        return status == errSecSuccess
    }

    /// Retrieves the password for a given profile ID.
    func getPassword(for profileId: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: profileId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }

    /// Deletes the password for a given profile ID.
    @discardableResult
    func deletePassword(for profileId: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: profileId.uuidString
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Updates an existing password for a given profile ID.
    func updatePassword(_ password: String, for profileId: UUID) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: profileId.uuidString
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            return savePassword(password, for: profileId)
        }

        if status != errSecSuccess {
            AppLogger.shared.log("Keychain update failed: \(status)", level: .error)
        }
        return status == errSecSuccess
    }
}
