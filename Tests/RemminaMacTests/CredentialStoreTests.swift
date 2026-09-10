import Testing
import Foundation
import Security
@testable import RemminaMac

/// Tests for the `CredentialStore` abstraction that decouples RemminaMac
/// from Apple Keychain: `NullCredentialStore` (the shipped default),
/// `KeychainStore`'s conformance (opt-in), and `ConnectionManager`'s use of
/// an injected store rather than reaching for `KeychainStore.shared`.
@Suite("CredentialStore Tests")
struct CredentialStoreTests {

    // MARK: - NullCredentialStore

    @Test("NullCredentialStore.secret returns nil for any profile id")
    func testNullCredentialStoreSecretAlwaysNil() throws {
        let store = NullCredentialStore.shared
        for _ in 0..<5 {
            #expect(try store.secret(.password, for: UUID()) == nil)
        }
    }

    @Test("NullCredentialStore.save is a no-op — secret still returns nil afterward")
    func testNullCredentialStoreSaveIsNoOp() throws {
        let store = NullCredentialStore.shared
        let id = UUID()

        try store.save("hunter2", kind: .password, for: id)

        #expect(try store.secret(.password, for: id) == nil,
                "NullCredentialStore must store nothing, even after save()")
    }

    @Test("NullCredentialStore methods never throw")
    func testNullCredentialStoreNeverThrows() {
        let store = NullCredentialStore.shared
        let id = UUID()

        #expect(throws: Never.self) { try store.secret(.password, for: id) }
        #expect(throws: Never.self) { try store.save("x", kind: .password, for: id) }
        #expect(throws: Never.self) { try store.delete(.password, for: id) }
        #expect(throws: Never.self) { try store.deleteAll(for: id) }
    }

    @Test("NullCredentialStore.persists is false")
    func testNullCredentialStorePersistsFalse() {
        #expect(NullCredentialStore.shared.persists == false)
    }

    // MARK: - ConnectionManager + injected CredentialStore

    @MainActor
    private func makeConnectionManager(
        credentialStore: CredentialStore,
        createdSessions: UnsafeMutablePointer<[FakeSession]>? = nil
    ) -> ConnectionManager {
        ConnectionManager(
            sessionFactory: { profile, password in
                let session = FakeSession(profile: profile, password: password, initialStatus: .connected)
                createdSessions?.pointee.append(session)
                return session
            },
            credentialStore: credentialStore
        )
    }

    @Test("openSession returns .opened for an SSH profile when the store yields nil (no secret needed), not .keychainFailed")
    @MainActor
    func testSSHOpensWithNoStoredSecret() throws {
        let fakeStore = FakeCredentialStore(persists: true)
        var created: [FakeSession] = []
        let manager = withUnsafeMutablePointer(to: &created) { ptr in
            makeConnectionManager(credentialStore: fakeStore, createdSessions: ptr)
        }

        let profile = ConnectionProfile(name: "NoSecretSSH", protocolType: .ssh, host: "192.0.2.1", port: 22)
        let result = manager.openSession(for: profile)

        #expect(result == .opened)
        #expect(created.count == 1)
        if case .keychainFailed = result {
            Issue.record("SSH with no stored secret must not report .keychainFailed")
        }
    }

    @Test("openSession returns .keychainFailed(status) when the store throws KeychainError.unexpectedStatus")
    @MainActor
    func testStoreThrowingUnexpectedStatusProducesKeychainFailed() throws {
        let fakeStore = FakeCredentialStore(persists: true)
        fakeStore.throwOnSecret = KeychainError.unexpectedStatus(errSecAuthFailed)

        var created: [FakeSession] = []
        let manager = withUnsafeMutablePointer(to: &created) { ptr in
            makeConnectionManager(credentialStore: fakeStore, createdSessions: ptr)
        }

        let profile = ConnectionProfile(name: "ThrowingStoreSSH", protocolType: .ssh, host: "192.0.2.2", port: 22)
        let result = manager.openSession(for: profile)

        #expect(result == .keychainFailed(errSecAuthFailed))
        #expect(created.isEmpty, "a failed credential read must abort before a session is created")
    }

    @Test("openSession returns .keychainFailed(errSecIO) when the store throws a non-Keychain error")
    @MainActor
    func testStoreThrowingGenericErrorProducesKeychainFailed() throws {
        struct SomeOtherError: Error {}
        let fakeStore = FakeCredentialStore(persists: true)
        fakeStore.throwOnSecret = SomeOtherError()

        let manager = makeConnectionManager(credentialStore: fakeStore)
        let profile = ConnectionProfile(name: "GenericThrowSSH", protocolType: .ssh, host: "192.0.2.3", port: 22)
        let result = manager.openSession(for: profile)

        #expect(result == .keychainFailed(errSecIO))
    }

    @Test("openSession returns .credentialUnavailable for a VNC profile when no secret is available and the store does not persist")
    @MainActor
    func testVNCWithNoSecretAndNonPersistingStoreIsCredentialUnavailable() throws {
        let fakeStore = FakeCredentialStore(persists: false)
        var created: [FakeSession] = []
        let manager = withUnsafeMutablePointer(to: &created) { ptr in
            makeConnectionManager(credentialStore: fakeStore, createdSessions: ptr)
        }

        let profile = ConnectionProfile(name: "NoSecretVNC", protocolType: .vnc, host: "192.0.2.4", port: 5900)
        let result = manager.openSession(for: profile)

        guard case .credentialUnavailable(let reason) = result else {
            Issue.record("expected .credentialUnavailable, got \(result)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(created.isEmpty, "no session/tab should be created when the credential is unavailable")
    }

    @Test("openSession returns .credentialUnavailable for an RDP profile when no secret is available and the store does not persist")
    @MainActor
    func testRDPWithNoSecretAndNonPersistingStoreIsCredentialUnavailable() throws {
        let fakeStore = FakeCredentialStore(persists: false)
        let manager = makeConnectionManager(credentialStore: fakeStore)

        let profile = ConnectionProfile(name: "NoSecretRDP", protocolType: .rdp, host: "192.0.2.5", port: 3389)
        let result = manager.openSession(for: profile)

        guard case .credentialUnavailable = result else {
            Issue.record("expected .credentialUnavailable, got \(result)")
            return
        }
    }

    @Test("openSession still opens a VNC session when a non-persisting store nonetheless has no secret required — i.e. a persisting store with nil just proceeds")
    @MainActor
    func testVNCOpensWhenStorePersistsEvenWithNoSecret() throws {
        // A store that *persists* but simply has nothing saved for this
        // profile is a normal "no password set" case, not the "storage is
        // disabled" case — VNC/RDP still get to try (and fail on their own
        // if they truly need a password), matching pre-refactor behavior.
        let fakeStore = FakeCredentialStore(persists: true)
        var created: [FakeSession] = []
        let manager = withUnsafeMutablePointer(to: &created) { ptr in
            makeConnectionManager(credentialStore: fakeStore, createdSessions: ptr)
        }

        let profile = ConnectionProfile(name: "PersistingNoSecretVNC", protocolType: .vnc, host: "192.0.2.6", port: 5900)
        let result = manager.openSession(for: profile)

        #expect(result == .opened)
        #expect(created.count == 1)
    }

    // MARK: - KeychainStore round-trips through the CredentialStore protocol

    private func makeKeychainStore(label: String) -> KeychainStore {
        KeychainStore(service: "com.stormbringer-v1.remminamac.tests.credentialstore.\(label).\(UUID().uuidString)")
    }

    @Test("KeychainStore.persists is true and displayName is 'macOS Keychain'")
    func testKeychainStoreMetadata() {
        let store: CredentialStore = makeKeychainStore(label: "metadata")
        #expect(store.persists == true)
        #expect(store.displayName == "macOS Keychain")
    }

    @Test("KeychainStore conformance round-trips save/secret/delete/deleteAll through the CredentialStore protocol")
    func testKeychainStoreProtocolRoundTrip() throws {
        let store: CredentialStore = makeKeychainStore(label: "roundtrip")
        let profileId = UUID()
        let password = "proto-pass-\(UUID().uuidString.prefix(8))"

        try store.save(password, kind: .password, for: profileId)
        #expect(try store.secret(.password, for: profileId) == password)

        try store.delete(.password, for: profileId)
        #expect(try store.secret(.password, for: profileId) == nil)

        try store.save(password, kind: .password, for: profileId)
        try store.deleteAll(for: profileId)
        #expect(try store.secret(.password, for: profileId) == nil)
    }

    @Test("KeychainStore protocol methods use the same kSecAttrService/kSecAttrAccount as the pre-refactor direct API")
    func testKeychainStoreProtocolUsesSameAccountAndServiceStrings() throws {
        let service = "com.stormbringer-v1.remminamac.tests.credentialstore.strings.\(UUID().uuidString)"
        let store: CredentialStore = KeychainStore(service: service)
        let profileId = UUID()
        let password = "string-check-\(UUID().uuidString.prefix(8))"

        try store.save(password, kind: .password, for: profileId)
        defer { try? store.delete(.password, for: profileId) }

        // Read back with a raw SecItemCopyMatching using exactly the
        // service string passed to KeychainStore(service:) and
        // kSecAttrAccount == profileId.uuidString — the documented shape
        // KeychainStore.swift has always used. If the protocol adapter (or
        // a future rename) changed either, this raw query would miss the
        // item and the read would come back empty instead of the password.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        #expect(status == errSecSuccess, "expected the item saved via the CredentialStore protocol to be found under service=\(service), account=profileId.uuidString")
        let retrieved = (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        #expect(retrieved == password)
    }

    @Test("KeychainStore's production service name is unchanged (static source audit)")
    func testKeychainStoreProductionServiceNameUnchanged() throws {
        // Locate the package root by walking up from this test file
        // (same technique as C2AuditTests' posix_spawn static audit).
        let fm = FileManager.default
        var searchURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var packageRoot: URL?
        for _ in 0..<10 {
            searchURL = searchURL.deletingLastPathComponent()
            if fm.fileExists(atPath: searchURL.appendingPathComponent("Package.swift").path) {
                packageRoot = searchURL
                break
            }
        }
        guard let root = packageRoot else {
            Issue.record("could not locate package root by walking up from \(#filePath)")
            return
        }

        let keychainStorePath = root.appendingPathComponent("Sources/RemminaMac/Stores/KeychainStore.swift").path
        let source = try String(contentsOf: URL(fileURLWithPath: keychainStorePath), encoding: .utf8)

        #expect(source.contains(#"com.stormbringer-v1.remminamac.credentials"#),
                "KeychainStore's default production service name must not change — previously saved passwords must remain readable when a user opts back into Keychain")
        #expect(source.contains("kSecAttrAccount as String: profileId.uuidString"),
                "the Keychain account must stay profileId.uuidString so previously saved passwords remain addressable")
    }
}
