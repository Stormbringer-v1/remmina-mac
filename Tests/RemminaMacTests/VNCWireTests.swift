import Testing
import Foundation
import AppKit
@testable import RemminaMac

/// Behavioral tests for the VNC wire parser. Each test stands up a
/// `FakeVNCServer` on 127.0.0.1, drives a `VNCSession` through a
/// scripted RFB 3.8 handshake, and asserts on the observable state
/// (status, framebuffer contents, callback invocations).
///
/// These tests cover the acceptance criteria from PROBLEMS.md:
///   - ISSUE-007: .error states are not clobbered by disconnect
///   - ISSUE-012: read loop cancels within 1 s, session deallocates
///   - ISSUE-013: unknown message type / unsupported encoding → .error
///   - ISSUE-014: writeData precondition is onQueue(writeQueue)
///   - ISSUE-020: VNC parser bounds, no-op-only behavior
@Suite("VNC Wire Protocol — FakeVNCServer")
struct VNCWireTests {

    /// Helper: build a VNCSession whose profile points at a 127.0.0.1
    /// ephemeral port (the FakeVNCServer we just started).
    private func makeSession(
        host: String = "127.0.0.1",
        port: UInt16,
        name: String = "WireTest",
        password: String? = nil
    ) -> VNCSession {
        let profile = ConnectionProfile(
            name: name,
            protocolType: .vnc,
            host: host,
            port: Int(port)
        )
        return VNCSession(profile: profile, password: password)
    }

