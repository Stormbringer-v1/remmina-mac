import Testing
import Foundation
@testable import RemminaMac

@Suite("KeychainStore Tests")
struct KeychainStoreTests {
    // Note: These tests interact with the actual macOS Keychain.
    // In a real CI environment, you would use a mock.
    // These tests use unique profile IDs to avoid conflicts.

    @Test("Save and retrieve password")
    func testSaveAndRetrieve() {
        let store = KeychainStore.shared
        let profileId = UUID()
        let password = "test-password-\(UUID().uuidString.prefix(8))"

        // Save
        let saved = store.savePassword(password, for: profileId)
        #expect(saved == true)

        // Retrieve
        let retrieved = store.getPassword(for: profileId)
        #expect(retrieved == password)

        // Cleanup
        store.deletePassword(for: profileId)
    }

    @Test("Delete password")
    func testDelete() {
        let store = KeychainStore.shared
        let profileId = UUID()

        // Save first
        _ = store.savePassword("temp-pass", for: profileId)

        // Delete
        let deleted = store.deletePassword(for: profileId)
        #expect(deleted == true)

        // Verify deleted
        let retrieved = store.getPassword(for: profileId)
        #expect(retrieved == nil)
    }

    @Test("Update password")
    func testUpdate() {
        let store = KeychainStore.shared
        let profileId = UUID()

        // Save initial
        _ = store.savePassword("old-password", for: profileId)

        // Update
        let updated = store.updatePassword("new-password", for: profileId)
        #expect(updated == true)

        // Verify updated
        let retrieved = store.getPassword(for: profileId)
        #expect(retrieved == "new-password")

        // Cleanup
        store.deletePassword(for: profileId)
    }

    @Test("Retrieve non-existent password returns nil")
    func testRetrieveNonExistent() {
        let store = KeychainStore.shared
        let profileId = UUID()

        let retrieved = store.getPassword(for: profileId)
        #expect(retrieved == nil)
    }

    @Test("Delete non-existent password succeeds")
    func testDeleteNonExistent() {
        let store = KeychainStore.shared
        let profileId = UUID()

        let deleted = store.deletePassword(for: profileId)
        #expect(deleted == true)
    }

    @Test("Save overwrites existing password")
    func testSaveOverwrite() {
        let store = KeychainStore.shared
        let profileId = UUID()

        _ = store.savePassword("first", for: profileId)
        _ = store.savePassword("second", for: profileId)

        let retrieved = store.getPassword(for: profileId)
        #expect(retrieved == "second")

        // Cleanup
        store.deletePassword(for: profileId)
    }

    @Test("Throwing password(for:) retrieves saved password")
    func testThrowingPasswordRetrieve() throws {
        let store = KeychainStore.shared
        let profileId = UUID()
        let pass = "secret-\(UUID().uuidString.prefix(6))"

        _ = store.savePassword(pass, for: profileId)
        defer { store.deletePassword(for: profileId) }

        let retrieved = try store.password(for: profileId)
        #expect(retrieved == pass)
    }

    @Test("Throwing password(for:) returns nil for non-existent")
    func testThrowingPasswordNonExistent() throws {
        let store = KeychainStore.shared
        let profileId = UUID()

        let retrieved = try store.password(for: profileId)
        #expect(retrieved == nil)
    }

    @Test("KeychainError description includes error code")
    func testKeychainErrorDescription() {
        let err = KeychainError.unexpectedStatus(errSecAuthFailed)
        #expect(err.errorDescription?.contains("\(errSecAuthFailed)") == true)
    }
}
