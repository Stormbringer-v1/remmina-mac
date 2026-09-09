import Foundation
import AppKit

/// RDP session that runs a local `xfreerdp` (FreeRDP) on a pseudo-terminal, or
/// hands off to the Microsoft Remote Desktop URL scheme when xfreerdp is absent.
///
/// Security: the password is never a CLI argument (invisible in `ps aux`). Like
/// the SSH session, xfreerdp is given the PTY slave as its controlling terminal
/// (see `PTYProcess`) so its `Password:` prompt appears on the terminal; we
/// detect the prompt and write the password to the PTY in-memory, once.
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
    /// then nilled.
    private var password: String?
    private let domain: String

    private let pty = PTYProcess()
    private var readSource: DispatchSourceRead?
    private var timeoutWorkItem: DispatchWorkItem?
    private var connectedWorkItem: DispatchWorkItem?
    private var passwordDelivered = false
    private var promptBuffer = Data()
    private static let maxPromptBufferBytes = 4096

    var onOutputReceived: ((String) -> Void)?

    private static let connectionTimeoutSeconds: Double = 15
    private static let postSpawnGraceSeconds: Double = 1.5

    init(profile: ConnectionProfile, password: String? = nil) {
        self.profileId = profile.id
        self.profileName = profile.name
        self.host = profile.host
        self.port = profile.port
        self.username = profile.username
        self.password = password
        self.domain = profile.domain
    }

    deinit {
        cleanupAllResources()
    }

    func connect() {
        guard !status.isActive else { return }
        status = .connecting
        AppLogger.shared.log("RDP: Connecting to \(host):\(port)")
        startConnectionTimeout()
        let (ignoreCert, clipboard): (Bool, Bool) = MainActor.assumeIsolated {
            let cert = SecuritySettings.shared.rdpIgnoreCertificate
            let clip = SecuritySettings.shared.allowRemoteClipboard || SecuritySettings.shared.sendLocalClipboard
            return (cert, clip)
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.startRDPConnection(ignoreCert: ignoreCert, clipboard: clipboard)
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

    private func cleanupAllResources() {
        cancelConnectionTimeout()
        connectedWorkItem?.cancel()
        connectedWorkItem = nil
        readSource?.cancel()
        readSource = nil
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

    private func startRDPConnection(ignoreCert: Bool, clipboard: Bool) {
        if let xfreerdpPath = findXFreerdp() {
            startXFreerdp(path: xfreerdpPath, ignoreCert: ignoreCert, clipboard: clipboard)
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

    private func findXFreerdp() -> String? {
        let paths = [
            "/opt/homebrew/bin/xfreerdp",
            "/opt/homebrew/bin/xfreerdp3",
            "/usr/local/bin/xfreerdp",
            "/usr/local/bin/xfreerdp3",
        ]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            AppLogger.shared.log("RDP: Found xfreerdp at \(path)")
            return path
        }

        let whichProc = Process()
        whichProc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProc.arguments = ["xfreerdp"]
        let pipe = Pipe()
        whichProc.standardOutput = pipe
        whichProc.standardError = FileHandle.nullDevice
        do {
            try whichProc.run()
            whichProc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {}
        return nil
    }

    private func startXFreerdp(path: String, ignoreCert: Bool, clipboard: Bool) {
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

        do {
            try pty.launch(path: path, args: args, env: env, onExit: { [weak self] code in
                self?.handleProcessExit(code)
            })
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.cancelConnectionTimeout()
                self?.status = .error("Failed to start xfreerdp — \(error.localizedDescription)")
                AppLogger.shared.log("RDP: Failed to start xfreerdp: \(error.localizedDescription)", level: .error)
            }
            return
        }

        startReading()
        schedulePostSpawnGrace()
    }

    /// Invoked on the main queue when xfreerdp exits (already reaped).
    private func handleProcessExit(_ exitCode: Int32) {
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
        readSource?.cancel()
        readSource = nil
        pty.closeMaster()
    }

    private func startReading() {
        let fd = pty.masterFD
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let fd = self.pty.masterFD
            guard fd >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.onOutputReceived?(text)
                    }
                }
                self.handlePossiblePasswordPrompt(in: data)
            } else if bytesRead <= 0 {
                DispatchQueue.main.async {
                    if self.status == .connected {
                        self.disconnect()
                    }
                }
            }
        }
        source.resume()
        readSource = source
    }

    /// Detects xfreerdp's password prompt and writes the stored password once.
    /// Runs only on the read source's queue.
    private func handlePossiblePasswordPrompt(in chunk: Data) {
        guard !passwordDelivered else { return }
        guard let pwd = password, !pwd.isEmpty else { return }

        promptBuffer.append(chunk)
        if promptBuffer.count > RDPSession.maxPromptBufferBytes {
            promptBuffer.removeFirst(promptBuffer.count - RDPSession.maxPromptBufferBytes)
        }

        guard let window = String(data: promptBuffer, encoding: .utf8) else { return }
        let lower = window.lowercased()
        if lower.contains("password:") || lower.contains("password for") {
            passwordDelivered = true
            _ = pty.write(Data((pwd + "\n").utf8))
            password = nil
            promptBuffer.removeAll(keepingCapacity: false)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if self.status == .connecting {
                    self.cancelConnectionTimeout()
                    self.status = .connected
                    AppLogger.shared.log("RDP: xfreerdp authenticated for \(self.host)")
                }
            }
        }
    }

    // MARK: - Microsoft Remote Desktop fallback

    private func tryMicrosoftRemoteDesktop() -> Bool {
        let msrdURL = "rdp://full%20address=s:\(host):\(port)"
        guard let url = URL(string: msrdURL) else { return false }

        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
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
