import Foundation
import SwiftData

/// A saved connection profile for remote desktop/terminal access.
@Model
final class ConnectionProfile {
    var id: UUID
    var name: String
    var protocolRawValue: String
    var host: String
    var port: Int
    var username: String
    var domain: String
    var notes: String
    var tagsRawValue: String  // comma-separated tags
    var isFavorite: Bool
    var connectOnOpen: Bool
    var sshKeyPath: String     // path to SSH private key (empty = use agent)
    var createdAt: Date
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        name: String = "",
        protocolType: ProtocolType = .ssh,
        host: String = "",
        port: Int? = nil,
        username: String = "",
        domain: String = "",
        notes: String = "",
        tags: [String] = [],
        isFavorite: Bool = false,
        connectOnOpen: Bool = false,
        sshKeyPath: String = "",
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.protocolRawValue = protocolType.rawValue
        self.host = host
        self.port = port ?? protocolType.defaultPort
        self.username = username
        self.domain = domain
        self.notes = notes
        self.tagsRawValue = Self.sanitizedTagsRawValue(from: tags)
        self.isFavorite = isFavorite
        self.connectOnOpen = connectOnOpen
        self.sshKeyPath = sshKeyPath
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    // MARK: - Computed Properties

    var protocolType: ProtocolType {
        get { ProtocolType(rawValue: protocolRawValue) ?? .ssh }
        set { protocolRawValue = newValue.rawValue }
    }

    var tags: [String] {
        get {
            tagsRawValue
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        set {
            tagsRawValue = Self.sanitizedTagsRawValue(from: newValue)
        }
    }

    /// Storage is comma-joined with no escaping, so a comma left inside a
    /// tag's own text would be indistinguishable from the separator on the
    /// next read (e.g. ["web,server", "prod"] would come back as 3 tags
    /// instead of 2). Strip commas here so that can't happen, and drop
    /// components that are empty once trimmed. Shared by `init` and the
    /// `tags` setter so both paths write the same sanitized storage.
    private static func sanitizedTagsRawValue(from tags: [String]) -> String {
        tags
            .map { $0.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ",")
    }

    /// Returns the connection string in the form user@host:port
    var connectionString: String {
        var parts = ""
        if !username.isEmpty {
            parts += "\(username)@"
        }
        parts += host
        let defaultPort = protocolType.defaultPort
        if port != defaultPort {
            parts += ":\(port)"
        }
        return parts
    }
}
