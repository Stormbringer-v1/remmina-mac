import Testing
import Foundation
@testable import RemminaMac

/// Tests for `CredentialStore.hasSecret(_:for:)` — the existence-only check
/// added so callers (e.g. `ProfileDetailView`) can find out whether a
/// secret is stored without reading its value.
///
/// - `KeychainStore` overrides `hasSecret` with an attributes-only query
///   (no `kSecReturnData`), so it must behave identically to checking
///   `secret(_:for:) != nil` from the caller's point of view.
/// - `EncryptedFileCredentialStore` relies on the protocol extension's
///   default implementation (`secret(_:for:) != nil`), which must still
///   throw `.locked` while the store is locked rather than quietly
///   returning `false` — `false` would be indistinguishable from "no
///   secret saved" and is exactly the bug class the `.locked` case exists
///   to prevent (see `EncryptedFileCredentialStore`'s doc comment).
@Suite("Credential Existence Tests")
struct CredentialExistenceTests {

    // MARK: - KeychainStore

    // Matching the convention in KeychainStoreTests.swift: each test gets
    // its own random service name so items never touch the developer's
    // real keychain and tests can't see each other's items.
    private func makeKeychainStore() -> KeychainStore {
        KeychainStore(service: "com.stormbringer-v1.remminamac.tests.existence.\(UUID().uuidString)")
    }

    @Test("KeychainStore.hasSecret: false before save, true after save, false after delete")
    func testKeychainStoreHasSecretLifecycle() throws {
        let store = makeKeychainStore()
        let profileId = UUID()
        defer { store.deletePassword(for: profileId) }

        #expect(try store.hasSecret(.password, for: profileId) == false)

        _ = store.savePassword("existence-test-\(UUID().uuidString.prefix(8))", for: profileId)
        #expect(try store.hasSecret(.password, for: profileId) == true)

        store.deletePassword(for: profileId)
        #expect(try store.hasSecret(.password, for: profileId) == false)
    }

    @Test("KeychainStore.hasSecret round-trips through the CredentialStore protocol existential")
    func testKeychainStoreHasSecretThroughProtocol() throws {
        let store: CredentialStore = makeKeychainStore()
        let profileId = UUID()
        defer { try? store.delete(.password, for: profileId) }

        #expect(try store.hasSecret(.password, for: profileId) == false)

        try store.save("proto-existence-pass", kind: .password, for: profileId)
        #expect(try store.hasSecret(.password, for: profileId) == true)

        try store.delete(.password, for: profileId)
        #expect(try store.hasSecret(.password, for: profileId) == false)
    }

    // MARK: - EncryptedFileCredentialStore

    /// A fresh, unique temp directory per test — matches the convention in
    /// EncryptedFileCredentialStoreTests.swift so this store never touches
    /// the real `~/Library/Application Support/RemminaMac/`.
    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("remmina_credential_existence_test_\(UUID().uuidString)", isDirectory: true)
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("EncryptedFileCredentialStore.hasSecret throws .locked while locked, never returns false")
    func testEncryptedStoreHasSecretThrowsLockedWhileLocked() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        try store.createStore(withPassphrase: "existence-lock-test-passphrase")
        try store.save("a-secret", kind: .password, for: UUID())
        store.lock()

        #expect(throws: EncryptedStoreError.locked) {
            _ = try store.hasSecret(.password, for: UUID())
        }
    }

    @Test("EncryptedFileCredentialStore.hasSecret: false when unlocked with nothing saved, true after save")
    func testEncryptedStoreHasSecretFalseThenTrueWhenUnlocked() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        try store.createStore(withPassphrase: "existence-unlocked-test-passphrase")
        let profileId = UUID()

        #expect(try store.hasSecret(.password, for: profileId) == false)

        try store.save("existence-secret", kind: .password, for: profileId)
        #expect(try store.hasSecret(.password, for: profileId) == true)

        try store.delete(.password, for: profileId)
        #expect(try store.hasSecret(.password, for: profileId) == false)
    }
}
