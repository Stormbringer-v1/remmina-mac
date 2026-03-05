import Foundation
import Network

/// Validates hostnames to prevent SSRF attacks and security risks.
enum HostnameValidator {
    enum ValidationError: Error, LocalizedError, Equatable {
        case empty
        case blockedLocalhost
        case blockedLoopback
        case blockedLinkLocal
        case blockedPrivateRange
        case blockedZeroAddress
        case malformedURL
        case fileURL
        case invalidFormat
        case dangerousCharacters
        
        var errorDescription: String? {
            switch self {
            case .empty:
                return "Host cannot be empty"
            case .blockedLocalhost:
                return "Connection to localhost is blocked for security reasons"
            case .blockedLoopback:
                return "Loopback addresses (127.x.x.x, ::1) are blocked for security reasons"
            case .blockedLinkLocal:
                return "Link-local addresses (169.254.x.x) including cloud metadata endpoints are blocked"
            case .blockedPrivateRange:
                return "Private network addresses are blocked in enterprise mode"
            case .blockedZeroAddress:
                return "Zero address (0.0.0.0) is not allowed"
            case .malformedURL:
                return "Hostname format is invalid"
            case .fileURL:
                return "File URLs are not allowed"
            case .invalidFormat:
                return "Invalid hostname format"
            case .dangerousCharacters:
                return "Hostname contains dangerous characters"
            }
        }
    }
    
    /// Characters that could enable command injection when hostnames are passed to shell commands
    private static let shellMetacharacters = CharacterSet(charactersIn: ";|&`$(){}!<>\\'\"\n\r\0")
    
    /// Validate hostname for security risks
    /// - Parameters:
    ///   - hostname: The hostname to validate
    ///   - blockPrivateRanges: If true, also block RFC1918 private addresses
    /// - Returns: Validated hostname
    /// - Throws: ValidationError if hostname is unsafe
    static func validate(_ hostname: String, blockPrivateRanges: Bool = false) throws -> String {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmed.isEmpty else {
            throw ValidationError.empty
        }
        
        // SECURITY: Block null bytes, newlines, and control characters
        // These can cause truncation or injection in C-based APIs (ssh, network libs)
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw ValidationError.dangerousCharacters
        }
        
        // SECURITY: Block shell metacharacters that could enable command injection
        // when hostname is passed to /usr/bin/ssh or xfreerdp
        if trimmed.unicodeScalars.contains(where: { shellMetacharacters.contains($0) }) {
            throw ValidationError.dangerousCharacters
        }
        
        // SECURITY: Block URL-encoded hostnames (can bypass text-based checks)
        if trimmed.contains("%") {
            throw ValidationError.dangerousCharacters
        }
        
        // Block file:// URLs
        if trimmed.lowercased().hasPrefix("file://") {
            throw ValidationError.fileURL
        }
        
        // Block scheme-prefixed URLs (http://, ssh://, etc.)
        if trimmed.contains("://") {
            throw ValidationError.invalidFormat
        }
        
        // Block localhost variants
        let lowercased = trimmed.lowercased()
        if lowercased == "localhost" || lowercased == "localhost.localdomain" {
            throw ValidationError.blockedLocalhost
        }
        // SECURITY: Reject octal/hex/decimal IP notation BEFORE standard parsing.
        // macOS IPv4Address("0177.0.0.1") resolves to 177.0.0.1, but other systems
        // (Linux inet_aton) interpret leading zeros as octal (= 127.0.0.1 loopback).
        // Block these ambiguous notations for defense-in-depth.
        try rejectEncodedIPNotation(trimmed)
        
        // Try to parse as IP address
        if let ipAddress = IPv4Address(trimmed) {
            try validateIPv4(ipAddress, blockPrivateRanges: blockPrivateRanges)
        } else if let ipAddress = IPv6Address(trimmed) {
            try validateIPv6(ipAddress)
        } else {
            // Validate as hostname/FQDN
            try validateHostnameFormat(trimmed)
        }
        
