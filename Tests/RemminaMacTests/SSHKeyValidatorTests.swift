import Testing
import Foundation
@testable import RemminaMac

@Suite("SSHKeyValidator Tests")
struct SSHKeyValidatorTests {
    
    // MARK: - Valid Cases
    
    @Test("Empty path is valid (uses SSH agent)")
    func testEmptyPathValid() throws {
        let result = try SSHKeyValidator.validate("")
        #expect(result == "")
    }
    
    @Test("Whitespace-only path returns empty")
    func testWhitespacePathReturnsEmpty() throws {
        let result = try SSHKeyValidator.validate("   ")
        #expect(result == "")
    }
    
    // MARK: - Path Traversal Attacks
    
    @Test("Block ../../../etc/passwd")
    func testBlockPathTraversal() {
        #expect(throws: SSHKeyValidator.ValidationError.pathTraversal) {
            try SSHKeyValidator.validate("../../../etc/passwd")
        }
    }
    
    @Test("Block path with ../ in middle")
    func testBlockPathTraversalMiddle() {
        #expect(throws: SSHKeyValidator.ValidationError.pathTraversal) {
            try SSHKeyValidator.validate("~/.ssh/../../../etc/passwd")
        }
    }
    
    @Test("Block path with /.. segment")
    func testBlockPathTraversalSegment() {
        #expect(throws: SSHKeyValidator.ValidationError.pathTraversal) {
            try SSHKeyValidator.validate("/home/user/.ssh/..")
        }
    }
    
    // MARK: - Non-Existent Files
    
    @Test("Non-existent file in ~/.ssh")
    func testNonExistentFile() {
        let path = "~/.ssh/nonexistent_key_12345.pem"
        #expect(throws: SSHKeyValidator.ValidationError.doesNotExist) {
            try SSHKeyValidator.validate(path)
        }
    }
    
    // MARK: - Outside ~/.ssh and Permission Validation
    
    @Test("Dangerous location /etc/hosts throws symlinkEscape")
    func testDangerousLocationThrows() {
        #expect(throws: SSHKeyValidator.ValidationError.symlinkEscape) {
            try SSHKeyValidator.validate("/etc/hosts", isUserSelected: true)
        }
    }

    @Test("Path in ~/.sshfoo throws outsideSshDirectory")
    func testSshFooThrowsOutsideSshDirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(throws: SSHKeyValidator.ValidationError.outsideSshDirectory) {
            try SSHKeyValidator.validate("\(home)/.sshfoo/key", isUserSelected: false)
        }
    }

    @Test("World-writable file throws worldWritable")
    func testWorldWritableFileThrows() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("remmina_test_key_ww_\(UUID().uuidString)")
        try "dummy-key-data".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: tempFile.path)

        #expect(throws: SSHKeyValidator.ValidationError.worldWritable) {
            try SSHKeyValidator.validate(tempFile.path, isUserSelected: true)
        }
    }

    @Test("User-selected key outside ~/.ssh with 0o600 permissions is accepted")
    func testUserSelectedOutsideSshDirAccepted() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("remmina_test_key_ok_\(UUID().uuidString)")
        try "dummy-private-key".write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempFile.path)

        let validated = try SSHKeyValidator.validate(tempFile.path, isUserSelected: true)
        #expect(validated == tempFile.path)
    }

    @Test("Missing file with allowMissing passes")
    func testMissingFileWithAllowMissing() throws {
        let missingPath = "/Users/dummy/some_nonexistent_key"
        let result = try SSHKeyValidator.validate(missingPath, isUserSelected: true, allowMissing: true)
        #expect(result == missingPath)
    }
}
