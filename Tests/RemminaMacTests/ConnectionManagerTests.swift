import Testing
import Foundation
@testable import RemminaMac

@Suite("ConnectionManager Integration Tests")
struct ConnectionManagerTests {

    @Test("Prevent duplicate active sessions for same profile")
    func testDuplicateSessionPrevention() throws {
        let manager = ConnectionManager()
        
        let profile = ConnectionProfile(name: "DupTest", protocolType: .ssh, host: "192.168.1.1", port: 22)
        
        // Open first session
        let openedFirst = manager.openSession(for: profile)
        #expect(openedFirst == true)
        #expect(manager.sessions.count == 1)
        #expect(manager.activeSessionId != nil)
        
        // Attempt to open duplicate
        let openedSecond = manager.openSession(for: profile)
        
        // Should return false and not create a new session
        #expect(openedSecond == false)
        #expect(manager.sessions.count == 1)
        
        // Should have updated activeSessionId to the existing session
        let existingSessionId = manager.sessions.first?.id
        #expect(manager.activeSessionId == existingSessionId)
    }
    
    @Test("Enforce maximum concurrent session limit")
    func testMaxSessionLimit() throws {
        let manager = ConnectionManager()
        
        let max = ConnectionManager.maxSessions
        
        // Open up to max sessions
        for i in 0..<max {
            let profile = ConnectionProfile(name: "MaxTest \(i)", protocolType: .ssh, host: "192.168.1.\(min(i + 1, 254))", port: 22)
            let opened = manager.openSession(for: profile)
            #expect(opened == true)
        }
        
        #expect(manager.sessions.count == max)
        
        // Attempt to open one more
        let excessProfile = ConnectionProfile(name: "Excess", protocolType: .ssh, host: "192.168.1.255", port: 22)
        let openedExcess = manager.openSession(for: excessProfile)
        
        // Should be rejected
        #expect(openedExcess == false)
        #expect(manager.sessions.count == max)
    }
    
    @Test("Allow new session for profile if previous session is disconnected")
    func testAllowSessionIfPreviousDisconnected() throws {
        let manager = ConnectionManager()
        
        let profile = ConnectionProfile(name: "ReconnectTest", protocolType: .ssh, host: "192.168.1.1", port: 22)
        
        // Open session
        let openedFirst = manager.openSession(for: profile)
        #expect(openedFirst == true)
        
        // Simulate disconnection by setting status directly or calling closeSession
        manager.closeSession(manager.sessions.first!)
        #expect(manager.sessions.count == 0)
        
        // Now it should allow reopening
        let openedSecond = manager.openSession(for: profile)
        #expect(openedSecond == true)
        #expect(manager.sessions.count == 1)
    }
}
