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

    /// Thread-safe box for collecting sessions created by a test's
    /// `sessionFactory` closure. Replaces `withUnsafeMutablePointer(to:)`,
    /// which handed a pointer into a local `var` to a closure retained (and
    /// invoked later) by `ConnectionManager` — the pointer's validity ends
    /// with the `withUnsafeMutablePointer` call, so writing through it after
    /// that point was undefined behavior.
    private final class CreatedSessions: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [FakeSession] = []

        func append(_ session: FakeSession) {
            lock.lock()
            storage.append(session)
            lock.unlock()
        }

        var all: [FakeSession] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @MainActor
    private func makeConnectionManager(
        credentialStore: CredentialStore,
        createdSessions: CreatedSessions? = nil
    ) -> ConnectionManager {
        ConnectionManager(
            sessionFactory: { profile, password in
                let session = FakeSession(profile: profile, password: password, initialStatus: .connected)
                createdSessions?.append(session)
                return session
            },
            credentialStore: credentialStore
        )
    }

    @Test("openSession returns .opened for an SSH profile when the store yields nil (no secret needed), not .keychainFailed")
    @MainActor
    func testSSHOpensWithNoStoredSecret() throws {
        let fakeStore = FakeCredentialStore(persists: true)
        let created = CreatedSessions()
        let manager = makeConnectionManager(credentialStore: fakeStore, createdSessions: created)

        let profile = ConnectionProfile(name: "NoSecretSSH", protocolType: .ssh, host: "192.0.2.1", port: 22)
        let result = manager.openSession(for: profile)

        #expect(result == .opened)
        #expect(created.all.count == 1)
        if case .keychainFailed = result {
            Issue.record("SSH with no stored secret must not report .keychainFailed")
        }
    }

    @Test("openSession returns .keychainFailed(status) when the store throws KeychainError.unexpectedStatus")
    @MainActor
    func testStoreThrowingUnexpectedStatusProducesKeychainFailed() throws {
        let fakeStore = FakeCredentialStore(persists: true)
        fakeStore.throwOnSecret = KeychainError.unexpectedStatus(errSecAuthFailed)

        let created = CreatedSessions()
        let manager = makeConnectionManager(credentialStore: fakeStore, createdSessions: created)

        let profile = ConnectionProfile(name: "ThrowingStoreSSH", protocolType: .ssh, host: "192.0.2.2", port: 22)
        let result = manager.openSession(for: profile)

        #expect(result == .keychainFailed(errSecAuthFailed))
        #expect(created.all.isEmpty, "a failed credential read must abort before a session is created")
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
        let created = CreatedSessions()
        let manager = makeConnectionManager(credentialStore: fakeStore, createdSessions: created)

        let profile = ConnectionProfile(name: "NoSecretVNC", protocolType: .vnc, host: "192.0.2.4", port: 5900)
        let result = manager.openSession(for: profile)

        guard case .credentialUnavailable(let reason) = result else {
            Issue.record("expected .credentialUnavailable, got \(result)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(created.all.isEmpty, "no session/tab should be created when the credential is unavailable")
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
        let created = CreatedSessions()
        let manager = makeConnectionManager(credentialStore: fakeStore, createdSessions: created)

        let profile = ConnectionProfile(name: "PersistingNoSecretVNC", protocolType: .vnc, host: "192.0.2.6", port: 5900)
        let result = manager.openSession(for: profile)

        #expect(result == .opened)
        #expect(created.all.count == 1)
    }

    @Test("openSession returns .storeLocked (not .keychainFailed) when the store throws EncryptedStoreError.locked, for both VNC and SSH profiles")
    @MainActor
    func testStoreThrowingLockedProducesStoreLocked() throws {
        let fakeStore = FakeCredentialStore(persists: true)
        fakeStore.throwOnSecret = EncryptedStoreError.locked

        let created = CreatedSessions()
        let manager = makeConnectionManager(credentialStore: fakeStore, createdSessions: created)

        let vncProfile = ConnectionProfile(name: "LockedVNC", protocolType: .vnc, host: "192.0.2.7", port: 5900)
        let vncResult = manager.openSession(for: vncProfile)

        guard case .storeLocked(let reason) = vncResult else {
            Issue.record("expected .storeLocked for a VNC profile against a locked store, got \(vncResult)")
            return
        }
        #expect(!reason.isEmpty)
        if case .keychainFailed = vncResult {
            Issue.record("a locked EncryptedFileCredentialStore must not be reported as .keychainFailed — that tells the user the wrong thing (Keychain error vs. 'unlock the store')")
        }

        let sshProfile = ConnectionProfile(name: "LockedSSH", protocolType: .ssh, host: "192.0.2.8", port: 22)
        let sshResult = manager.openSession(for: sshProfile)
        guard case .storeLocked = sshResult else {
            Issue.record("expected .storeLocked for an SSH profile too — the store read fails before protocol-specific logic runs, got \(sshResult)")
            return
        }

        #expect(created.all.isEmpty, "no session/tab should be created while the credential store is locked")
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

    // (A prior "KeychainStore's production service name is unchanged" test
    // lived here. It grepped KeychainStore.swift's source text for the
    // literal production service string and the `profileId.uuidString`
    // account key — a source-text audit, not a behavioral test, and it
    // pinned down the actual production Keychain service name (which none
    // of the tests in this file should touch). The behavioral half of what
    // it checked — that the CredentialStore protocol adapter uses
    // `kSecAttrService`/`kSecAttrAccount` the same way the direct API does —
    // is already covered, against a random per-run service, by
    // testKeychainStoreProtocolUsesSameAccountAndServiceStrings above.)
}
