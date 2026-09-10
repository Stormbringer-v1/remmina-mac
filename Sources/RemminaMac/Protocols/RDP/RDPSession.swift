import Foundation
import AppKit

/// RDP session that runs a local `xfreerdp` (FreeRDP) on a pseudo-terminal, or
/// hands off to the Microsoft Remote Desktop URL scheme when xfreerdp is absent.
///
/// Security: the password is never a CLI argument (invisible in `ps aux`). Like
/// the SSH session, xfreerdp is given the PTY slave as its controlling terminal
/// (see `PTYProcess`) so its `Password:` prompt appears on the terminal; we
/// detect the prompt — via the same `PasswordPromptDetector` SSH uses, gated on
/// `pty.echoEnabled() == false` — and write the password to the PTY in-memory,
/// once (ISSUE-005).
///
/// Status handling: the session is promoted to `.connected` either when the
/// password prompt is answered or, after a short grace window, if the process is
/// still running. It is NOT marked connected merely because the process started
/// — that masked authentication failures.
///
/// Note: this path depends on a locally installed FreeRDP and has not been
/// verified end-to-end against a live RDP host in this workspace.
final class RDPSession: SessionProtocol {
    let id = UUID()
    let profileId: UUID
    let profileName: String
    let protocolType: ProtocolType = .rdp
    weak var delegate: SessionDelegate?

