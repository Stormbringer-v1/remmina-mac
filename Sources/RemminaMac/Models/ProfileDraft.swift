import Foundation

/// A transient draft of a ConnectionProfile used during creation or editing.
/// Keeps field mutations off live SwiftData models until validation succeeds.
struct ProfileDraft: Equatable {
    var name: String
    var protocolType: ProtocolType
    var host: String
    var portText: String
    var username: String
    var domain: String
    var notes: String
    var tags: [String]
    var isFavorite: Bool
    var connectOnOpen: Bool
    var sshKeyPath: String

    init(
        name: String = "",
        protocolType: ProtocolType = .ssh,
        host: String = "",
        portText: String = "",
        username: String = "",
        domain: String = "",
        notes: String = "",
        tags: [String] = [],
        isFavorite: Bool = false,
        connectOnOpen: Bool = false,
        sshKeyPath: String = ""
    ) {
        self.name = name
        self.protocolType = protocolType
        self.host = host
        self.portText = portText
        self.username = username
        self.domain = domain
        self.notes = notes
        self.tags = tags
        self.isFavorite = isFavorite
        self.connectOnOpen = connectOnOpen
        self.sshKeyPath = sshKeyPath
    }

    init(from profile: ConnectionProfile) {
        self.name = profile.name
        self.protocolType = profile.protocolType
        self.host = profile.host
        self.portText = "\(profile.port)"
        self.username = profile.username
        self.domain = profile.domain
        self.notes = profile.notes
        self.tags = profile.tags
        self.isFavorite = profile.isFavorite
        self.connectOnOpen = profile.connectOnOpen
        self.sshKeyPath = profile.sshKeyPath
    }

    /// Validates and returns a normalized copy of the draft.
    func validated(blockPrivateRanges: Bool = false, blockLocalhost: Bool = false) throws -> ProfileDraft {
        let trimmedName = try ProfileValidator.validateName(name)
        let trimmedHost = try ProfileValidator.validateHost(host, blockPrivateRanges: blockPrivateRanges, blockLocalhost: blockLocalhost)
        
        let trimmedPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let p = Int(trimmedPort) else {
            throw ProfileValidator.ValidationError.portOutOfRange
        }
        let validPort = try ProfileValidator.validatePort(p)
        
        let trimmedUsername = try ProfileValidator.validateUsername(username)
        let trimmedDomain = try ProfileValidator.validateDomain(domain)
        let trimmedNotes = try ProfileValidator.validateNotes(notes)
        let validTags = try ProfileValidator.validateTags(tags)
        let validSSHKeyPath = try ProfileValidator.validateSSHKeyPath(sshKeyPath, isUserSelected: true)

        return ProfileDraft(
            name: trimmedName,
            protocolType: protocolType,
            host: trimmedHost,
            portText: "\(validPort)",
            username: trimmedUsername,
            domain: trimmedDomain,
            notes: trimmedNotes,
            tags: validTags,
            isFavorite: isFavorite,
            connectOnOpen: connectOnOpen,
            sshKeyPath: validSSHKeyPath
        )
    }

    /// Applies normalized draft fields to an existing profile.
    func apply(to profile: ConnectionProfile) {
        guard let p = Int(portText) else { return }
        profile.name = name
        profile.protocolType = protocolType
        profile.host = host
        profile.port = p
        profile.username = username
        profile.domain = domain
        profile.notes = notes
        profile.tags = tags
        profile.isFavorite = isFavorite
        profile.connectOnOpen = connectOnOpen
        profile.sshKeyPath = sshKeyPath
    }

    /// Creates a new ConnectionProfile from this draft.
    func makeProfile() -> ConnectionProfile {
        let p = Int(portText) ?? protocolType.defaultPort
        return ConnectionProfile(
            name: name,
            protocolType: protocolType,
            host: host,
            port: p,
            username: username,
            domain: domain,
            notes: notes,
            tags: tags,
            isFavorite: isFavorite,
            connectOnOpen: connectOnOpen,
            sshKeyPath: sshKeyPath
        )
    }
}
