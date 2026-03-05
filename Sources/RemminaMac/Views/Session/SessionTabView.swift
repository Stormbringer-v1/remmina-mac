import SwiftUI

/// Tabbed view for active remote sessions.
struct SessionTabView: View {
    @Environment(ConnectionManager.self) private var connectionManager

    var body: some View {
        @Bindable var manager = connectionManager

        VStack(spacing: 0) {
            // Tab bar
            if connectionManager.sessions.count > 0 {
                tabBar
                Divider()
            }

            // Active session content
            if let activeSession = connectionManager.activeSession {
                sessionContent(for: activeSession)
                    .id(activeSession.id)

                // Session toolbar
                sessionToolbar(for: activeSession)
            } else {
                noSessionView
            }
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(connectionManager.sessions, id: \.id) { session in
                    tabItem(for: session)
                }
                Spacer()
            }
        }
        .frame(height: 36)
        .background(.bar)
    }

    private func tabItem(for session: any SessionProtocol) -> some View {
        let isActive = session.id == connectionManager.activeSessionId

        return HStack(spacing: 6) {
            // Status indicator
            Circle()
                .fill(statusColor(for: session.status))
                .frame(width: 8, height: 8)

            Image(systemName: session.protocolType.iconName)
                .font(.caption)

            Text(session.profileName)
                .font(.caption)
                .lineLimit(1)

            Button(action: {
                connectionManager.closeSession(session)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color.clear)
        .overlay(
            Rectangle()
                .frame(height: 2)
                .foregroundStyle(isActive ? Color.accentColor : Color.clear),
            alignment: .bottom
        )
        .contentShape(Rectangle())
        .onTapGesture {
            connectionManager.activeSessionId = session.id
        }
    }

    // MARK: - Session Content

    @ViewBuilder
    private func sessionContent(for session: any SessionProtocol) -> some View {
        switch session.protocolType {
        case .ssh:
            if let sshSession = session as? SSHSession {
                TerminalView(session: sshSession)
            }
        case .vnc:
            if let vncSession = session as? VNCSession {
                VNCSessionView(session: vncSession)
            }
        case .rdp:
            if let rdpSession = session as? RDPSession {
                RDPSessionView(session: rdpSession)
            }
        }
    }

    // MARK: - Session Toolbar

    private func sessionToolbar(for session: any SessionProtocol) -> some View {
        HStack(spacing: 12) {
            // Status
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor(for: session.status))
                    .frame(width: 8, height: 8)
                Text(session.status.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Actions
            Button(action: {
                connectionManager.reconnectSession(session)
            }) {
                Label("Reconnect", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!session.status.isActive && session.status != .disconnected)

            Button(action: {
                connectionManager.closeSession(session)
            }) {
                Label("Disconnect", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Empty State

    private var noSessionView: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Active Sessions")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Select a profile and click Connect to start a session")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func statusColor(for status: SessionStatus) -> Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected: return .gray
        case .error: return .red
        }
    }
}
