import Testing
import Foundation
@testable import RemminaMac

@Suite("PasswordPromptDetector Tests")
struct PasswordPromptDetectorTests {

    @Test("Matches valid SSH and RDP password prompts (ISSUE-005)")
    func testValidPrompts() {
        // user@host's password:
        let p1 = Data("user@host's password: ".utf8)
        #expect(PasswordPromptDetector.matches(window: p1) == true)

        // Password:
        let p2 = Data("Password:".utf8)
        #expect(PasswordPromptDetector.matches(window: p2) == true)

        // (user@host) Password for user:
        let p3 = Data("(user@host) Password for user:".utf8)
        #expect(PasswordPromptDetector.matches(window: p3) == true)
    }

    @Test("Rejects pre-auth banner text with prompt not at end (ISSUE-005)")
    func testPromptNotAtEnd() {
        let banner = Data("Welcome. Enter password: in the portal\r\n".utf8)
        #expect(PasswordPromptDetector.matches(window: banner) == false)

        let newlineAfter = Data("Password:\n".utf8)
        #expect(PasswordPromptDetector.matches(window: newlineAfter) == false)

        let crlfAfter = Data("Password:\r\n".utf8)
        #expect(PasswordPromptDetector.matches(window: crlfAfter) == false)
    }

    @Test("Rejects passphrase prompt and empty input (ISSUE-005)")
    func testPassphraseAndEmpty() {
        let passphrase = Data("Enter passphrase for key '/x/id_rsa':".utf8)
        #expect(PasswordPromptDetector.matches(window: passphrase) == false)

        let empty = Data()
        #expect(PasswordPromptDetector.matches(window: empty) == false)
    }

    @Test("Rolling window appends and resets")
    func testRollingWindow() {
        var detector = PasswordPromptDetector()
        detector.append(Data("Welcome to server\r\n".utf8))
        #expect(detector.matches() == false)

        detector.append(Data("user@host's password: ".utf8))
        #expect(detector.matches() == true)

        detector.reset()
        #expect(detector.matches() == false)
    }
}
