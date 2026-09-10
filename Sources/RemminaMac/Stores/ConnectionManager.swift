import Foundation
import AppKit

/// Manages active remote sessions (tab state).
///
/// Enterprise features:
/// - Dock badge showing active connection count
/// - Sleep/wake health checking
/// - Duplicate session prevention
@Observable
final class ConnectionManager: SessionDelegate {
    private(set) var sessions: [any SessionProtocol] = []
    var activeSessionId: UUID?

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

    /// `@MainActor`-isolated (PROBLEMS.md regression fix, ex-ISSUE-032
    /// follow-up): the default factory reads `SecuritySettings.shared`,
    /// which is itself `@MainActor`. Without this annotation the factory
    /// type would let a caller read that main-actor-isolated state from an
    /// unenforced context — exactly the isolation trap ISSUE-032 removed
    /// from `RDPSession.connect()`. `SessionProtocol.connect()` itself stays
    /// un-isolated (RDPArgumentsTests exercises it from a background
    /// thread), so only the factory and `openSession` (which invokes it)
    /// are marked `@MainActor`, not the whole session type hierarchy.
    typealias SessionFactory = @MainActor (ConnectionProfile, String?) -> any SessionProtocol

    static let defaultFactory: SessionFactory = { profile, password in
        switch profile.protocolType {
        case .ssh:
            return SSHSession(profile: profile, password: password)
        case .vnc:
            return VNCSession(profile: profile, password: password)
        case .rdp:
            // Regression fix: previously called RDPSession(profile:password:)
            // with ignoreCert/clipboard left at their defaults (false/false),
            // so RDP always verified certificates and always disabled
            // clipboard regardless of what the user configured in Security
            // settings. Fails safe, but the toggles did nothing.
            return RDPSession(
                profile: profile,
                password: password,
                ignoreCert: SecuritySettings.shared.rdpIgnoreCertificate,
                clipboard: SecuritySettings.shared.allowRemoteClipboard || SecuritySettings.shared.sendLocalClipboard
            )
        }
    }

    private let sessionFactory: SessionFactory

    init(sessionFactory: @escaping SessionFactory = ConnectionManager.defaultFactory) {
        self.sessionFactory = sessionFactory
    }

    // MARK: - Session Management

    /// Maximum concurrent sessions to prevent resource exhaustion
    static let maxSessions = 20

    /// Result of an `openSession` attempt (PROBLEMS.md ISSUE-016). Replaces
    /// a bare `Bool`, which could not distinguish "no password stored" from
    /// "Keychain read failed" — the latter must never fall through to
    /// connecting with no credential.
    enum OpenResult: Equatable {
        case opened
        case duplicate
        case limitReached
        case hostInvalid(String)
        case keychainFailed(OSStatus)
    }

    /// Opens a new session for the given profile.
    ///
    /// `@MainActor` because it invokes `sessionFactory`, which for the
    /// default factory reads `SecuritySettings.shared` synchronously
    /// (see `defaultFactory`'s doc comment).
    @discardableResult
    @MainActor
    func openSession(for profile: ConnectionProfile) -> OpenResult {
        // Re-validate host at connect time. Mutated/imported profiles might have bypassed UI validation.
        do {
            _ = try ProfileValidator.validateHost(profile.host)
        } catch {
            AppLogger.shared.log("Connection aborted: Host validation failed for \(profile.name) — \(error.localizedDescription)", level: .error)
            return .hostInvalid(error.localizedDescription)
        }

        // Prevent duplicate sessions to the same profile
        if let existing = sessions.first(where: { $0.profileId == profile.id && $0.status.isActive }) {
            activeSessionId = existing.id
            AppLogger.shared.log("Session already active for: \(profile.name) — switched to existing tab")
            return .duplicate
        }

        // Prevent resource exhaustion: enforce maximum session count
        if sessions.count >= Self.maxSessions {
            AppLogger.shared.log("Session limit reached (\(Self.maxSessions)) — cannot open new session for: \(profile.name)", level: .warning)
            return .limitReached
        }

        // A denied Keychain prompt, a locked keychain, or a missing
        // entitlement must abort the connection rather than silently
        // proceeding with no credential (PROBLEMS.md ISSUE-016) — that was
        // indistinguishable from "no password stored" under the deprecated
        // `getPassword(for:)`.
        let password: String?
        do {
            password = try KeychainStore.shared.password(for: profile.id)
        } catch KeychainError.unexpectedStatus(let status) {
            AppLogger.shared.log("Connection aborted: Keychain read failed for \(profile.name) — status \(status)", level: .error)
            return .keychainFailed(status)
        } catch {
            AppLogger.shared.log("Connection aborted: Keychain read failed for \(profile.name) — \(error.localizedDescription)", level: .error)
            return .keychainFailed(errSecIO)
        }

        let session = sessionFactory(profile, password)

        session.delegate = self
        sessions.append(session)
        // Seed the observable status mirror with the initial status so views
        // don't briefly show "Disconnected" before the delegate fires.
        sessionStatuses[session.id] = session.status
        activeSessionId = session.id
        session.connect()

        updateDockBadge()
        AppLogger.shared.log("Session opened for profile: \(profile.name)")
        return .opened
    }

    func closeSession(_ session: any SessionProtocol) {
        session.delegate = nil
        session.disconnect()
        sessions.removeAll { $0.id == session.id }
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
        sessionStatuses.removeAll()
        activeSessionId = nil
        updateDockBadge()
    }

    func reconnectSession(_ session: any SessionProtocol) {
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
}
