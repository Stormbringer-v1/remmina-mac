import Testing
import Foundation
@testable import RemminaMac

@Suite("ProfileImportExport Security Tests")
struct ImportValidationTests {
    
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
}
