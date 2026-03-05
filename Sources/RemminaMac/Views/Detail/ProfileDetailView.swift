import SwiftUI

/// Detail view showing full profile information with actions.
struct ProfileDetailView: View {
    let profile: ConnectionProfile
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                header

                Divider()

                // Connection info
                connectionSection

                // Authentication
                if !profile.username.isEmpty || !profile.domain.isEmpty {
                    authSection
                }

                // Tags
                if !profile.tags.isEmpty {
                    tagsSection
                }

                // Notes
                if !profile.notes.isEmpty {
                    notesSection
                }

                // Metadata
                metadataSection

                Spacer()
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Delete Profile", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete() }
        } message: {
            Text("Are you sure you want to delete \"\(profile.name)\"? This cannot be undone.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: profile.protocolType.iconName)
                .font(.system(size: 36))
                .foregroundStyle(protocolColor)
                .frame(width: 64, height: 64)
                .background(protocolColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(profile.name)
                        .font(.title)
                        .fontWeight(.bold)
                    if profile.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }
                Text(profile.protocolType.displayName + " Connection")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: onEdit) {
                    Label("Edit", systemImage: "pencil")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive, action: { showDeleteConfirmation = true }) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)

                Button(action: onConnect) {
                    Label("Connect", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection")
                .font(.headline)
                .foregroundStyle(.secondary)

            LabeledContent("Host", value: profile.host)
            LabeledContent("Port", value: "\(profile.port)")
            LabeledContent("Protocol", value: profile.protocolType.displayName)
        }
    }

    private var authSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Authentication")
                .font(.headline)
                .foregroundStyle(.secondary)

            if !profile.username.isEmpty {
                LabeledContent("Username", value: profile.username)
            }
            if !profile.domain.isEmpty {
                LabeledContent("Domain", value: profile.domain)
            }

            HStack {
                Text("Password")
                    .foregroundStyle(.secondary)
                Spacer()
                if KeychainStore.shared.getPassword(for: profile.id) != nil {
                    Label("Stored in Keychain", systemImage: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Not set")
                        .foregroundStyle(.tertiary)
                }
            }

            if !profile.sshKeyPath.isEmpty {
                HStack {
                    Text("SSH Key")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label(shortenedKeyPath(profile.sshKeyPath), systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .help(profile.sshKeyPath)
                }
            }
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.headline)
                .foregroundStyle(.secondary)

            FlowLayout(spacing: 6) {
                ForEach(profile.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(profile.notes)
                .font(.body)
                .foregroundStyle(.primary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Info")
                .font(.headline)
                .foregroundStyle(.secondary)

            LabeledContent("Created", value: profile.createdAt.formatted(date: .abbreviated, time: .shortened))

            if let lastConnected = profile.lastConnectedAt {
                LabeledContent("Last Connected", value: lastConnected.formatted(date: .abbreviated, time: .shortened))
            }

            if profile.connectOnOpen {
                Label("Auto-connect on open", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        }
    }

    private func shortenedKeyPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private var protocolColor: Color {
        switch profile.protocolType {
        case .ssh: return .green
        case .vnc: return .blue
        case .rdp: return .orange
        }
    }
}

// MARK: - FlowLayout

/// Simple horizontal wrapping layout for tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
