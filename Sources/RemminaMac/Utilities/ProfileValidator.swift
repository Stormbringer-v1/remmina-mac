import Foundation

/// Validates connection profile fields for security and correctness.
enum ProfileValidator {
    enum ValidationError: Error, LocalizedError, Equatable {
        case nameEmpty
        case nameTooLong
        case nameContainsControlChars
        case hostInvalid(String)
        case portOutOfRange
        case usernameInvalid
        case usernameTooLong
        case domainTooLong
        case notesTooLong
        case sshKeyInvalid(String)
        
        var errorDescription: String? {
            switch self {
            case .nameEmpty:
                return "Profile name cannot be empty"
            case .nameTooLong:
                return "Profile name too long (max 100 characters)"
            case .nameContainsControlChars:
                return "Profile name contains invalid characters"
            case .hostInvalid(let reason):
                return reason
            case .portOutOfRange:
                return "Port must be between 1 and 65535"
            case .usernameInvalid:
                return "Username contains invalid characters"
            case .usernameTooLong:
                return "Username too long (max 64 characters)"
            case .domainTooLong:
                return "Domain too long (max 255 characters)"
            case .notesTooLong:
                return "Notes too long (max 1000 characters)"
            case .sshKeyInvalid(let reason):
                return reason
            }
        }
    }
    
    /// Validate profile name
    static func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmed.isEmpty else {
            throw ValidationError.nameEmpty
        }
        
        guard trimmed.count <= 100 else {
            throw ValidationError.nameTooLong
        }
        
        // Check for control characters
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw ValidationError.nameContainsControlChars
        }
        
        return trimmed
    }
    
    /// Validate hostname
    static func validateHost(_ host: String, blockPrivateRanges: Bool = false) throws -> String {
        do {
            return try HostnameValidator.validate(host, blockPrivateRanges: blockPrivateRanges)
        } catch let error as HostnameValidator.ValidationError {
            throw ValidationError.hostInvalid(error.localizedDescription)
        }
    }
    
    /// Validate port number
    static func validatePort(_ port: Int) throws -> Int {
        guard port >= 1 && port <= 65535 else {
            throw ValidationError.portOutOfRange
        }
        return port
    }
    
    /// Validate username
    static func validateUsername(_ username: String) throws -> String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Empty username is OK (will use current user)
        if trimmed.isEmpty {
            return ""
        }
        
        guard trimmed.count <= 64 else {
            throw ValidationError.usernameTooLong
        }
        
        // RFC-compliant username: alphanumeric, underscore, hyphen, dot
        let validChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        if trimmed.unicodeScalars.contains(where: { !validChars.contains($0) }) {
            throw ValidationError.usernameInvalid
        }
        
        return trimmed
    }
    
    /// Validate domain
    static func validateDomain(_ domain: String) throws -> String {
        let trimmed = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard trimmed.count <= 255 else {
            throw ValidationError.domainTooLong
        }
        
        return trimmed
    }
    
    /// Validate notes
    static func validateNotes(_ notes: String) throws -> String {
        guard notes.count <= 1000 else {
            throw ValidationError.notesTooLong
        }
        
        return notes
    }
    
    /// Validate SSH key path
    static func validateSSHKeyPath(_ path: String, isUserSelected: Bool = false) throws -> String {
        do {
            return try SSHKeyValidator.validate(path, isUserSelected: isUserSelected)
        } catch let error as SSHKeyValidator.ValidationError {
            throw ValidationError.sshKeyInvalid(error.localizedDescription)
        }
    }
    
    /// Validate entire profile
    static func validate(_ profile: ConnectionProfile, blockPrivateRanges: Bool = false) throws {
        _ = try validateName(profile.name)
        _ = try validateHost(profile.host, blockPrivateRanges: blockPrivateRanges)
        _ = try validatePort(profile.port)
        _ = try validateUsername(profile.username)
        _ = try validateDomain(profile.domain)
        _ = try validateNotes(profile.notes)
        _ = try validateSSHKeyPath(profile.sshKeyPath, isUserSelected: false)
    }
}
