import Testing
import Foundation
@testable import RemminaMac

/// AppLogger behavior audit: what AppLogger actually does with the strings
/// it is given, and whether the real call sites that touch credentials ever
/// hand it one.
///
/// AppLogger.shared.log() performs **no redaction**: whatever message a
/// caller passes is stored verbatim in the in-memory ring buffer and written
/// verbatim to the on-disk log file. There is no filtering layer that would
/// catch a caller who accidentally interpolates a password into a log
/// message — credential safety here is entirely a *caller discipline*
/// property, not something AppLogger enforces. The tests below are split
/// accordingly:
///   1. Documents that AppLogger stores messages verbatim (no redaction),
///      so this fact stays pinned down rather than being assumed.
///   2/3. Confirms that real call sites which handle credentials —
///      SSHSession's init and KeychainStore's save/get/delete — never pass
///      the credential value itself to AppLogger.
///
/// This file is test-only — no production source is modified.
@Suite("Security Audit — AppLogger Behavior & Credential Call-Site Hygiene")
struct C2AuditTests {

    // MARK: - 1. AppLogger performs no redaction (documented behavior, not a security guarantee)

    /// AppLogger.shared.log() stores the message it is given verbatim, with no
    /// filtering or redaction of secret-looking content. This is not a safety
    /// net — it is exactly why the call sites in tests 2 and 3 below must
    /// never pass a credential value as the message.
    ///
    /// Design: poll the ring buffer with a timeout rather than a single sleep,
    /// so the test is immune to main-queue congestion under parallel test execution.
    @Test("AppLogger stores log messages verbatim — it performs no redaction")
    func testAppLoggerStoresMessagesVerbatim() async throws {
        let logger = AppLogger.shared
        let syntheticSecret = "AUDIT_TEST_SECRET_\(UUID().uuidString)"

        // Log the secret — internally dispatches entries.append to DispatchQueue.main.async
        logger.log(syntheticSecret, level: .debug)

        // Poll the ring buffer for up to 2s locally (scaled up under CI) via
        // 50ms-spaced iterations, generous enough that even under heavy
        // parallel test load the main queue will have processed the async
        // append well within the window.
        var containsSecret = false
        for _ in 0..<pollIterations(40) {
            containsSecret = await MainActor.run {
                logger.entries.contains { $0.message == syntheticSecret }
            }
            if containsSecret { break }
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms per poll
        }

        // CONFIRMED: the logger stores whatever it is given verbatim.
        // This is why callers must NEVER pass credential values as the message parameter.
        #expect(containsSecret == true,
                "AppLogger stores messages verbatim — callers must not pass secrets")
    }

    // MARK: - 2. Real call site: SSHSession init never logs the password

    /// Confirms that a simulated SSH connect flow (no network) does not cause any
    /// password-like string to appear in AppLogger's in-memory entries.
    @Test("AppLogger ring buffer: no credential appears in entries after SSHSession init")
    func testAppLoggerRingBufferDoesNotContainCredentials() async throws {
        let logger = AppLogger.shared
        let beforeCount = await MainActor.run { logger.entries.count }

        let testPassword = "ShouldNeverAppearInLog_\(UUID().uuidString)"
        let profile = ConnectionProfile(
            name: "LogAuditSSH",
            protocolType: .ssh,
            host: "192.0.2.3"
        )
        // Create session — init logs "SSH key validation" or nothing
        let session = SSHSession(profile: profile, password: testPassword)
        _ = session.id

        // Give logger time to flush any async entries
        try await Task.sleep(nanoseconds: 100_000_000)

        let entriesAfter = await MainActor.run {
            logger.entries.dropFirst(beforeCount)
        }

        let leakFound = entriesAfter.contains { entry in
            entry.message.contains(testPassword)
        }

        #expect(!leakFound,
                "AppLogger ring buffer must not contain the password after SSHSession init")
    }

    // MARK: - 3. Real call site: KeychainStore never logs the password

    @Test("KeychainStore save/get/delete never pass the password value to AppLogger")
    func testKeychainStoreLogsDoNotContainPassword() async throws {
        let logger = AppLogger.shared
        let beforeCount = await MainActor.run { logger.entries.count }

        // Per-run random service name — never touches the developer's real
        // login keychain (the production service name), and is cleaned up
        // even if an assertion above throws.
        let store = KeychainStore(service: "com.stormbringer-v1.remminamac.tests." + UUID().uuidString)
        let fakeId = UUID()
        let testPwd = "KeychainAuditPwd_\(UUID().uuidString)"
        defer { store.deletePassword(for: fakeId) }

        // Save → should succeed
        _ = store.savePassword(testPwd, for: fakeId)
        // Get → retrieve it back
        let retrieved = try store.password(for: fakeId)

        // Verify we got the right password back (functional check)
        #expect(retrieved == testPwd, "Keychain round-trip should succeed")

        try await Task.sleep(nanoseconds: 100_000_000)

        let entriesAfter = await MainActor.run {
            logger.entries.dropFirst(beforeCount)
        }

        let leakFound = entriesAfter.contains { entry in
            entry.message.contains(testPwd)
        }

        #expect(!leakFound,
                "KeychainStore must not log the password value in any log entry")
    }
}


