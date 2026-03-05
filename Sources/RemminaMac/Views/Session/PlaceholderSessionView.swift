import SwiftUI

/// Placeholder view for VNC/RDP sessions not yet implemented.
struct PlaceholderSessionView: View {
    let protocolType: ProtocolType

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: protocolType.iconName)
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)

            Text("\(protocolType.displayName) Support")
                .font(.title)
                .fontWeight(.bold)

            Text("Coming Soon")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("\(protocolType.displayName) protocol support is planned for a future release.\nThe architecture is ready — stay tuned!")
                .font(.body)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            // Feature list
            VStack(alignment: .leading, spacing: 8) {
                Label("Session management", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("Profile storage", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("Keychain integration", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("\(protocolType.displayName) client", systemImage: "clock.fill")
                    .foregroundStyle(.orange)
            }
            .font(.body)
            .padding(20)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
