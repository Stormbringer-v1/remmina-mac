import SwiftUI
import SwiftData

/// Main window view with sidebar navigation and session area.
///
/// Enterprise UX:
/// - Delete confirmation dialog (no one-click data loss)
/// - Import success alert
/// - connectOnOpen honored on launch
/// - Human-readable error guidance
struct MainView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ConnectionManager.self) private var connectionManager

    // @Query is the correct live data source for SwiftData in SwiftUI.
    // Root cause of previous failures: @Query was added but filteredProfiles still
    // called profileStore.search()/recents() (manual fetches) instead of filtering
    // the @Query array in-memory — so the sidebar read stale data even though @Query
    // had updated. Fix: @Query feeds allProfiles; filteredProfiles filters it in-memory.
    @Query(sort: \ConnectionProfile.name, order: .forward) private var allProfiles: [ConnectionProfile]

    @State private var selectedProfile: ConnectionProfile?
    @State private var searchText = ""
    @State private var showingNewProfile = false
    @State private var showingEditProfile = false
    @State private var showingLog = false
    @State private var filterMode: FilterMode = .all
    @State private var profileStore: ProfileStore?
    @State private var importAlert = false
    @State private var importCount = 0
    @State private var showingDeleteConfirmation = false
    @State private var profileToDelete: ConnectionProfile?
    @State private var validationError: String?
    @State private var showingValidationError = false

    enum FilterMode: String, CaseIterable {
        case all = "All"
        case favorites = "Favorites"
        case recent = "Recent"
    }

    var body: some View {
        NavigationSplitView {
            MainSidebarView(
                profiles: filteredProfiles,
                selectedProfile: $selectedProfile,
                filterMode: $filterMode,
                onConnect: { connectToProfile($0) },
                onFavorite: { profileStore?.toggleFavorite($0) },
                onEdit: { profile in
                    selectedProfile = profile
                    showingEditProfile = true
                },
                onDelete: { requestDelete($0) }
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 350)
        } detail: {
            detailContent
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarItems
            }
        }
        .searchable(text: $searchText, prompt: "Search profiles (⌘F)")
        .onAppear {
            profileStore = ProfileStore(modelContext: modelContext)
            // Auto-connect profiles marked "Connect on open"
            autoConnectOnOpen()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newProfile)) { _ in
            showingNewProfile = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .reconnectSession)) { _ in
            if let session = connectionManager.activeSession {
                connectionManager.reconnectSession(session)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .disconnectSession)) { _ in
            if let session = connectionManager.activeSession {
                connectionManager.closeSession(session)
            }
        }
        .sheet(isPresented: $showingNewProfile) {
            ProfileEditView(mode: .create) { profile, password in
                do {
                    try profileStore?.add(profile)
                    if let password = password, !password.isEmpty {
                        if !KeychainStore.shared.savePassword(password, for: profile.id) {
                            validationError = "Unable to save password to Keychain. Check System Settings → Privacy & Security."
                            showingValidationError = true
                        }
                    }
                    // Auto-select the newly created profile
                    selectedProfile = profile
                } catch {
                    validationError = error.localizedDescription
                    showingValidationError = true
                }
            }
        }
        .sheet(isPresented: $showingEditProfile) {
            if let profile = selectedProfile {
                ProfileEditView(mode: .edit(profile)) { _, password in
                    // Password is only saved if the user actually changed it
                    // (tracked by passwordDirty flag in ProfileEditView)
                    if let password = password {
                        if password.isEmpty {
                            // User explicitly cleared the password
                            KeychainStore.shared.deletePassword(for: profile.id)
                        } else {
                            _ = KeychainStore.shared.updatePassword(password, for: profile.id)
                        }
                    }
                    // password == nil means user didn't touch the password field
                    profileStore?.save()
                }
            }
        }
        .sheet(isPresented: $showingLog) {
            LogView()
                .frame(minWidth: 600, minHeight: 400)
        }
        // Import success alert
        .alert("Import Successful", isPresented: $importAlert) {
            Button("OK") {}
        } message: {
            Text("Imported \(importCount) profile\(importCount == 1 ? "" : "s") successfully.")
        }
        // Delete confirmation dialog
        .alert("Delete Profile", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                profileToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    performDelete(profile)
                }
                profileToDelete = nil
            }
        } message: {
            if let profile = profileToDelete {
                Text("Are you sure you want to delete \"\(profile.name)\"? This action cannot be undone.")
            }
        }
        // Validation error alert
        .alert("Validation Error", isPresented: $showingValidationError) {
            Button("OK") {}
        } message: {
            Text(validationError ?? "An unknown error occurred.")
        }
    }

    // Removed sidebarContent

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        if connectionManager.sessions.isEmpty {
            if let profile = selectedProfile {
                ProfileDetailView(
                    profile: profile,
                    onConnect: { connectToProfile(profile) },
                    onEdit: { showingEditProfile = true },
                    onDelete: { requestDelete(profile) }
                )
            } else {
                MainEmptyStateView(
                    hasNoProfiles: allProfiles.isEmpty,
                    onNewProfile: { showingNewProfile = true }
                )
            }
        } else {
            SessionTabView()
        }
    }

    // Removed emptyState

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbarItems: some View {
        Button(action: { showingNewProfile = true }) {
            Label("New Profile", systemImage: "plus")
        }

        if !connectionManager.sessions.isEmpty {
            Button(action: {
                if let session = connectionManager.activeSession {
                    connectionManager.closeSession(session)
                }
            }) {
                Label("Disconnect", systemImage: "xmark.circle")
            }

            Button(action: {
                if let session = connectionManager.activeSession {
                    connectionManager.reconnectSession(session)
                }
            }) {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
        }

        Menu {
            Button(action: exportProfiles) {
                Label("Export Profiles…", systemImage: "square.and.arrow.up")
            }
            Button(action: importProfiles) {
                Label("Import Profiles…", systemImage: "square.and.arrow.down")
            }
            Divider()
            Button(action: { showingLog = true }) {
                Label("View Logs", systemImage: "doc.text")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }

    // Removed profileContextMenu

    // MARK: - Helpers



    private var filteredProfiles: [ConnectionProfile] {
        var result = allProfiles

        // 2. Apply search text in-memory (much faster than querying SQLite)
        if !searchText.isEmpty {
            result = result.filter { profile in
                profile.name.localizedStandardContains(searchText) ||
                profile.host.localizedStandardContains(searchText) ||
                profile.username.localizedStandardContains(searchText) ||
                profile.tagsRawValue.localizedStandardContains(searchText)
            }
        }

        // 3. Apply the sidebar tab filter
        switch filterMode {
        case .all:
            return result
        case .favorites:
            return result.filter { $0.isFavorite }
        case .recent:
            return result
                .filter { $0.lastConnectedAt != nil }
                .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        }
    }

    private func connectToProfile(_ profile: ConnectionProfile) {
        profileStore?.markConnected(profile)
        connectionManager.openSession(for: profile)
    }

    /// Requests deletion with confirmation dialog (no one-click data loss)
    private func requestDelete(_ profile: ConnectionProfile) {
        profileToDelete = profile
        showingDeleteConfirmation = true
    }

    /// Actually performs the deletion after user confirms
    private func performDelete(_ profile: ConnectionProfile) {
        KeychainStore.shared.deletePassword(for: profile.id)
        if selectedProfile?.id == profile.id {
            selectedProfile = nil
        }
        profileStore?.delete(profile)
    }

    /// Auto-connect profiles marked "Connect on open" at app launch
    private func autoConnectOnOpen() {
        let autoConnectProfiles = allProfiles.filter { $0.connectOnOpen }
        for profile in autoConnectProfiles {
            profileStore?.markConnected(profile)
            connectionManager.openSession(for: profile)
        }
        if !autoConnectProfiles.isEmpty {
            AppLogger.shared.log("Auto-connected \(autoConnectProfiles.count) profile(s) on launch")
        }
    }

    private func exportProfiles() {
        guard !allProfiles.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "remmina_profiles.json"

        if panel.runModal() == .OK, let url = panel.url {
            if ProfileImportExport.exportToFile(allProfiles, url: url) {
                AppLogger.shared.log("Exported \(allProfiles.count) profiles to \(url.lastPathComponent)")
            }
        }
    }

    private func importProfiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let imported = try ProfileImportExport.importFromFile(url)
                var successCount = 0
                var failedProfiles: [(String, String)] = []
                
                for profile in imported {
                    do {
                        try profileStore?.add(profile)
                        successCount += 1
                    } catch {
                        failedProfiles.append((profile.name, error.localizedDescription))
                    }
                }
                
                if successCount > 0 {
                    importCount = successCount
                    importAlert = true
                }
                
                if !failedProfiles.isEmpty {
                    let errorMsg = failedProfiles.map { "• \($0.0): \($0.1)" }.joined(separator: "\n")
                    validationError = "Failed to import \(failedProfiles.count) profile(s):\n\n\(errorMsg)"
                    showingValidationError = true
                }
            } catch let error as ProfileImportExport.ImportError {
                validationError = error.localizedDescription
                showingValidationError = true
            } catch {
                validationError = "Import failed: \(error.localizedDescription)"
                showingValidationError = true
            }
        }
    }
}
