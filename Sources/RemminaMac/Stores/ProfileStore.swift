import Foundation
import SwiftData

/// Manages CRUD operations for connection profiles using SwiftData.
@Observable
final class ProfileStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - CRUD

    func add(_ profile: ConnectionProfile, allowMissingSSHKey: Bool = false) throws {
        // Validate profile before adding
        try ProfileValidator.validate(profile, blockPrivateRanges: false, sshKeyAllowMissing: allowMissingSSHKey)

        // PROBLEMS.md ISSUE-001: importing a profile whose SSH key file is
        // absent on this machine is allowed when the caller opts in, but we
        // still want a visible trail of which profiles need attention.
        if allowMissingSSHKey, !profile.sshKeyPath.isEmpty,
           !FileManager.default.fileExists(atPath: profile.sshKeyPath) {
            AppLogger.shared.log(
                "Profile '\(profile.name)' added with an SSH key that does not exist on this machine: \(profile.sshKeyPath)",
                level: .warning,
                profileId: profile.id
            )
        }

        modelContext.insert(profile)
        save()
        AppLogger.shared.log("Profile added: \(profile.name)", profileId: profile.id)
    }

    func delete(_ profile: ConnectionProfile) {
        AppLogger.shared.log("Profile deleted: \(profile.name)", profileId: profile.id)
        modelContext.delete(profile)
        save()
    }

    func save() {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            AppLogger.shared.log("Failed to save profiles: \(error.localizedDescription)", level: .error)
        }
    }

    func saveOrRollback() throws {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            AppLogger.shared.log("Failed to save profiles, rolled back: \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    // MARK: - Queries

    func allProfiles() -> [ConnectionProfile] {
        let descriptor = FetchDescriptor<ConnectionProfile>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    // PROBLEMS.md ISSUE-027d: `search`/`recents`/`filterByTag` were dead code
    // (MainView filters `@Query`'s in-memory array instead — see the comment
    // on `filteredProfiles` there) and have been removed. `favorites()` is
    // kept: it is exercised by ProfileStoreIntegrationTests.swift, a test
    // file outside this pass's ownership.
    func favorites() -> [ConnectionProfile] {
        let descriptor = FetchDescriptor<ConnectionProfile>(
            predicate: #Predicate<ConnectionProfile> { $0.isFavorite },
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func toggleFavorite(_ profile: ConnectionProfile) {
        profile.isFavorite.toggle()
        save()
    }

    func markConnected(_ profile: ConnectionProfile) {
        profile.lastConnectedAt = Date()
        save()
    }
}
