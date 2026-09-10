import Foundation
import Security

/// Errors encountered during Keychain operations.
enum KeychainError: Error, LocalizedError, Equatable {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            if let msg = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error \(status): \(msg)"
            }
            return "Keychain error \(status)"
        }
    }
}

/// Manages secure storage of passwords and keys in macOS Keychain.
final class KeychainStore {
    static let shared = KeychainStore()

    private let serviceName: String

    /// - Parameter service: Keychain service name to namespace items under.
    ///   Defaults to the production service. Tests should pass a per-run
    ///   random service name (PROBLEMS.md ISSUE-020) so keychain items are
    ///   isolated from the developer's real credentials and from each other.
    init(service: String = "com.stormbringer-v1.remminamac.credentials") {
        self.serviceName = service
    }

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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            // Explicitly opt out of iCloud Keychain sync. Without this,
            // kSecAttrSynchronizable defaults to false on macOS but we'd
            // rather state the intent than rely on the platform default.
            kSecAttrSynchronizable as String: false
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            AppLogger.shared.log("Keychain save failed: \(status)", level: .error)
        }
        return status == errSecSuccess
    }

    /// Retrieves the password for a given profile ID.
    /// Returns `nil` when the password is not stored, and throws `KeychainError.unexpectedStatus` on other failures.
    func password(for profileId: UUID) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: profileId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            AppLogger.shared.log("Keychain read failed with status: \(status)", level: .error)
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data else {
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
