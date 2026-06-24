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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
