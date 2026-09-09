import Testing
import Foundation
@testable import RemminaMac

@Suite("ConnectionManager Integration Tests")
struct ConnectionManagerTests {

    private func makeManager(createdSessions: UnsafeMutablePointer<[FakeSession]>? = nil) -> ConnectionManager {
        ConnectionManager(sessionFactory: { profile, password in
            let session = FakeSession(profile: profile, password: password, initialStatus: .connected)
            createdSessions?.pointee.append(session)
            return session
        })
    }

    @Test("Prevent duplicate active sessions for same profile with FakeSession")
    func testDuplicateSessionPrevention() throws {
        var created: [FakeSession] = []
        let manager = withUnsafeMutablePointer(to: &created) { ptr in
            makeManager(createdSessions: ptr)
        }

        let profile = ConnectionProfile(name: "DupTest", protocolType: .ssh, host: "192.0.2.1", port: 22)

        // Open first session
        let openedFirst = manager.openSession(for: profile)
        #expect(openedFirst == true)
        #expect(manager.sessions.count == 1)
        #expect(manager.activeSessionId != nil)
        #expect(created.count == 1)
        #expect(created[0].connectCalls == 1)

        // Attempt to open duplicate
        let openedSecond = manager.openSession(for: profile)

        // Should return false and not create a new session
        #expect(openedSecond == false)
        #expect(manager.sessions.count == 1)
        #expect(created.count == 1)

        // Should have updated activeSessionId to the existing session
        let existingSessionId = manager.sessions.first?.id
        #expect(manager.activeSessionId == existingSessionId)
    }

    @Test("Enforce maximum concurrent session limit without spawning child processes")
    func testMaxSessionLimit() throws {
        var created: [FakeSession] = []
        let manager = withUnsafeMutablePointer(to: &created) { ptr in
            makeManager(createdSessions: ptr)
        }

        let max = ConnectionManager.maxSessions

        for i in 0..<max {
            let host = "192.0.2.\(min(i + 1, 254))"
            let profile = ConnectionProfile(name: "MaxTest \(i)", protocolType: .ssh, host: host, port: 22)
            let opened = manager.openSession(for: profile)
            #expect(opened == true)
        }

        #expect(manager.sessions.count == max)
        #expect(created.count == max)

        // Attempt to open one more
        let excessProfile = ConnectionProfile(name: "Excess", protocolType: .ssh, host: "192.0.2.255", port: 22)
        let openedExcess = manager.openSession(for: excessProfile)

        // Should be rejected
        #expect(openedExcess == false)
        #expect(manager.sessions.count == max)
        #expect(created.count == max)
    }

    @Test("Allow new session for profile if previous session is closed")
    func testAllowSessionIfPreviousDisconnected() throws {
        let manager = makeManager()

        let profile = ConnectionProfile(name: "ReconnectTest", protocolType: .ssh, host: "192.0.2.1", port: 22)

        // Open session
        let openedFirst = manager.openSession(for: profile)
        #expect(openedFirst == true)

        // Close session
        let session = manager.sessions.first!
        manager.closeSession(session)
        #expect(manager.sessions.count == 0)

        // Now it should allow reopening
        let openedSecond = manager.openSession(for: profile)
        #expect(openedSecond == true)
        #expect(manager.sessions.count == 1)
    }

    @Test("Late status callback does not re-insert closed session into sessionStatuses (ISSUE-015)")
    func testLateStatusCallbackDoesNotReinsertSession() async throws {
        var created: [FakeSession] = []
        let manager = withUnsafeMutablePointer(to: &created) { ptr in
            makeManager(createdSessions: ptr)
        }

        let profile = ConnectionProfile(name: "LateStatusTest", protocolType: .ssh, host: "192.0.2.1", port: 22)
        let opened = manager.openSession(for: profile)
        #expect(opened == true)

        let fake = created.first!
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

    @Test("Status callback and output for non-existent session are no-ops")
    func testCallbacksForUnknownSessionAreNoOps() {
        let manager = makeManager()
        let orphanSession = FakeSession(profileName: "Orphan")

        // Directly invoke delegate methods for a session not registered in manager
        manager.sessionDidChangeStatus(orphanSession, status: .connected)
        #expect(manager.sessionStatuses[orphanSession.id] == nil)

        manager.sessionDidReceiveOutput(orphanSession, data: Data("hello".utf8))
        #expect(manager.outputBuffers[orphanSession.id] == nil)
    }

    @Test("closeAll cleans up all sessions and nils delegates")
    func testCloseAllCleansUp() {
        var created: [FakeSession] = []
        let manager = withUnsafeMutablePointer(to: &created) { ptr in
            makeManager(createdSessions: ptr)
        }

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
        for s in created {
            #expect(s.delegate == nil)
            #expect(s.disconnectCalls == 1)
        }
    }
}