    /// Pump the main run loop until `predicate` returns true or `timeout`
    /// elapses. Many VNC side-effects (`status` mutations, callback
    /// dispatches) are bounced to `DispatchQueue.main.async`, so a
    /// test that connects and immediately reads `status` will see the
    /// pre-connection value. This helper lets us wait for them.
    private func waitFor(_ predicate: () -> Bool,
                         timeout: TimeInterval = 3.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            // Drain the main run loop so async dispatches can run.
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    // MARK: - ISSUE-020: oversize framebuffer dimensions → .error

    @Test("VNC: oversize framebuffer dimensions are rejected with .error")
    func testOversizeFramebufferDimensionsRejected() throws {
        let server = try FakeVNCServer.start()
        defer { server.stop() }
        let session = makeSession(port: server.port, name: "OversizeDims")
        session.connect()
        #expect(server.waitForClient())
        // Send ServerInit with 65535 x 65535 — both exceed
        // VNCSession.maxFramebufferDimension (8192).
        server.sendHandshake(serverName: "Oversize", width: 65535, height: 65535)
        let sawError = waitFor({
            if case .error(let msg) = session.status {
                return msg.contains("out of range")
            }
            return false
        })
        #expect(sawError, "Expected .error mentioning dimensions out of range, got \(session.status)")
        session.disconnect()
    }

    // MARK: - ISSUE-020: rectangle outside framebuffer → .error

    @Test("VNC: rect outside the framebuffer is rejected with .error")
    func testOutOfBoundsRectRejected() throws {
        let server = try FakeVNCServer.start()
        defer { server.stop() }
        let session = makeSession(port: server.port, name: "OOBRect")
        var updateReceived = false
        session.onFramebufferUpdate = { _, _ in updateReceived = true }
        session.connect()
        #expect(server.waitForClient())
        // 32 x 32 framebuffer; rect at (10, 10) sized 64 x 64 extends
        // past the right and bottom edges.
        server.sendHandshake(serverName: "OOB", width: 32, height: 32)
        Thread.sleep(forTimeInterval: 0.2)
        server.sendOutOfBoundsRect(x: 10, y: 10, w: 64, h: 64)
        let sawError = waitFor({
            if case .error = session.status { return true }
            return false
        })
        #expect(sawError, "Expected .error for out-of-bounds rect, got \(session.status)")
        #expect(!updateReceived, "onFramebufferUpdate must not fire for a rejected rect")
        session.disconnect()
    }

    // MARK: - ISSUE-013: unknown server message type → .error

    @Test("VNC: unknown server message type ends the session with .error")
    func testUnknownMessageTypeRejected() throws {
        let server = try FakeVNCServer.start()
        defer { server.stop() }
        let session = makeSession(port: server.port, name: "UnknownMsg")
        session.connect()
        #expect(server.waitForClient())
        server.sendHandshake(serverName: "Unknown", width: 16, height: 16)
        Thread.sleep(forTimeInterval: 0.2)
        // Type 99 is outside the spec's 0..3 range.
        server.sendUnknownMessage(type: 99, payload: Data([0xDE, 0xAD, 0xBE, 0xEF]))
        let sawError = waitFor({
            if case .error(let msg) = session.status {
                return msg.contains("Unknown server message type 99")
            }
            return false
        })
        #expect(sawError, "Expected .error mentioning the unknown type, got \(session.status)")
        session.disconnect()
    }

    // MARK: - ISSUE-013: unsupported encoding → .error

    @Test("VNC: unsupported rectangle encoding ends the session with .error")
    func testUnsupportedEncodingRejected() throws {
        let server = try FakeVNCServer.start()
        defer { server.stop() }
        let session = makeSession(port: server.port, name: "UnsupportedEnc")
        session.connect()
        #expect(server.waitForClient())
        server.sendHandshake(serverName: "Unsupported", width: 32, height: 32)
        Thread.sleep(forTimeInterval: 0.2)
        // Encoding 16 is reserved/unimplemented (we only do Raw and CopyRect).
        server.sendUnsupportedEncodingRect(x: 0, y: 0, w: 4, h: 4, encoding: 16)
        let sawError = waitFor({
            if case .error(let msg) = session.status {
                return msg.contains("Unsupported encoding 16")
            }
            return false
        })
        #expect(sawError, "Expected .error mentioning the unsupported encoding, got \(session.status)")
        session.disconnect()
    }

    // MARK: - ISSUE-020: valid Raw rect → onFramebufferUpdate fires

    @Test("VNC: valid Raw rect fires onFramebufferUpdate with the expected pixel")
    func testValidRawRectFiresUpdate() throws {
        let server = try FakeVNCServer.start()
        defer { server.stop() }
        let session = makeSession(port: server.port, name: "ValidRaw")
        // Hold the captured state in a thread-safe box; the update
        // callback runs on the main queue.
        let captured = CapturedUpdate()
        session.onFramebufferUpdate = { image, rect in
            captured.set(image: image, rect: rect)
        }
        session.connect()
        #expect(server.waitForClient())
        server.sendHandshake(serverName: "Valid", width: 16, height: 16)
        // Wait for the session to become .connected.
        #expect(waitFor({ session.status == .connected }))

        // 2x2 rect at (3, 3), each pixel BGRA (0, 0, 255, 255) — opaque red.
        let bgra = Data([0x00, 0x00, 0xFF, 0xFF,
                         0x00, 0x00, 0xFF, 0xFF,
                         0x00, 0x00, 0xFF, 0xFF,
                         0x00, 0x00, 0xFF, 0xFF])
        server.sendRawRect(x: 3, y: 3, w: 2, h: 2, bgra: bgra)
        #expect(waitFor({ captured.image != nil }))

        let rect = captured.rect ?? .zero
        #expect(rect == NSRect(x: 3, y: 3, width: 2, height: 2),
                "Dirty rect should be the union of the handled rects, got \(rect)")

        // Spot-check the pixel at (3, 3) in the rendered image. The
        // image is a CGImage-backed NSImage; we can read a pixel via
        // CGImageSource.
        guard let image = captured.image else {
            Issue.record("Image was not delivered")
            return
        }
        let pixel = readPixel(image: image, x: 3, y: 3)
        #expect(pixel == Pixel(r: 0xFF, g: 0x00, b: 0x00, a: 0xFF),
                "Pixel at (3, 3) should be opaque red, got \(String(describing: pixel))")
        session.disconnect()
    }

    // MARK: - ISSUE-007: .error is not clobbered by disconnect

    @Test("VNC: a user-initiated disconnect does not overwrite a .error state")
    func testDisconnectDoesNotClobberError() throws {
        let server = try FakeVNCServer.start()
        defer { server.stop() }
        let session = makeSession(port: server.port, name: "DontClobber")
        session.connect()
        #expect(server.waitForClient())
        server.sendHandshake(serverName: "X", width: 65535, height: 65535)
        #expect(waitFor({ if case .error = session.status { return true }; return false }))
        // Capture the error message, then disconnect.
        let before: SessionStatus = session.status
        session.disconnect()
        // After disconnect, the status must still be .error, NOT .disconnected.
        let after: SessionStatus = session.status
        if case .error = before, case .error = after {
            // pass
        } else {
            Issue.record("disconnect() clobbered .error: before=\(before) after=\(after)")
        }
    }

    // MARK: - ISSUE-012: disconnect unblocks a stuck read within ~1s

    @Test("VNC: disconnect() unblocks a stuck read and deallocates the session")
    func testDisconnectUnblocksStuckRead() throws {
        let server = try FakeVNCServer.start()
        defer { server.stop() }
        var session: VNCSession? = makeSession(port: server.port, name: "StuckRead")
        weak var weakSession = session
        session?.connect()
        #expect(server.waitForClient())
        // Send the version banner so the read advances past the
        // handshake, but then stop sending bytes — `read` will block.
        server.send(Data("RFB 003.008\n".utf8))
        Thread.sleep(forTimeInterval: 0.3)

        let t0 = Date()
        session?.disconnect()
        // The read thread observes the running flag flip / socket
        // shutdown(SHUT_RDWR) and returns. We give it up to 2 s.
        let disconnected = waitFor({
            if case .disconnected = session?.status { return true }
            if case .error = session?.status { return true }
            return false
        }, timeout: 2.0)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(disconnected, "session did not reach .disconnected within 2s")
        #expect(elapsed < 2.0, "disconnect took \(elapsed)s, expected < 2s")

        // Drop the local strong reference so only the read thread's reference (if any) remains.
        session = nil

        // Poll for deallocation
        let start = CFAbsoluteTimeGetCurrent()
        while weakSession != nil && (CFAbsoluteTimeGetCurrent() - start) < 2.0 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            usleep(20_000)
        }
        #expect(weakSession == nil,
                "session did not deallocate after disconnect (still strongly held)")
    }

    // MARK: - ISSUE-028: hostname resolution via getaddrinfo

    @Test("VNCSession reaches a loopback server by IP literal")
    func vncByIP() async throws {
        let server = try FakeVNCServer.start(); defer { server.stop() }
        let p = ConnectionProfile(name: "ip", protocolType: .vnc, host: "127.0.0.1", port: Int(server.port))
        let s = VNCSession(profile: p, password: nil); s.connect()
        #expect(server.waitForClient(timeout: 3.0) == true)
    }

    @Test("VNCSession reaches the same server by hostname 'localhost'")
    func vncByHostname() async throws {
        let server = try FakeVNCServer.start(); defer { server.stop() }
        let p = ConnectionProfile(name: "name", protocolType: .vnc, host: "localhost", port: Int(server.port))
        let s = VNCSession(profile: p, password: nil); s.connect()
        #expect(server.waitForClient(timeout: 3.0) == true)
    }

    @Test("VNC: a non-resolving hostname reaches .error within 5s, not a 75s hang")
    func testNonResolvingHostReachesErrorQuickly() throws {
        let session = makeSession(host: "this-host-does-not-exist.invalid", port: 12345, name: "BadHost")
        let t0 = Date()
        session.connect()
        let sawError = waitFor({
            if case .error = session.status { return true }
            return false
        }, timeout: 5.0)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(sawError, "Expected .error for a non-resolving host, got \(session.status)")
        #expect(elapsed < 5.0, "Resolution failure took \(elapsed)s, expected < 5s")
        session.disconnect()
    }

    @Test("VNC: a blackholed SYN reaches .error within the connect deadline, and the read thread exits")
    func testBlackholedConnectReachesErrorAndReadThreadExits() throws {
        // 192.0.2.0/24 is TEST-NET-1 (RFC 5737) — reserved for
        // documentation, never routed. A SYN to it is dropped rather than
        // RST'd or refused, so `connect()` never resolves on its own; this
        // is the standard way to test a connect timeout without relying on
        // a specific unreachable-but-still-somehow-responsive host.
        // Confirmed on this machine: `connect()` to it does not return
        // within 15s (an OS-level `nc -w 2 -z 192.0.2.13 3389` still hung
        // well past its own 2s flag), so this genuinely exercises
        // `attemptConnect`'s `waitForConnect` EINPROGRESS/poll path rather
        // than an immediate ECONNREFUSED.
        var session: VNCSession? = makeSession(host: "192.0.2.13", port: 3389, name: "Blackhole")
        weak var weakSession = session
        // Inject a short connect deadline so the test doesn't wait out the
        // real 15s (PROBLEMS.md ISSUE-028's remediation guide applies the
        // same "make it injectable" pattern used for readTimeoutSeconds).
        session?.connectionTimeoutSeconds = 2.0
        let t0 = Date()
        session?.connect()
        let sawError = waitFor({
            if case .error = session?.status { return true }
            return false
        }, timeout: 5.0)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(sawError, "Expected .error for a blackholed SYN, got \(String(describing: session?.status))")
        #expect(elapsed < 4.0, "Blackholed connect took \(elapsed)s to fail, expected just over the 2s deadline")

        // Drop the local strong reference; the read thread must have
        // already exited (and released its own `self` capture) by the
        // time attemptConnect's deadline fired, or this session leaks
        // for up to ~75s (the OS's own TCP connect timeout) — exactly
        // the ISSUE-028 defect this test guards against.
        session = nil
        let start = CFAbsoluteTimeGetCurrent()
        while weakSession != nil && (CFAbsoluteTimeGetCurrent() - start) < 2.0 {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            usleep(20_000)
        }
        #expect(weakSession == nil, "session did not deallocate after a blackholed connect timed out")
    }

    // MARK: - ISSUE-029: the read deadline actually applies

    @Test("VNC: a server that completes the handshake and then goes silent reaches .error just after 2x the read deadline")
    func testReadDeadlineFires() throws {
        let server = try FakeVNCServer.start()
        defer { server.stop() }
        let session = makeSession(port: server.port, name: "SilentServer")
        // Inject a short deadline so this test doesn't wait out the real
        // 30s default.
        session.readTimeoutSeconds = 1
        session.connect()
        #expect(server.waitForClient())
        server.sendHandshake(serverName: "Silent", width: 16, height: 16)
        #expect(waitFor({ session.status == .connected }))

        // Server goes silent from here on — no more bytes. The first
        // idle read timeout (~1s) now sends a liveness probe instead of
        // failing outright; only a second, unanswered timeout (~another
        // 1s) is fatal, so the error arrives after roughly 2x
        // readTimeoutSeconds rather than 1x.
        let t0 = Date()
        let sawError = waitFor({
            if case .error = session.status { return true }
            return false
        }, timeout: 6.0 * ciDeadlineScale)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(sawError, "Expected .error after the read deadline, got \(session.status)")
        #expect(elapsed > 1.2, "Read deadline fired after only \(elapsed)s — expected it to survive the first idle timeout via a liveness probe")
        #expect(elapsed < 5.0 * ciDeadlineScale, "Read deadline took \(elapsed)s to fire, expected just over 2x readTimeoutSeconds")
        session.disconnect()
    }

    // MARK: - Idle read timeout sends a liveness probe instead of failing

    @Test("VNC: an idle read timeout sends a 1x1 liveness probe instead of failing immediately")
    func testIdleTimeoutSendsLivenessProbe() throws {
        let server = try FakeVNCServer.start()
        defer { server.stop() }
        let session = makeSession(port: server.port, name: "ProbeSend")
        session.readTimeoutSeconds = 1
        session.connect()
        #expect(server.waitForClient())
        server.sendHandshake(serverName: "Probe", width: 16, height: 16)
        #expect(waitFor({ session.status == .connected }))

        // Drain everything the client sends before its first
        // FramebufferUpdateRequest: version banner (12) + security type
        // (1) + ClientInit (1) + SetPixelFormat (20) + SetEncodings (12)
        // = 46 bytes, all written before `performHandshake` returns.
        #expect(server.receive(count: 46, timeout: 3.0 * ciDeadlineScale) != nil,
                "Expected the client's handshake bytes")
        // Then the initial non-incremental full-framebuffer request
        // (w=h=16), sent right after the handshake completes — drain it
        // too so it isn't mistaken for the probe below.
        let initial = server.receive(count: 10, timeout: 3.0 * ciDeadlineScale)
        #expect(initial != nil, "Expected the initial full-framebuffer request")
        if let bytes = initial {
            let expectedInitial: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 16, 0, 16]
            #expect(Array(bytes) == expectedInitial, "Unexpected initial request: \(Array(bytes))")
        }
        server.drainReceived()

        // The server then goes silent. After ~readTimeoutSeconds, the
        // idle read times out with nothing received; instead of failing,
        // the client should send a 1x1 non-incremental probe.
        let probeBytes = server.receive(count: 10, timeout: 3.0 * ciDeadlineScale)
        #expect(probeBytes != nil, "Expected a 10-byte FramebufferUpdateRequest probe after the idle timeout")
        if let bytes = probeBytes {
            // type=3 (FramebufferUpdateRequest), incremental=0, x=0, y=0,
            // w=1, h=1 — all big-endian UInt16 fields.
            let expected: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 1, 0, 1]
            #expect(Array(bytes) == expected, "Unexpected probe bytes: \(Array(bytes))")
        }

        // Give any pending main-thread status dispatch a chance to run
        // before checking — status changes are always bounced through
        // DispatchQueue.main.
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        #expect(session.status == .connected, "Session should still be connected after only the first idle timeout, got \(session.status)")
        session.disconnect()
    }

    @Test("VNC: replying to the liveness probe keeps the session alive past 2x the read timeout")
    func testLivenessProbeReplyKeepsSessionAlive() throws {
        let server = try FakeVNCServer.start()
        defer { server.stop() }
        let session = makeSession(port: server.port, name: "ProbeReply")
        // Scaled like the SO_RCVTIMEO deadline it drives: under CI, the
        // test's own thread needs slack to notice the probe and reply to
        // it before the client's next real timeout, not just to wait for
        // an eventual result.
        let readSeconds = Int(2 * ciDeadlineScale)
        session.readTimeoutSeconds = readSeconds
        session.connect()
        #expect(server.waitForClient())
        server.sendHandshake(serverName: "ProbeReply", width: 16, height: 16)
        #expect(waitFor({ session.status == .connected }))

        // Drain everything the client sends before its first
        // FramebufferUpdateRequest: version banner (12) + security type
        // (1) + ClientInit (1) + SetPixelFormat (20) + SetEncodings (12)
        // = 46 bytes, all written before `performHandshake` returns.
        #expect(server.receive(count: 46, timeout: 5.0 * ciDeadlineScale) != nil,
                "Expected the client's handshake bytes")
        // Then the initial post-handshake full-framebuffer request.
        #expect(server.receive(count: 10, timeout: 5.0 * ciDeadlineScale) != nil,
                "Expected the initial full-framebuffer request")

        // Wait for the idle-timeout-triggered liveness probe, confirm
        // it's genuinely the 1x1 probe (not the initial request drained
        // above), then answer it with an empty FramebufferUpdate — proof
        // of life without any real screen data.
        let probeBytes = server.receive(count: 10, timeout: Double(readSeconds) + 5.0 * ciDeadlineScale)
        #expect(probeBytes != nil, "Expected the liveness probe to arrive")
        if let bytes = probeBytes {
            let expectedProbe: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 1, 0, 1]
            #expect(Array(bytes) == expectedProbe, "Expected the 1x1 probe, got \(Array(bytes))")
        }
        server.sendEmptyFramebufferUpdate()

        // A single unanswered idle timeout used to fail the session
        // outright. Now it takes a second, unanswered timeout after the
        // probe — roughly 2x readTimeoutSeconds. Poll comfortably past
        // that 2x mark (but short of the next, ~3x, failure point) and
        // confirm the session never left .connected.
        let checkUntil = Date().addingTimeInterval(Double(readSeconds) * 1.5)
        var leftConnected = false
        var lastStatus: SessionStatus = session.status
        while Date() < checkUntil {
            lastStatus = session.status
            if lastStatus != .connected { leftConnected = true; break }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        #expect(!leftConnected, "Session should remain .connected after answering the liveness probe, got \(lastStatus)")
        session.disconnect()
    }

    // MARK: - Issue-013: Clean EOF while .connected is treated as .disconnected

    @Test("VNC: clean server-side close is .disconnected, not .error")
    func testCleanCloseIsDisconnected() throws {
        let server = try FakeVNCServer.start()
        defer { server.stop() }
        let session = makeSession(port: server.port, name: "CleanClose")
        session.connect()
        #expect(server.waitForClient())
        // Brief wait to let the read thread settle.
        Thread.sleep(forTimeInterval: 0.2)
        server.sendHandshake(serverName: "C", width: 16, height: 16)
        #expect(waitFor({ session.status == .connected }))
        // Server hangs up.
        server.stop()
        let sawDisconnected = waitFor({ session.status == .disconnected }, timeout: 3.0)
        #expect(sawDisconnected, "Expected .disconnected after server close, got \(session.status)")
    }

    // MARK: - Issue-021: clipboard shouldSend helper

    @Test("VNCSessionView.shouldSend: only returns true on a real change")
    func testClipboardShouldSend() {
        // First observation: changeCount 5, lastSent -1 (initial). Should
        // send because 5 != -1.
        #expect(VNCSessionView.shouldSend(changeCount: 5, lastSent: -1) == true)
        // Same change count, no new change: should not send.
        #expect(VNCSessionView.shouldSend(changeCount: 5, lastSent: 5) == false)
        // New change: should send.
        #expect(VNCSessionView.shouldSend(changeCount: 6, lastSent: 5) == true)
        // Zero change count is the OS's "no clipboard" sentinel; never
        // forward.
        #expect(VNCSessionView.shouldSend(changeCount: 0, lastSent: 5) == false)
        #expect(VNCSessionView.shouldSend(changeCount: 0, lastSent: 0) == false)
    }

    // MARK: - ISSUE-023: keysym mapping

    @Test("VNCCanvasView.keysym: Ctrl+C → 0x63 (XK_c)")
    func testKeysymCtrlC() {
        let sym = VNCCanvasView.keysym(
            keyCode: 8,  // physical 'c' on US layout
            characters: "\u{03}",  // cooked control glyph
            charactersIgnoringModifiers: "c",
            flags: [.control]
        )
        #expect(sym == 0x63)
    }

    @Test("VNCCanvasView.keysym: é → 0xE9 (Latin-1)")
    func testKeysymLatin1() {
        let sym = VNCCanvasView.keysym(
            keyCode: 18,  // physical 'e' on US layout
            characters: "é",
            charactersIgnoringModifiers: "e",
            flags: [.option]
        )
        #expect(sym == 0xE9)
    }

    @Test("VNCCanvasView.keysym: 日 → 0x010065E5 (Unicode offset)")
    func testKeysymUnicodeOffset() {
        let sym = VNCCanvasView.keysym(
            keyCode: 0,
            characters: "日",
            charactersIgnoringModifiers: "日",
            flags: []
        )
        #expect(sym == 0x010065E5)
    }

    @Test("VNCCanvasView.keysym: Return → 0xFF0D")
    func testKeysymReturn() {
        let sym = VNCCanvasView.keysym(
            keyCode: 36,  // Return
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            flags: []
        )
        #expect(sym == 0xFF0D)
    }

    @Test("VNCCanvasView.keysym: arrow keys use the special-key table")
    func testKeysymArrowKeys() {
        #expect(VNCCanvasView.keysym(keyCode: 123, characters: nil, charactersIgnoringModifiers: nil, flags: []) == 0xFF51)
        #expect(VNCCanvasView.keysym(keyCode: 124, characters: nil, charactersIgnoringModifiers: nil, flags: []) == 0xFF53)
        #expect(VNCCanvasView.keysym(keyCode: 125, characters: nil, charactersIgnoringModifiers: nil, flags: []) == 0xFF54)
        #expect(VNCCanvasView.keysym(keyCode: 126, characters: nil, charactersIgnoringModifiers: nil, flags: []) == 0xFF52)
    }
}

