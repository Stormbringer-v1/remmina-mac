import Foundation
import Darwin

/// A POSIX-socket fake RFB 3.8 server for testing `VNCSession` against
/// real protocol bytes.
///
/// The server listens on 127.0.0.1:ephemeral, accepts one connection, and
/// exposes helpers for the test cases enumerated in PROBLEMS.md ISSUE-020:
/// - oversize framebuffer dimensions → expect `.error`
/// - rect outside the framebuffer → expect `.error`
/// - unknown message type → expect `.error`  (ISSUE-013)
/// - valid Raw rect → expect `onFramebufferUpdate` to fire with a
///   snapshot whose pixel at (x, y) has the expected BGRA value
///
/// We deliberately use POSIX sockets rather than `NWListener` so the
/// tests don't drag in Network framework threading semantics, and so we
/// can assert on the exact bytes `VNCSession` sends.
final class FakeVNCServer: @unchecked Sendable {
    /// 127.0.0.1 — loopback only.
    let host = "127.0.0.1"
    /// The port the listener was bound to (0 = "pick ephemeral").
    let port: UInt16
    private let listenFD: Int32
    private let ioQueue = DispatchQueue(label: "com.remmina-mac.fakevnc.io")
    private let stateLock = NSLock()
    /// Set when `accept()` returns a client fd. -1 until the client connects.
    private var _clientFD: Int32 = -1
    private var clientFD: Int32 {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _clientFD }
        set { stateLock.lock(); _clientFD = newValue; stateLock.unlock() }
    }
    /// Total bytes the client has sent us. Useful for assertion in tests.
    private(set) var receivedBytes: Int = 0
    /// Bytes buffered for `receive(count:)`. Bounded; tests should drain
    /// promptly. Not a real ring buffer — it just collects what `recv`
    /// returns, no backpressure.
    private var receivedBuffer = Data()
    private let receivedBufferLock = NSLock()
    /// Set true when `stop()` is called; the accept loop exits. Backed by
    /// `stateLock` (like `clientFD` above) because it's written from
    /// whichever thread calls `stop()` and read from the accept-loop and
    /// client-reader threads — a thread sanitizer run over the VNC tests
    /// (PROBLEMS.md ISSUE-012) flagged the previous plain `Bool` as a
    /// genuine data race.
    private var _stopped = false
    private var stopped: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _stopped }
        set { stateLock.lock(); _stopped = newValue; stateLock.unlock() }
    }

    enum ServerError: Error, LocalizedError {
        case socketCreate(String)
        case bind(String)
        case listen(String)
        case accept(String)

        var errorDescription: String? {
            switch self {
            case .socketCreate(let m): return "FakeVNCServer: socket() failed: \(m)"
            case .bind(let m): return "FakeVNCServer: bind() failed: \(m)"
            case .listen(let m): return "FakeVNCServer: listen() failed: \(m)"
            case .accept(let m): return "FakeVNCServer: accept() failed: \(m)"
            }
        }
    }

    /// Start a fake server on 127.0.0.1 with an ephemeral port. The
    /// listener is non-blocking; the accept loop runs on `ioQueue`.
    static func start() throws -> FakeVNCServer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServerError.socketCreate(String(cString: strerror(errno)))
        }

        // SO_REUSEADDR so rapid test cycles don't get EADDRINUSE.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRc == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw ServerError.bind(msg)
        }

        guard listen(fd, 1) == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw ServerError.listen(msg)
        }

        // Read back the bound port. We pass port=0 to bind, the kernel
        // picks an ephemeral one — this is how we discover it.
        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getRc = withUnsafeMutablePointer(to: &boundAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &boundLen)
            }
        }
        guard getRc == 0 else {
            close(fd)
            throw ServerError.bind("getsockname failed")
        }

        let server = FakeVNCServer(listenFD: fd, port: UInt16(bigEndian: boundAddr.sin_port))
        server.spinAcceptLoop()
        return server
    }

    private init(listenFD: Int32, port: UInt16) {
        self.listenFD = listenFD
        self.port = port
    }

    private func spinAcceptLoop() {
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            while !self.stopped {
                let client = accept(self.listenFD, nil, nil)
                if client >= 0 {
                    var noSig: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSig, socklen_t(MemoryLayout<Int32>.size))
                    self.clientFD = client
                    self.spinClientReader()
                    return
                }
                if self.stopped { return }
                if errno == EINTR { continue }
                return
            }
        }
    }

    private func spinClientReader() {
        Thread.detachNewThread { [weak self] in
            guard let self = self else { return }
            let fd = self.clientFD
            var buf = [UInt8](repeating: 0, count: 4096)
            while !self.stopped {
                let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                    Darwin.read(fd, ptr.baseAddress, ptr.count)
                }
                if n > 0 {
                    self.receivedBufferLock.lock()
                    self.receivedBuffer.append(buf, count: n)
                    self.receivedBytes += n
                    self.receivedBufferLock.unlock()
                    continue
                }
                if n == 0 || self.stopped { return }
                if errno == EINTR { continue }
                return
            }
        }
    }

    /// Block until the client connects or `timeout` elapses. Returns true
    /// if connected.
    /// `timeout` defaults scale with `ciDeadlineScale`: on a loaded CI
    /// runner the client's connect can take several seconds.
    func waitForClient(timeout: TimeInterval = 5.0 * ciDeadlineScale) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if clientFD >= 0 { return true }
            usleep(5_000)
        }
        return clientFD >= 0
    }

    /// Send the RFB 3.8 server-init banner, the security-type list (None
    /// only), and a ServerInit with the given framebuffer dimensions and
    /// name. Used to drive a successful handshake.
    @discardableResult
    func sendHandshake(serverName: String = "FakeVNC", width: UInt16, height: UInt16) -> Bool {
        // 1. Server protocol version: "RFB 003.008\n"
        if !send(Data("RFB 003.008\n".utf8)) { return false }
        // 2. Security types: count = 1, type = 1 (None)
        if !send(Data([0x01, 0x01])) { return false }
        // 3. Security result: 0 (OK)
        if !send(uint32: 0) { return false }
        // 4. ServerInit: 2 bytes width, 2 bytes height, 16 bytes pixel format,
        //    4 bytes name length, N bytes name.
        var initMsg = Data()
        initMsg.append(contentsOf: width.bigEndianBytes)
        initMsg.append(contentsOf: height.bigEndianBytes)
        // BGRA32 pixel format (matches VNCSession.sendSetPixelFormat).
        initMsg.append(contentsOf: [
            32,  // bpp
            24,  // depth
            0,   // big-endian flag
            1,   // true-color
        ])
        initMsg.append(contentsOf: UInt16(255).bigEndianBytes)  // red-max
        initMsg.append(contentsOf: UInt16(255).bigEndianBytes)  // green-max
        initMsg.append(contentsOf: UInt16(255).bigEndianBytes)  // blue-max
        initMsg.append(16)  // red-shift
        initMsg.append(8)   // green-shift
        initMsg.append(0)   // blue-shift
        initMsg.append(contentsOf: [0, 0, 0])  // padding
        let nameData = Data(serverName.utf8)
        var nameLen = UInt32(nameData.count).bigEndian
        withUnsafeBytes(of: &nameLen) { initMsg.append(contentsOf: $0) }
        initMsg.append(nameData)
        return send(initMsg)
    }

    /// Send a single FramebufferUpdate message containing one Raw rect with
    /// the given pixel data (BGRA bytes, length must be `w*h*4`).
    func sendRawRect(x: UInt16, y: UInt16, w: UInt16, h: UInt16, bgra: Data) {
        var msg = Data()
        msg.append(0)              // message-type: FramebufferUpdate
        msg.append(0)              // padding
        msg.append(contentsOf: UInt16(1).bigEndianBytes)  // 1 rect
        msg.append(contentsOf: x.bigEndianBytes)
        msg.append(contentsOf: y.bigEndianBytes)
        msg.append(contentsOf: w.bigEndianBytes)
        msg.append(contentsOf: h.bigEndianBytes)
        msg.append(contentsOf: Int32(0).bigEndianBytes)   // encoding: Raw
        msg.append(bgra)
        send(msg)
    }

    /// Send a single FramebufferUpdate header with one rect whose bounding
    /// box is intentionally outside the framebuffer. The rect header is
    /// emitted so the client will read it and trip the bounds check.
    func sendOutOfBoundsRect(x: UInt16, y: UInt16, w: UInt16, h: UInt16) {
        var msg = Data()
        msg.append(0)
        msg.append(0)
        msg.append(contentsOf: UInt16(1).bigEndianBytes)
        msg.append(contentsOf: x.bigEndianBytes)
        msg.append(contentsOf: y.bigEndianBytes)
        msg.append(contentsOf: w.bigEndianBytes)
        msg.append(contentsOf: h.bigEndianBytes)
        msg.append(contentsOf: Int32(0).bigEndianBytes)   // Raw encoding
        // No pixel payload — the client should reject the rect before
        // trying to read it.
        send(msg)
    }

    /// Send a server-to-client message of an unknown type with a payload.
    /// The client's parser should hit the `default:` branch in `messageLoop`
    /// and throw (ISSUE-013).
    func sendUnknownMessage(type: UInt8, payload: Data = Data()) {
        var msg = Data()
        msg.append(type)
        msg.append(payload)
        send(msg)
    }

    /// Send an unsupported encoding within a FramebufferUpdate. A
    /// compliant client should reject it with a protocolError
    /// (ISSUE-013).
    func sendUnsupportedEncodingRect(x: UInt16, y: UInt16, w: UInt16, h: UInt16, encoding: Int32) {
        var msg = Data()
        msg.append(0)
        msg.append(0)
        msg.append(contentsOf: UInt16(1).bigEndianBytes)
        msg.append(contentsOf: x.bigEndianBytes)
        msg.append(contentsOf: y.bigEndianBytes)
        msg.append(contentsOf: w.bigEndianBytes)
        msg.append(contentsOf: h.bigEndianBytes)
        msg.append(contentsOf: encoding.bigEndianBytes)
        send(msg)
    }

    /// Send a FramebufferUpdate with zero rectangles — a minimal, valid
    /// reply used to answer a client's liveness probe without any real
    /// screen data.
    func sendEmptyFramebufferUpdate() {
        var msg = Data()
        msg.append(0)     // message-type: FramebufferUpdate
        msg.append(0)     // padding
        msg.append(contentsOf: UInt16(0).bigEndianBytes)  // 0 rects
        send(msg)
    }

    /// Send raw bytes to the connected client. Returns true if every byte
    /// was written; false if the peer has closed (EPIPE/ECONNRESET) or
    /// otherwise refused the write.
    @discardableResult
    func send(_ data: Data) -> Bool {
        guard clientFD >= 0 else { return false }
        // SO_NOSIGPIPE so writing to a peer-closed socket returns EPIPE
        // instead of killing the test process with SIGPIPE.
        var success = true
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(clientFD, base.advanced(by: written), data.count - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    success = false
                    return
                }
                if n == 0 {
                    success = false
                    return
                }
                written += n
            }
        }
        return success
    }

    private func send(uint32 value: UInt32) -> Bool {
        var v = value.bigEndian
        var ok = true
        withUnsafeBytes(of: &v) { ok = send(Data($0)) }
        return ok
    }

    /// Block until `count` bytes have been received from the client, or
    /// `timeout` elapses. Returns the bytes actually received.
    func receive(count: Int, timeout: TimeInterval = 2.0 * ciDeadlineScale) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            receivedBufferLock.lock()
            if receivedBuffer.count >= count {
                let out = receivedBuffer.prefix(count)
                receivedBuffer.removeFirst(count)
                receivedBufferLock.unlock()
                return Data(out)
            }
            receivedBufferLock.unlock()
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    /// Drop all buffered received bytes. Useful between phases of a test.
    func drainReceived() {
        receivedBufferLock.lock()
        receivedBuffer.removeAll(keepingCapacity: false)
        receivedBufferLock.unlock()
    }

    /// Stop the server, close the client and listener sockets.
    func stop() {
        stopped = true
        if clientFD >= 0 {
            shutdown(clientFD, SHUT_RDWR)
            close(clientFD)
            clientFD = -1
        }
        if listenFD >= 0 { close(listenFD) }
    }

    deinit {
        if clientFD >= 0 { close(clientFD) }
        if listenFD >= 0 { close(listenFD) }
    }
}

private extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
}

private extension Int32 {
    var bigEndianBytes: [UInt8] {
        let u = UInt32(bitPattern: self)
        return [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
    }
}
