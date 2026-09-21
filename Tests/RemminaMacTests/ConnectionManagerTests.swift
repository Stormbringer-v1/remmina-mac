import Testing
import Foundation
@testable import RemminaMac

@Suite("ConnectionManager Integration Tests")
@MainActor
struct ConnectionManagerTests {

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

    private func makeManager(createdSessions: CreatedSessions? = nil) -> ConnectionManager {
        ConnectionManager(sessionFactory: { profile, password in
            let session = FakeSession(profile: profile, password: password, initialStatus: .connected)
            createdSessions?.append(session)
            return session
        })
    }

    @Test("Prevent duplicate active sessions for same profile with FakeSession")
    func testDuplicateSessionPrevention() throws {
        let created = CreatedSessions()
        let manager = makeManager(createdSessions: created)

        let profile = ConnectionProfile(name: "DupTest", protocolType: .ssh, host: "192.0.2.1", port: 22)

        // Open first session
        let openedFirst = manager.openSession(for: profile)
        #expect(openedFirst == .opened)
        #expect(manager.sessions.count == 1)
        #expect(manager.activeSessionId != nil)
        #expect(created.all.count == 1)
        #expect(created.all[0].connectCalls == 1)

        // Attempt to open duplicate
        let openedSecond = manager.openSession(for: profile)

        // Should return .duplicate and not create a new session
        #expect(openedSecond == .duplicate)
        #expect(manager.sessions.count == 1)
        #expect(created.all.count == 1)

        // Should have updated activeSessionId to the existing session
        let existingSessionId = manager.sessions.first?.id
        #expect(manager.activeSessionId == existingSessionId)
    }

    @Test("Enforce maximum concurrent session limit without spawning child processes")
    func testMaxSessionLimit() throws {
        let created = CreatedSessions()
        let manager = makeManager(createdSessions: created)

        let max = ConnectionManager.maxSessions

        for i in 0..<max {
            let host = "192.0.2.\(min(i + 1, 254))"
            let profile = ConnectionProfile(name: "MaxTest \(i)", protocolType: .ssh, host: host, port: 22)
            let opened = manager.openSession(for: profile)
            #expect(opened == .opened)
        }

        #expect(manager.sessions.count == max)
        #expect(created.all.count == max)

        // Attempt to open one more
        let excessProfile = ConnectionProfile(name: "Excess", protocolType: .ssh, host: "192.0.2.255", port: 22)
        let openedExcess = manager.openSession(for: excessProfile)

        // Should be rejected
        #expect(openedExcess == .limitReached)
        #expect(manager.sessions.count == max)
        #expect(created.all.count == max)
    }

    @Test("Allow new session for profile if previous session is closed")
    func testAllowSessionIfPreviousDisconnected() throws {
        let manager = makeManager()

        let profile = ConnectionProfile(name: "ReconnectTest", protocolType: .ssh, host: "192.0.2.1", port: 22)

        // Open session
        let openedFirst = manager.openSession(for: profile)
        #expect(openedFirst == .opened)

        // Close session
        let session = manager.sessions.first!
        manager.closeSession(session)
        #expect(manager.sessions.count == 0)

        // Now it should allow reopening
        let openedSecond = manager.openSession(for: profile)
        #expect(openedSecond == .opened)
        #expect(manager.sessions.count == 1)
    }

    @Test("Late status callback does not re-insert closed session into sessionStatuses (ISSUE-015)")
    func testLateStatusCallbackDoesNotReinsertSession() async throws {
        let created = CreatedSessions()
        let manager = makeManager(createdSessions: created)

        let profile = ConnectionProfile(name: "LateStatusTest", protocolType: .ssh, host: "192.0.2.1", port: 22)
        let opened = manager.openSession(for: profile)
        #expect(opened == .opened)

        let fake = created.all.first!
        let sessionId = fake.id
        #expect(manager.sessionStatuses[sessionId] != nil)

        // Close session: delegate should be nilled and sessionStatuses removed
        manager.closeSession(fake)
        #expect(fake.delegate == nil)
        #expect(manager.sessionStatuses[sessionId] == nil)

        // Simulate a late asynchronous status callback
        fake.simulateAsyncStatusChange(.error("Late network error"))

        // Drain runloop
        for _ in 0..<5 {
            await Task.yield()
        }

        // sessionStatuses must remain nil
        #expect(manager.sessionStatuses[sessionId] == nil)
        #expect(manager.status(for: sessionId) == .disconnected)
    }

    @Test("Status callback for non-existent session is a no-op (ISSUE-008: outputBuffers/sessionDidReceiveOutput removed as dead code)")
    func testCallbacksForUnknownSessionAreNoOps() {
        let manager = makeManager()
        let orphanSession = FakeSession(profileName: "Orphan")

        // Directly invoke the delegate method for a session not registered in manager
        manager.sessionDidChangeStatus(orphanSession, status: .connected)
        #expect(manager.sessionStatuses[orphanSession.id] == nil)

        // A second late callback must still be a no-op — same guard as ISSUE-015.
        manager.sessionDidChangeStatus(orphanSession, status: .error("late"))
        #expect(manager.sessionStatuses[orphanSession.id] == nil)
    }

