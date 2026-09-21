import Testing
import Foundation
@testable import RemminaMac

@Suite("SSH Arguments & Key Authentication Tests (ISSUE-001 & ISSUE-022)")
struct SSHArgumentsTests {

    @Test("buildArguments includes -i when key exists, custom port, and -- option terminator")
    func testBuildArgumentsWithKeyAndPort() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let keyFile = tempDir.appendingPathComponent("test_key_\(UUID().uuidString)")
        try "dummy-private-key".write(to: keyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: keyFile) }

        let args = SSHSession.buildArguments(
            host: "example.com",
            port: 2222,
            username: "deploy",
            sshKeyPath: keyFile.path
        )

        // Must include -i <path>
        let iIndex = args.firstIndex(of: "-i")
        #expect(iIndex != nil)
        if let idx = iIndex {
            #expect(args[idx + 1] == keyFile.path)
        }

        // Must include -p 2222
        let pIndex = args.firstIndex(of: "-p")
        #expect(pIndex != nil)
        if let idx = pIndex {
            #expect(args[idx + 1] == "2222")
        }

        // Must include "--" immediately before destination (ISSUE-022)
        let terminatorIndex = args.firstIndex(of: "--")
        #expect(terminatorIndex != nil)
        if let tIdx = terminatorIndex {
            #expect(tIdx == args.count - 2)
            #expect(args[tIdx + 1] == "deploy@example.com")
        }
    }

    @Test("buildArguments omits -i when key does not exist, uses standard port 22")
    func testBuildArgumentsMissingKeyStandardPort() {
        let missingPath = "/non/existent/key/path/id_ed25519"
        let args = SSHSession.buildArguments(
            host: "192.0.2.1",
            port: 22,
            username: "admin",
            sshKeyPath: missingPath
        )

        #expect(!args.contains("-i"))
        #expect(!args.contains("-p"))

        let terminatorIndex = args.firstIndex(of: "--")
        #expect(terminatorIndex != nil)
        if let tIdx = terminatorIndex {
            #expect(tIdx == args.count - 2)
            #expect(args[tIdx + 1] == "admin@192.0.2.1")
        }
    }

    @Test("SSHSession retains outside-~/.ssh key when valid (ISSUE-001)")
    func testSSHSessionRetainsOutsideKey() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let keyFile = tempDir.appendingPathComponent("id_ed25519_\(UUID().uuidString)")
        try "dummy-key-content".write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        defer { try? FileManager.default.removeItem(at: keyFile) }

        let profile = ConnectionProfile(
            name: "OutsideKeyTest",
            protocolType: .ssh,
            host: "192.0.2.1",
            port: 22,
            username: "testuser",
            sshKeyPath: keyFile.path
        )

        let session = SSHSession(profile: profile, password: nil)
        #expect(session.effectiveKeyPath == keyFile.path)
    }

    // MARK: - Key validation must not silently degrade to the agent

    @Test("connect() surfaces .error and never spawns when the configured SSH key is invalid")
    func testConnectFailsFastOnInvalidKey() {
        let profile = ConnectionProfile(
            name: "InvalidKeyTest",
            protocolType: .ssh,
            host: "192.0.2.1",
            port: 22,
            username: "testuser",
            sshKeyPath: "/nonexistent/path/id_rsa_\(UUID().uuidString)"
        )

        let session = SSHSession(profile: profile, password: nil)
        session.connect()

        // Assigned synchronously on the caller's thread by connect() itself
        // (this path never dispatches to main), so no polling is needed.
        var isError = false
        if case .error = session.status { isError = true }
        #expect(isError, "expected .error, got \(session.status.displayName)")
        #expect(session.isProcessAlive == false, "connect() must return before spawning ssh")
    }

    // MARK: - diagnose(): exit-code + recent-output classification (ISSUE-005 follow-up)

    @Test("diagnose() maps known ssh failure phrases to specific messages, always including the exit code")
    func testDiagnoseMapsKnownPhrases() {
        let cases: [(output: String, expectedFragment: String)] = [
            ("Permission denied (publickey).", "authentication failed"),
            ("Host key verification failed.", "host key problem"),
            ("@@@@@@@@@@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@@@@@@@@@@", "host key problem"),
            ("ssh: Could not resolve hostname foo.invalid: nodename nor servname provided, or not known", "dns lookup failed"),
            ("ssh: connect to host 10.0.0.1 port 22: Connection refused", "nothing is listening"),
            ("ssh: connect to host 10.0.0.1 port 22: Connection timed out", "network timeout"),
            ("ssh: connect to host 10.0.0.1 port 22: Operation timed out", "network timeout"),
            ("ssh: connect to host 10.0.0.1 port 22: No route to host", "network unreachable"),
            ("connect: Network is unreachable", "network unreachable"),
        ]

        for testCase in cases {
            let message = SSHSession.diagnose(exitCode: 255, recentOutput: testCase.output, wasConnecting: true)
            #expect(message.contains("255"), "message must include the exit code: \(message)")
            #expect(message.lowercased().contains(testCase.expectedFragment), "expected '\(testCase.expectedFragment)' in: \(message)")
        }
    }

    @Test("diagnose() falls back to the existing generic messages, unchanged, when nothing matches")
    func testDiagnoseFallback() {
        let whileConnecting = SSHSession.diagnose(exitCode: 1, recentOutput: "some unrelated banner text", wasConnecting: true)
        #expect(whileConnecting == "SSH exited with code 1 before authenticating — verify credentials, host, and network")

        let afterConnecting = SSHSession.diagnose(exitCode: 1, recentOutput: "some unrelated banner text", wasConnecting: false)
        #expect(afterConnecting == "SSH session ended (exit code 1)")
    }

    @Test("diagnose() never echoes the raw output buffer into the returned message")
    func testDiagnoseNeverLeaksRawOutput() {
        let suspiciousOutput = "some-very-specific-debug-token-should-not-leak Permission denied (publickey)."
        let message = SSHSession.diagnose(exitCode: 255, recentOutput: suspiciousOutput, wasConnecting: true)
        #expect(!message.contains("some-very-specific-debug-token-should-not-leak"))
    }
}
