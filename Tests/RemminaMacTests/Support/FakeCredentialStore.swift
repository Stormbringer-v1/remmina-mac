import Foundation
@testable import RemminaMac

/// Test double conforming to `CredentialStore`. Configurable to return a
/// fixed secret per profile, to throw on read, and to report `persists`
/// either way — records every call so tests can assert on call counts too.
final class FakeCredentialStore: CredentialStore, @unchecked Sendable {
    var secretsByProfile: [UUID: String] = [:]
    var throwOnSecret: Error?
    var persists: Bool
    var displayName: String

    private(set) var secretCalls: [(kind: SecretKind, profileId: UUID)] = []
    private(set) var saveCalls: [(secret: String, kind: SecretKind, profileId: UUID)] = []
    private(set) var deleteCalls: [(kind: SecretKind, profileId: UUID)] = []
    private(set) var deleteAllCalls: [UUID] = []

    init(persists: Bool = true, displayName: String = "Fake") {
        self.persists = persists
        self.displayName = displayName
    }

    func secret(_ kind: SecretKind, for profileId: UUID) throws -> String? {
        secretCalls.append((kind, profileId))
        if let error = throwOnSecret {
            throw error
        }
        return secretsByProfile[profileId]
    }

    func save(_ secret: String, kind: SecretKind, for profileId: UUID) throws {
        saveCalls.append((secret, kind, profileId))
        secretsByProfile[profileId] = secret
    }

    func delete(_ kind: SecretKind, for profileId: UUID) throws {
        deleteCalls.append((kind, profileId))
        secretsByProfile.removeValue(forKey: profileId)
    }

    func deleteAll(for profileId: UUID) throws {
        deleteAllCalls.append(profileId)
        secretsByProfile.removeValue(forKey: profileId)
    }
}
