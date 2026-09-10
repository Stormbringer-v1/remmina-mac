import Testing
import Foundation
@testable import RemminaMac

@Suite("KeychainStore Tests")
struct KeychainStoreTests {
    // PROBLEMS.md ISSUE-020: these tests used to run against
    // `KeychainStore.shared`, which reads and writes the developer's real
    // login keychain — slow, order-dependent, and a hazard on a CI runner
    // whose keychain is locked. Each test now creates its own
    // `KeychainStore(service:)` under a per-run random service name so
    // items are namespaced away from the production service and from each
    // other, and every test cleans up everything it wrote.

    private func makeStore() -> KeychainStore {
        KeychainStore(service: "com.stormbringer-v1.remminamac.tests.\(UUID().uuidString)")
    }

    @Test("Save and retrieve password")
    func testSaveAndRetrieve() throws {
        let store = makeStore()
        let profileId = UUID()
        let password = "test-password-\(UUID().uuidString.prefix(8))"

        // Save
        let saved = store.savePassword(password, for: profileId)
        #expect(saved == true)

        // Retrieve
        let retrieved = try store.password(for: profileId)
        #expect(retrieved == password)

        // Cleanup
        store.deletePassword(for: profileId)
    }

    @Test("Delete password")
    func testDelete() throws {
        let store = makeStore()
        let profileId = UUID()

        // Save first
        _ = store.savePassword("temp-pass", for: profileId)

        // Delete
        let deleted = store.deletePassword(for: profileId)
        #expect(deleted == true)

        // Verify deleted
        let retrieved = try store.password(for: profileId)
        #expect(retrieved == nil)
    }

    @Test("Update password")
    func testUpdate() throws {
        let store = makeStore()
        let profileId = UUID()

        // Save initial
        _ = store.savePassword("old-password", for: profileId)

        // Update
        let updated = store.updatePassword("new-password", for: profileId)
        #expect(updated == true)

        // Verify updated
        let retrieved = try store.password(for: profileId)
        #expect(retrieved == "new-password")

        // Cleanup
        store.deletePassword(for: profileId)
    }

    @Test("Retrieve non-existent password returns nil")
    func testRetrieveNonExistent() throws {
        let store = makeStore()
        let profileId = UUID()

        let retrieved = try store.password(for: profileId)
        #expect(retrieved == nil)
    }

    @Test("Delete non-existent password succeeds")
    func testDeleteNonExistent() {
        let store = makeStore()
        let profileId = UUID()

        let deleted = store.deletePassword(for: profileId)
        #expect(deleted == true)
    }

    @Test("Save overwrites existing password")
    func testSaveOverwrite() throws {
        let store = makeStore()
        let profileId = UUID()

        _ = store.savePassword("first", for: profileId)
        _ = store.savePassword("second", for: profileId)

        let retrieved = try store.password(for: profileId)
        #expect(retrieved == "second")

        // Cleanup
        store.deletePassword(for: profileId)
    }

    @Test("Throwing password(for:) retrieves saved password")
    func testThrowingPasswordRetrieve() throws {
        let store = makeStore()
        let profileId = UUID()
        let pass = "secret-\(UUID().uuidString.prefix(6))"

        _ = store.savePassword(pass, for: profileId)
        defer { store.deletePassword(for: profileId) }

        let retrieved = try store.password(for: profileId)
        #expect(retrieved == pass)
    }

    @Test("Throwing password(for:) returns nil for non-existent")
    func testThrowingPasswordNonExistent() throws {
        let store = makeStore()
        let profileId = UUID()

        let retrieved = try store.password(for: profileId)
        #expect(retrieved == nil)
    }

    @Test("Two KeychainStore instances with different service names do not see each other's items")
    func testServiceNamespaceIsolation() throws {
        let storeA = makeStore()
        let storeB = makeStore()
        let profileId = UUID()

        _ = storeA.savePassword("only-in-a", for: profileId)
        defer { storeA.deletePassword(for: profileId) }

        let seenFromB = try storeB.password(for: profileId)
        #expect(seenFromB == nil, "a different service name must not see another instance's items")

        let seenFromA = try storeA.password(for: profileId)
        #expect(seenFromA == "only-in-a")
    }

    @Test("KeychainError description includes error code")
    func testKeychainErrorDescription() {
        let err = KeychainError.unexpectedStatus(errSecAuthFailed)
        #expect(err.errorDescription?.contains("\(errSecAuthFailed)") == true)
    }
}
