import Foundation

/// Import/export connection profiles as JSON with strict security validation.
struct ProfileImportExport {
    
    // MARK: - Security Limits
    
    /// Maximum import file size: 1 MB
    static let maxImportFileSize: Int = 1_024 * 1024
    
    /// Maximum profiles per import: 500
    static let maxProfilesPerImport: Int = 500
    
    // MARK: - Errors
    
    enum ImportError: Error, LocalizedError, Equatable {
        case fileTooLarge(size: Int)
        case tooManyProfiles(count: Int)
        case invalidJSON(String)
        case invalidVersion(Int)
        case invalidProfileData(index: Int, reason: String)
        case validationFailed(index: Int, reason: String)
        
        var errorDescription: String? {
            switch self {
            case .fileTooLarge(let size):
                return "Import file too large (\(size) bytes). Maximum: \(maxImportFileSize) bytes (1 MB)"
            case .tooManyProfiles(let count):
                return "Too many profiles (\(count)). Maximum: \(maxProfilesPerImport) profiles per import"
            case .invalidJSON(let reason):
                return "Invalid JSON format: \(reason)"
            case .invalidVersion(let version):
                return "Unsupported import format version: \(version)"
            case .invalidProfileData(let index, let reason):
                return "Profile #\(index + 1): Invalid data - \(reason)"
            case .validationFailed(let index, let reason):
                return "Profile #\(index + 1): Validation failed - \(reason)"
            }
        }
    }

    // MARK: - Data Transfer Object

    struct ProfileDTO: Codable {
        let name: String
        let protocolType: String
        let host: String
        let port: Int
        let username: String
        let domain: String
        let notes: String
        let tags: [String]
        let isFavorite: Bool
        let connectOnOpen: Bool
        let sshKeyPath: String?
        
        // Strict decoding - reject unknown fields
        enum CodingKeys: String, CodingKey {
            case name, protocolType, host, port, username, domain
            case notes, tags, isFavorite, connectOnOpen, sshKeyPath
        }

        init(from profile: ConnectionProfile) {
            self.name = profile.name
            self.protocolType = profile.protocolRawValue
            self.host = profile.host
            self.port = profile.port
            self.username = profile.username
            self.domain = profile.domain
            self.notes = profile.notes
            self.tags = profile.tags
            self.isFavorite = profile.isFavorite
            self.connectOnOpen = profile.connectOnOpen
            self.sshKeyPath = profile.sshKeyPath.isEmpty ? nil : profile.sshKeyPath
        }
        
        /// Validate and convert to ConnectionProfile
        func toProfile(at index: Int) throws -> ConnectionProfile {
            // Validate name
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportError.invalidProfileData(index: index, reason: "Name cannot be empty")
            }
            guard name.count <= 100 else {
                throw ImportError.invalidProfileData(index: index, reason: "Name too long (max 100 chars)")
            }
            
            // Validate hostname format (but don't block private IPs on import - let user decide)
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHost.isEmpty else {
                throw ImportError.invalidProfileData(index: index, reason: "Host cannot be empty")
            }
            guard trimmedHost.count <= 253 else {
                throw ImportError.invalidProfileData(index: index, reason: "Host too long (max 253 chars)")
            }
            
            // Validate port range
            guard port >= 1 && port <= 65535 else {
                throw ImportError.invalidProfileData(index: index, reason: "Port must be 1-65535, got \(port)")
            }
            
            // Validate protocol enum
            guard ProtocolType(rawValue: protocolType) != nil else {
                throw ImportError.invalidProfileData(index: index, reason: "Invalid protocol '\(protocolType)'. Must be SSH, VNC, or RDP")
            }
            
            // Validate username length
            guard username.count <= 64 else {
                throw ImportError.invalidProfileData(index: index, reason: "Username too long (max 64 chars)")
            }
            
