import Testing
import Foundation
import SwiftData
@testable import RemminaMac

@Suite("ProfileStore Integration Tests")
@MainActor
struct ProfileStoreIntegrationTests {
    
    // Helper to create an in-memory ProfileStore
    func makeTestStore() throws -> ProfileStore {
        print("Creating store")
        let schema = Schema([ConnectionProfile.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ProfileStore(modelContext: ModelContext(container))
    }

    @Test("Sidebar list reactivity (F3 workaround) - add, delete, favorite")
    func testSidebarListReactivity() throws {
        let store = try makeTestStore()
        
        #expect(store.allProfiles().isEmpty)
        
        // 1. Add
        let profile1 = ConnectionProfile(name: "Test 1", protocolType: .ssh, host: "host")
        try store.add(profile1)
        
        #expect(store.allProfiles().count == 1)
        #expect(store.allProfiles().first?.name == "Test 1")
        
        // 2. Favorite
        let addedProfile = store.allProfiles().first!
        store.toggleFavorite(addedProfile)
        
        #expect(store.allProfiles().first?.isFavorite == true)
        #expect(store.favorites().count == 1)
        
        // 3. Delete
        store.delete(addedProfile)
        #expect(store.allProfiles().isEmpty)
    }
}