// MARK: - Helpers (test-only)

/// Thread-safe box for the captured update callback's arguments. The
/// callback runs on the main queue, but the test reads from whatever
/// thread the test was scheduled on, so a lock is required.
private final class CapturedUpdate: @unchecked Sendable {
    private let lock = NSLock()
    private var _image: NSImage?
    private var _rect: NSRect?
    var image: NSImage? { lock.lock(); defer { lock.unlock() }; return _image }
    var rect: NSRect? { lock.lock(); defer { lock.unlock() }; return _rect }
    func set(image: NSImage, rect: NSRect) {
        lock.lock(); _image = image; _rect = rect; lock.unlock()
    }
}

private struct Pixel: Equatable { let r, g, b, a: UInt8 }

/// Read a single pixel from a CGImage-backed NSImage. We use a
/// CGDataProvider that points at a freshly-allocated buffer, draw the
/// image into it via CGContext, and return the pixel at (x, y).
private func readPixel(image: NSImage, x: Int, y: Int) -> Pixel? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let width = cg.width
    let height = cg.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = data.withUnsafeMutableBufferPointer({ ptr -> CGContext? in
        CGContext(
            data: ptr.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
    }) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    let offset = (y * width + x) * bytesPerPixel
    guard offset + 3 < data.count else { return nil }
    // CGContext with premultipliedFirst + BGRA byte-order reads as
    // [B, G, R, A] in memory. Map back to RGBA.
    return Pixel(r: data[offset + 2], g: data[offset + 1], b: data[offset + 0], a: data[offset + 3])
}