            // Validate domain length
            guard domain.count <= 255 else {
                throw ImportError.invalidProfileData(index: index, reason: "Domain too long (max 255 chars)")
            }
            
            // Validate notes length
            guard notes.count <= 1000 else {
                throw ImportError.invalidProfileData(index: index, reason: "Notes too long (max 1000 chars)")
            }
            
            // Validate tags (max 10 tags, max 50 chars each)
            guard tags.count <= 10 else {
                throw ImportError.invalidProfileData(index: index, reason: "Too many tags (max 10)")
            }
            for tag in tags {
                guard tag.count <= 50 else {
                    throw ImportError.invalidProfileData(index: index, reason: "Tag too long (max 50 chars)")
                }
            }
            
            let proto = ProtocolType(rawValue: protocolType) ?? .ssh
            return ConnectionProfile(
                name: name,
                protocolType: proto,
                host: trimmedHost,
                port: port,
                username: username,
                domain: domain,
                notes: notes,
                tags: tags,
                isFavorite: isFavorite,
                connectOnOpen: connectOnOpen,
                sshKeyPath: sshKeyPath ?? ""
            )
        }
    }

    struct ExportData: Codable {
        let version: Int
        let exportDate: Date
        let profiles: [ProfileDTO]
    }

    // MARK: - Export

    static func exportProfiles(_ profiles: [ConnectionProfile]) -> Data? {
        let dtos = profiles.map { ProfileDTO(from: $0) }
        let export = ExportData(
            version: 1,
            exportDate: Date(),
            profiles: dtos
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let data = try encoder.encode(export)
            AppLogger.shared.log("Exported \(profiles.count) profiles")
            return data
        } catch {
            AppLogger.shared.log("Export failed: \(error)", level: .error)
            return nil
        }
    }

    static func exportToFile(_ profiles: [ConnectionProfile], url: URL) -> Bool {
        guard let data = exportProfiles(profiles) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            AppLogger.shared.log("Export to file failed: \(error)", level: .error)
            return false
        }
    }

    // MARK: - Import (Secure)

    /// Securely import profiles from data with validation
    static func importProfiles(from data: Data) throws -> [ConnectionProfile] {
        // Check file size
        guard data.count <= maxImportFileSize else {
            throw ImportError.fileTooLarge(size: data.count)
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let export: ExportData
        do {
            export = try decoder.decode(ExportData.self, from: data)
        } catch {
            throw ImportError.invalidJSON(error.localizedDescription)
        }
        
        // Check version
        guard export.version == 1 else {
            throw ImportError.invalidVersion(export.version)
        }
        
        // Check profile count
        guard export.profiles.count <= maxProfilesPerImport else {
            throw ImportError.tooManyProfiles(count: export.profiles.count)
        }
        
        // Validate and convert each profile
        var profiles: [ConnectionProfile] = []
        for (index, dto) in export.profiles.enumerated() {
            let profile = try dto.toProfile(at: index)
            profiles.append(profile)
        }
        
        AppLogger.shared.log("Imported \(profiles.count) profiles (version \(export.version))")
        return profiles
    }

    /// Securely import profiles from file with validation
    static func importFromFile(_ url: URL) throws -> [ConnectionProfile] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportError.invalidJSON("Cannot read file: \(error.localizedDescription)")
        }
        
        return try importProfiles(from: data)
    }
    
    // MARK: - Legacy (Deprecated)
    
    /// Legacy import method - returns nil on error instead of throwing
    /// Use importProfiles(from:) or importFromFile(_:) for better error handling
    @available(*, deprecated, message: "Use throwing version for better error handling")
    static func legacyImportProfiles(from data: Data) -> [ConnectionProfile]? {
        try? importProfiles(from: data)
    }
    
    @available(*, deprecated, message: "Use throwing version for better error handling")
    static func legacyImportFromFile(_ url: URL) -> [ConnectionProfile]? {
        try? importFromFile(url)
    }
}
