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

    func add(_ profile: ConnectionProfile) throws {
        // Validate profile before adding
        try ProfileValidator.validate(profile, blockPrivateRanges: false)
        
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
            AppLogger.shared.log("Failed to save profiles: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: - Queries

    func allProfiles() -> [ConnectionProfile] {
        let descriptor = FetchDescriptor<ConnectionProfile>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func search(query: String) -> [ConnectionProfile] {
        if query.isEmpty {
            return allProfiles()
        }
        let descriptor = FetchDescriptor<ConnectionProfile>(
            predicate: #Predicate<ConnectionProfile> { profile in
                profile.name.localizedStandardContains(query) ||
                profile.host.localizedStandardContains(query) ||
                profile.username.localizedStandardContains(query) ||
                profile.tagsRawValue.localizedStandardContains(query)
            },
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func favorites() -> [ConnectionProfile] {
        let descriptor = FetchDescriptor<ConnectionProfile>(
            predicate: #Predicate<ConnectionProfile> { $0.isFavorite },
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func recents(limit: Int = 10) -> [ConnectionProfile] {
        var descriptor = FetchDescriptor<ConnectionProfile>(
            predicate: #Predicate<ConnectionProfile> { $0.lastConnectedAt != nil },
            sortBy: [SortDescriptor(\.lastConnectedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func filterByTag(_ tag: String) -> [ConnectionProfile] {
        let descriptor = FetchDescriptor<ConnectionProfile>(
            predicate: #Predicate<ConnectionProfile> { profile in
                profile.tagsRawValue.localizedStandardContains(tag)
            },
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