    @Test("openSession rejects an invalid host without opening a session (ISSUE-016: OpenResult.hostInvalid)")
    func testOpenSessionHostInvalid() throws {
        let created = CreatedSessions()
        let manager = makeManager(createdSessions: created)

        // ConnectionProfile's own initializer does not re-validate the host,
        // so this bypasses UI validation the way a mutated/imported profile
        // could — exactly what openSession's re-validation guards against.
        let profile = ConnectionProfile(name: "BadHost", protocolType: .ssh, host: "", port: 22)

        let result = manager.openSession(for: profile)
        guard case .hostInvalid(let reason) = result else {
            Issue.record("expected .hostInvalid, got \(result)")
            return
        }
        #expect(!reason.isEmpty)
        #expect(manager.sessions.isEmpty)
        #expect(created.all.isEmpty)
    }

    @Test("ConnectionManager.defaultFactory threads SecuritySettings.rdpIgnoreCertificate into RDPSession (regression fix)")
    func testDefaultFactoryPassesRDPCertSetting() async throws {
        let original = SecuritySettings.shared.rdpIgnoreCertificate
        defer { SecuritySettings.shared.rdpIgnoreCertificate = original }
        SecuritySettings.shared.rdpIgnoreCertificate = true

        let profile = ConnectionProfile(name: "RDPFactoryRegression", protocolType: .rdp, host: "192.0.2.50", port: 3389)
        let session = ConnectionManager.defaultFactory(profile, nil)
        guard let rdpSession = session as? RDPSession else {
            Issue.record("ConnectionManager.defaultFactory did not produce an RDPSession for an .rdp profile")
            return
        }

        // `ignoreCert`/`clipboard` are `private let` on RDPSession (by
        // design — PROBLEMS.md ISSUE-032's fix), so they cannot be read
        // directly even via @testable from this file. The only externally
        // observable evidence that the factory threaded the live
        // SecuritySettings value through to RDPSession's initializer is the
        // certificate warning RDPSession itself logs when it actually
        // launches with ignoreCert == true (RDPSession.swift:280). We do
        // not edit RDPSession.swift to add a test seam; this is the
        // pre-existing seam.
        //
        // /usr/bin/yes tolerates arbitrary argv (used the same way in
        // RDPArgumentsTests' ISSUE-010 test), standing in for xfreerdp so
        // the test doesn't need FreeRDP installed.
        rdpSession.xfreerdpLocator = { "/usr/bin/yes" }
        rdpSession.connect()
        defer { rdpSession.disconnect() }

        // PROBLEMS.md ISSUE-033: don't poll AppLogger.shared.entries. That
        // shared in-memory ring buffer is capped at 1000 and
        // StressTests.testLoggerRingBuffer floods it with 1500 rapid
        // entries elsewhere in this same suite run; under the full parallel
        // test run that flood empirically evicted this kind of assertion's
        // target entry even with a generous (8-10 s) polling deadline,
        // while it passed instantly every time run in isolation. Waiting
        // longer doesn't fix a shared mutable buffer another test is
        // actively churning.
        //
        // AppLogger also persists every entry to
        // ~/Library/Logs/RemminaMac/RemminaMac.log via a dedicated serial
        // queue, append-only and rotated only at 5 MB — not subject to the
        // in-memory 1000-entry churn — so read that instead.
        let logFileURL = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/RemminaMac/RemminaMac.log")
        var sawCertIgnoreWarning = false
        let deadline = Date().addingTimeInterval(8.0 * ciDeadlineScale)
        while Date() < deadline {
            if let contents = try? String(contentsOf: logFileURL, encoding: .utf8),
               contents.contains("/cert:ignore") {
                sawCertIgnoreWarning = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(sawCertIgnoreWarning, "RDPSession built by ConnectionManager.defaultFactory with rdpIgnoreCertificate=true must launch with /cert:ignore, proving the factory threaded the live SecuritySettings value through rather than leaving ignoreCert at its default")
    }

    @Test("closeAll cleans up all sessions and nils delegates")
    func testCloseAllCleansUp() {
        let created = CreatedSessions()
        let manager = makeManager(createdSessions: created)

        for i in 1...3 {
            let profile = ConnectionProfile(name: "CloseAll \(i)", protocolType: .ssh, host: "192.0.2.\(i)", port: 22)
            manager.openSession(for: profile)
        }

        #expect(manager.sessions.count == 3)
        #expect(manager.sessionStatuses.count == 3)

        manager.closeAll()

        #expect(manager.sessions.isEmpty)
        #expect(manager.sessionStatuses.isEmpty)
        #expect(manager.activeSessionId == nil)
        for s in created.all {
            #expect(s.delegate == nil)
            #expect(s.disconnectCalls == 1)
        }
    }
}
