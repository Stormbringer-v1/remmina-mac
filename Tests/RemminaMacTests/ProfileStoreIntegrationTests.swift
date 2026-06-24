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
    func testSidebarReactivity() throws {
        let store = try makeTestStore()
        
        let initialTrigger = store.refreshTrigger
        #expect(initialTrigger == 0)
        #expect(store.allProfiles().isEmpty)
        
        // 1. Add
        let profile1 = ConnectionProfile(name: "Test 1", protocolType: .ssh, host: "10.0.0.1")
        try store.add(profile1)
        
        #expect(store.refreshTrigger == initialTrigger + 1)
        #expect(store.allProfiles().count == 1)
        #expect(store.allProfiles().first?.name == "Test 1")
        
        // 2. Favorite
        let addedProfile = store.allProfiles().first!
        #expect(addedProfile.isFavorite == false)
        store.toggleFavorite(addedProfile)
        
        #expect(store.refreshTrigger == initialTrigger + 2)
        #expect(store.allProfiles().first?.isFavorite == true)
        #expect(store.favorites().count == 1)
        
        // 3. Delete
        store.delete(addedProfile)
        #expect(store.refreshTrigger == initialTrigger + 3)
        #expect(store.allProfiles().isEmpty)
    }
}
