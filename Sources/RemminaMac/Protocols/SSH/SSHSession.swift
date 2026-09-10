import Foundation

/// SSH session that runs `/usr/bin/ssh` on a pseudo-terminal.
///
/// Security: the stored password is never written to disk, never passed as a
/// process argument (so it never appears in `ps aux`), and no askpass helper is
/// used. Instead the child ssh is given the PTY slave as its **controlling
/// terminal** (see `PTYProcess`), so ssh prints its normal `Password:` prompt on
/// the terminal; we detect that prompt in the PTY output and write the password
/// to the PTY in-memory, exactly once. The password reference is dropped
/// immediately afterwards.
final class SSHSession: SessionProtocol {
    let id = UUID()
    let profileId: UUID
    let profileName: String
    let protocolType: ProtocolType = .ssh
    weak var delegate: SessionDelegate?

    private(set) var status: SessionStatus = .disconnected {
        didSet {
            delegate?.sessionDidChangeStatus(self, status: status)
        }
    }

    private var pty = PTYProcess()
    private var timeoutWorkItem: DispatchWorkItem?
    private var connectedWorkItem: DispatchWorkItem?

    private let host: String
    private let port: Int
    private let username: String
    /// Held until written to the PTY in response to ssh's password prompt, then
    /// nilled. Swift does not guarantee zeroing of String storage on release,
    /// but dropping the reference is the best the language allows.
    private var password: String?
    let effectiveKeyPath: String

    /// Direct byte feed handler for SwiftTerm — bypasses string conversion.
    var terminalFeedHandler: ((Data) -> Void)?

    /// Overall connection timeout in seconds.
    private static let connectionTimeoutSeconds: Double = 15
    /// Delay after spawn before we declare `.connected`, giving auth a chance to
    /// fail (and the exit handler to surface a real error) first.
    private static let postSpawnGraceSeconds: Double = 1.5

    /// Password prompt detector with end-anchored matching.
    private var detector = PasswordPromptDetector()
    /// True once the password has been written, or once we've decided no prompt
    /// will be answered. Touched only on the read queue.
    private var passwordHandled = false

    init(profile: ConnectionProfile, password: String?) {
        self.profileId = profile.id
        self.profileName = profile.name
        self.host = profile.host
        self.port = profile.port
        self.username = profile.username
        self.password = password

        if !profile.sshKeyPath.isEmpty {
            do {
                self.effectiveKeyPath = try SSHKeyValidator.validate(profile.sshKeyPath, isUserSelected: true)
            } catch {
                AppLogger.shared.log("SSH key validation failed: \(error.localizedDescription)", level: .warning, profileId: profile.id, component: "SSHSession")
                self.effectiveKeyPath = ""
            }
        } else {
            self.effectiveKeyPath = ""
        }
    }

    deinit {
        cleanupAllResources()
    }

