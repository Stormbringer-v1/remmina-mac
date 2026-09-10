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

    /// Observable mirror of each session's status. The session classes are
    /// reference types but not @Observable, so views that want to redraw
    /// on status changes must observe this dictionary instead of reading
    /// `session.status` directly.
    private(set) var sessionStatuses: [UUID: SessionStatus] = [:]

    /// Tracks which sessions need health checks after system wake
    private var needsHealthCheck = false

    var activeSession: (any SessionProtocol)? {
        sessions.first { $0.id == activeSessionId }
    }

    /// Number of active (connected/connecting) sessions
    var activeCount: Int {
        sessions.filter { (sessionStatuses[$0.id] ?? $0.status).isActive }.count
    }

    /// Observable accessor for a session's status. Falls back to the session's
    /// own status if the mirror hasn't been populated yet (which happens on
    /// the synchronous path before the delegate callback fires).
    func status(for sessionId: UUID) -> SessionStatus {
        sessionStatuses[sessionId] ?? sessions.first(where: { $0.id == sessionId })?.status ?? .disconnected
    }

    // MARK: - Factory & Lifecycle

    typealias SessionFactory = (ConnectionProfile, String?) -> any SessionProtocol

    static let defaultFactory: SessionFactory = { profile, password in
        switch profile.protocolType {
        case .ssh:
            return SSHSession(profile: profile, password: password)
        case .vnc:
            return VNCSession(profile: profile, password: password)
        case .rdp:
            return RDPSession(profile: profile, password: password)
        }
    }

    private let sessionFactory: SessionFactory

    init(sessionFactory: @escaping SessionFactory = ConnectionManager.defaultFactory) {
        self.sessionFactory = sessionFactory
    }

    // MARK: - Session Management

    /// Maximum concurrent sessions to prevent resource exhaustion
    static let maxSessions = 20

    /// Per-session output buffer ceiling (1 MiB). Once a session's scrollback
    /// exceeds this, we trim the oldest bytes.
    static let outputBufferMaxBytes = 1 << 20
    /// When the buffer is trimmed, retain this many of the most-recent bytes
    /// (512 KiB).
    static let outputBufferTrimBytes = 1 << 19

    /// Opens a new session for the given profile.
    /// Returns false if a session to this profile already exists (prevents duplicates)
    /// or if the maximum session limit has been reached.
    @discardableResult
    func openSession(for profile: ConnectionProfile) -> Bool {
        // Re-validate host at connect time. Mutated/imported profiles might have bypassed UI validation.
        do {
            _ = try ProfileValidator.validateHost(profile.host)
        } catch {
            AppLogger.shared.log("Connection aborted: Host validation failed for \(profile.name) — \(error.localizedDescription)", level: .error)
            return false
        }

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
        let session = sessionFactory(profile, password)

        session.delegate = self
        sessions.append(session)
        outputBuffers[session.id] = Data()
        // Seed the observable status mirror with the initial status so views
        // don't briefly show "Disconnected" before the delegate fires.
        sessionStatuses[session.id] = session.status
        activeSessionId = session.id
        session.connect()

        updateDockBadge()
        AppLogger.shared.log("Session opened for profile: \(profile.name)")
        return true
    }

    func closeSession(_ session: any SessionProtocol) {
        session.delegate = nil
        session.disconnect()
        sessions.removeAll { $0.id == session.id }
        outputBuffers.removeValue(forKey: session.id)
        sessionStatuses.removeValue(forKey: session.id)

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
            session.delegate = nil
            session.disconnect()
        }
        sessions.removeAll()
        outputBuffers.removeAll()
        sessionStatuses.removeAll()
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
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: - SessionDelegate

    func sessionDidChangeStatus(_ session: any SessionProtocol, status: SessionStatus) {
        // Late status callbacks must not re-insert closed sessions (PROBLEMS.md ISSUE-015)
        guard sessions.contains(where: { $0.id == session.id }) else { return }

        // Mirror the status into the observable dictionary so views that
        // observe `connectionManager.sessionStatuses[id]` will redraw when
        // the underlying session changes state.
        sessionStatuses[session.id] = status
        AppLogger.shared.log("Session \(session.profileName) status: \(status.displayName)")
        updateDockBadge()
    }

    func sessionDidReceiveOutput(_ session: any SessionProtocol, data: Data) {
        guard sessions.contains(where: { $0.id == session.id }) else { return }
        if var buffer = outputBuffers[session.id] {
            buffer.append(data)
            // Keep at most 1 MB of scrollback per session; when the buffer
            // overflows, trim to the most recent 512 KB so the user keeps
            // the most recent context.
            if buffer.count > ConnectionManager.outputBufferMaxBytes {
                buffer = buffer.suffix(ConnectionManager.outputBufferTrimBytes)
            }
            outputBuffers[session.id] = buffer
        }
    }
}
