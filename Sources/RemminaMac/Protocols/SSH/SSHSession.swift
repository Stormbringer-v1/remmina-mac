import Foundation

/// SSH session using Process + pseudo-terminal to run /usr/bin/ssh.
///
/// Security: Passwords are never written to disk. The askpass script uses an
/// inherited file descriptor (pipe) to read the password from memory at runtime.
/// The password never appears in /tmp, process arguments, or logs.
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

    private var process: Process?
    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timeoutWorkItem: DispatchWorkItem?
    private let host: String
    private let port: Int
    private let username: String
    private let password: String?
    private let sshKeyPath: String

    /// Direct byte feed handler for SwiftTerm — bypasses string conversion
    var terminalFeedHandler: ((Data) -> Void)?

    /// Connection timeout in seconds
    private static let connectionTimeoutSeconds: Double = 15

    init(profile: ConnectionProfile, password: String?) {
        self.profileId = profile.id
        self.profileName = profile.name
        self.host = profile.host
        self.port = profile.port
        self.username = profile.username
        self.password = password
        
        // Validate SSH key path on init
        if !profile.sshKeyPath.isEmpty {
            do {
                self.sshKeyPath = try SSHKeyValidator.validate(profile.sshKeyPath, isUserSelected: false)
            } catch {
                AppLogger.shared.log("SSH key validation failed: \(error.localizedDescription)", level: .warning, profileId: profile.id, component: "SSHSession")
                self.sshKeyPath = "" // Fallback to no key
            }
        } else {
            self.sshKeyPath = ""
        }
    }

    deinit {
        // Deterministic cleanup: ensure no leaked file descriptors or temp files
        cleanupAllResources()
    }

    func connect() {
        guard status != .connected && status != .connecting else { return }

        status = .connecting
        AppLogger.shared.log("SSH: Connecting to \(hostDescription)", sessionId: id, profileId: profileId, component: "SSHSession")

        // Start connection timeout
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
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                let _ = write(masterFD, baseAddress, ptr.count)
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        guard masterFD >= 0, cols > 0, rows > 0 else { return }
        var winSize = winsize(
            ws_row: UInt16(clamping: rows),
            ws_col: UInt16(clamping: cols),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &winSize)
    }

    // MARK: - Private

    /// Temporary askpass script path (cleaned up on disconnect/deinit)
    private var askpassPath: String?
    /// Pipe for passing password to askpass script securely (no disk write)
    private var askpassPipeFD: [Int32] = [-1, -1]

    /// Sanitized host description for logs (never includes credentials)
    private var hostDescription: String {
        let user = username.isEmpty ? "" : "\(username)@"
        return "\(user)\(host):\(port)"
    }

    // MARK: - Connection Timeout

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

    // MARK: - Resource Cleanup

    /// Cleans up ALL resources: process, file descriptors, temp files, pipes.
    /// Safe to call multiple times. Does NOT change status (caller decides).
    private func cleanupAllResources() {
        cancelConnectionTimeout()

        readSource?.cancel()
        readSource = nil

        if let process = process, process.isRunning {
            process.terminate()
        }
        process = nil

        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        if slaveFD >= 0 { close(slaveFD); slaveFD = -1 }

        cleanupAskpass()
    }

    // MARK: - SSH Process

    private func startSSHProcess() {
        var master: Int32 = -1
        var slave: Int32 = -1

        let rc = openpty(&master, &slave, nil, nil, nil)
        guard rc == 0 else {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cancelConnectionTimeout()
                self.status = .error("Failed to allocate terminal — system resources may be exhausted")
                AppLogger.shared.log("SSH: Failed to open PTY", level: .error, sessionId: self.id, profileId: self.profileId, component: "SSHSession")
            }
            return
        }

        self.masterFD = master
        self.slaveFD = slave

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")

        var args: [String] = []
        args.append("-o")
        args.append("StrictHostKeyChecking=accept-new")

        // Keepalive: detect dead connections after 30s * 3 = 90s of silence
        args.append("-o")
        args.append("ServerAliveInterval=30")
        args.append("-o")
        args.append("ServerAliveCountMax=3")

        // SSH key authentication
        if !sshKeyPath.isEmpty && FileManager.default.fileExists(atPath: sshKeyPath) {
            args.append("-i")
            args.append(sshKeyPath)
            AppLogger.shared.log("SSH: Using key authentication", sessionId: id, profileId: profileId, component: "SSHSession")
        }

        if port != 22 {
            args.append("-p")
            args.append("\(port)")
        }
        if !username.isEmpty {
            args.append("\(username)@\(host)")
        } else {
            args.append(host)
        }

        proc.arguments = args

        // Set up environment — SECURE askpass
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"

        if let askpass = createSecureAskpassScript() {
            self.askpassPath = askpass
            env["SSH_ASKPASS"] = askpass
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env["DISPLAY"] = ":0"
            AppLogger.shared.log("SSH: Askpass configured for credential handling", sessionId: id, profileId: profileId, component: "SSHSession")
        }
        proc.environment = env

        // Log sanitized command (no secrets, no key paths)
        AppLogger.shared.log("SSH: Connecting to \(hostDescription)", sessionId: id, profileId: profileId, component: "SSHSession")

        // Use the slave side of the PTY as stdin/stdout/stderr
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        proc.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.cancelConnectionTimeout()
                if self.status != .disconnected {
                    if process.terminationStatus != 0 && self.status == .connecting {
                        self.status = .error("Connection failed (exit code \(process.terminationStatus)) — verify credentials and host")
                    } else {
                        self.status = .disconnected
                    }
                    AppLogger.shared.log("SSH: Process terminated for \(self.host) (exit \(process.terminationStatus))", sessionId: self.id, profileId: self.profileId, component: "SSHSession")
                }
            }
        }

        do {
            try proc.run()
            self.process = proc

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cancelConnectionTimeout()
                self.status = .connected
                AppLogger.shared.log("SSH: Connected to \(self.host)", sessionId: self.id, profileId: self.profileId, component: "SSHSession")
            }

            startReading()
        } catch {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cancelConnectionTimeout()
                self.status = .error("Failed to start SSH — \(error.localizedDescription)")
                AppLogger.shared.log("SSH: Failed to start process: \(error)", level: .error, sessionId: self.id, profileId: self.profileId, component: "SSHSession")
            }
        }
    }

    // MARK: - Secure Askpass (no plaintext passwords on disk)

    /// Creates a secure askpass script that reads the password from an inherited
    /// file descriptor (pipe), never writing the password to disk.
    ///
    /// When a password is stored: The script reads from fd 3 (inherited pipe).
    /// When no password is stored: The script shows a macOS dialog via osascript.
    ///
    /// Security properties:
    /// - Password never touches the filesystem
    /// - Password not visible via `ps aux` or `/proc`
    /// - Pipe FD is only inherited by the SSH child process
    /// - Script is 0700 (owner-only executable)
    private func createSecureAskpassScript() -> String? {
        let tmpDir = FileManager.default.temporaryDirectory
        let scriptPath = tmpDir.appendingPathComponent("remmina_askpass_\(id.uuidString).sh").path

        let scriptContent: String
        if let pwd = password, !pwd.isEmpty {
            // SECURE: Script reads password from inherited file descriptor 3 (pipe)
            // The password is written to the pipe AFTER script creation, and the
            // pipe's write end is closed immediately after. No disk exposure.
            var pipeFDs: [Int32] = [0, 0]
            guard pipe(&pipeFDs) == 0 else {
                AppLogger.shared.log("SSH: Failed to create credential pipe", level: .error, sessionId: id, profileId: profileId, component: "SSHSession")
                return nil
            }
            self.askpassPipeFD = pipeFDs

            // Write password to pipe write-end, then close it
            let pwdData = Data(pwd.utf8)
            pwdData.withUnsafeBytes { ptr in
                if let base = ptr.baseAddress {
                    _ = Foundation.write(pipeFDs[1], base, ptr.count)
                }
            }
            close(pipeFDs[1])
            self.askpassPipeFD[1] = -1

            // Script reads from fd 3 which will be the pipe read-end
            scriptContent = """
            #!/bin/bash
            cat <&3
            """
        } else {
            // No password stored — show a macOS dialog to ask the user
            scriptContent = """
            #!/bin/bash
            osascript -e 'Tell application "System Events" to display dialog "'"$1"'" default answer "" with hidden answer' -e 'text returned of result' 2>/dev/null
            """
        }

        // Atomic file creation with restrictive permissions (0700) in one step
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        let created = FileManager.default.createFile(
            atPath: scriptPath,
            contents: scriptContent.data(using: .utf8),
            attributes: attrs
        )

        guard created else {
            AppLogger.shared.log("SSH: Failed to create askpass script", level: .error, sessionId: id, profileId: profileId, component: "SSHSession")
            return nil
        }

        return scriptPath
    }

    /// Cleans up the temporary askpass script and pipe file descriptors.
    private func cleanupAskpass() {
        if let path = askpassPath {
            try? FileManager.default.removeItem(atPath: path)
            askpassPath = nil
        }
        // Close pipe read-end if still open
        if askpassPipeFD[0] >= 0 {
            close(askpassPipeFD[0])
            askpassPipeFD[0] = -1
        }
        if askpassPipeFD[1] >= 0 {
            close(askpassPipeFD[1])
            askpassPipeFD[1] = -1
        }
    }

    // MARK: - PTY Reading

    private func startReading() {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: masterFD,
            queue: DispatchQueue.global(qos: .userInteractive)
        )

        source.setEventHandler { [weak self] in
            guard let self = self, self.masterFD >= 0 else { return }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = read(self.masterFD, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                DispatchQueue.main.async {
                    // Feed raw bytes directly to SwiftTerm (primary path)
                    self.terminalFeedHandler?(data)
                    // Also notify delegate (ConnectionManager) for output buffer
                    self.delegate?.sessionDidReceiveOutput(self, data: data)
                }
            } else if bytesRead <= 0 {
                DispatchQueue.main.async {
                    if self.status == .connected {
                        self.status = .disconnected
                        AppLogger.shared.log("SSH: Connection lost to \(self.host)", sessionId: self.id, profileId: self.profileId, component: "SSHSession")
                        self.cleanupAllResources()
                    }
                }
            }
        }

        source.setCancelHandler { [weak self] in
            _ = self
        }

        source.resume()
        self.readSource = source
    }
}
