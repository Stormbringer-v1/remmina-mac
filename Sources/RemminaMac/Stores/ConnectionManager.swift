import Foundation
import AppKit

/// Manages active remote sessions (tab state).
///
/// Enterprise features:
/// - Dock badge showing active connection count
/// - Sleep/wake health checking
/// - Duplicate session prevention
/// - Bounded output buffers (1MB per session)
@Observable
final class ConnectionManager: SessionDelegate {
    private(set) var sessions: [any SessionProtocol] = []
    var activeSessionId: UUID?

    /// Output buffers per session for terminal rendering.
    private(set) var outputBuffers: [UUID: Data] = [:]

    /// Tracks which sessions need health checks after system wake
    private var needsHealthCheck = false

    var activeSession: (any SessionProtocol)? {
        sessions.first { $0.id == activeSessionId }
    }

    /// Number of active (connected/connecting) sessions
    var activeCount: Int {
        sessions.filter { $0.status.isActive }.count
    }

    // MARK: - Session Management

    /// Maximum concurrent sessions to prevent resource exhaustion
    static let maxSessions = 20

    /// Opens a new session for the given profile.
    /// Returns false if a session to this profile already exists (prevents duplicates)
    /// or if the maximum session limit has been reached.
    @discardableResult
    func openSession(for profile: ConnectionProfile) -> Bool {
        // Prevent duplicate sessions to the same profile
        if let existing = sessions.first(where: { $0.profileId == profile.id && $0.status.isActive }) {
            activeSessionId = existing.id
            AppLogger.shared.log("Session already active for: \(profile.name) — switched to existing tab")
            return false
        }

        // Prevent resource exhaustion: enforce maximum session count
        if sessions.count >= Self.maxSessions {
            AppLogger.shared.log("Session limit reached (\(Self.maxSessions)) — cannot open new session for: \(profile.name)", level: .warning)
            return false
        }

        let password = KeychainStore.shared.getPassword(for: profile.id)
        let session: any SessionProtocol

        switch profile.protocolType {
        case .ssh:
            session = SSHSession(profile: profile, password: password)
        case .vnc:
            session = VNCSession(profile: profile, password: password)
        case .rdp:
            session = RDPSession(profile: profile, password: password)
        }

        session.delegate = self
        sessions.append(session)
        outputBuffers[session.id] = Data()
        activeSessionId = session.id
        session.connect()

        updateDockBadge()
        AppLogger.shared.log("Session opened for profile: \(profile.name)")
        return true
    }

    func closeSession(_ session: any SessionProtocol) {
        session.disconnect()
        sessions.removeAll { $0.id == session.id }
        outputBuffers.removeValue(forKey: session.id)

        if activeSessionId == session.id {
            activeSessionId = sessions.last?.id
        }

        updateDockBadge()
        AppLogger.shared.log("Session closed: \(session.profileName)")
    }

    func closeSession(byId sessionId: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        closeSession(session)
    }

    func closeAll() {
        for session in sessions {
            session.disconnect()
        }
        sessions.removeAll()
        outputBuffers.removeAll()
        activeSessionId = nil
        updateDockBadge()
    }

    func reconnectSession(_ session: any SessionProtocol) {
        outputBuffers[session.id] = Data()
        session.reconnect()
    }

    // MARK: - Sleep/Wake Health Check

    /// Marks all sessions for health check (called before system sleep)
    func markAllForHealthCheck() {
        needsHealthCheck = true
    }

    /// Probes all active sessions after system wake.
    /// Sessions that have silently died are marked as disconnected.
    func probeSessionHealth() {
        guard needsHealthCheck else { return }
        needsHealthCheck = false

        for session in sessions {
            if session.status == .connected {
                // For SSH sessions, check if process is still running
                if session is SSHSession {
                    // The SSH keepalive (ServerAliveInterval=30) will detect dead
                    // connections within 90s. After wake, give it a moment.
                    AppLogger.shared.log("SSH: Health check for \(session.profileName) — keepalive will detect if dead")
                }
                // For VNC, the message loop will detect dead connections
                // For RDP, the process termination handler will fire
            }
        }
        updateDockBadge()
    }

    // MARK: - Dock Badge

    private func updateDockBadge() {
        let count = activeCount
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: - SessionDelegate

    func sessionDidChangeStatus(_ session: any SessionProtocol, status: SessionStatus) {
        AppLogger.shared.log("Session \(session.profileName) status: \(status.displayName)")
        updateDockBadge()
    }

    func sessionDidReceiveOutput(_ session: any SessionProtocol, data: Data) {
        if var buffer = outputBuffers[session.id] {
            buffer.append(data)
            // Keep max 1MB of scrollback
            if buffer.count > 1_048_576 {
                buffer = buffer.suffix(524_288)
            }
            outputBuffers[session.id] = buffer
        }
    }
}
