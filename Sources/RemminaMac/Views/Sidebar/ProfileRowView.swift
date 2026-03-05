import SwiftUI

/// A single row in the profile list sidebar.
struct ProfileRowView: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 10) {
            // Protocol icon
            Image(systemName: profile.protocolType.iconName)
                .font(.title3)
                .foregroundStyle(protocolColor)
                .frame(width: 28, height: 28)
                .background(protocolColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(profile.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if profile.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }

                Text(profile.connectionString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Protocol badge
            Text(profile.protocolType.displayName)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(protocolColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(protocolColor.opacity(0.12))
                .clipShape(Capsule())
        }
        .padding(.vertical, 4)
    }

    private var protocolColor: Color {
        switch profile.protocolType {
        case .ssh: return .green
        case .vnc: return .blue
        case .rdp: return .orange
        }
    }
}
