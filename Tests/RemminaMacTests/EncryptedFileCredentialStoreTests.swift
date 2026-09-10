import Testing
import Foundation
@testable import RemminaMac

/// Tests for `EncryptedFileCredentialStore` — the portable, OS-independent
/// (no Apple Keychain dependency) `CredentialStore` conformance backed by a
/// single AES-256-GCM-encrypted file.
///
/// Every test uses a per-test temporary directory (`makeTempDirectory()`)
/// and never touches the real `~/Library/Application Support/RemminaMac/`.
@Suite("EncryptedFileCredentialStore Tests")
struct EncryptedFileCredentialStoreTests {

    // MARK: - Test helpers

    /// A fresh, unique temp directory per test. Registered for cleanup via
    /// the caller's own teardown (Swift Testing has no per-test `tearDown`
    /// hook for structs, so each test removes its own directory at the end
    /// — matching the temp-file conventions already used elsewhere in this
    /// suite, e.g. SSHKeyValidatorTests/ProfileValidatorTests).
    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remmina_enc_store_test_\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Metadata

    @Test("persists is true and displayName is 'Encrypted file (portable)'")
    func testMetadata() {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        #expect(store.persists == true)
        #expect(store.displayName == "Encrypted file (portable)")
    }

    @Test("init performs no filesystem I/O — directory is not created until createStore/save")
    func testInitDoesNoIO() {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        _ = store.displayName
        _ = store.persists
        #expect(!FileManager.default.fileExists(atPath: dir.path),
                "constructing the store (and reading persists/displayName) must not touch disk")
        #expect(store.isUnlocked == false)
        #expect(store.fileExists == false)
    }

    // MARK: - Round trip

    @Test("Round trip: create, save, lock, unlock with the same passphrase, read identical secret back")
    func testRoundTrip() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        let passphrase = "correct horse battery staple"
        let profileId = UUID()
        let secret = "s3cr3t-\(UUID().uuidString)"

        try store.createStore(withPassphrase: passphrase)
        #expect(store.isUnlocked)

        try store.save(secret, kind: .password, for: profileId)
        #expect(try store.secret(.password, for: profileId) == secret)

        store.lock()
        #expect(!store.isUnlocked)

        try store.unlock(withPassphrase: passphrase)
        #expect(store.isUnlocked)
        #expect(try store.secret(.password, for: profileId) == secret,
                "the identical secret must read back after a lock/unlock cycle")
    }

    @Test("delete removes a secret; deleteAll removes every secret kind for a profile")
    func testDeleteAndDeleteAll() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        try store.createStore(withPassphrase: "another-passphrase")

        let id1 = UUID()
        let id2 = UUID()
        try store.save("pw1", kind: .password, for: id1)
        try store.save("pw2", kind: .password, for: id2)

        try store.delete(.password, for: id1)
        #expect(try store.secret(.password, for: id1) == nil)
        #expect(try store.secret(.password, for: id2) == "pw2")

        try store.deleteAll(for: id2)
        #expect(try store.secret(.password, for: id2) == nil)
    }

    // MARK: - Wrong passphrase

    @Test("Wrong passphrase throws wrongPassphrase — not nil, not an empty store — and the file is still readable with the correct passphrase afterward")
    func testWrongPassphraseThrowsAndDoesNotCorrupt() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        let correctPassphrase = "the-real-passphrase"
        let profileId = UUID()
        let secret = "top-secret-\(UUID().uuidString)"

        try store.createStore(withPassphrase: correctPassphrase)
        try store.save(secret, kind: .password, for: profileId)
        store.lock()

        // Attempt unlock with the wrong passphrase on a *different* store
        // instance pointed at the same file, so state doesn't leak from the
        // first instance's (already-locked) key box.
        let attacker = EncryptedFileCredentialStore(directory: dir)
        #expect(throws: EncryptedStoreError.wrongPassphrase) {
            try attacker.unlock(withPassphrase: "definitely-wrong")
        }
        #expect(!attacker.isUnlocked, "a failed unlock must not leave the store unlocked")

        // The file itself must be untouched: unlock with the correct
        // passphrase (on a fresh instance) must still work and return the
        // identical secret.
        let verifier = EncryptedFileCredentialStore(directory: dir)
        try verifier.unlock(withPassphrase: correctPassphrase)
        #expect(try verifier.secret(.password, for: profileId) == secret,
                "a wrong-passphrase attempt must not corrupt the on-disk file")
    }

    // MARK: - Tamper detection

    @Test("Tamper detection: flipping one byte of the persisted ciphertext causes unlock to throw, not yield plaintext")
    func testTamperDetection() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        let passphrase = "tamper-test-passphrase"
        try store.createStore(withPassphrase: passphrase)
        try store.save("some-secret", kind: .password, for: UUID())

        // Flip one byte of the *decoded* ciphertext (not a raw byte of the
        // JSON file — that could just as easily break JSON parsing, which
        // would "throw" without actually exercising GCM authentication).
        let fileURL = dir.appendingPathComponent("credentials.enc")
        let data = try Data(contentsOf: fileURL)
        var envelope = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: data)
        var cipherBytes = [UInt8](Data(base64Encoded: envelope.ciphertext)!)
        #expect(!cipherBytes.isEmpty)
        cipherBytes[0] ^= 0xFF
        envelope.ciphertext = Data(cipherBytes).base64EncodedString()
        let tamperedData = try JSONEncoder().encode(envelope)
        try tamperedData.write(to: fileURL)

        let reopened = EncryptedFileCredentialStore(directory: dir)
        #expect(throws: EncryptedStoreError.wrongPassphrase) {
            try reopened.unlock(withPassphrase: passphrase)
        }
        #expect(!reopened.isUnlocked, "tampered ciphertext must never leave the store unlocked / yield plaintext")
    }

    // MARK: - File permissions

    @Test("File mode is exactly 0600 after creation and after an update")
    func testFilePermissions0600() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        try store.createStore(withPassphrase: "perm-test-passphrase")

        let fileURL = dir.appendingPathComponent("credentials.enc")
        let attrsAfterCreate = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modeAfterCreate = (attrsAfterCreate[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(modeAfterCreate == 0o600, "expected mode 0600 after createStore, got \(String(describing: modeAfterCreate.map { String($0, radix: 8) }))")

        try store.save("value", kind: .password, for: UUID())
        let attrsAfterUpdate = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let modeAfterUpdate = (attrsAfterUpdate[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(modeAfterUpdate == 0o600, "expected mode 0600 after save/update, got \(String(describing: modeAfterUpdate.map { String($0, radix: 8) }))")
    }

    // MARK: - Persisted header matches the spec

    @Test("Persisted envelope header matches the spec exactly: version 1, PBKDF2-HMAC-SHA256, 600,000 iterations, 32-byte salt, 12-byte nonce")
    func testPersistedHeaderMatchesSpec() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        try store.createStore(withPassphrase: "header-spec-passphrase")

        let data = try Data(contentsOf: dir.appendingPathComponent("credentials.enc"))
        let envelope = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: data)

        #expect(envelope.version == 1)
        #expect(envelope.kdf == "PBKDF2-HMAC-SHA256")
        #expect(envelope.iterations == 600_000)

        let saltBytes = Data(base64Encoded: envelope.salt)
        #expect(saltBytes?.count == 32, "salt must be 32 random bytes from SecRandomCopyBytes")

        let nonceBytes = Data(base64Encoded: envelope.nonce)
        #expect(nonceBytes?.count == 12, "AES-GCM nonce must be the standard 12 bytes")
    }

    // MARK: - Salt usage

    @Test("Two stores created with the same passphrase have different salts in their headers")
    func testSameSaltNotReused() throws {
        let dir1 = makeTempDirectory()
        let dir2 = makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        let store1 = EncryptedFileCredentialStore(directory: dir1)
        let store2 = EncryptedFileCredentialStore(directory: dir2)
        try store1.createStore(withPassphrase: "same-passphrase")
        try store2.createStore(withPassphrase: "same-passphrase")

        let envelope1 = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: Data(contentsOf: dir1.appendingPathComponent("credentials.enc")))
        let envelope2 = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: Data(contentsOf: dir2.appendingPathComponent("credentials.enc")))

        #expect(envelope1.salt != envelope2.salt, "each store must generate its own random salt, even with an identical passphrase")
    }

    @Test("Two different passphrases produce different ciphertext for identical plaintext")
    func testDifferentPassphrasesProduceDifferentCiphertext() throws {
        let dir1 = makeTempDirectory()
        let dir2 = makeTempDirectory()
        defer { cleanup(dir1); cleanup(dir2) }

        let store1 = EncryptedFileCredentialStore(directory: dir1)
        let store2 = EncryptedFileCredentialStore(directory: dir2)
        try store1.createStore(withPassphrase: "passphrase-one")
        try store2.createStore(withPassphrase: "passphrase-two")

        let profileId = UUID()
        try store1.save("identical-plaintext-value", kind: .password, for: profileId)
        try store2.save("identical-plaintext-value", kind: .password, for: profileId)

        let envelope1 = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: Data(contentsOf: dir1.appendingPathComponent("credentials.enc")))
        let envelope2 = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: Data(contentsOf: dir2.appendingPathComponent("credentials.enc")))

        #expect(envelope1.ciphertext != envelope2.ciphertext)
    }

    // MARK: - Nonce uniqueness

    @Test("Nonce uniqueness: saving twice persists two different nonces")
    func testNonceUniquenessAcrossSaves() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        try store.createStore(withPassphrase: "nonce-test-passphrase")
        let fileURL = dir.appendingPathComponent("credentials.enc")

        try store.save("first-value", kind: .password, for: UUID())
        let envelopeAfterFirst = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: Data(contentsOf: fileURL))

        try store.save("second-value", kind: .password, for: UUID())
        let envelopeAfterSecond = try JSONDecoder().decode(EncryptedFileCredentialStore.Envelope.self, from: Data(contentsOf: fileURL))

        #expect(envelopeAfterFirst.nonce != envelopeAfterSecond.nonce,
                "every seal operation must use a fresh random nonce")
    }

    // MARK: - Locked store

    @Test("Locked store: secret(_:for:) throws .locked, and never returns nil")
    func testLockedStoreThrowsLockedNotNil() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        try store.createStore(withPassphrase: "lock-test-passphrase")
        try store.save("a-secret", kind: .password, for: UUID())
        store.lock()

        #expect(throws: EncryptedStoreError.locked) {
            _ = try store.secret(.password, for: UUID())
        }
    }

    @Test("save/delete/deleteAll also throw .locked while locked")
    func testMutatingOperationsThrowLockedWhileLocked() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        try store.createStore(withPassphrase: "lock-test-passphrase-2")
        store.lock()

        #expect(throws: EncryptedStoreError.locked) {
            try store.save("x", kind: .password, for: UUID())
        }
        #expect(throws: EncryptedStoreError.locked) {
            try store.delete(.password, for: UUID())
        }
        #expect(throws: EncryptedStoreError.locked) {
            try store.deleteAll(for: UUID())
        }
    }

    // MARK: - Atomic write

    @Test("Atomic write: no temp file remains in the directory after a successful save")
    func testNoTempFileRemainsAfterSave() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        try store.createStore(withPassphrase: "atomic-test-passphrase")
        try store.save("value", kind: .password, for: UUID())
        try store.save("value2", kind: .password, for: UUID())

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["credentials.enc"],
                "directory must contain exactly the final file — no leftover .tmp- files. Found: \(contents)")
    }

    // MARK: - createStore / unlock error paths

    @Test("createStore throws .alreadyExists when a store file is already present")
    func testCreateStoreAlreadyExists() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        try store.createStore(withPassphrase: "first")

        let other = EncryptedFileCredentialStore(directory: dir)
        #expect(throws: EncryptedStoreError.alreadyExists) {
            try other.createStore(withPassphrase: "second")
        }
    }

    @Test("unlock throws .storeNotFound when no store file exists yet")
    func testUnlockStoreNotFound() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        #expect(throws: EncryptedStoreError.storeNotFound) {
            try store.unlock(withPassphrase: "anything")
        }
    }

    // MARK: - Log audit (no secret or passphrase reaches AppLogger)

    @Test("AppLogger never contains the passphrase or a saved secret after create/save/lock/unlock")
    func testNoSecretOrPassphraseInLogs() async throws {
        let logger = AppLogger.shared
        let beforeCount = await MainActor.run { logger.entries.count }

        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let store = EncryptedFileCredentialStore(directory: dir)
        let passphrase = "LogAuditPassphrase_\(UUID().uuidString)"
        let secret = "LogAuditSecret_\(UUID().uuidString)"
        let profileId = UUID()

        try store.createStore(withPassphrase: passphrase)
        try store.save(secret, kind: .password, for: profileId)
        store.lock()
        try store.unlock(withPassphrase: passphrase)
        _ = try store.secret(.password, for: profileId)

        try await Task.sleep(nanoseconds: 100_000_000)

        let entriesAfter = await MainActor.run {
            logger.entries.dropFirst(beforeCount)
        }

        let leakedPassphrase = entriesAfter.contains { $0.message.contains(passphrase) }
        let leakedSecret = entriesAfter.contains { $0.message.contains(secret) }

        #expect(!leakedPassphrase, "AppLogger must never contain the passphrase")
        #expect(!leakedSecret, "AppLogger must never contain a saved secret value")
    }

    // MARK: - CredentialStore protocol conformance sanity

    @Test("Conforms to CredentialStore and round-trips through the protocol type")
    func testProtocolConformance() throws {
        let dir = makeTempDirectory()
        defer { cleanup(dir) }
        let concrete = EncryptedFileCredentialStore(directory: dir)
        try concrete.createStore(withPassphrase: "protocol-test-passphrase")

        let store: CredentialStore = concrete
        let profileId = UUID()
        try store.save("proto-secret", kind: .password, for: profileId)
        #expect(try store.secret(.password, for: profileId) == "proto-secret")
        #expect(store.persists == true)
        #expect(store.displayName == "Encrypted file (portable)")
    }
}
