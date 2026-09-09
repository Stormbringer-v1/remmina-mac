import Foundation

/// Spawns a child process attached to a pseudo-terminal, with the slave PTY as
/// the child's **controlling terminal**.
///
/// This is required for programs like `ssh` and `xfreerdp` that read passwords
/// via `/dev/tty` (OpenSSH `readpassphrase`, FreeRDP `freerdp_passphrase_read`)
/// rather than from stdin. A child that merely has the PTY slave duped onto
/// fds 0/1/2 — the previous approach — has no controlling terminal, so ssh
/// never emits a password prompt and denies immediately. We fix that by making
/// the child a session leader (`POSIX_SPAWN_SETSID`) and having it *open* the
/// slave by path (without `O_NOCTTY`), which acquires it as the controlling
/// terminal.
///
/// This type also owns child reaping. A detached thread blocks in `waitpid`
/// until the child exits; because it holds no strong reference to the caller, a
/// session object can be deallocated (e.g. a closed tab) without leaking the
/// child as a zombie — the reap still happens.
///
/// We use `posix_spawn` rather than a manual `fork()`+`login_tty()`+`execve()`
/// on purpose: `posix_spawn` performs the fork/exec inside libc, so there is no
/// window of Swift/ObjC runtime code running between fork and exec (which can
/// deadlock on locks held by other threads).
final class PTYProcess: @unchecked Sendable {

    struct SpawnError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The PTY master. Read remote output from it and write input (including a
    /// password) to it. -1 once closed.
    private(set) var masterFD: Int32 = -1
    /// The child pid, or -1 after `terminate()` / before launch.
    private(set) var pid: pid_t = -1

    /// Dispatch source for reading from the master PTY.
    private var readSource: DispatchSourceRead?

    /// Dedicated serial queue for non-blocking I/O (writes, window resize).
    private let ioQueue = DispatchQueue(label: "com.remmina-mac.pty.io", qos: .userInitiated)

    /// Dispatch source for draining the write buffer when masterFD is writable.
    private var writeSource: DispatchSourceWrite?

    /// Outbound buffer for masterFD writes, touched only on ioQueue.
    private var outboundBuffer = Data()

    /// Maximum outbound buffer size (4 MiB).
    private static let maxOutboundBufferBytes = 4 * 1024 * 1024

    /// Box for coordinating SIGKILL escalation on terminate.
    private final class KillCoordinationBox: @unchecked Sendable {
        private let lock = NSLock()
        var workItem: DispatchWorkItem?

        func cancelWorkItem() {
            lock.lock()
            workItem?.cancel()
            workItem = nil
            lock.unlock()
        }

        func setWorkItem(_ item: DispatchWorkItem) {
            lock.lock()
            workItem = item
            lock.unlock()
        }
    }

    /// Checks if echo is enabled on the slave terminal attached to masterFD.
    /// Returns nil if masterFD is closed or tcgetattr fails; false if ECHO is off; true otherwise.
    /// Reads masterFD under ioQueue to stay consistent with the read handler's
    /// EOF teardown and closeMaster(), both of which mutate it there (ISSUE-031c).
    func echoEnabled() -> Bool? {
        let fd = ioQueue.sync { masterFD }
        var t = termios()
        guard fd >= 0, tcgetattr(fd, &t) == 0 else { return nil }
        return (t.c_lflag & UInt(ECHO)) != 0
    }

    /// Test hook (ISSUE-031): true if a DispatchSourceWrite is currently armed
    /// on the master fd. Not for production use by session code.
    var hasArmedWriteSource: Bool {
        ioQueue.sync { writeSource != nil }
    }

    /// Launches `path` with `args` (argv[0] is set to `path`) and `env`
    /// (KEY=VALUE pairs). On success `masterFD` and `pid` are populated and
    /// `onExit` is invoked exactly once, on `onExitQueue`, with the decoded
    /// exit code when the child terminates. The child is reaped internally.
    func launch(path: String,
                args: [String],
                env: [String: String],
                onExit: @escaping (Int32) -> Void,
                onExitQueue: DispatchQueue = .main) throws {
        // Enforce single-launch per instance (ISSUE-010)
        guard pid < 0 && masterFD < 0 else {
            throw SpawnError(message: "PTYProcess already launched")
        }

        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw SpawnError(message: "Failed to allocate a pseudo-terminal (openpty)")
        }
        guard let slaveNameC = ptsname(master) else {
            close(master); close(slave)
            throw SpawnError(message: "Failed to resolve the pseudo-terminal path (ptsname)")
        }
        let slavePath = String(cString: slaveNameC)

        var attr = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Reset every signal to its default disposition and clear the signal mask
        // in the child. Without this the child inherits any signal the parent set
        // to ignore — the Swift/AppKit runtime ignores several — so a later
        // `kill(pid, SIGTERM)` on teardown would be silently ignored and the
        // child (ssh/xfreerdp) would never terminate.
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attr, &defaultSignals)
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        posix_spawnattr_setsigmask(&attr, &emptyMask)

