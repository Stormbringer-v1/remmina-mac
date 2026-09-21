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
    @State private var importSkippedCount = 0
    @State private var showingDeleteConfirmation = false
    @State private var profileToDelete: ConnectionProfile?
    @State private var validationError: String?
    @State private var showingValidationError = false

    /// The active credential store. Read directly from `SecuritySettings`
    /// (not `@Environment`, since this view is where the environment value
    /// for descendants — `ProfileEditView`, `ProfileDetailView` — is set)
    /// so it's always current: it's a computed property, not cached, and
    /// this read happening during body evaluation makes `body` re-run
    /// (via Observation) whenever the backend setting changes.
    private var credentialStore: CredentialStore { SecuritySettings.shared.activeCredentialStore }

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
        .environment(\.credentialStore, credentialStore)
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
                        do {
                            try credentialStore.save(password, kind: .password, for: profile.id)
                        } catch EncryptedStoreError.locked {
                            validationError = "The profile was saved, but its password was not: the encrypted credential store is locked. Unlock it in Settings → Security, then edit this profile to re-enter the password."
                            showingValidationError = true
                        } catch {
                            validationError = "Unable to save password to \(credentialStore.displayName). Check System Settings → Privacy & Security."
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
                ProfileEditView(mode: .edit(profile)) { editedProfile, password in
                    // PROBLEMS.md ISSUE-002: ProfileEditView.saveProfile() is
                    // the single validation gate — it builds a ProfileDraft,
                    // calls validated(), and only calls apply(to:) on
                    // success. A second ProfileValidator.validate() call
                    // here used to run AFTER apply(to:) had already written
                    // the model and would normalize the live SwiftData
                    // object in place a second time. Do not reintroduce it.
                    //
                    // Password is only saved if the user actually changed it
                    // (tracked by passwordDirty flag in ProfileEditView)
                    if let password = password {
                        do {
                            if password.isEmpty {
                                // User explicitly cleared the password
                                try credentialStore.delete(.password, for: editedProfile.id)
                            } else {
                                try credentialStore.save(password, kind: .password, for: editedProfile.id)
                            }
                        } catch {
                            validationError = "Unable to update password in \(credentialStore.displayName). Check System Settings → Privacy & Security."
                            showingValidationError = true
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
            Text("Imported \(importCount) profile\(importCount == 1 ? "" : "s"), skipped \(importSkippedCount) profile\(importSkippedCount == 1 ? "" : "s") already in the library.")
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
        // Only stamp "last connected" (which feeds the Recents filter) when a
        // session is actually opened — not on a validation failure, a duplicate,
        // or when the max-session limit has been reached.
        switch connectionManager.openSession(for: profile) {
        case .opened:
            profileStore?.markConnected(profile)
        case .duplicate, .limitReached:
            break
        case .hostInvalid(let reason):
            validationError = reason
            showingValidationError = true
        case .keychainFailed(let status):
            validationError = KeychainError.unexpectedStatus(status).localizedDescription
            showingValidationError = true
        case .credentialUnavailable(let reason):
            validationError = reason
            showingValidationError = true
        case .storeLocked(let reason):
            validationError = reason
            showingValidationError = true
        }
    }

    /// Requests deletion with confirmation dialog (no one-click data loss)
    private func requestDelete(_ profile: ConnectionProfile) {
        profileToDelete = profile
        showingDeleteConfirmation = true
    }

    /// Actually performs the deletion after user confirms.
    ///
    /// Order matters: close every live session for this profile first (a
    /// session must never outlive the profile it's connected from), then
    /// delete the SwiftData model and save. Only once that save actually
    /// succeeds — `saveOrRollback()` can roll back — do we delete the
    /// stored credentials; deleting them first (the old order) meant a
    /// rolled-back save left a profile with no password.
    private func performDelete(_ profile: ConnectionProfile) {
        guard let profileStore else {
            AppLogger.shared.log("Delete requested before profileStore was ready — ignoring", level: .error)
            return
        }
        let profileId = profile.id

        for session in connectionManager.sessions where session.profileId == profileId {
            connectionManager.closeSession(byId: session.id)
        }

        if selectedProfile?.id == profileId {
            selectedProfile = nil
        }

        modelContext.delete(profile)
        do {
            try profileStore.saveOrRollback()
            AppLogger.shared.log("Profile deleted: \(profile.name)", profileId: profileId)
            // The profile row is gone either way at this point; a failure to
            // delete its credentials shouldn't be reported as a delete
            // failure — just log it and move on.
            do {
                try credentialStore.deleteAll(for: profileId)
            } catch {
                AppLogger.shared.log("Failed to delete credentials for profile \(profileId): \(error.localizedDescription)", level: .error, profileId: profileId)
            }
        } catch {
            validationError = "Unable to delete \"\(profile.name)\": \(error.localizedDescription)"
            showingValidationError = true
        }
    }

    /// Auto-connect profiles marked "Connect on open" at app launch
    private func autoConnectOnOpen() {
        let autoConnectProfiles = allProfiles.filter { $0.connectOnOpen }
        var connectedCount = 0
        var failures: [(String, String)] = []
        for profile in autoConnectProfiles {
            switch connectionManager.openSession(for: profile) {
            case .opened:
                profileStore?.markConnected(profile)
                connectedCount += 1
            case .duplicate, .limitReached:
                break
            case .hostInvalid(let reason):
                failures.append((profile.name, reason))
            case .keychainFailed(let status):
                failures.append((profile.name, KeychainError.unexpectedStatus(status).localizedDescription))
            case .credentialUnavailable(let reason):
                failures.append((profile.name, reason))
            case .storeLocked(let reason):
                failures.append((profile.name, reason))
            }
        }
        if connectedCount > 0 {
            AppLogger.shared.log("Auto-connected \(connectedCount) profile(s) on launch")
        }
        if !failures.isEmpty {
            let errorMsg = failures.map { "• \($0.0): \($0.1)" }.joined(separator: "\n")
            validationError = "Failed to auto-connect \(failures.count) profile(s):\n\n\(errorMsg)"
            showingValidationError = true
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
                // Re-importing the same export used to duplicate every
                // profile: skip anything whose id already exists among the
                // current profiles (from @Query'd `allProfiles`), and also
                // track ids added earlier in this same pass so a file that
                // repeats an id internally doesn't create two rows for it.
                var seenIds = Set(allProfiles.map(\.id))
                var successCount = 0
                var skippedCount = 0
                var failedProfiles: [(String, String)] = []

                for profile in imported {
                    if seenIds.contains(profile.id) {
                        skippedCount += 1
                        continue
                    }
                    do {
                        // PROBLEMS.md ISSUE-001: an imported profile's SSH
                        // key almost never lives at the same path on this
                        // machine, so allow the import to succeed with a
                        // missing key file (ProfileStore.add logs a warning
                        // naming the path). The create path (above) keeps
                        // the strict default.
                        try profileStore?.add(profile, allowMissingSSHKey: true)
                        successCount += 1
                        seenIds.insert(profile.id)
                    } catch {
                        failedProfiles.append((profile.name, error.localizedDescription))
                    }
                }

                // Exactly one alert must fire per import pass. A failure
                // takes priority (it folds in the imported/skipped counts
                // too) since it's the more actionable outcome; otherwise the
                // success alert reports imported vs. skipped counts.
                if !failedProfiles.isEmpty {
                    var errorMsg = "Failed to import \(failedProfiles.count) profile(s):\n\n"
                    errorMsg += failedProfiles.map { "• \($0.0): \($0.1)" }.joined(separator: "\n")
                    if successCount > 0 || skippedCount > 0 {
                        errorMsg += "\n\n(\(successCount) imported, \(skippedCount) already in the library and skipped.)"
                    }
                    validationError = errorMsg
                    showingValidationError = true
                } else if successCount > 0 || skippedCount > 0 {
                    importCount = successCount
                    importSkippedCount = skippedCount
                    importAlert = true
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
