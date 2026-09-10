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
                // ZStack of all sessions, only the active one is visible. This
                // keeps every session's view alive across tab switches so the
                // SwiftTerm scrollback (and VNC framebuffer, RDP state) is
                // preserved. The previous `.id(activeSession.id)` destroyed
                // and rebuilt the view on every tab switch, which is why
                // switching tabs lost scrollback.
                ZStack {
                    ForEach(connectionManager.sessions, id: \.id) { session in
                        let isActive = session.id == connectionManager.activeSessionId
                        SessionContainerView(isActive: isActive) {
                            sessionContent(for: session)
                        }
                        .opacity(isActive ? 1 : 0)
                        .allowsHitTesting(isActive)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        let status = connectionManager.status(for: session.id)

        return HStack(spacing: 6) {
            // Status indicator — observes the connectionManager's status mirror
            Circle()
                .fill(statusColor(for: status))
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
        let status = connectionManager.status(for: session.id)

        return HStack(spacing: 12) {
            // Status — observes the connectionManager's status mirror
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor(for: status))
                    .frame(width: 8, height: 8)
                Text(status.displayName)
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
            .disabled(!status.isActive && status != .disconnected)

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

// MARK: - AppKit Focus & Visibility Management

/// Marker protocol for the NSView subclasses that should receive keyboard
/// focus inside a session tab (PROBLEMS.md ISSUE-003). Replaces matching on
/// a stringified type name (`!String(describing: type(of: view)).contains
/// ("Hosting")`), which was fragile and coupled to AppKit's private view
/// class naming. Conform the actual input-handling view for each protocol
/// (`VNCCanvasView` in VNCDesktopView.swift, `SwiftTerm.TerminalView` via an
/// extension in TerminalView.swift) rather than every `NSView` that happens
/// to accept first responder.
protocol SessionFocusable: NSView {}

/// Manages AppKit focus and isHidden state for session views across tab switches (PROBLEMS.md ISSUE-003).
private struct SessionContainerView<Content: View>: NSViewRepresentable {
    let isActive: Bool
    let content: Content

    init(isActive: Bool, @ViewBuilder content: () -> Content) {
        self.isActive = isActive
        self.content = content()
    }

    func makeNSView(context: Context) -> SessionHostingContainerView {
        let container = SessionHostingContainerView()
        let hostingView = NSHostingView(rootView: AnyView(content))
        container.hostingView = hostingView
        container.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        container.updateActive(isActive)
        return container
    }

    func updateNSView(_ container: SessionHostingContainerView, context: Context) {
        container.hostingView?.rootView = AnyView(content)
        container.updateActive(isActive)
    }
}

private final class SessionHostingContainerView: NSView {
    var hostingView: NSHostingView<AnyView>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func updateActive(_ isActive: Bool) {
        self.isHidden = !isActive
        if isActive {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.isHidden, let window = self.window else { return }
                if let responder = self.findFirstResponder(in: self), window.firstResponder !== responder {
                    window.makeFirstResponder(responder)
                }
            }
        }
    }

    private func findFirstResponder(in view: NSView) -> NSView? {
        for subview in view.subviews {
            if let found = findFirstResponder(in: subview) {
                return found
            }
        }
        if let focusable = view as? SessionFocusable, focusable.acceptsFirstResponder {
            return focusable
        }
        return nil
    }
}
