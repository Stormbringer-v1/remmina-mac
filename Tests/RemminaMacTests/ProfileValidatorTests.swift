import Testing
import Foundation
@testable import RemminaMac

@Suite("ProfileValidator Tests")
struct ProfileValidatorTests {
    
    // MARK: - Name Validation
    
    @Test("Valid name")
    func testValidName() throws {
        let result = try ProfileValidator.validateName("Production Server")
        #expect(result == "Production Server")
    }
    
    @Test("Trim name whitespace")
    func testTrimNameWhitespace() throws {
        let result = try ProfileValidator.validateName("  Server  ")
        #expect(result == "Server")
    }
    
    @Test("Empty name throws")
    func testEmptyName() {
        #expect(throws: ProfileValidator.ValidationError.nameEmpty) {
            try ProfileValidator.validateName("")
        }
    }
    
    @Test("Whitespace-only name throws")
    func testWhitespaceOnlyName() {
        #expect(throws: ProfileValidator.ValidationError.nameEmpty) {
            try ProfileValidator.validateName("   ")
        }
    }
    
    @Test("Name too long throws")
    func testNameTooLong() {
        let longName = String(repeating: "a", count: 101)
        #expect(throws: ProfileValidator.ValidationError.nameTooLong) {
            try ProfileValidator.validateName(longName)
        }
    }
    
    @Test("Name with control characters throws")
    func testNameWithControlChars() {
        #expect(throws: ProfileValidator.ValidationError.nameContainsControlChars) {
            try ProfileValidator.validateName("Server\tAttack")  // Tab character
        }
    }
    
    // MARK: - Port Validation
    
    @Test("Valid port")
    func testValidPort() throws {
        let result = try ProfileValidator.validatePort(22)
        #expect(result == 22)
    }
    
    @Test("Port 1 is valid")
    func testPort1Valid() throws {
        let result = try ProfileValidator.validatePort(1)
        #expect(result == 1)
    }
    
    @Test("Port 65535 is valid")
    func testPort65535Valid() throws {
        let result = try ProfileValidator.validatePort(65535)
        #expect(result == 65535)
    }
    
    @Test("Port 0 throws")
    func testPort0Invalid() {
        #expect(throws: ProfileValidator.ValidationError.portOutOfRange) {
            try ProfileValidator.validatePort(0)
        }
    }
    
    @Test("Port 65536 throws")
    func testPort65536Invalid() {
        #expect(throws: ProfileValidator.ValidationError.portOutOfRange) {
            try ProfileValidator.validatePort(65536)
        }
    }
    
    @Test("Negative port throws")
    func testNegativePortInvalid() {
        #expect(throws: ProfileValidator.ValidationError.portOutOfRange) {
            try ProfileValidator.validatePort(-1)
        }
    }
    
    // MARK: - Username Validation
    
    @Test("Valid username")
    func testValidUsername() throws {
        let result = try ProfileValidator.validateUsername("admin")
        #expect(result == "admin")
    }
    
    @Test("Empty username is valid (uses current user)")
    func testEmptyUsernameValid() throws {
        let result = try ProfileValidator.validateUsername("")
        #expect(result == "")
    }
    
    @Test("Username with underscore")
    func testUsernameWithUnderscore() throws {
        let result = try ProfileValidator.validateUsername("deploy_user")
        #expect(result == "deploy_user")
    }
    
    @Test("Username with hyphen")
    func testUsernameWithHyphen() throws {
        let result = try ProfileValidator.validateUsername("deploy-user")
        #expect(result == "deploy-user")
    }
    
    @Test("Username with dot")
    func testUsernameWithDot() throws {
        let result = try ProfileValidator.validateUsername("user.name")
        #expect(result == "user.name")
    }
    
    @Test("Username too long throws")
    func testUsernameTooLong() {
        let longUsername = String(repeating: "a", count: 65)
        #expect(throws: ProfileValidator.ValidationError.usernameTooLong) {
            try ProfileValidator.validateUsername(longUsername)
        }
    }
    
    @Test("Username with spaces throws")
    func testUsernameWithSpaces() {
        #expect(throws: ProfileValidator.ValidationError.usernameInvalid) {
            try ProfileValidator.validateUsername("user name")
        }
    }
    
    @Test("Username with special chars throws")
    func testUsernameWithSpecialChars() {
        #expect(throws: ProfileValidator.ValidationError.usernameInvalid) {
            try ProfileValidator.validateUsername("user@host")
        }
    }
    
    // MARK: - Domain Validation
    
    @Test("Valid domain")
    func testValidDomain() throws {
        let result = try ProfileValidator.validateDomain("WORKGROUP")
        #expect(result == "WORKGROUP")
    }
    
    @Test("Empty domain is valid")
    func testEmptyDomainValid() throws {
        let result = try ProfileValidator.validateDomain("")
        #expect(result == "")
    }
    
    @Test("Domain too long throws")
    func testDomainTooLong() {
        let longDomain = String(repeating: "a", count: 256)
        #expect(throws: ProfileValidator.ValidationError.domainTooLong) {
            try ProfileValidator.validateDomain(longDomain)
        }
    }
    
    // MARK: - Notes Validation
    
    @Test("Valid notes")
    func testValidNotes() throws {
        let result = try ProfileValidator.validateNotes("Production server - handle with care")
        #expect(result == "Production server - handle with care")
    }
    
    @Test("Empty notes is valid")
    func testEmptyNotesValid() throws {
        let result = try ProfileValidator.validateNotes("")
        #expect(result == "")
    }
    
    @Test("Notes too long throws")
    func testNotesTooLong() {
        let longNotes = String(repeating: "a", count: 1001)
        #expect(throws: ProfileValidator.ValidationError.notesTooLong) {
            try ProfileValidator.validateNotes(longNotes)
        }
    }
    
    // MARK: - Host Validation (Delegates to HostnameValidator)
    
    @Test("Valid host delegates correctly")
    func testValidHostDelegates() throws {
        let result = try ProfileValidator.validateHost("example.com")
        #expect(result == "example.com")
    }
    
    @Test("Blocked host throws with hostname error")
    func testBlockedHostThrows() {
        #expect(throws: ProfileValidator.ValidationError.self) {
            try ProfileValidator.validateHost("localhost")
        }
    }
}
