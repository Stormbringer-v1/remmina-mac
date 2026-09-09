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
}
