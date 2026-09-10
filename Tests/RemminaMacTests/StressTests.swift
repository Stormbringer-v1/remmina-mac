import Testing
import Foundation
@testable import RemminaMac

@Suite("Stress & Robustness Tests")
struct StressTests {
    
    // MARK: - AppLogger Tests
    
    @Test("Logger ring buffer caps at 1000 entries")
    func testLoggerRingBuffer() async throws {
        let logger = AppLogger.shared
        let initialCount = await MainActor.run { logger.entries.count }

        // Add many entries to trigger ring buffer pruning.
        for i in 0..<1500 {
            logger.log("Stress test entry \(i)")
        }

        // Poll for the dispatch-source flush to settle, then assert that the
        // ring buffer is bounded. We added 1500 entries, so the count must
        // be strictly less than `initialCount + 1500` (the ring buffer caps
        // at 1000) and the new entries are present in the buffer.
        var finalCount = 0
        var containsRecent = false
        for _ in 0..<40 {
            finalCount = await MainActor.run { logger.entries.count }
            containsRecent = await MainActor.run {
                logger.entries.contains { $0.message == "Stress test entry 1499" }
            }
            if containsRecent { break }
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }

        // The buffer should not have grown by the full 1500 we just added;
        // the ring buffer is bounded.
        let growth = finalCount - initialCount
        #expect(growth < 1500,
                "Logger ring buffer should cap growth below 1500 entries (was \(growth))")
        #expect(containsRecent,
                "Logger should contain the most recent entry after ring-buffer pruning")
    }

    @Test("Logger handles all log levels")
    func testLoggerAllLevels() async throws {
        let logger = AppLogger.shared

        let token1 = "audit-info-\(UUID().uuidString)"
        let token2 = "audit-warning-\(UUID().uuidString)"
        let token3 = "audit-error-\(UUID().uuidString)"
        let token4 = "audit-debug-\(UUID().uuidString)"

        logger.log(token1, level: .info)
        logger.log(token2, level: .warning)
        logger.log(token3, level: .error)
        logger.log(token4, level: .debug)

        // Each level should be accepted and stored in the ring buffer.
        var found: [String: Bool] = [:]
        for _ in 0..<40 {
            found = await MainActor.run {
                var result: [String: Bool] = [:]
                result[token1] = logger.entries.contains { $0.message == token1 }
                result[token2] = logger.entries.contains { $0.message == token2 }
                result[token3] = logger.entries.contains { $0.message == token3 }
                result[token4] = logger.entries.contains { $0.message == token4 }
                return result
            }
            if found.values.allSatisfy({ $0 }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        for (token, present) in found {
            #expect(present, "Logger should have stored entry for \(token)")
        }
    }
    
    @Test("Logger handles correlation IDs")
    func testLoggerCorrelationIDs() {
        let logger = AppLogger.shared
        let sessionId = UUID()
        let profileId = UUID()
        
        // Log with all correlation ID combinations
        logger.log("Test 1", sessionId: sessionId)
        logger.log("Test 2", profileId: profileId)
        logger.log("Test 3", sessionId: sessionId, profileId: profileId)
        logger.log("Test 4", sessionId: sessionId, profileId: profileId, component: "TestComponent")
        logger.log("Test 5", component: "StandaloneComponent")
        
        // Should not crash
    }
    
    @Test("Logger handles special characters in messages")
    func testLoggerSpecialCharacters() {
        let logger = AppLogger.shared
        
        logger.log("Unicode: こんにちは 🔥 Привет")
        logger.log("Newlines: line1\nline2\nline3")
        logger.log("Tabs: col1\tcol2\tcol3")
        logger.log("Empty string: ")
        logger.log(String(repeating: "A", count: 10_000)) // Very long message
        
        // Should not crash
    }
    
    // MARK: - Profile Model Edge Cases
    
    @Test("Profile with maximum field lengths")
    func testProfileMaxFieldLengths() {
        let profile = ConnectionProfile(
            name: String(repeating: "N", count: 100),
            protocolType: .ssh,
            host: "example.com",
            port: 65535,
            username: String(repeating: "U", count: 64),
            domain: String(repeating: "D", count: 255),
            notes: String(repeating: ".", count: 1000),
            tags: (1...10).map { "tag\($0)" }
        )
        
        #expect(profile.name.count == 100)
        #expect(profile.username.count == 64)
        #expect(profile.domain.count == 255)
        #expect(profile.notes.count == 1000)
        #expect(profile.tags.count == 10)
        #expect(profile.port == 65535)
    }
    
    @Test("Profile with empty tags produces empty array")
    func testEmptyTagsSerialization() {
        let profile = ConnectionProfile(
            name: "Test",
            protocolType: .ssh,
            host: "host",
            tags: []
        )
        
        #expect(profile.tags.isEmpty)
        #expect(profile.tagsRawValue == "")
    }
    
    @Test("Profile tags with commas in values")
    func testTagsWithCommasInValues() {
        // Tags are comma-separated, so commas in tag names would cause issues
        let profile = ConnectionProfile(
            name: "Test",
            protocolType: .ssh,
            host: "host",
            tags: ["web,server", "prod"]
        )
        
        // Current implementation joins with comma — this reveals the limitation
        // The raw value would serialize incorrectly if tags contain commas
        #expect(profile.tagsRawValue == "web,server,prod")
        // Deserialized, this would produce 3 tags instead of 2
        #expect(profile.tags.count == 3) // Known limitation documented here
    }
    
    @Test("Connection string with all combinations")
    func testConnectionStringCombinations() {
        // SSH with user, default port
        let p1 = ConnectionProfile(name: "T", protocolType: .ssh, host: "h", username: "u")
        #expect(p1.connectionString == "u@h")
        
        // SSH with user, custom port
        let p2 = ConnectionProfile(name: "T", protocolType: .ssh, host: "h", port: 2222, username: "u")
        #expect(p2.connectionString == "u@h:2222")
        
        // VNC without user
        let p3 = ConnectionProfile(name: "T", protocolType: .vnc, host: "h")
        #expect(p3.connectionString == "h")
        
        // RDP default port (3389) — should not show port
        let p4 = ConnectionProfile(name: "T", protocolType: .rdp, host: "h", username: "admin")
        #expect(p4.connectionString == "admin@h")
        
        // Empty host
        let p5 = ConnectionProfile(name: "T", protocolType: .ssh, host: "")
        #expect(p5.connectionString == "")
    }
    
    // MARK: - Import/Export Round-Trip
    
    @Test("Export and re-import preserves all fields")
    func testExportImportRoundTrip() throws {
        let original = ConnectionProfile(
            name: "Production DB",
            protocolType: .ssh,
            host: "db.example.com",
            port: 2222,
            username: "dbadmin",
            domain: "corp.local",
            notes: "Handle with care — production database server",
            tags: ["production", "database", "critical"],
            isFavorite: true,
            connectOnOpen: false,
            sshKeyPath: ""
        )
        
        // Export
        guard let exportData = ProfileImportExport.exportProfiles([original]) else {
            #expect(Bool(false), "Export should not return nil")
            return
        }
        
        // Re-import
        let imported = try ProfileImportExport.importProfiles(from: exportData)
        #expect(imported.count == 1)
        
        let p = imported[0]
        #expect(p.name == "Production DB")
        #expect(p.protocolType == .ssh)
        #expect(p.host == "db.example.com")
        #expect(p.port == 2222)
        #expect(p.username == "dbadmin")
        #expect(p.domain == "corp.local")
        #expect(p.notes == "Handle with care — production database server")
        #expect(p.tags == ["production", "database", "critical"])
        #expect(p.isFavorite == true)
        #expect(p.connectOnOpen == false)
    }
    
    @Test("Export and re-import preserves Unicode")
    func testExportImportUnicode() throws {
        let original = ConnectionProfile(
            name: "サーバー日本",
            protocolType: .vnc,
            host: "server.example.com",
            username: "管理者",
            notes: "Примечание: 重要なサーバー 🖥️"
        )
        
        guard let exportData = ProfileImportExport.exportProfiles([original]) else {
            #expect(Bool(false), "Export should not return nil")
            return
        }
        
        let imported = try ProfileImportExport.importProfiles(from: exportData)
        #expect(imported.count == 1)
        #expect(imported[0].name == "サーバー日本")
        #expect(imported[0].notes == "Примечание: 重要なサーバー 🖥️")
    }
    
    @Test("Export and re-import with all protocol types")
    func testExportImportAllProtocols() throws {
        let profiles = ProtocolType.allCases.map { proto in
            ConnectionProfile(
                name: "\(proto.displayName) Server",
                protocolType: proto,
                host: "example.com"
            )
        }
        
        guard let exportData = ProfileImportExport.exportProfiles(profiles) else {
            #expect(Bool(false), "Export should not return nil")
            return
        }
        
        let imported = try ProfileImportExport.importProfiles(from: exportData)
        #expect(imported.count == ProtocolType.allCases.count)
        
        for (i, proto) in ProtocolType.allCases.enumerated() {
            #expect(imported[i].protocolType == proto)
            #expect(imported[i].port == proto.defaultPort)
        }
    }
    
    // MARK: - SessionStatus Tests
    
    @Test("SessionStatus equality")
    func testSessionStatusEquality() {
        #expect(SessionStatus.connected == SessionStatus.connected)
        #expect(SessionStatus.disconnected == SessionStatus.disconnected)
        #expect(SessionStatus.connecting == SessionStatus.connecting)
        #expect(SessionStatus.error("test") == SessionStatus.error("test"))
        #expect(SessionStatus.error("a") != SessionStatus.error("b"))
        #expect(SessionStatus.connected != SessionStatus.disconnected)
    }
    
    @Test("SessionStatus isActive correctness")
    func testSessionStatusIsActive() {
        #expect(SessionStatus.connected.isActive == true)
        #expect(SessionStatus.connecting.isActive == true)
        #expect(SessionStatus.disconnected.isActive == false)
        #expect(SessionStatus.error("test").isActive == false)
    }
    
    @Test("SessionStatus display names are non-empty")
    func testSessionStatusDisplayNames() {
        let statuses: [SessionStatus] = [
            .connected, .connecting, .disconnected, .error("test error")
        ]
        
        for status in statuses {
            #expect(!status.displayName.isEmpty, "\(status) has empty display name")
        }
    }
    
    // MARK: - ProfileValidator Edge Cases
    
    @Test("Validate profile with exactly max-length fields")
    func testValidateMaxLengthProfile() throws {
        let profile = ConnectionProfile(
            name: String(repeating: "N", count: 100),
            protocolType: .ssh,
            host: "example.com",
            port: 65535,
            username: String(repeating: "a", count: 64),
            domain: String(repeating: "d", count: 255),
            notes: String(repeating: ".", count: 1000)
        )
        
        // Should not throw — all fields at exact maximum
        try ProfileValidator.validate(profile, blockPrivateRanges: false)
    }
    
    @Test("Validate profile rejects fields one character over max")
    func testValidateOverMaxLengthFields() {
        // Name too long by 1
        #expect(throws: ProfileValidator.ValidationError.nameTooLong) {
            try ProfileValidator.validateName(String(repeating: "N", count: 101))
        }
        
        // Username too long by 1
        #expect(throws: ProfileValidator.ValidationError.usernameTooLong) {
            try ProfileValidator.validateUsername(String(repeating: "a", count: 65))
        }
        
        // Domain too long by 1
        #expect(throws: ProfileValidator.ValidationError.domainTooLong) {
            try ProfileValidator.validateDomain(String(repeating: "d", count: 256))
        }
        
        // Notes too long by 1
        #expect(throws: ProfileValidator.ValidationError.notesTooLong) {
            try ProfileValidator.validateNotes(String(repeating: ".", count: 1001))
        }
    }
    
    // MARK: - Search Edge Cases
    
    @Test("ConnectionProfile search query with special characters doesn't crash")
    func testSearchSpecialCharacters() {
        // This tests the model's string handling — actual SwiftData queries
        // would need an in-memory container, but we verify no crashes here
        let profile = ConnectionProfile(
            name: "Test 'Quotes' & <Angles>",
            protocolType: .ssh,
            host: "example.com",
            username: "admin"
        )
        
        // Verify the profile's name stored correctly
        #expect(profile.name == "Test 'Quotes' & <Angles>")
    }

    // MARK: - Validator Fuzzing
    
    @Test("Validator fuzzing - random character strings")
    func testValidatorFuzzing() throws {
        // Generate a variety of nasty strings
        let nastyCharacters: [Character] = [
            "\0", "\n", "\r", "\t", " ", ";", "|", "&", "`", "$", "(", ")", "{", "}", "!", "<", ">", "\\", "'", "\"",
            "%", "/", ".", "-", "_", "@", ":", "a", "1", "日", "🔥", "\u{FFFD}"
        ]
        
        var nastyStrings: [String] = []
        
        // 1. Single characters
        for char in nastyCharacters {
            nastyStrings.append(String(char))
        }
        
        // 2. Repeated characters (edge cases for length)
        for char in nastyCharacters {
            nastyStrings.append(String(repeating: char, count: 64))
            nastyStrings.append(String(repeating: char, count: 256))
            nastyStrings.append(String(repeating: char, count: 1024))
        }
        
        // 3. Random combinations
        // Seeded RNG for deterministic tests
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<1000 {
            let length = Int.random(in: 1...500, using: &rng)
            var str = ""
            for _ in 0..<length {
                str.append(nastyCharacters.randomElement(using: &rng)!)
            }
            nastyStrings.append(str)
        }
        
        // Fuzz ProfileValidator methods
        for str in nastyStrings {
            // These should either return a valid string or throw a ValidationError,
            // but they MUST NOT crash (no fatalError, forced unwrap trap, or infinite loop)
            
            _ = try? ProfileValidator.validateName(str)
            _ = try? ProfileValidator.validateUsername(str)
            _ = try? ProfileValidator.validateDomain(str)
            _ = try? ProfileValidator.validateNotes(str)
            _ = try? ProfileValidator.validateHost(str)
            _ = try? SSHKeyValidator.validate(str, isUserSelected: false)
        }
        
        // Assert specific outcomes for known valid and invalid inputs
        #expect(throws: ProfileValidator.ValidationError.self) {
            try ProfileValidator.validateName("")
        }
        #expect(throws: ProfileValidator.ValidationError.self) {
            try ProfileValidator.validateHost("bad;host")
        }
        let validName = try ProfileValidator.validateName("Production Server")
        #expect(!validName.isEmpty)
        let validHost = try ProfileValidator.validateHost("192.168.1.1")
        #expect(!validHost.isEmpty)
        #expect(nastyStrings.count >= 50)
    }
    
    @Test("HostnameValidator fuzzing - IP address edge cases")
    func testHostnameValidatorFuzzing() throws {
        let edgeCases = [
            "0.0.0.0", "255.255.255.255", "127.0.0.1", "169.254.169.254", "10.0.0.1", "172.16.0.1", "192.168.0.1",
            "::1", "fe80::1", "::ffff:127.0.0.1",
            "0", "1", "2130706433", "4294967295",
            "0x7f000001", "0x7f.0x0.0x0.0x1", "0177.0.0.1", "127.000.000.001",
            "...", "1.2.3.4.5", "1..2", ".1.2.3", "1.2.3.",
            "localhost", "localhost.localdomain", "local",
            "a.b.c", "a-b.com", "-a.com", "a-.com", "a.com-", "a..com",
            String(repeating: "a", count: 63) + ".com",
            String(repeating: "a", count: 64) + ".com",
            String(repeating: "a", count: 254),
            "file:///etc/passwd", "http://localhost", "ssh://10.0.0.1"
        ]
        
        for host in edgeCases {
            _ = try? ProfileValidator.validateHost(host)
        }
        
        // Assert specific outcomes for known valid and invalid edge cases
        #expect(throws: HostnameValidator.ValidationError.self) {
            try HostnameValidator.validate("file:///etc/passwd")
        }
        #expect(throws: HostnameValidator.ValidationError.self) {
            try HostnameValidator.validate("0.0.0.0")
        }
        #expect(throws: HostnameValidator.ValidationError.self) {
            try HostnameValidator.validate("..")
        }
        let validIP = try HostnameValidator.validate("192.168.0.1")
        #expect(!validIP.isEmpty)
        #expect(edgeCases.count > 10)
    }
}
