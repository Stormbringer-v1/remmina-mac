import Foundation
import AppKit
import os
import CommonCrypto

/// Native RFB (Remote Framebuffer) protocol client for VNC connections.
/// Implements RFB 3.8 protocol with Raw and CopyRect encodings.
///
/// Threading model (PROBLEMS.md ISSUE-014):
///   - The read+message loop runs on a dedicated thread (`readThread`).
///   - Client-to-server writes (mouse, keyboard, clipboard, framebuffer
///     requests) are dispatched to a serial `writeQueue` so they never
///     interleave with each other.
///   - During the handshake, `isRunning` is false and the read thread
///     writes directly. After `isRunning` becomes true, `writeData` is
///     gated to `writeQueue` via `dispatchPrecondition`, so the read
///     thread's post-handshake `sendFramebufferUpdateRequest` is routed
///     through `writeQueue` too.
final class VNCSession: SessionProtocol {
    let id = UUID()
    let profileId: UUID
    let profileName: String
    let protocolType: ProtocolType = .vnc
    weak var delegate: SessionDelegate?

    private(set) var status: SessionStatus = .disconnected {
        didSet {
            // Bounce to the main thread for the delegate so the view layer
            // and dock badge updates stay on a single thread. `fail(_:)`
            // uses a `DispatchQueue.main.async` block too, so this branch
            // never races with the explicit main-thread status assignment.
            if Thread.isMainThread {
                delegate?.sessionDidChangeStatus(self, status: status)
            } else {
                let s = status
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.sessionDidChangeStatus(self, status: s)
                }
            }
        }
    }

    // MARK: - Connection state

    private let host: String
    private let port: Int
    /// Held only until the VNC DES auth challenge is answered in
    /// `performVNCAuth()`. The read thread also `defer { password = nil }`s
    /// it at the top of `performConnection` so any failure path drops it.
    private var password: String?

    /// Native socket backing the connection. We use raw BSD sockets
    /// rather than CFStream because CFStream requires a run loop to
    /// dispatch its read/write events, and driving that from a
    /// background thread is fragile. POSIX sockets + Darwin.read/write
    /// are synchronous and don't have that problem.
    private var socketFD: Int32 = -1

    /// Serial queue for post-handshake client-to-server writes. Pre-handshake
    /// writes (version banner, security type choice, pixel format, encodings)
    /// are emitted directly from the read thread.
    private var writeQueue = DispatchQueue(label: "com.remmina-mac.vnc.write", qos: .userInitiated)
    /// Dedicated thread for the read + message loop.
    private var readThread: Thread?
    /// Lock-protected `isRunning` (PROBLEMS.md ISSUE-012). Replaces the
    /// previous unsynchronized `var isRunning = false`.
    private let runningLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let cancelledLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var timeoutWorkItem: DispatchWorkItem?

    /// Connection timeout in seconds (covers DNS resolution + connect()
    /// across all candidates). An instance property, like
    /// `readTimeoutSeconds` below, so tests can inject a short deadline
    /// instead of waiting out the real 15s (PROBLEMS.md ISSUE-028).
    var connectionTimeoutSeconds: Double = 15
    /// Read deadline in seconds (PROBLEMS.md ISSUE-012 / ISSUE-029). After
    /// this, a stuck read returns and we surface a `.streamClosed` error
    /// rather than spinning forever. An instance property (not a static
    /// constant) so tests can inject a short deadline instead of waiting
    /// out the real 30s.
    var readTimeoutSeconds: Int = 30
    /// Reason the most recent `attemptConnect` candidate failed. Read
    /// immediately after the call on the same (read) thread — never
    /// shared across threads.
    private var lastConnectError: String?

    // MARK: - RFB protocol bounds (PROBLEMS.md P0-4)
    // Every value the server sends us is capped to a sane maximum to
    // prevent a hostile server from forcing multi-GB allocations or
    // out-of-range writes into the framebuffer. Exceeding any bound is
    // treated as a protocol error and the connection is dropped.

    private static let maxFramebufferDimension: Int = 8192
    private static let maxRectDimension: Int = 8192
    private static let maxRectanglesPerUpdate: Int = 4096
    private static let maxServerNameLength: Int = 1024
    private static let maxCutTextLength: Int = 1 << 20  // 1 MB
    private static let maxColormapEntries: Int = 256

    // MARK: - Framebuffer

    /// Public, view-facing copies of the framebuffer dimensions and
    /// server name. PROBLEMS.md ISSUE-012 (thread sanitizer): these are
    /// read from the main thread by `VNCSessionView`'s `fbInfo` closure
    /// and by `VNCDesktopView.translatePoint` on every mouse event, with
    /// no synchronization back to the read thread. Rather than share the
    /// read-thread's working copies (`rfbWidth`/`rfbHeight`/
    /// `rfbServerName` below) across threads, we publish these once —
    /// on the main thread, in the same `DispatchQueue.main.async` block
    /// that sets `.connected` — so every subsequent read of these three
    /// properties happens on the same thread (main) that wrote them.
    private(set) var framebufferWidth: Int = 0
    private(set) var framebufferHeight: Int = 0
    private(set) var serverName: String = ""
    /// Read-thread-only working copies of the same values, used by the
    /// handshake, message loop, and framebuffer rendering. Never touched
    /// from any other thread — see the doc comment above.
    private var rfbWidth: Int = 0
    private var rfbHeight: Int = 0
    private var rfbServerName: String = ""
    private var framebuffer: [UInt8] = []
    private let bytesPerPixel = 4  // BGRA32
    /// Union of the rectangles handled since the last `onFramebufferUpdate`
    /// was emitted. Used to drive partial canvas redraws (PROBLEMS.md
    /// ISSUE-024). The framebuffer is still copied in full on each render,
    /// but the canvas only asks AppKit to repaint the dirty region.
    private var dirtyRect: NSRect = .null

    /// Callback for framebuffer updates. The second parameter is the
    /// union rectangle that changed since the last call (in framebuffer
    /// pixel coordinates); pass it to `NSView.setNeedsDisplay(_:)`.
    var onFramebufferUpdate: ((NSImage, NSRect) -> Void)?

    init(profile: ConnectionProfile, password: String?) {
        self.profileId = profile.id
        self.profileName = profile.name
        self.host = profile.host
        self.port = profile.port
        self.password = password
    }

    deinit {
        // Detached teardown — `deinit` may run on any thread, so we just
        // set the running flag and shutdown the socket. The read thread
        // observes the flag and exits, closing the streams itself.
        runningLock.withLock { $0 = false }
        let fd = socketFD
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
    }

    // MARK: - SessionProtocol

    func connect() {
        guard !status.isActive else { return }
        status = .connecting
        runningLock.withLock { $0 = false }
        cancelledLock.withLock { $0 = false }
        AppLogger.shared.log("VNC: Connecting to \(host):\(port)")

        startConnectionTimeout()

        let thread = Thread { [weak self] in
            self?.performConnection()
        }
        thread.name = "com.remmina-mac.vnc.read"
        thread.start()
        readThread = thread
    }

    /// User-initiated disconnect: tears down streams and moves to
    /// `.disconnected`. Does NOT clobber a `.error` state — the timeout
    /// path and `fail(_:)` rely on this.
    func disconnect() {
        tearDownStreams()
        // Set status on the main thread. We don't overwrite `.error`,
        // because the error already represents what the user needs to
        // see.
        let setDisconnected = { [weak self] in
            guard let self = self else { return }
            if case .error = self.status { return }
            if self.status != .disconnected {
                self.status = .disconnected
                AppLogger.shared.log("VNC: Disconnected from \(self.host)")
            }
        }
        if Thread.isMainThread {
            setDisconnected()
        } else {
            DispatchQueue.main.async(execute: setDisconnected)
        }
    }

    func reconnect() {
        disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.connect()
        }
    }

    func sendInput(_ data: Data) {
        // Handled via specific VNC input methods below.
    }

    // MARK: - Mouse & Keyboard Input

    func sendPointerEvent(buttons: UInt8, x: UInt16, y: UInt16) {
        guard runningLock.withLock({ $0 }) else { return }
        writeQueue.async { [weak self] in
            var msg = Data()
            msg.append(5) // message type: PointerEvent
            msg.append(buttons)
            msg.append(contentsOf: x.bigEndianBytes)
            msg.append(contentsOf: y.bigEndianBytes)
            self?.writeData(msg)
        }
    }

    func sendKeyEvent(down: Bool, key: UInt32) {
        guard runningLock.withLock({ $0 }) else { return }
        writeQueue.async { [weak self] in
            var msg = Data()
            msg.append(4) // message type: KeyEvent
            msg.append(down ? 1 : 0)
            msg.append(contentsOf: [0, 0]) // padding
            msg.append(contentsOf: key.bigEndianBytes)
            self?.writeData(msg)
        }
    }

    func sendClipboardText(_ text: String) {
        guard runningLock.withLock({ $0 }) else { return }
        guard let textData = text.data(using: .isoLatin1) else { return }
        writeQueue.async { [weak self] in
            var msg = Data()
            msg.append(6) // ClientCutText
            msg.append(contentsOf: [0, 0, 0]) // padding
            let length = UInt32(textData.count)
            msg.append(contentsOf: length.bigEndianBytes)
            msg.append(textData)
            self?.writeData(msg)
        }
    }

    func requestFullUpdate() {
        guard runningLock.withLock({ $0 }) else { return }
        writeQueue.async { [weak self] in
            self?.sendFramebufferUpdateRequest(incremental: false)
        }
    }

    // MARK: - Teardown (PROBLEMS.md ISSUE-007 / ISSUE-012)

    /// Tear down streams and stop the read thread, but never touch `status`.
    /// Safe to call from any thread. The read thread will close and nil
    /// the streams itself when it observes the running flag flip.
    private func tearDownStreams() {
        cancelledLock.withLock { $0 = true }
        runningLock.withLock { $0 = false }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        // The blocking-thread-safe way to unblock a read on the socket is
        // `shutdown(SHUT_RDWR)`. After this returns, the read thread's
        // pending `read` returns 0/-1 and it exits the message loop.
        let fd = socketFD
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
        }
    }

    /// Move the session to `.error` and tear down streams. The previous
    /// design called `disconnect()` here, which clobbered the error
    /// (PROBLEMS.md ISSUE-007). Used by the timeout handler, the
    /// `messageLoop` catch block, and the `readExact` failure path.
    private func fail(_ message: String) {
        tearDownStreams()
        let setError = { [weak self] in
            guard let self = self else { return }
            if case .error = self.status { return }
            self.status = .error(message)
            AppLogger.shared.log("VNC: \(message)", level: .error)
        }
        if Thread.isMainThread {
            setError()
        } else {
            DispatchQueue.main.async(execute: setError)
        }
    }

    // MARK: - Connection Timeout

    private func startConnectionTimeout() {
        timeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // The timeout itself doesn't run on main; the fail() helper
            // bounces the status assignment back to main.
            self.fail("Connection timed out after \(Int(connectionTimeoutSeconds))s — check host and port")
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + connectionTimeoutSeconds, execute: work)
    }

    // MARK: - Connection setup

    private func performConnection() {
        // Drop the password reference at the end of this scope no matter
        // what happens (handshake success, failure, timeout, disconnect).
        defer { password = nil }

        // Resolve `host` with getaddrinfo rather than inet_addr (PROBLEMS.md
        // ISSUE-028). inet_addr only parses dotted-quad IPv4 text and
        // returns INADDR_NONE for anything else (including DNS names),
        // which silently dialed 255.255.255.255. AF_UNSPEC lets an
        // IPv6-only host resolve too.
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var resolved: UnsafeMutablePointer<addrinfo>?
        let gaiRc = getaddrinfo(host, String(port), &hints, &resolved)
        guard gaiRc == 0, let firstInfo = resolved else {
            let reason = String(cString: gai_strerror(gaiRc))
            fail("Cannot resolve \(host): \(reason)")
            if let resolved = resolved { freeaddrinfo(resolved) }
            return
        }

        // Try each candidate in turn, bounded by one overall connection
        // deadline shared across all of them.
        let deadline = Date().addingTimeInterval(connectionTimeoutSeconds)
        var lastError = "Cannot resolve \(host): no usable addresses"
        var connectedFD: Int32 = -1
        var cancelledDuringResolve = false

        var cursor: UnsafeMutablePointer<addrinfo>? = firstInfo
        while let info = cursor {
            if cancelledLock.withLock({ $0 }) {
                cancelledDuringResolve = true
                break
            }
            if Date() >= deadline {
                lastError = "Connection timed out after \(Int(connectionTimeoutSeconds))s — check host and port"
                break
            }
            if let fd = attemptConnect(info: info.pointee, deadline: deadline) {
                connectedFD = fd
                break
            }
            lastError = lastConnectError ?? lastError
            cursor = info.pointee.ai_next
        }
        freeaddrinfo(firstInfo)

        if cancelledDuringResolve {
            return
        }
        guard connectedFD >= 0 else {
            fail(lastError)
            return
        }

        do {
            try performHandshake()
        } catch {
            fail(error.localizedDescription)
            return
        }

        // Connection is fully established. From here on, client-to-server
        // writes are routed through writeQueue (the precondition in
        // `writeData` enforces this).
        runningLock.withLock { $0 = true }

        // Capture the read-thread's working copies by value *here*, on
        // the read thread, right after the handshake finished writing
        // them. The closure below only ever assigns the public
        // `framebufferWidth`/`framebufferHeight`/`serverName` from the
        // main thread, so every subsequent read of those three
        // properties (VNCSessionView's fbInfo label, VNCDesktopView's
        // mouse-coordinate translation) happens on the same thread that
        // wrote them — no cross-thread access to the public copies at
        // all (PROBLEMS.md ISSUE-012, thread sanitizer).
        let connectedWidth = rfbWidth
        let connectedHeight = rfbHeight
        let connectedName = rfbServerName

        let setConnected = { [weak self] in
            guard let self = self else { return }
            self.timeoutWorkItem?.cancel()
            self.framebufferWidth = connectedWidth
            self.framebufferHeight = connectedHeight
            self.serverName = connectedName
            if self.status == .connecting {
                self.status = .connected
            }
            AppLogger.shared.log("VNC: Connected to \(self.serverName) (\(self.framebufferWidth)x\(self.framebufferHeight))")
        }
        if Thread.isMainThread {
            setConnected()
        } else {
            DispatchQueue.main.async(execute: setConnected)
        }

        // Request the initial full framebuffer.
        writeQueue.async { [weak self] in
            self?.sendFramebufferUpdateRequest(incremental: false)
        }

        messageLoop()

        // Message loop returned (clean disconnect, or a fail() path).
        // Close the socket here, on the read thread, where it's safe
        // (PROBLEMS.md ISSUE-012). shutdown() was already called from
        // tearDownStreams to unblock any pending read; close() releases
        // the file descriptor.
        runningLock.withLock { $0 = false }
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    // MARK: - Connect (one candidate)

    /// Try connecting to one address returned by `getaddrinfo`.
    ///
    /// On success, returns the connected fd — already restored to
    /// blocking mode, with `SO_NOSIGPIPE` and `SO_RCVTIMEO` applied —
    /// and, crucially, `socketFD` has already been assigned *before*
    /// this function waited for the connect to complete, so a concurrent
    /// `tearDownStreams()` can `shutdown()` a connect that never
    /// resolves instead of leaving this thread (and a strong `self`)
    /// pinned until the OS gives up on its own (PROBLEMS.md ISSUE-028).
    ///
    /// On failure, closes whatever socket it opened, records the reason
    /// in `lastConnectError`, and returns nil.
    private func attemptConnect(info: addrinfo, deadline: Date) -> Int32? {
        let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard fd >= 0 else {
            lastConnectError = "Failed to create network socket: \(String(cString: strerror(errno)))"
            return nil
        }

        // Disable SIGPIPE — if the peer closes mid-write, write()
        // returns EPIPE instead of killing the process.
        var noSig: Int32 = 1
        if setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            AppLogger.shared.log("VNC: setsockopt(SO_NOSIGPIPE) failed: \(String(cString: strerror(errno)))", level: .warning)
        }
        // SO_RCVTIMEO takes a `struct timeval`, not a bare integer
        // (PROBLEMS.md ISSUE-029) — a `time_t`-sized argument fails with
        // EINVAL and silently leaves no read deadline set at all.
        var tv = timeval(tv_sec: time_t(readTimeoutSeconds), tv_usec: 0)
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size)) != 0 {
            AppLogger.shared.log("VNC: setsockopt(SO_RCVTIMEO) failed: \(String(cString: strerror(errno)))", level: .warning)
        }

        // Make the connect interruptible and bounded: switch to
        // non-blocking before calling connect() so we can poll for
        // completion against our own deadline (and the cancelled flag)
        // instead of blocking this thread indefinitely.
        let originalFlags = fcntl(fd, F_GETFL, 0)
        if originalFlags == -1 {
            AppLogger.shared.log("VNC: fcntl(F_GETFL) failed: \(String(cString: strerror(errno)))", level: .warning)
        } else if fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == -1 {
            AppLogger.shared.log("VNC: fcntl(F_SETFL, +O_NONBLOCK) failed: \(String(cString: strerror(errno)))", level: .warning)
        }

        guard let addrPtr = info.ai_addr else {
            lastConnectError = "Address candidate has no sockaddr"
            close(fd)
            return nil
        }
        let connectRc = Darwin.connect(fd, addrPtr, info.ai_addrlen)
        if connectRc != 0 && errno != EINPROGRESS {
            lastConnectError = "Connection failed: \(String(cString: strerror(errno)))"
            close(fd)
            return nil
        }

        // Assign socketFD now — before waiting for the connect to
        // resolve — so tearDownStreams() can shut this down if the
        // caller disconnects/deallocates while we're still waiting.
        socketFD = fd

        if connectRc != 0 {
            switch waitForConnect(fd: fd, deadline: deadline) {
            case .connected:
                break
            case .failed(let msg):
                lastConnectError = msg
                socketFD = -1
                close(fd)
                return nil
            case .timedOut:
                lastConnectError = "Connection timed out after \(Int(connectionTimeoutSeconds))s — check host and port"
                socketFD = -1
                close(fd)
                return nil
            case .cancelled:
                socketFD = -1
                close(fd)
                return nil
            }
        }

        // Clear O_NONBLOCK now that we're connected. This is required,
        // not cosmetic: the rest of the session (readExact) relies on
        // SO_RCVTIMEO to bound a stalled read, and SO_RCVTIMEO has no
        // effect on a non-blocking socket — a read on a non-blocking fd
        // just returns EAGAIN immediately regardless of the timeout,
        // which would turn the EAGAIN/EWOULDBLOCK branch in readExact
        // into a tight busy-spin instead of a bounded wait (PROBLEMS.md
        // ISSUE-029's "critical interaction" with this connect path).
        if originalFlags != -1 {
            if fcntl(fd, F_SETFL, originalFlags) == -1 {
                AppLogger.shared.log("VNC: fcntl(F_SETFL, -O_NONBLOCK) failed: \(String(cString: strerror(errno)))", level: .warning)
            }
        }

        return fd
    }

    private enum ConnectWaitResult {
        case connected
        case failed(String)
        case timedOut
        case cancelled
    }

    /// Poll `fd` for writability — the standard way to learn a
    /// non-blocking `connect()` has resolved — in short slices, so we
    /// can also notice the cancelled flag and the overall connect
    /// deadline without a dedicated timer.
    private func waitForConnect(fd: Int32, deadline: Date) -> ConnectWaitResult {
        while true {
            if cancelledLock.withLock({ $0 }) { return .cancelled }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .timedOut }

            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let sliceMs = Int32(max(1, min(remaining * 1000, 200)))
            let rc = poll(&pfd, 1, sliceMs)
            if rc < 0 {
                if errno == EINTR { continue }
                return .failed("poll() failed: \(String(cString: strerror(errno)))")
            }
            if rc == 0 { continue } // slice elapsed with no event; loop re-checks deadline/cancellation

            if pfd.revents & Int16(POLLOUT | POLLERR | POLLHUP) != 0 {
                var soError: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) != 0 {
                    return .failed("getsockopt(SO_ERROR) failed: \(String(cString: strerror(errno)))")
                }
                if soError != 0 {
                    return .failed("Connection failed: \(String(cString: strerror(soError)))")
                }
                return .connected
            }
        }
    }

    // MARK: - RFB Handshake

    private func performHandshake() throws {
        // 1. Read server protocol version
        let versionBytes = try readExact(count: 12)
        let versionStr = String(bytes: versionBytes, encoding: .ascii) ?? ""
        AppLogger.shared.log("VNC: Server version: \(versionStr.trimmingCharacters(in: .whitespacesAndNewlines))")

        if let minor = VNCSession.parseRFBMinor(versionStr), minor < 7 {
            throw VNCError.protocolError("Server speaks RFB 3.\(minor); only 3.7 and 3.8 are supported")
        }

        // 2. Send our protocol version (3.8). After every write, pump
        // the run loop so CFStream dispatches its write-completion
        // event and actually pushes the bytes to the socket.
        let clientVersion = "RFB 003.008\n"
        writeData(Data(clientVersion.utf8))

        // 3. Security handshake
        let numSecTypes = try readExact(count: 1)[0]
        if numSecTypes == 0 {
            let reasonLen = try readUInt32()
            let reasonBytes = try readExact(count: Int(reasonLen))
            let reason = String(bytes: reasonBytes, encoding: .utf8) ?? "Unknown"
            throw VNCError.connectionFailed(reason)
        }

        let secTypes = try readExact(count: Int(numSecTypes))
        AppLogger.shared.log("VNC: Security types: \(secTypes.map { String($0) }.joined(separator: ", "))")

        if secTypes.contains(1) {
            writeData(Data([1]))      // None
            } else if secTypes.contains(2) {
            writeData(Data([2]))      // VNC Auth
                try performVNCAuth()
        } else {
            throw VNCError.unsupportedSecurity
        }

        // 4. Read security result
        let result = try readUInt32()
        if result != 0 {
            var reason = "Authentication failed"
            if let reasonLen = try? readUInt32(), reasonLen > 0 && reasonLen < 1024 {
                if let reasonBytes = try? readExact(count: Int(reasonLen)) {
                    reason = String(bytes: reasonBytes, encoding: .utf8) ?? reason
                }
            }
            throw VNCError.authFailed(reason)
        }

        // 5. ClientInit (shared = true)
        writeData(Data([1]))

        // 6. Read ServerInit
        // These populate the read-thread-only `rfb*` working copies, not
        // the public `framebufferWidth`/`framebufferHeight`/`serverName`
        // (see the doc comment on those properties — PROBLEMS.md
        // ISSUE-012). The public copies are published once, from the
        // main thread, in `performConnection`'s `setConnected` closure.
        let fbWidthBytes = try readExact(count: 2)
        let fbHeightBytes = try readExact(count: 2)
        rfbWidth = Int(UInt16(fbWidthBytes[0]) << 8 | UInt16(fbWidthBytes[1]))
        rfbHeight = Int(UInt16(fbHeightBytes[0]) << 8 | UInt16(fbHeightBytes[1]))

        guard rfbWidth > 0, rfbHeight > 0,
              rfbWidth <= VNCSession.maxFramebufferDimension,
              rfbHeight <= VNCSession.maxFramebufferDimension else {
            throw VNCError.protocolError("Server framebuffer dimensions out of range: \(rfbWidth)x\(rfbHeight)")
        }

        // Pixel format (16 bytes)
        let pixelFormat = try readExact(count: 16)
        AppLogger.shared.log("VNC: Server pixel format - bpp: \(pixelFormat[0]), depth: \(pixelFormat[1]), bigEndian: \(pixelFormat[2]), trueColor: \(pixelFormat[3])")

        // Server name — cap length before allocating.
        let nameLen = Int(try readUInt32())
        guard nameLen <= VNCSession.maxServerNameLength else {
            throw VNCError.protocolError("Server name length \(nameLen) exceeds limit \(VNCSession.maxServerNameLength)")
        }
        let nameBytes = try readExact(count: nameLen)
        rfbServerName = String(bytes: nameBytes, encoding: .utf8) ?? "Unknown"

        // Allocate framebuffer.
        framebuffer = [UInt8](repeating: 0, count: rfbWidth * rfbHeight * bytesPerPixel)
        dirtyRect = NSRect(x: 0, y: 0, width: rfbWidth, height: rfbHeight)

        // Set pixel format to BGRA32, then encodings.
        sendSetPixelFormat()
        sendSetEncodings()
    }

    private static func parseRFBMinor(_ version: String) -> Int? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("RFB "), trimmed.count >= 11 else { return nil }
        let parts = trimmed.dropFirst(4).split(separator: ".")
        guard parts.count == 2, let minor = Int(parts[1]) else { return nil }
        return minor
    }

    private func performVNCAuth() throws {
        let challenge = try readExact(count: 16)

        guard let pwd = password, !pwd.isEmpty else {
            throw VNCError.authFailed("Password required but not provided")
        }

        let response = vncEncryptChallenge(challenge: challenge, password: pwd)
        writeData(Data(response))
        password = nil
    }

    private func vncEncryptChallenge(challenge: [UInt8], password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        let pwdBytes = Array(password.utf8)
        for i in 0..<min(8, pwdBytes.count) {
            key[i] = pwdBytes[i]
        }
        for i in 0..<8 {
            key[i] = reverseBits(key[i])
        }

        var result = [UInt8](repeating: 0, count: 16)
        desEncrypt(block: Array(challenge[0..<8]), key: key, output: &result, offset: 0)
        desEncrypt(block: Array(challenge[8..<16]), key: key, output: &result, offset: 8)
        return result
    }

    private func reverseBits(_ b: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var input = b
        for _ in 0..<8 {
            result = (result << 1) | (input & 1)
            input >>= 1
        }
        return result
    }

    // MARK: - Message Loop

    private func messageLoop() {
        while runningLock.withLock({ $0 }) {
            let msgType: UInt8
            let firstByte: UInt8?
            do {
                firstByte = try readExact(count: 1).first
            } catch {
                // readExact only throws VNCError, but Swift's exhaustive
                // catch needs us to handle the whole Error protocol.
                // Dispatch on the underlying type.
                if let vncErr = error as? VNCError {
                    switch vncErr {
                    case .streamClosed:
                        // Clean EOF (read returned 0) or stream torn down
                        // by `fail(_:)` / `disconnect()`. The running flag
                        // is already false in the latter case.
                        if runningLock.withLock({ $0 }) {
                            let setDisconnected = { [weak self] in
                                guard let self = self else { return }
                                if case .error = self.status { return }
                                self.status = .disconnected
                                AppLogger.shared.log("VNC: Connection closed by server")
                            }
                            if Thread.isMainThread { setDisconnected() }
                            else { DispatchQueue.main.async(execute: setDisconnected) }
                        }
                    default:
                        fail(vncErr.localizedDescription)
                    }
                } else {
                    fail(error.localizedDescription)
                }
                return
            }
            guard let first = firstByte else {
                // Clean EOF before the running flag was cleared.
                AppLogger.shared.log("VNC: Connection closed by server")
                return
            }
            msgType = first

            do {
                switch msgType {
                case 0: try handleFramebufferUpdate()
                case 1: try handleSetColourMap()
                case 2: NSSound.beep()
                case 3: try handleServerCutText()
                default:
                    // PROBLEMS.md ISSUE-013: an unknown message type means
                    // we don't know how many bytes its payload consumed, so
                    // every subsequent parse is garbage. End the session
                    // with a clear error instead of silently desyncing.
                    throw VNCError.protocolError("Unknown server message type \(msgType)")
                }
            } catch let error as VNCError {
                fail(error.localizedDescription)
                return
            } catch {
                fail(error.localizedDescription)
                return
            }
        }
    }

    // MARK: - Server messages

    private func handleFramebufferUpdate() throws {
        _ = try readExact(count: 1) // padding
        let numRects = Int(try readUInt16())

        guard numRects <= VNCSession.maxRectanglesPerUpdate else {
            throw VNCError.protocolError("Framebuffer update has \(numRects) rects, max is \(VNCSession.maxRectanglesPerUpdate)")
        }

        // Track the union of handled rects for partial redraw (ISSUE-024).
        var unionRect = NSRect.null

        for _ in 0..<numRects {
            let x = Int(try readUInt16())
            let y = Int(try readUInt16())
            let w = Int(try readUInt16())
            let h = Int(try readUInt16())
            let encoding = try readInt32()

            guard w > 0, h > 0,
                  w <= VNCSession.maxRectDimension,
                  h <= VNCSession.maxRectDimension,
                  x < rfbWidth, y < rfbHeight,
                  x + w <= rfbWidth, y + h <= rfbHeight else {
                throw VNCError.protocolError("Rectangle out of framebuffer bounds: x=\(x) y=\(y) w=\(w) h=\(h) (fb=\(rfbWidth)x\(rfbHeight))")
            }

            // PROBLEMS.md ISSUE-013: unsupported encodings are a fatal
            // protocol error, not a warning. The rect payload is well-defined
            // by the encoding integer but we don't have a parser for it; if
            // we just `break` we never consume those bytes and the next
            // message type byte is read from the middle of the payload.
            switch encoding {
            case 0:
                try handleRawRect(x: x, y: y, w: w, h: h)
            case 1:
                try handleCopyRect(x: x, y: y, w: w, h: h)
            default:
                throw VNCError.protocolError("Unsupported encoding \(encoding)")
            }

            let r = NSRect(x: x, y: y, width: w, height: h)
            unionRect = unionRect == .null ? r : unionRect.union(r)
        }

        // Render and notify on main. The dirty rect passed to the view
        // is the union of the rectangles touched in this update.
        dirtyRect = unionRect
        if let image = renderFramebuffer() {
            let rect = unionRect
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onFramebufferUpdate?(image, rect)
            }
        }

        // PROBLEMS.md ISSUE-014: route the post-update request through
        // writeQueue. After handshake, writeData requires being on
        // writeQueue.
        writeQueue.async { [weak self] in
            self?.sendFramebufferUpdateRequest(incremental: true)
        }
    }

    private func handleRawRect(x: Int, y: Int, w: Int, h: Int) throws {
        let pixelData = try readExact(count: w * h * bytesPerPixel)
        let rowBytes = w * bytesPerPixel
        for row in 0..<h {
            let srcOffset = row * rowBytes
            let dstOffset = ((y + row) * rfbWidth + x) * bytesPerPixel
            pixelData.withUnsafeBufferPointer { srcBuf in
                framebuffer.withUnsafeMutableBufferPointer { dstBuf in
                    guard let dst = dstBuf.baseAddress, let src = srcBuf.baseAddress else { return }
                    memcpy(dst + dstOffset, src + srcOffset, rowBytes)
                }
            }
        }
    }

    private func handleCopyRect(x: Int, y: Int, w: Int, h: Int) throws {
        let srcX = Int(try readUInt16())
        let srcY = Int(try readUInt16())

        guard srcX < rfbWidth, srcY < rfbHeight,
              srcX + w <= rfbWidth, srcY + h <= rfbHeight else {
            throw VNCError.protocolError("CopyRect source out of framebuffer bounds: srcX=\(srcX) srcY=\(srcY) w=\(w) h=\(h)")
        }

        var temp = [UInt8](repeating: 0, count: w * h * bytesPerPixel)
        for row in 0..<h {
            let srcOffset = ((srcY + row) * rfbWidth + srcX) * bytesPerPixel
            let tmpOffset = row * w * bytesPerPixel
            for col in 0..<(w * bytesPerPixel) {
                if srcOffset + col < framebuffer.count {
                    temp[tmpOffset + col] = framebuffer[srcOffset + col]
                }
            }
        }
        for row in 0..<h {
            let dstOffset = ((y + row) * rfbWidth + x) * bytesPerPixel
            let tmpOffset = row * w * bytesPerPixel
            for col in 0..<(w * bytesPerPixel) {
                if dstOffset + col < framebuffer.count {
                    framebuffer[dstOffset + col] = temp[tmpOffset + col]
                }
            }
        }
    }

    private func handleSetColourMap() throws {
        _ = try readExact(count: 1) // padding
        _ = try readUInt16() // firstColor
        let numColors = Int(try readUInt16())
        guard numColors <= VNCSession.maxColormapEntries else {
            throw VNCError.protocolError("Colormap has \(numColors) entries, max is \(VNCSession.maxColormapEntries)")
        }
        _ = try readExact(count: numColors * 6) // RGB values
    }

    private func handleServerCutText() throws {
        _ = try readExact(count: 3) // padding
        let length = Int(try readUInt32())
        guard length <= VNCSession.maxCutTextLength else {
            throw VNCError.protocolError("ServerCutText length \(length) exceeds limit \(VNCSession.maxCutTextLength)")
        }
        let textBytes = try readExact(count: length)
        if let text = String(bytes: textBytes, encoding: .isoLatin1) {
            DispatchQueue.main.async {
                guard SecuritySettings.shared.allowRemoteClipboard else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            AppLogger.shared.log("VNC: Received clipboard text (\(text.count) chars)")
        }
    }

    // MARK: - Client messages

    private func sendSetPixelFormat() {
        var msg = Data()
        msg.append(0) // SetPixelFormat
        msg.append(contentsOf: [0, 0, 0]) // padding
        msg.append(32)  // bpp
        msg.append(24)  // depth
        msg.append(0)   // big-endian
        msg.append(1)   // true-color
        msg.append(contentsOf: UInt16(255).bigEndianBytes)
        msg.append(contentsOf: UInt16(255).bigEndianBytes)
        msg.append(contentsOf: UInt16(255).bigEndianBytes)
        msg.append(16)
        msg.append(8)
        msg.append(0)
        msg.append(contentsOf: [0, 0, 0])
        writeData(msg)
    }

    private func sendSetEncodings() {
        var msg = Data()
        msg.append(2) // SetEncodings
        msg.append(0) // padding
        msg.append(contentsOf: UInt16(2).bigEndianBytes)
        msg.append(contentsOf: Int32(1).bigEndianBytes)  // CopyRect
        msg.append(contentsOf: Int32(0).bigEndianBytes)  // Raw
        writeData(msg)
    }

    private func sendFramebufferUpdateRequest(incremental: Bool) {
        var msg = Data()
        msg.append(3) // FramebufferUpdateRequest
        msg.append(incremental ? 1 : 0)
        msg.append(contentsOf: UInt16(0).bigEndianBytes)
        msg.append(contentsOf: UInt16(0).bigEndianBytes)
        msg.append(contentsOf: UInt16(rfbWidth).bigEndianBytes)
        msg.append(contentsOf: UInt16(rfbHeight).bigEndianBytes)
        writeData(msg)
    }

    // MARK: - Framebuffer Rendering

    private func renderFramebuffer() -> NSImage? {
        guard rfbWidth > 0 && rfbHeight > 0 else { return nil }
        guard framebuffer.count >= rfbWidth * rfbHeight * bytesPerPixel else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let bytesPerRow = rfbWidth * bytesPerPixel

        var resultImage: NSImage?
        framebuffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            guard let context = CGContext(
                data: base,
                width: rfbWidth,
                height: rfbHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return }
            guard let cgImage = context.makeImage() else { return }
            resultImage = NSImage(cgImage: cgImage, size: NSSize(width: rfbWidth, height: rfbHeight))
        }
        return resultImage
    }

    // MARK: - Socket I/O

    private func readExact(count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        let fd = socketFD
        guard fd >= 0 else { throw VNCError.streamClosed }

        var buffer = [UInt8](repeating: 0, count: count)
        var totalRead = 0

        while totalRead < count {
            // Honor the cancelled flag so a disconnect during a slow read
            // unblocks us promptly.
            if cancelledLock.withLock({ $0 }) {
                throw VNCError.streamClosed
            }

            let remaining = count - totalRead
            let bytesRead = buffer.withUnsafeMutableBufferPointer { bufferPtr -> Int in
                guard let base = bufferPtr.baseAddress else { return -1 }
                return Darwin.read(fd, base.advanced(by: totalRead), remaining)
            }

            if bytesRead == 0 {
                // Clean EOF.
                throw VNCError.streamClosed
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // SO_RCVTIMEO fired (PROBLEMS.md ISSUE-029). This is
                    // NOT the same situation as a clean EOF: the peer is
                    // still connected but stalled. Throwing `.streamClosed`
                    // here would make `messageLoop` treat it exactly like
                    // a normal server-initiated close (-> `.disconnected`),
                    // silently swallowing what should be a visible error.
                    throw VNCError.readTimedOut(readTimeoutSeconds)
                }
                if errno == ECONNRESET || errno == EPIPE || errno == ENOTCONN {
                    throw VNCError.streamClosed
                }
                throw VNCError.protocolError("Read failed: \(String(cString: strerror(errno)))")
            }
            totalRead += bytesRead
        }

        return buffer
    }

    private func readUInt16() throws -> UInt16 {
        let bytes = try readExact(count: 2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private func readUInt32() throws -> UInt32 {
        let bytes = try readExact(count: 4)
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    private func readInt32() throws -> Int32 {
        let u = try readUInt32()
        return Int32(bitPattern: u)
    }

    /// Emit `data` to the output side of the socket. The dispatch
    /// precondition enforces that post-handshake writes go through
    /// `writeQueue` (PROBLEMS.md ISSUE-014). Pre-handshake writes
    /// (the version banner, the security type choice, the pixel
    /// format / encodings messages) originate on the read thread
    /// BEFORE `isRunning` flips true, so the precondition is
    /// conditional on the running flag.
    private func writeData(_ data: Data) {
        if runningLock.withLock({ $0 }) {
            // Post-handshake: only the write queue is allowed to write.
            dispatchPrecondition(condition: .onQueue(writeQueue))
        }
        let fd = socketFD
        guard fd >= 0 else { return }
        data.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            let typedPtr = baseAddress.assumingMemoryBound(to: UInt8.self)
            var written = 0
            while written < data.count {
                let result = Darwin.write(fd, typedPtr + written, data.count - written)
                if result < 0 {
                    if errno == EINTR { continue }
                    return  // EPIPE / ECONNRESET — peer closed
                }
                if result == 0 { return }
                written += result
            }
        }
    }

    // MARK: - DES Encryption (for VNC Auth)

    private func desEncrypt(block: [UInt8], key: [UInt8], output: inout [UInt8], offset: Int) {
        let keyData = key
        let blockData = block
        var outData = [UInt8](repeating: 0, count: 8)

        let keyLength = 8
        let dataLength = 8
        var numBytesEncrypted: Int = 0

        let status = keyData.withUnsafeBufferPointer { keyBuf -> CCCryptorStatus in
            blockData.withUnsafeBufferPointer { dataBuf -> CCCryptorStatus in
                outData.withUnsafeMutableBufferPointer { outBuf -> CCCryptorStatus in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionECBMode),
                        keyBuf.baseAddress!, keyLength,
                        nil,
                        dataBuf.baseAddress!, dataLength,
                        outBuf.baseAddress!, dataLength,
                        &numBytesEncrypted
                    )
                }
            }
        }
        if status != kCCSuccess {
            AppLogger.shared.log("VNC: DES encryption failed (CCCryptorStatus \(status))", level: .error)
        }

        for i in 0..<8 {
            output[offset + i] = outData[i]
        }
    }
}

// MARK: - Helpers

extension UInt16 {
    var bigEndianBytes: [UInt8] {
        [UInt8(self >> 8), UInt8(self & 0xFF)]
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8(self >> 24), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}

extension Int32 {
    var bigEndianBytes: [UInt8] {
        let u = UInt32(bitPattern: self)
        return u.bigEndianBytes
    }
}

// MARK: - Errors

enum VNCError: Error, LocalizedError {
    case connectionFailed(String)
    case unsupportedSecurity
    case authFailed(String)
    case streamClosed
    case protocolError(String)
    /// SO_RCVTIMEO fired (PROBLEMS.md ISSUE-029): distinct from
    /// `.streamClosed` so `messageLoop` surfaces it as `.error` instead
    /// of treating a stalled connection like a normal server close.
    case readTimedOut(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .unsupportedSecurity: return "No supported security type"
        case .authFailed(let msg): return "Authentication failed: \(msg)"
        case .streamClosed: return "Connection closed"
        case .protocolError(let msg): return "Protocol error: \(msg)"
        case .readTimedOut(let seconds): return "No data received for \(seconds)s — connection appears stalled"
        }
    }
}
