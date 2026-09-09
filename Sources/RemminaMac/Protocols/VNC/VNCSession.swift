import Foundation
import AppKit
import os

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

    /// Connection timeout in seconds.
    private static let connectionTimeoutSeconds: Double = 15
    /// Read deadline in seconds (PROBLEMS.md ISSUE-012). After this, a
    /// stuck read returns and we surface a `.streamClosed` error rather
    /// than spinning forever.
    private static let readTimeoutSeconds: time_t = 30

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

    private(set) var framebufferWidth: Int = 0
    private(set) var framebufferHeight: Int = 0
    private(set) var serverName: String = ""
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
            self.fail("Connection timed out after \(Int(VNCSession.connectionTimeoutSeconds))s — check host and port")
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + VNCSession.connectionTimeoutSeconds, execute: work)
    }

    // MARK: - Connection setup

    private func performConnection() {
        // Drop the password reference at the end of this scope no matter
        // what happens (handshake success, failure, timeout, disconnect).
        defer { password = nil }

        // Open a raw BSD socket instead of CFStream. CFStream requires
        // a run loop to dispatch its read/write events, and driving
        // that from a background thread is fragile (every operation
        // needs a manual pump, and missed pumps silently lose data).
        // POSIX sockets + Darwin.read/write are synchronous and don't
        // have that problem. We use SO_RCVTIMEO for the read deadline.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fail("Failed to create network socket: \(String(cString: strerror(errno)))")
            return
        }
        // Disable SIGPIPE — if the peer closes mid-write, write()
        // returns EPIPE instead of killing the process.
        var noSig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
        var timeout = VNCSession.readTimeoutSeconds
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<time_t>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let connectRc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectRc != 0 {
            let err = String(cString: strerror(errno))
            close(fd)
            fail("Connection failed: \(err)")
            return
        }
        socketFD = fd

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

        let setConnected = { [weak self] in
            guard let self = self else { return }
            self.timeoutWorkItem?.cancel()
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

    // MARK: - Stream open wait (CFStream run-loop dependency)

    /// Result of waiting for a CFStream pair to open.
    private enum OpenResult {
        case opened
        case errored(String)
        case timedOut
        case cancelled
    }

    // (Legacy CFStream helpers removed — we now use a raw BSD socket.)

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
        let fbWidthBytes = try readExact(count: 2)
        let fbHeightBytes = try readExact(count: 2)
        framebufferWidth = Int(UInt16(fbWidthBytes[0]) << 8 | UInt16(fbWidthBytes[1]))
        framebufferHeight = Int(UInt16(fbHeightBytes[0]) << 8 | UInt16(fbHeightBytes[1]))

        guard framebufferWidth > 0, framebufferHeight > 0,
              framebufferWidth <= VNCSession.maxFramebufferDimension,
              framebufferHeight <= VNCSession.maxFramebufferDimension else {
            throw VNCError.protocolError("Server framebuffer dimensions out of range: \(framebufferWidth)x\(framebufferHeight)")
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
        serverName = String(bytes: nameBytes, encoding: .utf8) ?? "Unknown"

        // Allocate framebuffer.
        framebuffer = [UInt8](repeating: 0, count: framebufferWidth * framebufferHeight * bytesPerPixel)
        dirtyRect = NSRect(x: 0, y: 0, width: framebufferWidth, height: framebufferHeight)

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
        let bytesPerRow = framebufferWidth * bytesPerPixel

        for _ in 0..<numRects {
            let x = Int(try readUInt16())
            let y = Int(try readUInt16())
            let w = Int(try readUInt16())
            let h = Int(try readUInt16())
            let encoding = try readInt32()

            guard w > 0, h > 0,
                  w <= VNCSession.maxRectDimension,
                  h <= VNCSession.maxRectDimension,
                  x < framebufferWidth, y < framebufferHeight,
                  x + w <= framebufferWidth, y + h <= framebufferHeight else {
                throw VNCError.protocolError("Rectangle out of framebuffer bounds: x=\(x) y=\(y) w=\(w) h=\(h) (fb=\(framebufferWidth)x\(framebufferHeight))")
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
            _ = bytesPerRow  // referenced above via framebufferWidth * bytesPerPixel
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
            let dstOffset = ((y + row) * framebufferWidth + x) * bytesPerPixel
            _ = pixelData.withUnsafeBufferPointer { srcBuf in
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

        guard srcX < framebufferWidth, srcY < framebufferHeight,
              srcX + w <= framebufferWidth, srcY + h <= framebufferHeight else {
            throw VNCError.protocolError("CopyRect source out of framebuffer bounds: srcX=\(srcX) srcY=\(srcY) w=\(w) h=\(h)")
        }

        var temp = [UInt8](repeating: 0, count: w * h * bytesPerPixel)
        for row in 0..<h {
            let srcOffset = ((srcY + row) * framebufferWidth + srcX) * bytesPerPixel
            let tmpOffset = row * w * bytesPerPixel
            for col in 0..<(w * bytesPerPixel) {
                if srcOffset + col < framebuffer.count {
                    temp[tmpOffset + col] = framebuffer[srcOffset + col]
                }
            }
        }
        for row in 0..<h {
            let dstOffset = ((y + row) * framebufferWidth + x) * bytesPerPixel
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
        msg.append(contentsOf: UInt16(framebufferWidth).bigEndianBytes)
        msg.append(contentsOf: UInt16(framebufferHeight).bigEndianBytes)
        writeData(msg)
    }

    // MARK: - Framebuffer Rendering

    private func renderFramebuffer() -> NSImage? {
        guard framebufferWidth > 0 && framebufferHeight > 0 else { return nil }
        guard framebuffer.count >= framebufferWidth * framebufferHeight * bytesPerPixel else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let bytesPerRow = framebufferWidth * bytesPerPixel

        var resultImage: NSImage?
        framebuffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            guard let context = CGContext(
                data: base,
                width: framebufferWidth,
                height: framebufferHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return }
            guard let cgImage = context.makeImage() else { return }
            resultImage = NSImage(cgImage: cgImage, size: NSSize(width: framebufferWidth, height: framebufferHeight))
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
                    // SO_RCVTIMEO fired. Treat as a stalled connection.
                    throw VNCError.streamClosed
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

        keyData.withUnsafeBufferPointer { keyBuf in
            blockData.withUnsafeBufferPointer { dataBuf in
                outData.withUnsafeMutableBufferPointer { outBuf in
                    _ = CCCrypt(
                        UInt32(0), // kCCEncrypt
                        UInt32(1), // kCCAlgorithmDES
                        UInt32(1), // kCCOptionECBMode
                        keyBuf.baseAddress!, keyLength,
                        nil,
                        dataBuf.baseAddress!, dataLength,
                        outBuf.baseAddress!, dataLength,
                        &numBytesEncrypted
                    )
                }
            }
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

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .unsupportedSecurity: return "No supported security type"
        case .authFailed(let msg): return "Authentication failed: \(msg)"
        case .streamClosed: return "Connection closed"
        case .protocolError(let msg): return "Protocol error: \(msg)"
        }
    }
}

// MARK: - CCCrypt binding

@_silgen_name("CCCrypt")
private func CCCrypt(
    _ op: UInt32,
    _ alg: UInt32,
    _ options: UInt32,
    _ key: UnsafeRawPointer,
    _ keyLength: Int,
    _ iv: UnsafeRawPointer?,
    _ dataIn: UnsafeRawPointer,
    _ dataInLength: Int,
    _ dataOut: UnsafeMutableRawPointer,
    _ dataOutAvailable: Int,
    _ dataOutMoved: UnsafeMutablePointer<Int>
) -> Int32
