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

    /// Explicit profile cache — mutated after every add/delete/edit/import
    /// so SwiftUI's @State change tracking triggers an immediate re-render.
    @State private var profiles: [ConnectionProfile] = []

    enum FilterMode: String, CaseIterable {
        case all = "All"
        case favorites = "Favorites"
        case recent = "Recent"
    }

    var body: some View {
        NavigationSplitView {
            sidebarContent
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
            reloadProfiles()
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
                    // Immediately refresh the sidebar list
                    reloadProfiles()
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
                    reloadProfiles()
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

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // Filter picker
            Picker("Filter", selection: $filterMode) {
                ForEach(FilterMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Profile list
            List(filteredProfiles, id: \.id, selection: $selectedProfile) { profile in
                ProfileRowView(profile: profile)
                    .tag(profile)
                    .onTapGesture(count: 2) {
                        connectToProfile(profile)
                    }
                    .contextMenu {
                        profileContextMenu(for: profile)
                    }
            }
            .listStyle(.sidebar)
        }
    }

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
                emptyState
            }
        } else {
            SessionTabView()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("No Profile Selected")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Select a profile from the sidebar or create a new one")
                .font(.body)
                .foregroundStyle(.tertiary)
            Button("New Profile") {
                showingNewProfile = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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

    // MARK: - Context Menu

    @ViewBuilder
    private func profileContextMenu(for profile: ConnectionProfile) -> some View {
        Button("Connect") {
            connectToProfile(profile)
        }

        Divider()

        Button(profile.isFavorite ? "Unfavorite" : "Favorite") {
            profileStore?.toggleFavorite(profile)
            reloadProfiles()
        }

        Button("Copy Host") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(profile.host, forType: .string)
        }

        if !profile.username.isEmpty {
            Button("Copy Username") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(profile.username, forType: .string)
            }
        }

        Divider()

        Button("Edit…") {
            selectedProfile = profile
            showingEditProfile = true
        }

        Button("Delete", role: .destructive) {
            requestDelete(profile)
        }
    }

    // MARK: - Helpers

    /// Reloads the profile list from SwiftData into the @State array.
    /// This is the single source of truth for the sidebar — call after every mutation.
    private func reloadProfiles() {
        profiles = profileStore?.allProfiles() ?? []
    }

    private var filteredProfiles: [ConnectionProfile] {
        let base: [ConnectionProfile]

        switch filterMode {
        case .all:
            base = profiles
        case .favorites:
            base = profiles.filter { $0.isFavorite }
        case .recent:
            base = profiles
                .filter { $0.lastConnectedAt != nil }
                .sorted { ($0.lastConnectedAt ?? .distantPast) > ($1.lastConnectedAt ?? .distantPast) }
        }

        if searchText.isEmpty {
            return base
        }

        let query = searchText.lowercased()
        return base.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.host.localizedCaseInsensitiveContains(query) ||
            $0.username.localizedCaseInsensitiveContains(query) ||
            $0.tagsRawValue.localizedCaseInsensitiveContains(query)
        }
    }

    private func connectToProfile(_ profile: ConnectionProfile) {
        profileStore?.markConnected(profile)
        reloadProfiles()
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
        reloadProfiles()
    }

    /// Auto-connect profiles marked "Connect on open" at app launch
    private func autoConnectOnOpen() {
        let autoConnectProfiles = profiles.filter { $0.connectOnOpen }
        for profile in autoConnectProfiles {
            profileStore?.markConnected(profile)
            connectionManager.openSession(for: profile)
        }
        if !autoConnectProfiles.isEmpty {
            AppLogger.shared.log("Auto-connected \(autoConnectProfiles.count) profile(s) on launch")
        }
    }

    private func exportProfiles() {
        guard !profiles.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "remmina_profiles.json"

        if panel.runModal() == .OK, let url = panel.url {
            if ProfileImportExport.exportToFile(profiles, url: url) {
                AppLogger.shared.log("Exported \(profiles.count) profiles to \(url.lastPathComponent)")
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
                
                // Refresh sidebar after all imports
                reloadProfiles()
                
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