        // POSIX_SPAWN_SETSID makes the child a session leader; combined with it
        // opening the slave tty below (without O_NOCTTY), the slave becomes the
        // child's controlling terminal — required so ssh/xfreerdp will prompt.
        // POSIX_SPAWN_CLOEXEC_DEFAULT (0x4000 on macOS) ensures all file descriptors
        // other than those explicitly mapped in file actions are closed on exec (ISSUE-010).
        let cloexecFlag: Int32 = 0x4000 // POSIX_SPAWN_CLOEXEC_DEFAULT
        let flags = Int16(POSIX_SPAWN_SETSID) |
                    Int16(POSIX_SPAWN_SETSIGDEF) |
                    Int16(POSIX_SPAWN_SETSIGMASK) |
                    Int16(truncatingIfNeeded: cloexecFlag)
        posix_spawnattr_setflags(&attr, flags)

        var actions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Open the slave as fd 0 -> acquires the controlling terminal, then
        // mirror it onto stdout/stderr.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        // With POSIX_SPAWN_CLOEXEC_DEFAULT, explicit addclose calls for master/slave are redundant,
        // but harmless.

        var cArgs: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            for p in cArgs where p != nil { free(p) }
            for p in cEnv where p != nil { free(p) }
        }

        var childPid: pid_t = 0
        let rc = posix_spawn(&childPid, path, &actions, &attr, cArgs, cEnv)

        // The parent never uses the slave; the child has its own copy.
        close(slave)

        guard rc == 0 else {
            close(master)
            throw SpawnError(message: "posix_spawn failed: \(String(cString: strerror(rc)))")
        }

        self.masterFD = master
        self.pid = childPid

        // Detached reaper. Holds no reference to any session object or self,
        // so it survives deallocation and always reaps the child.
        let killBox = KillCoordinationBox()
        self.activeKillBox = killBox

        Thread.detachNewThread {
            var status: Int32 = 0
            _ = waitpid(childPid, &status, 0)
            killBox.cancelWorkItem()
            let code = PTYProcess.decodeExitStatus(status)
            onExitQueue.async { onExit(code) }
        }
    }

    private var activeKillBox: KillCoordinationBox?

    /// Starts reading from masterFD using DispatchSourceRead.
    /// Closes masterFD in the cancel handler so no race can read an already-closed or reused fd.
    func startReading(queue: DispatchQueue,
                      onData: @escaping (Data) -> Void,
                      onEOF: @escaping () -> Void) {
        // Read masterFD and check readSource under ioQueue: closeMasterLocked() (called from
        // the EOF branch below and from closeMaster()) mutates both there, and this call may
        // run on an arbitrary caller thread (ISSUE-031c).
        let fd: Int32 = ioQueue.sync {
            guard masterFD >= 0, readSource == nil else { return -1 }
            return masterFD
        }
        guard fd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)

        source.setCancelHandler {
            Foundation.close(fd)
        }

        source.setEventHandler { [weak self, weak source] in
            guard let self = self, source != nil else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytesRead = Foundation.read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                let data = Data(buffer[0..<bytesRead])
                onData(data)
            } else if bytesRead < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                    return
                }
                // EOF or error: cancel immediately to avoid busy-spin on level-triggered source (ISSUE-009).
                // Route through closeMasterLocked() on ioQueue so writeSource (which may still be
                // armed if the outbound buffer had not drained) is torn down atomically with
                // readSource/masterFD instead of being left dangling on a closed fd (ISSUE-031a/c).
                self.ioQueue.sync { self.closeMasterLocked() }
                onEOF()
            } else {
                // bytesRead == 0 (EOF)
                self.ioQueue.sync { self.closeMasterLocked() }
                onEOF()
            }
        }

        ioQueue.sync { self.readSource = source }
        source.resume()
    }

    /// Asynchronously writes bytes to the PTY master on the dedicated ioQueue (ISSUE-011).
    /// Handles partial writes and buffers overflow with non-blocking draining.
    @discardableResult
    func write(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        ioQueue.async { [weak self] in
            guard let self = self, self.masterFD >= 0 else { return }
            self.appendAndDrain(data)
        }
        return true
    }

    /// Drains outboundBuffer to masterFD. Must be invoked on ioQueue.
    private func appendAndDrain(_ data: Data) {
        let fd = masterFD
        let curFlags = fcntl(fd, F_GETFL, 0)
        if curFlags >= 0 && (curFlags & O_NONBLOCK) == 0 {
            _ = fcntl(fd, F_SETFL, curFlags | O_NONBLOCK)
        }

        if outboundBuffer.count + data.count > Self.maxOutboundBufferBytes {
            AppLogger.shared.log("PTYProcess outbound buffer exceeded 4MB; dropping oldest bytes", level: .warning)
            let excess = (outboundBuffer.count + data.count) - Self.maxOutboundBufferBytes
            if excess < outboundBuffer.count {
                outboundBuffer.removeFirst(excess)
            } else {
                outboundBuffer.removeAll(keepingCapacity: false)
            }
        }
        outboundBuffer.append(data)
        drainWriteBuffer()
    }

    /// Attempts to write outboundBuffer into masterFD until EAGAIN / blocked.
    /// Must be invoked on ioQueue (via appendAndDrain or the writeSource event handler).
    private func drainWriteBuffer() {
        guard masterFD >= 0, !outboundBuffer.isEmpty else {
            writeSource?.cancel()
            writeSource = nil
            return
        }

        let fd = masterFD
        // Snapshot the buffer and run the write loop over the snapshot's own
        // storage. Mutating outboundBuffer (removeFirst/removeAll) happens only
        // after withUnsafeBytes returns, never while its pointer is borrowed —
        // mutating a collection under its own borrowed buffer pointer is an
        // exclusive-access violation (ISSUE-031b).
        let snapshot = outboundBuffer
        var offset = 0
        var hardError = false
        snapshot.withUnsafeBytes { rawPtr in
            guard let base = rawPtr.baseAddress else { return }
            while offset < snapshot.count {
                let bytesLeft = snapshot.count - offset
                let n = Foundation.write(fd, base + offset, bytesLeft)
                if n > 0 {
                    offset += n
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    break
                } else {
                    // Write error (EPIPE, EBADF, etc.)
                    hardError = true
                    break
                }
            }
        }

        if hardError {
            outboundBuffer.removeAll()
            writeSource?.cancel()
            writeSource = nil
            return
        }
        if offset > 0 {
            outboundBuffer.removeFirst(offset)
        }

        if outboundBuffer.isEmpty {
            writeSource?.cancel()
            writeSource = nil
        } else if writeSource == nil {
            // Need a write source to notify when writable again
            let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: ioQueue)
            source.setEventHandler { [weak self] in
                self?.drainWriteBuffer()
            }
            source.setCancelHandler { [weak self] in
                self?.writeSource = nil
            }
            self.writeSource = source
            source.resume()
        }
    }

    /// Resizes the terminal via TIOCSWINSZ on the serial ioQueue (ISSUE-009 / ISSUE-011).
    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        ioQueue.async { [weak self] in
            guard let self = self, self.masterFD >= 0 else { return }
            var winSize = winsize(
                ws_row: UInt16(clamping: rows),
                ws_col: UInt16(clamping: cols),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            _ = ioctl(self.masterFD, TIOCSWINSZ, &winSize)
        }
    }

    /// Sends SIGTERM to the child with SIGKILL escalation after `gracePeriod` seconds (ISSUE-010).
    func terminate(gracePeriod: TimeInterval = 3) {
        let childPid = pid
        guard childPid > 0 else { return }
        kill(childPid, SIGTERM)
        pid = -1

        let box = activeKillBox
        let killItem = DispatchWorkItem {
            if kill(childPid, 0) == 0 {
                kill(childPid, SIGKILL)
            }
        }
        box?.setWorkItem(killItem)
        DispatchQueue.global().asyncAfter(deadline: .now() + gracePeriod, execute: killItem)
    }

    /// Cancels writeSource, clears outboundBuffer, cancels readSource, and closes
    /// the fd exactly once (ISSUE-031a/c). Must be called while already executing
    /// on `ioQueue` — callers are responsible for the `ioQueue.sync`/`async` wrap.
    /// Idempotent: safe to call again once readSource is nil and masterFD is -1.
    private func closeMasterLocked() {
        writeSource?.cancel()
        writeSource = nil
        outboundBuffer.removeAll()

        if let source = readSource {
            readSource = nil
            masterFD = -1
            source.cancel() // Cancel handler closes the fd
        } else if masterFD >= 0 {
            Foundation.close(masterFD)
            masterFD = -1
        }
    }

    /// Closes the PTY master and cancels all read/write sources and pending writes (ISSUE-009).
    /// Routes through closeMasterLocked() on ioQueue so this is safe to call even if the
    /// EOF path (startReading's event handler) has already torn things down (ISSUE-031a).
    func closeMaster() {
        ioQueue.sync {
            closeMasterLocked()
        }
    }

    /// Decodes a `waitpid` status into a conventional exit code (128+signal for
    /// signal deaths, matching shell conventions).
    static func decodeExitStatus(_ status: Int32) -> Int32 {
        if (status & 0x7f) == 0 {
            return (status >> 8) & 0xff
        } else {
            return 128 + (status & 0x7f)
        }
    }
}