    func connect() {
        guard status != .connected && status != .connecting else { return }
        status = .connecting
        AppLogger.shared.log("SSH: Connecting to \(hostDescription)", sessionId: id, profileId: profileId, component: "SSHSession")
        startConnectionTimeout()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.startSSHProcess()
        }
    }

    func disconnect() {
        AppLogger.shared.log("SSH: Disconnecting from \(host)", sessionId: id, profileId: profileId, component: "SSHSession")
        cleanupAllResources()
        DispatchQueue.main.async { [weak self] in
            self?.status = .disconnected
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

    func resize(cols: Int, rows: Int) {
        pty.resize(cols: cols, rows: rows)
    }

    // MARK: - Arguments Builder (ISSUE-001 & ISSUE-022)

    /// Pure function to build the command-line arguments for `/usr/bin/ssh`.
    static func buildArguments(
        host: String,
        port: Int,
        username: String,
        sshKeyPath: String
    ) -> [String] {
        var args: [String] = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "NumberOfPasswordPrompts=1",
        ]

        if !sshKeyPath.isEmpty && FileManager.default.fileExists(atPath: sshKeyPath) {
            args.append(contentsOf: ["-i", sshKeyPath])
        }

        if port != 22 {
            args.append(contentsOf: ["-p", "\(port)"])
        }

        // Option terminator before destination to prevent option injection (ISSUE-022)
        args.append("--")

        let destination = username.isEmpty ? host : "\(username)@\(host)"
        args.append(destination)

        return args
    }

    // MARK: - Private

    private var hostDescription: String {
        let user = username.isEmpty ? "" : "\(username)@"
        return "\(user)\(host):\(port)"
    }

    // MARK: - Timers

    private func startConnectionTimeout() {
        timeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.status == .connecting {
                    self.status = .error("Connection timed out after \(Int(SSHSession.connectionTimeoutSeconds))s — check host and network")
                    AppLogger.shared.log("SSH: Connection timeout for \(self.host)", level: .error, sessionId: self.id, profileId: self.profileId, component: "SSHSession")
                    self.cleanupAllResources()
                }
            }
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SSHSession.connectionTimeoutSeconds, execute: work)
    }

    private func cancelConnectionTimeout() {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
    }

    /// After a short grace window, if we're still `.connecting` promote to
    /// `.connected`. If the process exited first (auth failure, unreachable
    /// host) the exit handler will have set an error instead.
    private func schedulePostSpawnGrace() {
        connectedWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard self.status == .connecting else { return }
                self.cancelConnectionTimeout()
                self.status = .connected
                AppLogger.shared.log("SSH: Connected to \(self.host)", sessionId: self.id, profileId: self.profileId, component: "SSHSession")
            }
        }
        connectedWorkItem = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + SSHSession.postSpawnGraceSeconds, execute: work)
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

    // MARK: - Process launch

    private func startSSHProcess() {
        let path = "/usr/bin/ssh"

        // Ensure previous pty is cleanly terminated/closed and create a fresh instance (ISSUE-010)
        pty.terminate()
        pty.closeMaster()
        pty = PTYProcess()

        let args = Self.buildArguments(
            host: host,
            port: port,
            username: username,
            sshKeyPath: effectiveKeyPath
        )

        if !effectiveKeyPath.isEmpty && FileManager.default.fileExists(atPath: effectiveKeyPath) {
            AppLogger.shared.log("SSH: Using key authentication", sessionId: id, profileId: profileId, component: "SSHSession")
        }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env.removeValue(forKey: "SSH_ASKPASS")
        env.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        env.removeValue(forKey: "DISPLAY")

        AppLogger.shared.log("SSH: Connecting to \(hostDescription)", sessionId: id, profileId: profileId, component: "SSHSession")

        do {
            try pty.launch(path: path, args: args, env: env, onExit: { [weak self] code in
                self?.handleProcessExit(code)
            })
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cancelConnectionTimeout()
                self.status = .error("Failed to start SSH — \(error.localizedDescription)")
                AppLogger.shared.log("SSH: Failed to start process: \(error.localizedDescription)", level: .error, sessionId: self.id, profileId: self.profileId, component: "SSHSession")
            }
            return
        }

        startReading()
        schedulePostSpawnGrace()
    }

    /// Invoked on the main queue when the ssh process exits (already reaped).
    private func handleProcessExit(_ exitCode: Int32) {
        cancelConnectionTimeout()
        connectedWorkItem?.cancel()
        if status != .disconnected {
            if exitCode != 0 && status == .connecting {
                status = .error("SSH exited with code \(exitCode) before authenticating — verify credentials, host, and network")
            } else if exitCode != 0 {
                status = .error("SSH session ended (exit code \(exitCode))")
            } else {
                status = .disconnected
            }
            AppLogger.shared.log("SSH: Process terminated for \(host) (exit \(exitCode))", sessionId: id, profileId: profileId, component: "SSHSession")
        }
        pty.closeMaster()
    }

    // MARK: - PTY reading + password-prompt detection

    private func startReading() {
        let readQueue = DispatchQueue.global(qos: .userInteractive)
        pty.startReading(queue: readQueue, onData: { [weak self] data in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.terminalFeedHandler?(data)
            }
            self.handlePossiblePasswordPrompt(in: data, on: readQueue)
        }, onEOF: { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.status == .connected {
                    self.status = .disconnected
                    AppLogger.shared.log("SSH: Connection lost to \(self.host)", sessionId: self.id, profileId: self.profileId, component: "SSHSession")
                    self.cleanupAllResources()
                }
            }
        })
    }

    /// Detects ssh's password prompt and writes the stored password only when
    /// detector matches AND echoEnabled == false (ISSUE-005).
    private func handlePossiblePasswordPrompt(in chunk: Data, on queue: DispatchQueue) {
        guard !passwordHandled else { return }
        guard let pwd = password, !pwd.isEmpty else {
            passwordHandled = true
            return
        }

        detector.append(chunk)

        guard detector.matches() else { return }

        // Check echo status
        if pty.echoEnabled() == false {
            deliverPassword(pwd)
        } else {
            // Prompt matched but echo might still be switching; schedule a 100ms re-check (ISSUE-005)
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
        self.password = nil
        detector.reset()
    }
}
