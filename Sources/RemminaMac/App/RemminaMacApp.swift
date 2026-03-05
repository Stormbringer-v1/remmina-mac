import SwiftUI
import SwiftData

@main
struct RemminaMacApp: App {
    let modelContainer: ModelContainer

    @State private var connectionManager = ConnectionManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Graceful DB recovery instead of fatalError
        // If the store is corrupted, we attempt recovery; never crash on launch.
        do {
            let schema = Schema([ConnectionProfile.self])
            let modelConfiguration = ModelConfiguration(
                "RemminaMac",
                schema: schema,
                isStoredInMemoryOnly: false
            )
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Attempt recovery: try in-memory store so the app launches
            AppLogger.shared.log("Database corrupted: \(error). Using temporary in-memory store.", level: .error)
            do {
                let schema = Schema([ConnectionProfile.self])
                let fallbackConfig = ModelConfiguration(
                    "RemminaMac-Recovery",
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
                modelContainer = try ModelContainer(for: schema, configurations: [fallbackConfig])
            } catch {
                // Absolute last resort — this should never happen
                fatalError("Cannot create even in-memory store: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(connectionManager)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    appDelegate.connectionManager = connectionManager
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
