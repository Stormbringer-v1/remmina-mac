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
    
    // MARK: - Outside ~/.ssh (Not User-Selected)
    
    // Note: Testing path restrictions requires actual files to exist, skipped for now
}