    private(set) var status: SessionStatus = .disconnected {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.sessionDidChangeStatus(self, status: self.status)
            }
        }
    }

    private let host: String
    private let port: Int
    private let username: String
    /// Held until written to the PTY in response to xfreerdp's password prompt,
    /// then nilled. Not `private` so tests can drive `handlePossiblePasswordPrompt`
    /// directly (ISSUE-005).
    var password: String?
    private let domain: String

    // ISSUE-032: read once at construction (main-thread-only `SecuritySettings`
    // is @MainActor-isolated) instead of via the main-actor isolation-assertion
    // helper previously used inside `connect()`, which traps if `connect()` is
    // ever called off main. See the note on `init` below — the caller
    // (`ConnectionManager.defaultFactory`) does not currently pass these through.
    private let ignoreCert: Bool
    private let clipboard: Bool

    /// Not `private` so tests can relaunch/inspect it directly (ISSUE-009/010).
    var pty = PTYProcess()
    private var timeoutWorkItem: DispatchWorkItem?
    private var connectedWorkItem: DispatchWorkItem?

    /// Password prompt detector shared with `SSHSession` (ISSUE-005). Not
    /// `private` so tests can drive `handlePossiblePasswordPrompt` directly.
    var detector = PasswordPromptDetector()
    /// True once the password has been written, or once we've decided no prompt
    /// will be answered. Touched only on the read queue. Not `private` — see
    /// `detector`.
    var passwordHandled = false

    /// Injectable xfreerdp lookup (ISSUE-006) so tests can force "not found"
    /// without touching the filesystem or spawning a process.
    var xfreerdpLocator: () -> String? = RDPSession.defaultLocator

    /// Injectable check for whether some app can handle the `rdp://` URL
    /// scheme (Microsoft Remote Desktop, typically). Separated out so a test
    /// can force the "no RDP client at all" path deterministically regardless
    /// of what happens to be installed on the machine running the test
    /// (ISSUE-006).
    var msrdAvailable: (URL) -> Bool = { url in
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    var onOutputReceived: ((String) -> Void)?

    private static let connectionTimeoutSeconds: Double = 15
    private static let postSpawnGraceSeconds: Double = 1.5
    /// Bound on the `/usr/bin/which` fallback so a hung or missing shell
    /// environment can't block the setup screen indefinitely (ISSUE-006).
    private static let whichTimeoutSeconds: Double = 1.0

    /// - Parameters:
    ///   - ignoreCert: mirrors `SecuritySettings.shared.rdpIgnoreCertificate`.
    ///     Defaults to `false` (safe default: certificate verification stays
    ///     on) because this session no longer reads `SecuritySettings` itself
    ///     (ISSUE-032). **Follow-up required**: `ConnectionManager.defaultFactory`
    ///     needs to read `SecuritySettings.shared` on the main thread and pass
    ///     the live value in; until then RDP sessions always verify certs and
    ///     never enable clipboard sharing regardless of the user's setting.
    ///   - clipboard: mirrors `SecuritySettings.shared.allowRemoteClipboard ||
    ///     SecuritySettings.shared.sendLocalClipboard`. Same follow-up applies.
    init(profile: ConnectionProfile, password: String? = nil, ignoreCert: Bool = false, clipboard: Bool = false) {
        self.profileId = profile.id
        self.profileName = profile.name
        self.host = profile.host
        self.port = profile.port
        self.username = profile.username
        self.password = password
        self.domain = profile.domain
        self.ignoreCert = ignoreCert
        self.clipboard = clipboard
    }

    deinit {
        cleanupAllResources()
    }

    func connect() {
        guard !status.isActive else { return }
        status = .connecting
        AppLogger.shared.log("RDP: Connecting to \(host):\(port)")
        startConnectionTimeout()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.startRDPConnection()
        }
    }

    func disconnect() {
        cleanupAllResources()
        if status != .disconnected {
            status = .disconnected
            AppLogger.shared.log("RDP: Disconnected from \(host)")
        }
    }

    func reconnect() {
        disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.connect()
        }
    }

    func sendInput(_ data: Data) {
        pty.write(data)
    }

    // MARK: - Sleep/wake health probe (ISSUE-027c, additive only)

    /// Read-only liveness signal for `ConnectionManager.probeSessionHealth()`.
    /// True while the child xfreerdp process still exists (`kill(pid, 0)`
    /// succeeds); false when it was never launched, handed off to Microsoft
    /// Remote Desktop, or has been terminated. This only proves the process
    /// is alive, not that the TCP connection survived sleep — a live-but-
    /// broken connection is still caught by the PTY EOF/exit handlers.
    var isProcessAlive: Bool {
        let childPid = pty.pid
        guard childPid > 0 else { return false }
        return kill(childPid, 0) == 0
    }

    /// Marks a `.connected` session whose child died across sleep as lost.
    /// Tears down the PTY, then surfaces `.error` (instead of a silent
    /// `.disconnected`) so the tab shows what happened. No-op unless the
    /// session is `.connected`. Safe from any thread: `status`'s `didSet`
    /// already bounces the delegate callback to the main queue.
    func markConnectionLost() {
        guard status == .connected else { return }
        cleanupAllResources()
        status = .error("Connection lost during sleep")
    }

    // MARK: - Timers

    private func startConnectionTimeout() {
        timeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.status == .connecting {
                    self.status = .error("Connection timed out after \(Int(RDPSession.connectionTimeoutSeconds))s — check host and network")
                    AppLogger.shared.log("RDP: Connection timeout for \(self.host)", level: .error)
                    self.cleanupAllResources()
                }
            }
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + RDPSession.connectionTimeoutSeconds, execute: work)
    }

    private func cancelConnectionTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    /// Promote to `.connected` if still connecting after the grace window. This
    /// is what lets a key-based or otherwise prompt-less xfreerdp session be
    /// reported as connected instead of being killed by the 15s timeout.
    private func schedulePostSpawnGrace() {
        connectedWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.status == .connecting else { return }
                self.cancelConnectionTimeout()
                self.status = .connected
                AppLogger.shared.log("RDP: xfreerdp running for \(self.host)")
            }
        }
        connectedWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + RDPSession.postSpawnGraceSeconds, execute: work)
    }

    // MARK: - Cleanup

    /// Cancels timers and terminates the child, and closes the PTY (ISSUE-009 / ISSUE-010).
    private func cleanupAllResources() {
        cancelConnectionTimeout()
        connectedWorkItem?.cancel()
        connectedWorkItem = nil
        pty.terminate()
        pty.closeMaster()
    }

    // MARK: - Connection strategy

    /// Pure argv builder for xfreerdp (PROBLEMS.md ISSUE-004, ISSUE-019).
    static func buildArguments(
        host: String,
        port: Int,
        username: String = "",
        domain: String = "",
        size: (width: Int, height: Int) = (1280, 800),
        ignoreCert: Bool = false,
        clipboard: Bool = false
    ) -> [String] {
        var args: [String] = ["/v:\(host):\(port)"]
        if !username.isEmpty { args.append("/u:\(username)") }
        if !domain.isEmpty { args.append("/d:\(domain)") }
        args.append("/size:\(size.width)x\(size.height)")
        args.append("/bpp:32")
        args.append(clipboard ? "+clipboard" : "-clipboard")
        args.append(ignoreCert ? "/cert:ignore" : "/cert:tofu")
        args.append("/log-level:WARN")
        return args
    }

    private func startRDPConnection() {
        if let xfreerdpPath = xfreerdpLocator() {
            startXFreerdp(path: xfreerdpPath)
            return
        }
        if tryMicrosoftRemoteDesktop() {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.cancelConnectionTimeout()
            self?.status = .error("No RDP client found — install FreeRDP: brew install freerdp")
            AppLogger.shared.log("RDP: No RDP client available", level: .error)
        }
    }

    /// Default xfreerdp lookup: well-known Homebrew paths, then `/usr/bin/which`
    /// bounded by `whichTimeoutSeconds` (ISSUE-006). Static/injectable so tests
    /// can substitute a locator that returns nil immediately.
    static func defaultLocator() -> String? {
        // FreeRDP 3 ships several clients. On macOS the SDL client draws
        // natively; the X11 client (`xfreerdp`) needs XQuartz AND a $DISPLAY,
        // and without one it dies with SIGFPE after logging
        // "xf_setup_x11: failed to open display" — surfacing to the user as
        // "xfreerdp exited with code 136 before authenticating", which points
        // at credentials when the real cause is a missing display. So prefer
        // the SDL clients, and only consider the X11 clients when $DISPLAY is
        // actually set.
        let nativePaths = [
            "/opt/homebrew/bin/sdl-freerdp3",
            "/opt/homebrew/bin/sdl-freerdp",
            "/usr/local/bin/sdl-freerdp3",
            "/usr/local/bin/sdl-freerdp",
        ]
        let x11Paths = [
            "/opt/homebrew/bin/xfreerdp3",
            "/opt/homebrew/bin/xfreerdp",
            "/usr/local/bin/xfreerdp3",
            "/usr/local/bin/xfreerdp",
        ]

        for path in nativePaths where FileManager.default.isExecutableFile(atPath: path) {
            AppLogger.shared.log("RDP: Using native FreeRDP client at \(path)")
            return path
        }

        let hasDisplay = !(ProcessInfo.processInfo.environment["DISPLAY"] ?? "").isEmpty
        if hasDisplay {
            for path in x11Paths where FileManager.default.isExecutableFile(atPath: path) {
                AppLogger.shared.log("RDP: Using X11 FreeRDP client at \(path) (DISPLAY is set)")
                return path
            }
        } else {
            let x11Present = x11Paths.contains { FileManager.default.isExecutableFile(atPath: $0) }
            if x11Present {
                AppLogger.shared.log(
                    "RDP: Only the X11 FreeRDP client is installed and $DISPLAY is unset. "
                    + "Install the native client (brew install freerdp provides sdl-freerdp) "
                    + "or start XQuartz.",
                    level: .warning)
            }
        }

        let whichProc = Process()
        whichProc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProc.arguments = ["sdl-freerdp"]
        let pipe = Pipe()
        whichProc.standardOutput = pipe
        whichProc.standardError = FileHandle.nullDevice

        let sem = DispatchSemaphore(value: 0)
        whichProc.terminationHandler = { _ in sem.signal() }

        do {
            try whichProc.run()
        } catch {
            return nil
        }

        if sem.wait(timeout: .now() + whichTimeoutSeconds) == .timedOut {
            whichProc.terminate()
            AppLogger.shared.log("RDP: /usr/bin/which timed out looking for xfreerdp", level: .warning)
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func startXFreerdp(path: String) {
        if ignoreCert {
            AppLogger.shared.log("RDP: Launching with certificate verification disabled (/cert:ignore)", level: .warning)
        }

        let args = Self.buildArguments(
            host: host,
            port: port,
            username: username,
            domain: domain,
            size: (1280, 800),
            ignoreCert: ignoreCert,
            clipboard: clipboard
        )

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"

        AppLogger.shared.log("RDP: Starting xfreerdp for \(host):\(port)")

        // Ensure the previous pty (if any, e.g. from a prior reconnect attempt)
        // is cleanly terminated/closed, then create a fresh instance (ISSUE-010).
        pty.terminate()
        pty.closeMaster()
        let newPty = PTYProcess()
        pty = newPty

        do {
            // Capture `newPty` (not `self.pty`) so a stale exit callback from a
            // superseded run acts on the object it belongs to, never on
            // whatever `self.pty` happens to point to by the time it fires.
            // The read source is armed inside launch so a fast-exiting child
            // cannot exit before the reader exists (ISSUE-033).
            let readQueue = DispatchQueue.global(qos: .userInteractive)
            let handlers = makeReadHandlers(on: readQueue)
            try newPty.launch(path: path, args: args, env: env, onExit: { [weak self] code in
                self?.handleProcessExit(code, for: newPty)
            }, readQueue: readQueue, onData: handlers.onData, onEOF: handlers.onEOF)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.cancelConnectionTimeout()
                self?.status = .error("Failed to start xfreerdp — \(error.localizedDescription)")
                AppLogger.shared.log("RDP: Failed to start xfreerdp: \(error.localizedDescription)", level: .error)
            }
            return
        }

        schedulePostSpawnGrace()
    }

    /// Invoked on the main queue when xfreerdp exits (already reaped).
    /// `exitedPty` is the specific `PTYProcess` this exit belongs to — a late
    /// callback from a superseded run must not act on the current `self.pty`
    /// (ISSUE-010). Not `private` so a test can simulate a stale/late callback
    /// directly.
    func handleProcessExit(_ exitCode: Int32, for exitedPty: PTYProcess) {
        guard exitedPty === pty else {
            exitedPty.closeMaster()
            return
        }
        cancelConnectionTimeout()
        connectedWorkItem?.cancel()
        if status != .disconnected {
            if exitCode != 0 && status == .connecting {
                status = .error("xfreerdp exited with code \(exitCode) before authenticating — verify credentials, host, and FreeRDP installation")
            } else if exitCode != 0 {
                status = .error("RDP session ended (exit code \(exitCode))")
            } else {
                status = .disconnected
            }
            AppLogger.shared.log("RDP: xfreerdp terminated (exit code: \(exitCode))")
        }
        exitedPty.closeMaster()
    }

    // MARK: - PTY reading + password-prompt detection

    /// Uses `PTYProcess.startReading`, which closes the fd in its own cancel
    /// handler and cancels inline on EOF, so this session never races
    /// `PTYProcess.closeMaster()` over a raw descriptor (ISSUE-009). Not
    /// `private` so a test can invoke it directly against a manually-launched
    /// `pty` without going through `xfreerdp`.
    func startReading() {
        let readQueue = DispatchQueue.global(qos: .userInteractive)
        let handlers = makeReadHandlers(on: readQueue)
        pty.startReading(queue: readQueue, onData: handlers.onData, onEOF: handlers.onEOF)
    }

    /// Shared onData/onEOF pair used both by `startReading()` (standalone,
    /// for tests) and by `startXFreerdp` (armed inside `launch` to close the
    /// launch-before-read race, ISSUE-033). No behavior difference between
    /// the two paths.
    private func makeReadHandlers(on readQueue: DispatchQueue) -> (onData: (Data) -> Void, onEOF: () -> Void) {
        let onData: (Data) -> Void = { [weak self] data in
            guard let self = self else { return }
            if let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self.onOutputReceived?(text)
                }
            }
            self.handlePossiblePasswordPrompt(in: data, on: readQueue)
        }
        let onEOF: () -> Void = { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.status == .connected {
                    self.status = .disconnected
                    AppLogger.shared.log("RDP: Connection lost to \(self.host)")
                    self.cleanupAllResources()
                }
            }
        }
        return (onData, onEOF)
    }

    /// Detects xfreerdp's password prompt using the same end-anchored
    /// `PasswordPromptDetector` SSH uses, and writes the stored password only
    /// when the detector matches AND `pty.echoEnabled() == false` (ISSUE-005).
    func handlePossiblePasswordPrompt(in chunk: Data, on queue: DispatchQueue) {
        guard !passwordHandled else { return }
        guard let pwd = password, !pwd.isEmpty else {
            passwordHandled = true
            return
        }

        detector.append(chunk)

        guard detector.matches() else { return }

        if pty.echoEnabled() == false {
            deliverPassword(pwd)
        } else {
            // Prompt matched but echo might still be switching; schedule a 100ms re-check.
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, !self.passwordHandled, let p = self.password else { return }
                if self.pty.echoEnabled() == false && self.detector.matches() {
                    self.deliverPassword(p)
                }
            }
        }
    }

    private func deliverPassword(_ pwd: String) {
        passwordHandled = true
        pty.write(Data((pwd + "\n").utf8))
        password = nil
        detector.reset()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.status == .connecting {
                self.cancelConnectionTimeout()
                self.status = .connected
                AppLogger.shared.log("RDP: xfreerdp authenticated for \(self.host)")
            }
        }
    }

    // MARK: - Microsoft Remote Desktop fallback

    private func tryMicrosoftRemoteDesktop() -> Bool {
        let msrdURL = "rdp://full%20address=s:\(host):\(port)"
        guard let url = URL(string: msrdURL) else { return false }

        if msrdAvailable(url) {
            // Handing off to the external app; we can no longer observe status,
            // so report `.disconnected` rather than a false `.connected`.
            DispatchQueue.main.async { [weak self] in
                self?.cancelConnectionTimeout()
                NSWorkspace.shared.open(url)
                self?.status = .disconnected
                AppLogger.shared.log("RDP: Handed off to Microsoft Remote Desktop (status no longer observable in-app)")
            }
            return true
        }
        return false
    }
}
