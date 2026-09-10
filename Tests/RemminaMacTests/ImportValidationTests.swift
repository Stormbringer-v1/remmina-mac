import Testing
import Foundation
import SwiftData
@testable import RemminaMac

@Suite("ProfileImportExport Security Tests")
@MainActor
struct ImportValidationTests {

    /// In-memory ProfileStore for end-to-end import tests (PROBLEMS.md
    /// ISSUE-001), mirroring the helper in ProfileStoreIntegrationTests.swift.
    private func makeTestStore() throws -> ProfileStore {
        let schema = Schema([ConnectionProfile.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ProfileStore(modelContext: ModelContext(container))
    }
    
    // MARK: - File Size Limits
    
    @Test("Accept file under 1MB")
    func testAcceptSmallFile() throws {
        let smallJSON = """
        {
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": [
                {
                    "name": "Test",
                    "protocolType": "SSH",
                    "host": "example.com",
                    "port": 22,
                    "username": "admin",
                    "domain": "",
                    "notes": "",
                    "tags": [],
                    "isFavorite": false,
                    "connectOnOpen": false,
                    "sshKeyPath": null
                }
            ]
        }
        """
        let data = Data(smallJSON.utf8)
        let profiles = try ProfileImportExport.importProfiles(from: data)
        #expect(profiles.count == 1)
    }
    
    @Test("Reject file over 1MB")
    func testRejectOversizedFile() {
        let largeData = Data(repeating: 0x20, count: 1_024 * 1024 + 1)
        
        do {
            _ = try ProfileImportExport.importProfiles(from: largeData)
            #expect(Bool(false), "Should have thrown error")
        } catch {
            // Expected error
        }
    }
    
    // MARK: - Profile Count Limits
    
    @Test("Accept 500 profiles")
    func testAccept500Profiles() throws {
        var profiles: [[String: Any]] = []
        for _ in 1...500 {
            profiles.append([
                "name": "Server",
                "protocolType": "SSH",
                "host": "example.com",
                "port": 22,
                "username": "admin",
                "domain": "",
                "notes": "",
                "tags": [],
                "isFavorite": false,
                "connectOnOpen": false
            ])
        }
        
        let exportData: [String: Any] = [
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": profiles
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: exportData)
        let imported = try ProfileImportExport.importProfiles(from: jsonData)
        #expect(imported.count == 500)
    }
    
    @Test("Reject 501 profiles")
    func testReject501Profiles() throws {
        var profiles: [[String: Any]] = []
        for _ in 1...501 {
            profiles.append([
                "name": "Server",
                "protocolType": "SSH",
                "host": "example.com",
                "port": 22,
                "username": "admin",
                "domain": "",
                "notes": "",
                "tags": [],
                "isFavorite": false,
                "connectOnOpen": false
            ])
        }
        
        let exportData: [String: Any] = [
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": profiles
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: exportData)
        
        do {
            _ = try ProfileImportExport.importProfiles(from: jsonData)
            #expect(Bool(false), "Should have thrown error")
        } catch {
            // Expected error
        }
    }
    
    // MARK: - Malformed JSON
    
    @Test("Reject invalid JSON")
    func testRejectInvalidJSON() {
        let invalidJSON = "{ this is not valid json }"
        let data = Data(invalidJSON.utf8)
        
        do {
            _ = try ProfileImportExport.importProfiles(from: data)
            #expect(Bool(false), "Should have thrown error")
        } catch {
            // Expected error
        }
    }
    
    @Test("Reject wrong version")
    func testRejectWrongVersion() throws {
        let wrongVersionJSON = """
        {
            "version": 999,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": []
        }
        """
        let data = Data(wrongVersionJSON.utf8)
        
        do {
            _ = try ProfileImportExport.importProfiles(from: data)
            #expect(Bool(false), "Should have thrown error")
        } catch {
            // Expected error
        }
    }
    
    // MARK: - Field Validation
    
    @Test("Reject empty name")
    func testRejectEmptyName() throws {
        let json = """
        {
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": [{
                "name": "",
                "protocolType": "SSH",
                "host": "example.com",
                "port": 22,
                "username": "admin",
                "domain": "",
                "notes": "",
                "tags": [],
                "isFavorite": false,
                "connectOnOpen": false
            }]
        }
        """
        let data = Data(json.utf8)
        
        do {
            _ = try ProfileImportExport.importProfiles(from: data)
            #expect(Bool(false), "Should have thrown error")
        } catch is ProfileImportExport.ImportError {
            // Expected
        }
    }
    
    @Test("Reject invalid protocol")
    func testRejectInvalidProtocol() throws {
        let json = """
        {
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": [{
                "name": "Test",
                "protocolType": "TELNET",
                "host": "example.com",
                "port": 22,
                "username": "admin",
                "domain": "",
                "notes": "",
                "tags": [],
                "isFavorite": false,
                "connectOnOpen": false
            }]
        }
        """
        let data = Data(json.utf8)
        
        do {
            _ = try ProfileImportExport.importProfiles(from: data)
            #expect(Bool(false), "Should have thrown error")
        } catch is ProfileImportExport.ImportError {
            // Expected
        }
    }
    
    @Test("Reject invalid port (0)")
    func testRejectPort0() throws {
        let json = """
        {
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": [{
                "name": "Test",
                "protocolType": "SSH",
                "host": "example.com",
                "port": 0,
                "username": "admin",
                "domain": "",
                "notes": "",
                "tags": [],
                "isFavorite": false,
                "connectOnOpen": false
            }]
        }
        """
        let data = Data(json.utf8)
        
        do {
            _ = try ProfileImportExport.importProfiles(from: data)
            #expect(Bool(false), "Should have thrown error")
        } catch is ProfileImportExport.ImportError {
            // Expected
        }
    }
    
    @Test("Reject invalid port (65536)")
    func testRejectPort65536() throws {
        let json = """
        {
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": [{
                "name": "Test",
                "protocolType": "SSH",
                "host": "example.com",
                "port": 65536,
                "username": "admin",
                "domain": "",
                "notes": "",
                "tags": [],
                "isFavorite": false,
                "connectOnOpen": false
            }]
        }
        """
        let data = Data(json.utf8)
        
        do {
            _ = try ProfileImportExport.importProfiles(from: data)
            #expect(Bool(false), "Should have thrown error")
        } catch is ProfileImportExport.ImportError {
            // Expected
        }
    }
    
    @Test("Reject name too long")
    func testRejectNameTooLong() throws {
        let longName = String(repeating: "a", count: 101)
        let json = """
        {
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": [{
                "name": "\(longName)",
                "protocolType": "SSH",
                "host": "example.com",
                "port": 22,
                "username": "admin",
                "domain": "",
                "notes": "",
                "tags": [],
                "isFavorite": false,
                "connectOnOpen": false
            }]
        }
        """
        let data = Data(json.utf8)
        
        do {
            _ = try ProfileImportExport.importProfiles(from: data)
            #expect(Bool(false), "Should have thrown error")
        } catch is ProfileImportExport.ImportError {
            // Expected
        }
    }
    
    @Test("Reject username too long")
    func testRejectUsernameTooLong() throws {
        let longUsername = String(repeating: "a", count: 65)
        let json = """
        {
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": [{
                "name": "Test",
                "protocolType": "SSH",
                "host": "example.com",
                "port": 22,
                "username": "\(longUsername)",
                "domain": "",
                "notes": "",
                "tags": [],
                "isFavorite": false,
                "connectOnOpen": false
            }]
        }
        """
        let data = Data(json.utf8)
        
        do {
            _ = try ProfileImportExport.importProfiles(from: data)
            #expect(Bool(false), "Should have thrown error")
        } catch is ProfileImportExport.ImportError {
            // Expected
        }
    }
    
    @Test("Reject too many tags")
    func testRejectTooManyTags() throws {
        let tags = (1...11).map { i in "tag\(i)" }
        let tagsJSON = tags.map { "\"\($0)\"" }.joined(separator: ",")
        
        let json = """
        {
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": [{
                "name": "Test",
                "protocolType": "SSH",
                "host": "example.com",
                "port": 22,
                "username": "admin",
                "domain": "",
                "notes": "",
                "tags": [\(tagsJSON)],
                "isFavorite": false,
                "connectOnOpen": false
            }]
        }
        """
        let data = Data(json.utf8)
        
        do {
            _ = try ProfileImportExport.importProfiles(from: data)
            #expect(Bool(false), "Should have thrown error")
        } catch is ProfileImportExport.ImportError {
            // Expected
        }
    }

    // MARK: - ISSUE-001: import with a missing SSH key

    /// End-to-end: parse an export whose sshKeyPath points at a file that
    /// does not exist on this machine, then run it through the same
    /// ProfileStore.add(_:allowMissingSSHKey:) call MainView.importProfiles()
    /// makes. This must succeed (unlike the create path, which keeps the
    /// strict default) and must log a warning naming the missing path.
    @Test("Import succeeds with a missing SSH key file and logs a warning naming the path")
    func testImportSucceedsWithMissingSSHKey() async throws {
        let missingKeyPath = "~/.ssh/id_rsa_issue001_\(UUID().uuidString)"
        let json = """
        {
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": [{
                "name": "ImportMissingKey",
                "protocolType": "SSH",
                "host": "example.com",
                "port": 22,
                "username": "admin",
                "domain": "",
                "notes": "",
                "tags": [],
                "isFavorite": false,
                "connectOnOpen": false,
                "sshKeyPath": "\(missingKeyPath)"
            }]
        }
        """
        let data = Data(json.utf8)

        let imported = try ProfileImportExport.importProfiles(from: data)
        #expect(imported.count == 1)
        let profile = imported[0]
        #expect(!FileManager.default.fileExists(atPath: NSString(string: profile.sshKeyPath).expandingTildeInPath))

        let store = try makeTestStore()
        // This is the exact call MainView.importProfiles() makes
        // (PROBLEMS.md ISSUE-001) — must not throw despite the missing key.
        try store.add(profile, allowMissingSSHKey: true)

        #expect(store.allProfiles().count == 1)

        // A warning naming the missing path should have been logged.
        //
        // PROBLEMS.md ISSUE-033: this deliberately does NOT check
        // AppLogger.shared.entries. That shared in-memory ring buffer is
        // capped at 1000 and StressTests.testLoggerRingBuffer floods it
        // with 1500 rapid entries elsewhere in this same suite run; under
        // the full parallel test run that flood reliably evicted this
        // test's entry (confirmed empirically: failed in 6 of 7 full-suite
        // runs at both a 3 s and an 8 s polling deadline, yet passed
        // instantly every time run in isolation). Waiting longer doesn't
        // fix a shared mutable buffer another test is actively churning.
        //
        // AppLogger also persists every entry to
        // ~/Library/Logs/RemminaMac/RemminaMac.log via a dedicated serial
        // queue, append-only and rotated only at 5 MB — not subject to the
        // in-memory 1000-entry churn — so read that instead. The path is
        // suffixed with a random UUID, so a match cannot be a stale line
        // from a previous run or a different test.
        let logFileURL = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/RemminaMac/RemminaMac.log")
        var sawWarning = false
        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            if let contents = try? String(contentsOf: logFileURL, encoding: .utf8),
               contents.split(separator: "\n").contains(where: { line in
                   line.contains("[WARN]") && line.contains(profile.sshKeyPath)
               }) {
                sawWarning = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(sawWarning, "ProfileStore.add should log a .warning naming the missing SSH key path when allowMissingSSHKey is true")
    }

    @Test("Import with a missing SSH key fails when allowMissingSSHKey is not set (create-path default)")
    func testCreatePathStillRejectsMissingSSHKey() throws {
        let missingKeyPath = "~/.ssh/id_rsa_issue001_create_\(UUID().uuidString)"
        let json = """
        {
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": [{
                "name": "CreatePathMissingKey",
                "protocolType": "SSH",
                "host": "example.com",
                "port": 22,
                "username": "admin",
                "domain": "",
                "notes": "",
                "tags": [],
                "isFavorite": false,
                "connectOnOpen": false,
                "sshKeyPath": "\(missingKeyPath)"
            }]
        }
        """
        let data = Data(json.utf8)
        let profile = try ProfileImportExport.importProfiles(from: data)[0]

        let store = try makeTestStore()
        #expect(throws: (any Error).self) {
            // Default allowMissingSSHKey: false — the create path (MainView
            // line ~87) must keep rejecting a missing key file.
            try store.add(profile)
        }
        #expect(store.allProfiles().isEmpty)
    }
}
