import Testing
import Foundation
@testable import RemminaMac

/// Behavioral tests for the shared PTY spawner. Unlike the source-grep "audit"
/// tests, these actually spawn a child and observe the properties that the
/// SSH/RDP credential path and teardown depend on:
///   1. the child is given a controlling terminal (so ssh/xfreerdp will prompt);
///   2. the child is reaped when it exits, even after `terminate()`, so a closed
///      session never leaks a zombie;
///   3. `PTYProcess.echoEnabled()` reflects slave ECHO state;
///   4. Bounded handler invocations after child exits;
///   5. SIGKILL escalation terminates stubborn processes;
///   6. Multiple launches on the same instance are rejected;
///   7. Inherited file descriptors other than 0, 1, 2 are closed on exec;
///   8. Non-blocking write handling and large write integrity.
@Suite("PTYProcess behavior")
struct PTYProcessTests {

    /// Thread-safe one-shot box for capturing values.
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ v: T) { value = v }
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("Child is given a controlling terminal (tty resolves to the slave)")
    func testChildHasControllingTerminal() throws {
        let pty = PTYProcess()
        let sem = DispatchSemaphore(value: 0)
        let code = Box<Int32?>(nil)

        try pty.launch(path: "/bin/sh",
                       args: ["-c", "tty"],
                       env: ["TERM": "xterm"],
                       onExit: { c in code.set(c); sem.signal() },
                       onExitQueue: .global())

        let outputBox = Box<Data>(Data())
        let eofSem = DispatchSemaphore(value: 0)

        pty.startReading(queue: .global(), onData: { chunk in
            var current = outputBox.get()
            current.append(chunk)
            outputBox.set(current)
        }, onEOF: {
            eofSem.signal()
        })

        _ = sem.wait(timeout: .now() + 3)
        _ = eofSem.wait(timeout: .now() + 1)
        #expect(code.get() == 0, "`tty` should exit 0")

        let text = String(data: outputBox.get(), encoding: .utf8) ?? ""
        #expect(text.contains("/dev/tty"), "child stdin should be a controlling tty; got: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(!text.lowercased().contains("not a tty"))

        pty.closeMaster()
    }

    @Test("Child is reaped after terminate() — no zombie is left behind")
    func testChildReapedNoZombie() throws {
        let pty = PTYProcess()
        let sem = DispatchSemaphore(value: 0)

        try pty.launch(path: "/bin/sleep",
                       args: ["30"],
                       env: [:],
                       onExit: { _ in sem.signal() },
                       onExitQueue: .global())

        let childPid = pty.pid
        #expect(childPid > 0)

        pty.terminate()

        let fired = sem.wait(timeout: .now() + 5)
        #expect(fired == .success, "onExit must fire after terminate()")

        var status: Int32 = 0
        let reapedAgain = waitpid(childPid, &status, WNOHANG)
        #expect(reapedAgain == -1, "child should already be reaped (no zombie); waitpid returned \(reapedAgain)")

        pty.closeMaster()
    }

    // MARK: - ISSUE-005: echoEnabled tests

    @Test("echoEnabled reflects stty -echo state (ISSUE-005)")
    func testEchoEnabledReflectsStty() throws {
        let pty = PTYProcess()
        let sem = DispatchSemaphore(value: 0)

        try pty.launch(path: "/bin/sh",
                       args: ["-c", "stty -echo; sleep 1"],
                       env: ["TERM": "xterm"],
                       onExit: { _ in sem.signal() },
                       onExitQueue: .global())

        // Wait for stty -echo to take effect (poll up to 2s under load)
        let start = CFAbsoluteTimeGetCurrent()
        var echoState = pty.echoEnabled()
        while echoState != false && (CFAbsoluteTimeGetCurrent() - start) < 2.0 {
            usleep(20_000)
            echoState = pty.echoEnabled()
        }
        #expect(echoState == false, "echoEnabled() should return false when stty -echo has run")

        _ = sem.wait(timeout: .now() + 3)
        pty.closeMaster()

        #expect(pty.echoEnabled() == nil, "echoEnabled() should return nil when master is closed")
    }

    // MARK: - ISSUE-009: Bounded read-handler invocations on EOF

    @Test("Read handler runs bounded number of times after child exits (ISSUE-009)")
    func testBoundedReadInvocationsOnEOF() throws {
        let pty = PTYProcess()
        let exitSem = DispatchSemaphore(value: 0)
        let invocationCount = Box<Int>(0)

        try pty.launch(path: "/bin/sh",
                       args: ["-c", "exit 0"],
                       env: [:],
                       onExit: { _ in exitSem.signal() },
                       onExitQueue: .global())

        let eofSem = DispatchSemaphore(value: 0)
        pty.startReading(queue: .global(), onData: { _ in
            invocationCount.set(invocationCount.get() + 1)
        }, onEOF: {
            eofSem.signal()
        })

        _ = exitSem.wait(timeout: .now() + 2)
        _ = eofSem.wait(timeout: .now() + 2)

        // Count invocations over 500 ms
        usleep(500_000)
        #expect(invocationCount.get() < 5, "Handler invocations must be bounded (< 5); was \(invocationCount.get())")

        pty.closeMaster()
    }

    // MARK: - ISSUE-010: SIGKILL Escalation, Re-launch rejection, Close-on-exec

    @Test("terminate() escalates to SIGKILL for processes that ignore SIGTERM (ISSUE-010)")
    func testSigkillEscalation() throws {
        let pty = PTYProcess()
        let sem = DispatchSemaphore(value: 0)

        try pty.launch(path: "/bin/sh",
                       args: ["-c", "trap '' TERM; sleep 60"],
                       env: [:],
                       onExit: { _ in sem.signal() },
                       onExitQueue: .global())

        let childPid = pty.pid
        #expect(childPid > 0)

        // Give the shell a moment to set up trap
        usleep(200_000)

        // Terminate with 1s grace period for test speed
        pty.terminate(gracePeriod: 1.0)

        let fired = sem.wait(timeout: .now() + 5)
        #expect(fired == .success, "onExit must fire within 5s following SIGKILL escalation")

        var status: Int32 = 0
        let reapedAgain = waitpid(childPid, &status, WNOHANG)
        #expect(reapedAgain == -1, "waitpid(pid, WNOHANG) should return -1 after reap")

        pty.closeMaster()
    }

    @Test("Second launch on same PTYProcess instance throws SpawnError (ISSUE-010)")
    func testSecondLaunchThrows() throws {
        let pty = PTYProcess()
        let sem = DispatchSemaphore(value: 0)

        try pty.launch(path: "/bin/sleep",
                       args: ["1"],
                       env: [:],
                       onExit: { _ in sem.signal() },
                       onExitQueue: .global())

        #expect(throws: PTYProcess.SpawnError.self) {
            try pty.launch(path: "/bin/sleep",
                           args: ["1"],
                           env: [:],
                           onExit: { _ in },
                           onExitQueue: .global())
        }

        pty.terminate()
        _ = sem.wait(timeout: .now() + 2)
        pty.closeMaster()
    }

    @Test("Child inherits no unexpected file descriptors (ISSUE-010)")
    func testCloseOnExecDevFd() throws {
        let pty = PTYProcess()
        let sem = DispatchSemaphore(value: 0)

        try pty.launch(path: "/bin/sh",
                       args: ["-c", "ls /dev/fd"],
                       env: [:],
                       onExit: { _ in sem.signal() },
                       onExitQueue: .global())

        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(pty.masterFD, &buffer, buffer.count)
            if n > 0 { out.append(buffer, count: n) } else { break }
        }
        let output = String(data: out, encoding: .utf8) ?? ""
        _ = sem.wait(timeout: .now() + 3)
        pty.closeMaster()

        // /dev/fd will list 0, 1, 2, and up to 2 descriptors opened by ls itself (cwd and dirfd)
        let entries = output.components(separatedBy: .whitespacesAndNewlines)
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

        let fdsGe3 = entries.filter { $0 >= 3 }
        #expect(fdsGe3.count <= 2, "Child should see at most two fds >= 3 (opened by ls itself); saw: \(fdsGe3)")
    }

    // MARK: - ISSUE-011: Non-blocking writes and integrity

    @Test("sendInput returns quickly during sleep (ISSUE-011)")
    func testSendInputNonBlocking() throws {
        let pty = PTYProcess()
        let sem = DispatchSemaphore(value: 0)

        try pty.launch(path: "/bin/sh",
                       args: ["-c", "sleep 30"],
                       env: [:],
                       onExit: { _ in sem.signal() },
                       onExitQueue: .global())

        let largeData = Data(repeating: 0x41, count: 256 * 1024) // 256 KiB
        let start = CFAbsoluteTimeGetCurrent()
        pty.write(largeData)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        #expect(elapsed < 0.050, "pty.write(256 KiB) must return in under 50ms; took \(elapsed)s")

        pty.terminate()
        _ = sem.wait(timeout: .now() + 2)
        pty.closeMaster()
    }

    @Test("Writing 256 KiB to cat yields exactly 256 KiB without drops (ISSUE-011)")
    func testWrite256KiBToCat() throws {
        let pty = PTYProcess()
        let exitSem = DispatchSemaphore(value: 0)

        try pty.launch(path: "/bin/sh",
                       args: ["-c", "stty raw -echo; exec /bin/cat"],
                       env: [:],
                       onExit: { _ in exitSem.signal() },
                       onExitQueue: .global())

        let expectedSize = 256 * 1024
        let testData = Data((0..<expectedSize).map { UInt8($0 % 256) })

        let readDataBox = Box<Data>(Data())
        let eofSem = DispatchSemaphore(value: 0)

        pty.startReading(queue: .global(), onData: { chunk in
            var current = readDataBox.get()
            current.append(chunk)
            readDataBox.set(current)
        }, onEOF: {
            eofSem.signal()
        })

        // Allow child shell to execute stty and exec cat
        usleep(100_000)

        // Write test data in chunks to cat
        pty.write(testData)

        // Allow some time for drain to settle
        let start = CFAbsoluteTimeGetCurrent()
        while readDataBox.get().count < expectedSize && (CFAbsoluteTimeGetCurrent() - start) < 5.0 {
            usleep(10_000)
        }

        let readCount = readDataBox.get().count
        #expect(readCount >= expectedSize, "Should read back at least 256 KiB from cat; got \(readCount)")
        let receivedPrefix = readDataBox.get().prefix(expectedSize)
        let matches = (receivedPrefix == testData)
        #expect(matches, "Data read back must match data written")

        pty.terminate()
        _ = exitSem.wait(timeout: .now() + 2)
        pty.closeMaster()
    }
}
