import SwiftUI
import SwiftData

@main
struct RemminaMacApp: App {
    let modelContainer: ModelContainer
    let appState: AppState

    @State private var connectionManager = ConnectionManager()
    @State private var showingRecoveryAlert = false
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        self.init(appState: nil)
    }

    init(appState: AppState?) {
        let state = appState ?? AppState()
        var container: ModelContainer?

        let schema = Schema([ConnectionProfile.self])
        let modelConfiguration = ModelConfiguration(
            "RemminaMac",
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            container = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            AppLogger.shared.log("Database corrupted: \(error). Backing up and attempting recovery.", level: .error)

            // Back up by MOVING the corrupted store (and its -wal/-shm
            // siblings) out of the way, then retry at the exact same
            // (original) configuration/URL. The old behavior copied the
            // corrupted file and created a NEW timestamped recovery store
            // instead — the corrupted original was still sitting at the
            // default URL, so every subsequent launch re-failed on it,
            // re-backed-up, and piled up another recovery store, and
            // anything written during recovery never migrated back.
            let backupPath = Self.backupCorruptedStore(storeURL: modelConfiguration.url)
            state.recoveryMode = true
            state.recoveryBackupPath = backupPath

            do {
                container = try ModelContainer(for: schema, configurations: [modelConfiguration])
                // Recovered onto a fresh on-disk store at the original
                // location — changes save normally from here on.
                state.recoveryIsInMemoryOnly = false
            } catch {
                AppLogger.shared.log("Recovery at the original store location also failed: \(error). Falling back to an in-memory store.", level: .error)
                do {
                    let fallbackConfig = ModelConfiguration(
                        "RemminaMac-Recovery",
                        schema: schema,
                        isStoredInMemoryOnly: true
                    )
                    container = try ModelContainer(for: schema, configurations: [fallbackConfig])
                    // Only this final fallback actually loses data — nothing
                    // typed this session will be saved anywhere on disk.
                    state.recoveryIsInMemoryOnly = true
                } catch {
                    fatalError("Cannot create even in-memory store: \(error)")
                }
            }
        }

        self.modelContainer = container!
        self.appState = state
    }

    /// Backs up corrupted store files to ~/Library/Application Support/RemminaMac/Backups/<ISO8601 timestamp>/
    /// by MOVING them (not copying) — the caller needs the original store
    /// location to be free of the corrupted file so a fresh container can be
    /// created at the exact same configuration/URL.
    @discardableResult
    static func backupCorruptedStore(
        storeURL: URL? = nil,
        fileManager: FileManager = .default,
        timestamp: String = ISO8601DateFormatter().string(from: Date())
    ) -> String? {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.applicationSupportDirectory
        let baseStoreURL = storeURL ?? appSupport.appendingPathComponent("RemminaMac.store")
        
        let backupDir = appSupport.appendingPathComponent("RemminaMac/Backups/\(timestamp)")
        
        let candidateURLs: [URL] = [
            baseStoreURL,
            appSupport.appendingPathComponent("RemminaMac/RemminaMac.store"),
            appSupport.appendingPathComponent("default.store")
        ]
        
        var filesFound = 0
        
        for candidate in candidateURLs {
            let candidateBase = candidate.path
            let suffixes = ["", "-wal", "-shm"]
            for suffix in suffixes {
                let filePath = candidateBase + suffix
                if fileManager.fileExists(atPath: filePath) {
                    do {
                        try fileManager.createDirectory(at: backupDir, withIntermediateDirectories: true)
                        let fileName = URL(fileURLWithPath: filePath).lastPathComponent
                        let destURL = backupDir.appendingPathComponent(fileName)
                        try fileManager.moveItem(at: URL(fileURLWithPath: filePath), to: destURL)
                        filesFound += 1
                    } catch {
                        AppLogger.shared.log("Failed to move \(filePath) to backup: \(error)", level: .error)
                    }
                }
            }
            if filesFound > 0 { break }
        }
        
        if filesFound > 0 {
            AppLogger.shared.log("Corrupted store backed up to: \(backupDir.path)", level: .error)
            return backupDir.path
        }
        
        return nil
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(connectionManager)
                .environment(appState)
                .safeAreaInset(edge: .top) {
                    if appState.recoveryMode {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                            Text(appState.recoveryIsInMemoryOnly
                                 ? "Recovery mode: running in memory — changes will not be saved"
                                 : "Recovery mode: recovered into a fresh store")
                                .font(.callout)
                                .fontWeight(.medium)
                            if let backupPath = appState.recoveryBackupPath {
                                Text("(Old store backed up: \(backupPath))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.15))
                        .overlay(
                            Rectangle()
                                .frame(height: 1)
                                .foregroundColor(.orange.opacity(0.3)),
                            alignment: .bottom
                        )
                    }
                }
                .frame(minWidth: 900, minHeight: 600)
                .alert("Recovery Mode", isPresented: $showingRecoveryAlert) {
                    Button("OK", role: .cancel) {}
                } message: {
                    if appState.recoveryIsInMemoryOnly {
                        if let backup = appState.recoveryBackupPath {
                            Text("The database failed to load and was backed up to:\n\(backup)\n\nA fresh store could not be created either, so the app is running in memory: changes will not be saved.")
                        } else {
                            Text("The database failed to load, and a fresh store could not be created. The app is running in memory: changes will not be saved.")
                        }
                    } else if let backup = appState.recoveryBackupPath {
                        Text("The database failed to load. The old store was backed up to:\n\(backup)\n\nThe app has recovered into a fresh, empty store — changes now save normally.")
                    } else {
                        Text("The database failed to load. The app has recovered into a fresh, empty store — changes now save normally.")
                    }
                }
                .onAppear {
                    appDelegate.connectionManager = connectionManager
                    if appState.recoveryMode {
                        showingRecoveryAlert = true
                    }
                }
        }
        .modelContainer(modelContainer)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Profile") {
                    NotificationCenter.default.post(name: .newProfile, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Session") {
                Button("Reconnect") {
                    NotificationCenter.default.post(name: .reconnectSession, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Disconnect") {
                    NotificationCenter.default.post(name: .disconnectSession, object: nil)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }

        Settings {
            SecuritySettingsView()
        }
    }
}

// MARK: - AppDelegate for Lifecycle Management

/// Handles macOS app lifecycle events:
/// - Graceful session cleanup on quit
/// - Sleep/wake detection for session health
/// - Dock badge for active connection count
final class AppDelegate: NSObject, NSApplicationDelegate {
    var connectionManager: ConnectionManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register for sleep/wake notifications
        let workspace = NSWorkspace.shared
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspace.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        AppLogger.shared.log("App launched — lifecycle monitoring active")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Gracefully disconnect all active sessions before quitting
        connectionManager?.closeAll()
        AppLogger.shared.log("App terminating — all sessions closed")

        // Flush persistent logs
        AppLogger.shared.flushToDisk()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ application: NSApplication) -> Bool {
        return false // Keep running in menu bar / dock
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        AppLogger.shared.log("System going to sleep — marking sessions for health check")
        connectionManager?.markAllForHealthCheck()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        AppLogger.shared.log("System woke from sleep — probing session health")
        // Give network 2 seconds to re-establish, then probe
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.connectionManager?.probeSessionHealth()
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let newProfile = Notification.Name("com.remmina-mac.newProfile")
    static let reconnectSession = Notification.Name("com.remmina-mac.reconnectSession")
    static let disconnectSession = Notification.Name("com.remmina-mac.disconnectSession")
}