        return trimmed
    }
    
    /// Rejects IP addresses written in octal, hexadecimal, or decimal notation
    /// that bypass standard IPv4Address parsing but resolve to dangerous addresses.
    private static func rejectEncodedIPNotation(_ hostname: String) throws {
        let lower = hostname.lowercased()
        
        // Block hex notation: 0x7f.0x0.0x0.0x1, 0x7f000001
        if lower.hasPrefix("0x") || lower.contains(".0x") {
            throw ValidationError.invalidFormat
        }
        
        // Block pure decimal notation: 2130706433 (= 127.0.0.1)
        // A hostname that is purely digits (no dots) and > 255 is likely a decimal IP
        if hostname.allSatisfy({ $0.isNumber }) {
            if let value = UInt64(hostname), value > 255 {
                throw ValidationError.invalidFormat
            }
        }
        
        // Block octal notation: 0177.0.0.1 (leading zeros in IP octets)
        let parts = hostname.split(separator: ".")
        if parts.count == 4 && parts.allSatisfy({ $0.allSatisfy({ $0.isNumber }) }) {
            // Looks like an IP address with 4 numeric parts
            // Block if any octet has a leading zero (octal indicator)
            for part in parts {
                if part.count > 1 && part.hasPrefix("0") {
                    throw ValidationError.invalidFormat
                }
            }
        }
    }
    
    private static func validateIPv4(_ ip: IPv4Address, blockPrivateRanges: Bool) throws {
        let octets = ip.rawValue
        
        // Block 0.0.0.0
        if octets.allSatisfy({ $0 == 0 }) {
            throw ValidationError.blockedZeroAddress
        }
        
        // Block 127.0.0.0/8 (loopback)
        if octets[0] == 127 {
            throw ValidationError.blockedLoopback
        }
        
        // Block 169.254.0.0/16 (link-local, cloud metadata)
        if octets[0] == 169 && octets[1] == 254 {
            throw ValidationError.blockedLinkLocal
        }
        
        // Optionally block RFC1918 private ranges
        if blockPrivateRanges {
            // 10.0.0.0/8
            if octets[0] == 10 {
                throw ValidationError.blockedPrivateRange
            }
            // 172.16.0.0/12
            if octets[0] == 172 && (octets[1] >= 16 && octets[1] <= 31) {
                throw ValidationError.blockedPrivateRange
            }
            // 192.168.0.0/16
            if octets[0] == 192 && octets[1] == 168 {
                throw ValidationError.blockedPrivateRange
            }
        }
    }
    
    private static func validateIPv6(_ ip: IPv6Address) throws {
        // Block ::1 (loopback)
        if ip == IPv6Address.loopback {
            throw ValidationError.blockedLoopback
        }
        
        // Block link-local (fe80::/10)
        let rawValue = ip.rawValue
        if rawValue[0] == 0xfe && (rawValue[1] & 0xc0) == 0x80 {
            throw ValidationError.blockedLinkLocal
        }
    }
    
    private static func validateHostnameFormat(_ hostname: String) throws {
        // Basic hostname format validation
        // RFC 1123: alphanumeric, hyphens, dots, max 253 chars
        
        guard hostname.count <= 253 else {
            throw ValidationError.invalidFormat
        }
        
        // Must not start or end with hyphen or dot
        if hostname.hasPrefix("-") || hostname.hasPrefix(".") ||
           hostname.hasSuffix("-") || hostname.hasSuffix(".") {
            throw ValidationError.invalidFormat
        }
        
        // Check each label (separated by dots)
        let labels = hostname.split(separator: ".")
        for label in labels {
            guard label.count <= 63 else {
                throw ValidationError.invalidFormat
            }
            
            // Label must be alphanumeric or hyphen
            let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
            if label.unicodeScalars.contains(where: { !validChars.contains($0) }) {
                throw ValidationError.invalidFormat
            }
        }
    }
}
