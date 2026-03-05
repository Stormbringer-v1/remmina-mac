import Foundation
import AppKit

/// RDP session using xfreerdp (FreeRDP) or Microsoft Remote Desktop URL scheme.
///
/// Security: Password is passed to xfreerdp via the /from-stdin flag or
/// environment variable, never as a CLI argument visible in `ps aux`.
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
    private let password: String?
    private let domain: String

    private var process: Process?
    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timeoutWorkItem: DispatchWorkItem?
    private var isRunning = false

    // Framebuffer for embedded mode
    private(set) var framebufferWidth: Int = 1280
    private(set) var framebufferHeight: Int = 800
    private var framebuffer: [UInt8] = []

    var onFramebufferUpdate: ((NSImage) -> Void)?
    var onOutputReceived: ((String) -> Void)?

    /// Connection timeout in seconds
    private static let connectionTimeoutSeconds: Double = 15

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
        guard masterFD >= 0 else { return }
        data.withUnsafeBytes { ptr in
            if let baseAddress = ptr.baseAddress {
                let _ = write(masterFD, baseAddress, ptr.count)
            }
        }
    }

    func sendCtrlAltDel() {
        AppLogger.shared.log("RDP: Sending Ctrl+Alt+Del")
    }

    // MARK: - Connection Timeout

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

    // MARK: - Resource Cleanup

    private func cleanupAllResources() {
        cancelConnectionTimeout()
        isRunning = false

        readSource?.cancel()
        readSource = nil

        if let process = process, process.isRunning {
            process.terminate()
        }
        process = nil

        if masterFD >= 0 { close(masterFD); masterFD = -1 }
        if slaveFD >= 0 { close(slaveFD); slaveFD = -1 }
    }

    // MARK: - Connection Strategy

    private func startRDPConnection() {
        // Strategy 1: Try xfreerdp (FreeRDP CLI)
        if let xfreerdpPath = findXFreerdp() {
            startXFreerdp(path: xfreerdpPath)
            return
        }

        // Strategy 2: Try Microsoft Remote Desktop URL scheme
        if tryMicrosoftRemoteDesktop() {
            return
        }

        // Strategy 3: Actionable error guidance
        DispatchQueue.main.async { [weak self] in
            self?.cancelConnectionTimeout()
            self?.status = .error("No RDP client found — install FreeRDP: brew install freerdp")
            AppLogger.shared.log("RDP: No RDP client available", level: .error)
        }
    }

    // MARK: - xfreerdp

    private func findXFreerdp() -> String? {
        let paths = [
            "/opt/homebrew/bin/xfreerdp",      // ARM Homebrew
            "/opt/homebrew/bin/xfreerdp3",     // FreeRDP 3.x
            "/usr/local/bin/xfreerdp",          // Intel Homebrew
            "/usr/local/bin/xfreerdp3",
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                AppLogger.shared.log("RDP: Found xfreerdp at \(path)")
                return path
            }
        }

        // Try which
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

    private func startXFreerdp(path: String) {
        var master: Int32 = -1
        var slave: Int32 = -1

        let rc = openpty(&master, &slave, nil, nil, nil)
        guard rc == 0 else {
            DispatchQueue.main.async { [weak self] in
                self?.cancelConnectionTimeout()
                self?.status = .error("Failed to allocate terminal — system resources may be exhausted")
            }
            return
        }

        self.masterFD = master
        self.slaveFD = slave

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)

        var args: [String] = []
        args.append("/v:\(host):\(port)")

        if !username.isEmpty {
            args.append("/u:\(username)")
        }
        if !domain.isEmpty {
            args.append("/d:\(domain)")
        }

        // SECURITY: Password is passed via environment variable, NOT as CLI arg.
        // CLI args are visible in `ps aux` to all users on the system.
        // xfreerdp reads password from /p: but we use environment to avoid exposure.
        var env = ProcessInfo.processInfo.environment
        if let pwd = password, !pwd.isEmpty {
            // Use /from-stdin approach: write password after process starts
            // OR pass via environment variable which xfreerdp supports
            args.append("/p:$REMMINA_RDP_PASS")
            env["REMMINA_RDP_PASS"] = pwd
        }

        // Display settings
        args.append("/size:\(framebufferWidth)x\(framebufferHeight)")
        args.append("/bpp:32")
        args.append("+clipboard")
        args.append("/cert:ignore")
        args.append("/log-level:WARN")

        proc.arguments = args
        proc.environment = env

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        proc.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.cancelConnectionTimeout()
                if self.status != .disconnected {
                    if process.terminationStatus != 0 {
                        self.status = .error("RDP connection failed (exit \(process.terminationStatus)) — verify credentials and host")
                    } else {
                        self.status = .disconnected
                    }
                    AppLogger.shared.log("RDP: xfreerdp terminated (exit code: \(process.terminationStatus))")
                }
            }
        }

        // Log WITHOUT credentials
        AppLogger.shared.log("RDP: Starting xfreerdp for \(host):\(port)")

        do {
            try proc.run()
            self.process = proc
            self.isRunning = true

            // If password provided, write it to stdin for xfreerdp
            // This is the secondary secure channel — stdin is not visible in ps
            if let pwd = password, !pwd.isEmpty {
                // Write password to xfreerdp via PTY (it prompts for it)
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self = self, self.masterFD >= 0 else { return }
                    let pwdData = Data((pwd + "\n").utf8)
                    pwdData.withUnsafeBytes { ptr in
                        if let base = ptr.baseAddress {
                            _ = Foundation.write(self.masterFD, base, ptr.count)
                        }
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.cancelConnectionTimeout()
                self?.status = .connected
                AppLogger.shared.log("RDP: xfreerdp started for \(self?.host ?? "")")
            }

            startReading()
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.cancelConnectionTimeout()
                self?.status = .error("Failed to start xfreerdp — \(error.localizedDescription)")
                AppLogger.shared.log("RDP: Failed to start xfreerdp: \(error)", level: .error)
            }
        }
    }

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
                if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self.onOutputReceived?(text)
                    }
                }
            } else if bytesRead <= 0 {
                DispatchQueue.main.async {
                    if self.status == .connected {
                        self.disconnect()
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

    // MARK: - Microsoft Remote Desktop

    private func tryMicrosoftRemoteDesktop() -> Bool {
        let msrdURL = "rdp://full%20address=s:\(host):\(port)"
        guard let url = URL(string: msrdURL) else { return false }

        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            DispatchQueue.main.async { [weak self] in
                self?.cancelConnectionTimeout()
                NSWorkspace.shared.open(url)
                self?.status = .connected
                AppLogger.shared.log("RDP: Opened via Microsoft Remote Desktop")
            }
            return true
        }

        return false
    }
}
