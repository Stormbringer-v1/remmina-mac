import Testing
import Foundation
@testable import RemminaMac

@Suite("HostnameValidator Tests")
struct HostnameValidatorTests {
    
    // MARK: - Valid Cases
    
    @Test("Valid FQDN")
    func testValidFQDN() throws {
        let result = try HostnameValidator.validate("example.com")
        #expect(result == "example.com")
    }
    
    @Test("Valid subdomain")
    func testValidSubdomain() throws {
        let result = try HostnameValidator.validate("api.staging.example.com")
        #expect(result == "api.staging.example.com")
    }
    
    @Test("Valid public IPv4")
    func testValidPublicIPv4() throws {
        let result = try HostnameValidator.validate("8.8.8.8")
        #expect(result == "8.8.8.8")
    }
    
    @Test("Valid IPv6")
    func testValidIPv6() throws {
        let result = try HostnameValidator.validate("2001:4860:4860::8888")
        #expect(result == "2001:4860:4860::8888")
    }
    
    // MARK: - Blocked Cases
    
    @Test("Block localhost")
    func testBlockLocalhost() {
        #expect(throws: HostnameValidator.ValidationError.blockedLocalhost) {
            try HostnameValidator.validate("localhost")
        }
    }
    
    @Test("Block localhost case insensitive")
    func testBlockLocalhostCaseInsensitive() {
        #expect(throws: HostnameValidator.ValidationError.blockedLocalhost) {
            try HostnameValidator.validate("LOCALHOST")
        }
    }
    
    @Test("Block 127.0.0.1")
    func testBlockLoopback127001() {
        #expect(throws: HostnameValidator.ValidationError.blockedLoopback) {
            try HostnameValidator.validate("127.0.0.1")
        }
    }
    
    @Test("Block 127.0.0.0/8 range")
    func testBlockLoopback127Range() {
        #expect(throws: HostnameValidator.ValidationError.blockedLoopback) {
            try HostnameValidator.validate("127.1.2.3")
        }
    }
    
    @Test("Block IPv6 loopback ::1")
    func testBlockIPv6Loopback() {
        #expect(throws: HostnameValidator.ValidationError.blockedLoopback) {
            try HostnameValidator.validate("::1")
        }
    }
    
    @Test("Block 169.254.x.x (cloud metadata)")
    func testBlockLinkLocal169254() {
        #expect(throws: HostnameValidator.ValidationError.blockedLinkLocal) {
            try HostnameValidator.validate("169.254.169.254")
        }
    }
    
    @Test("Block 169.254.169.253")
    func testBlockLinkLocal169253() {
        #expect(throws: HostnameValidator.ValidationError.blockedLinkLocal) {
            try HostnameValidator.validate("169.254.169.253")
        }
    }
    
    @Test("Block 0.0.0.0")
    func testBlockZeroAddress() {
        #expect(throws: HostnameValidator.ValidationError.blockedZeroAddress) {
            try HostnameValidator.validate("0.0.0.0")
        }
    }
    
    @Test("Block file:// URLs")
    func testBlockFileURL() {
        #expect(throws: HostnameValidator.ValidationError.fileURL) {
            try HostnameValidator.validate("file:///etc/passwd")
        }
    }
    
    @Test("Block file URL case insensitive")
    func testBlockFileURLCaseInsensitive() {
        #expect(throws: HostnameValidator.ValidationError.fileURL) {
            try HostnameValidator.validate("FILE:///etc/passwd")
        }
    }
    
    // MARK: - Private Ranges (Optional Blocking)
    
    @Test("Allow 10.x.x.x by default")
    func testAllow10ByDefault() throws {
        let result = try HostnameValidator.validate("10.0.0.1", blockPrivateRanges: false)
        #expect(result == "10.0.0.1")
    }
    
    @Test("Block 10.x.x.x when enabled")
    func testBlock10WhenEnabled() {
        #expect(throws: HostnameValidator.ValidationError.blockedPrivateRange) {
            try HostnameValidator.validate("10.0.0.1", blockPrivateRanges: true)
        }
    }
    
    @Test("Allow 192.168.x.x by default")
    func testAllow192168ByDefault() throws {
        let result = try HostnameValidator.validate("192.168.1.1", blockPrivateRanges: false)
        #expect(result == "192.168.1.1")
    }
    
    @Test("Block 192.168.x.x when enabled")
    func testBlock192168WhenEnabled() {
        #expect(throws: HostnameValidator.ValidationError.blockedPrivateRange) {
            try HostnameValidator.validate("192.168.1.1", blockPrivateRanges: true)
        }
    }
    
    @Test("Allow 172.16.x.x by default")
    func testAllow17216ByDefault() throws {
        let result = try HostnameValidator.validate("172.16.0.1", blockPrivateRanges: false)
        #expect(result == "172.16.0.1")
    }
    
    @Test("Block 172.16-31.x.x when enabled")
    func testBlock17216WhenEnabled() {
        #expect(throws: HostnameValidator.ValidationError.blockedPrivateRange) {
            try HostnameValidator.validate("172.20.0.1", blockPrivateRanges: true)
        }
    }
    
    // MARK: - Invalid Format
    
    @Test("Empty hostname")
    func testEmptyHostname() {
        #expect(throws: HostnameValidator.ValidationError.empty) {
            try HostnameValidator.validate("")
        }
    }
    
    @Test("Whitespace-only hostname")
    func testWhitespaceOnlyHostname() {
        #expect(throws: HostnameValidator.ValidationError.empty) {
            try HostnameValidator.validate("   ")
        }
    }
    
    @Test("Hostname too long")
    func testHostnameTooLong() {
        let longHostname = String(repeating: "a", count: 254)
        #expect(throws: HostnameValidator.ValidationError.invalidFormat) {
            try HostnameValidator.validate(longHostname)
        }
    }
    
    @Test("Label too long")
    func testLabelTooLong() {
        let longLabel = String(repeating: "a", count: 64) + ".com"
        #expect(throws: HostnameValidator.ValidationError.invalidFormat) {
            try HostnameValidator.validate(longLabel)
        }
    }
    
    @Test("Starts with hyphen")
    func testStartsWithHyphen() {
        #expect(throws: HostnameValidator.ValidationError.invalidFormat) {
            try HostnameValidator.validate("-example.com")
        }
    }
    
    @Test("Trim whitespace")
    func testTrimWhitespace() throws {
        let result = try HostnameValidator.validate("  example.com  ")
        #expect(result == "example.com")
    }
}
