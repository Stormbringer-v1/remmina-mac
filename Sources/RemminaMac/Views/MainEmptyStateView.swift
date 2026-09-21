import SwiftUI

struct MainEmptyStateView: View {
    let hasNoProfiles: Bool
    let onNewProfile: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(hasNoProfiles ? "Welcome to RemminaMac" : "No Profile Selected")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(hasNoProfiles ? "Create your first connection profile to get started" : "Select a profile from the sidebar or create a new one")
                .font(.body)
                .foregroundStyle(.tertiary)
            Button("New Profile") {
                onNewProfile()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            // Shown only while no backend persists anything: new users otherwise
            // discover that passwords aren't saved only when a VNC/RDP connect
            // fails. Kept flat (no nested stack, no fixedSize) — a fixed-size
            // multiline text here made NavigationSplitView lay the sidebar's
            // filter picker out above the window.
            if SecuritySettings.shared.credentialBackend == .none {
                Text("Passwords aren't saved until you choose a credential backend in Settings → Security. SSH works with keys or ssh-agent without one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                SettingsLink {
                    Label("Open Security Settings…", systemImage: "lock.shield")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
