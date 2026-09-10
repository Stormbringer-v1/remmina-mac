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

    @Test("Username leading hyphen throws (ISSUE-022)")
    func testUsernameLeadingHyphenThrows() {
        #expect(throws: ProfileValidator.ValidationError.usernameInvalid) {
            try ProfileValidator.validateUsername("-x")
        }
    }

    @Test("Username with internal hyphen and dot passes (ISSUE-022)")
    func testUsernameInternalHyphenAndDotPass() throws {
        #expect(try ProfileValidator.validateUsername("x-y") == "x-y")
        #expect(try ProfileValidator.validateUsername("x.y_z") == "x.y_z")
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
            try ProfileValidator.validateHost("0.0.0.0")
        }
    }

    // MARK: - Tag Validation (ISSUE-017)

    @Test("Valid tags pass validation")
    func testValidTags() throws {
        let tags = ["web", "production", "linux"]
        let validated = try ProfileValidator.validateTags(tags)
        #expect(validated == tags)
    }

    @Test("More than 10 tags throws")
    func testTooManyTagsThrows() {
        let tags = (1...11).map { "tag\($0)" }
        #expect(throws: ProfileValidator.ValidationError.tagsInvalid("Too many tags (max 10)")) {
            try ProfileValidator.validateTags(tags)
        }
    }

    @Test("Tag longer than 50 characters throws")
    func testTagTooLongThrows() {
        let longTag = String(repeating: "t", count: 51)
        #expect(throws: ProfileValidator.ValidationError.self) {
            try ProfileValidator.validateTags([longTag])
        }
    }

    @Test("Tag containing comma throws")
    func testTagWithCommaThrows() {
        #expect(throws: ProfileValidator.ValidationError.self) {
            try ProfileValidator.validateTags(["production,web"])
        }
    }

    @Test("Tag containing control character throws")
    func testTagWithControlCharThrows() {
        #expect(throws: ProfileValidator.ValidationError.self) {
            try ProfileValidator.validateTags(["prod\u{0007}tag"])
        }
    }

    // MARK: - In-Place Normalization (ISSUE-017)

    @Test("ProfileValidator.validate normalizes fields in place")
    func testProfileValidateNormalizesInPlace() throws {
        let profile = ConnectionProfile(
            name: "  My Server  ",
            protocolType: .ssh,
            host: "  example.com  ",
            port: 22,
            username: "  alice  ",
            domain: "  corp.local  ",
            notes: "  some notes  ",
            tags: ["  prod  ", "  web  "],
            sshKeyPath: ""
        )

        try ProfileValidator.validate(profile)

        #expect(profile.name == "My Server")
        #expect(profile.host == "example.com")
        #expect(profile.username == "alice")
        #expect(profile.domain == "corp.local")
        #expect(profile.tags == ["prod", "web"])
    }

    // MARK: - ProfileDraft & Edit Mode Autosave Guard (ISSUE-002, ISSUE-017)

    @Test("ProfileDraft validated trims fields and parses port")
    func testProfileDraftValidatedNormalizes() throws {
        let draft = ProfileDraft(
            name: " Test ",
            protocolType: .vnc,
            host: " 192.168.1.50 ",
            portText: " 5901 ",
            username: " bob ",
            domain: " ",
            notes: " notes ",
            tags: [" vnc "],
            isFavorite: true,
            connectOnOpen: false,
            sshKeyPath: ""
        )

        let valid = try draft.validated()
        #expect(valid.name == "Test")
        #expect(valid.host == "192.168.1.50")
        #expect(valid.portText == "5901")
        #expect(valid.username == "bob")
        #expect(valid.domain == "")
        #expect(valid.tags == ["vnc"])
    }

    @Test("ProfileDraft non-numeric port throws portOutOfRange")
    func testProfileDraftNonNumericPortThrows() {
        let draft = ProfileDraft(
            name: "Test",
            protocolType: .ssh,
            host: "example.com",
            portText: "invalid_port"
        )
        #expect(throws: ProfileValidator.ValidationError.portOutOfRange) {
            try draft.validated()
        }
    }

    @Test("ProfileDraft port out of range throws portOutOfRange")
    func testProfileDraftOutOfRangePortThrows() {
        let draft = ProfileDraft(
            name: "Test",
            protocolType: .ssh,
            host: "example.com",
            portText: "70000"
        )
        #expect(throws: ProfileValidator.ValidationError.portOutOfRange) {
            try draft.validated()
        }
    }

    @Test("In edit mode, invalid draft leaves ConnectionProfile completely unchanged")
    func testEditModeInvalidDraftLeavesProfileUnchanged() {
        let profile = ConnectionProfile(
            name: "Original Name",
            protocolType: .ssh,
            host: "original.com",
            port: 22,
            username: "orig_user",
            notes: "orig_notes",
            tags: ["orig"]
        )

        var draft = ProfileDraft(from: profile)
        draft.name = "Mutated Name"
        draft.host = "bad host;rm" // Invalid host

        #expect(throws: ProfileValidator.ValidationError.self) {
            _ = try draft.validated()
        }

        // Assert profile was NOT modified
        #expect(profile.name == "Original Name")
        #expect(profile.host == "original.com")
        #expect(profile.port == 22)
        #expect(profile.username == "orig_user")
        #expect(profile.notes == "orig_notes")
        #expect(profile.tags == ["orig"])
    }

    @Test("ProfileDraft apply updates profile fields on valid edit")
    func testProfileDraftApplyUpdatesProfile() throws {
        let profile = ConnectionProfile(
            name: "Original",
            protocolType: .ssh,
            host: "original.com",
            port: 22
        )

        var draft = ProfileDraft(from: profile)
        draft.name = "  Updated Name  "
        draft.host = "  updated.com  "
        draft.portText = "  2222  "

        let valid = try draft.validated()
        valid.apply(to: profile)

        #expect(profile.name == "Updated Name")
        #expect(profile.host == "updated.com")
        #expect(profile.port == 2222)
    }

    // MARK: - ProfileDTO Strict Decoding & Tag Round-Trip (ISSUE-017)

    @Test("ProfileDTO rejects unknown JSON fields")
    func testProfileDTORejectsUnknownFields() {
        let json = """
        {
            "name": "Server",
            "protocolType": "SSH",
            "host": "example.com",
            "port": 22,
            "username": "user",
            "domain": "",
            "notes": "",
            "tags": ["web"],
            "isFavorite": false,
            "connectOnOpen": false,
            "extraMaliciousField": "injected"
        }
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ProfileImportExport.ProfileDTO.self, from: json)
        }
    }

    @Test("ProfileDTO tag containing comma is rejected on import")
    func testProfileDTOTagWithCommaRejected() throws {
        let json = """
        {
            "name": "Server",
            "protocolType": "SSH",
            "host": "example.com",
            "port": 22,
            "username": "user",
            "domain": "",
            "notes": "",
            "tags": ["bad,tag"],
            "isFavorite": false,
            "connectOnOpen": false
        }
        """.data(using: .utf8)!

        let dto = try JSONDecoder().decode(ProfileImportExport.ProfileDTO.self, from: json)
        #expect(throws: ProfileImportExport.ImportError.self) {
            try dto.toProfile(at: 0)
        }
    }

    @Test("Tags round-trip through export and import unchanged")
    func testTagsRoundTripExportImport() throws {
        let profile = ConnectionProfile(
            name: "Prod",
            protocolType: .ssh,
            host: "prod.example.com",
            port: 22,
            tags: ["cloud", "eu-central", "database"]
        )

        let exportedData = try #require(ProfileImportExport.exportProfiles([profile]))
        let importedProfiles = try ProfileImportExport.importProfiles(from: exportedData)

        #expect(importedProfiles.count == 1)
        #expect(importedProfiles[0].tags == ["cloud", "eu-central", "database"])
    }

    // MARK: - SSH Key Outside ~/.ssh and Missing Key (ISSUE-001)

    @Test("ProfileValidator accepts user-selected SSH key outside ~/.ssh")
    func testProfileValidatorAcceptsKeyOutsideSshDir() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempKey = tempDir.appendingPathComponent("remmina_valid_key_\(UUID().uuidString)")
        try "my-key".write(to: tempKey, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempKey) }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempKey.path)

        let profile = ConnectionProfile(
            name: "Server Outside SSH Key",
            protocolType: .ssh,
            host: "example.com",
            port: 22,
            sshKeyPath: tempKey.path
        )

        try ProfileValidator.validate(profile)
        #expect(profile.sshKeyPath == tempKey.path)
    }

    @Test("ProfileValidator with sshKeyAllowMissing accepts missing key")
    func testProfileValidatorAcceptsMissingKeyWhenAllowed() throws {
        let profile = ConnectionProfile(
            name: "Imported Server",
            protocolType: .ssh,
            host: "example.com",
            port: 22,
            sshKeyPath: "/Users/nonexistent/keys/id_ed25519"
        )

        try ProfileValidator.validate(profile, sshKeyAllowMissing: true)
        #expect(profile.sshKeyPath == "/Users/nonexistent/keys/id_ed25519")
    }

    // MARK: - Corrupted Store Backup & Recovery Mode (ISSUE-018)

    @Test("Corrupted store backup copies store files and returns backup directory path")
    func testBackupCorruptedStore() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("remmina_backup_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let storeFile = tempDir.appendingPathComponent("RemminaMac.store")
        let walFile = tempDir.appendingPathComponent("RemminaMac.store-wal")
        let shmFile = tempDir.appendingPathComponent("RemminaMac.store-shm")

        try "store-data".write(to: storeFile, atomically: true, encoding: .utf8)
        try "wal-data".write(to: walFile, atomically: true, encoding: .utf8)
        try "shm-data".write(to: shmFile, atomically: true, encoding: .utf8)

        let backupPath = RemminaMacApp.backupCorruptedStore(storeURL: storeFile, timestamp: "2026-09-10T00-00-00Z")
        let path = try #require(backupPath)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("RemminaMac.store")))
        #expect(FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("RemminaMac.store-wal")))
        #expect(FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent("RemminaMac.store-shm")))
    }

    @Test("AppState recoveryMode is observable and settable")
    func testAppStateRecoveryMode() {
        let state = AppState()
        #expect(state.recoveryMode == false)
        #expect(state.recoveryBackupPath == nil)

        state.recoveryMode = true
        state.recoveryBackupPath = "/tmp/backup"
        #expect(state.recoveryMode == true)
        #expect(state.recoveryBackupPath == "/tmp/backup")
    }
}
