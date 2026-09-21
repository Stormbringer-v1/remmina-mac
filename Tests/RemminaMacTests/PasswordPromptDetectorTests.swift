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

    @Test("classify() distinguishes password prompts from passphrase prompts")
    func testClassifyDistinguishesPasswordFromPassphrase() {
        // A plain password prompt classifies as .password.
        let plainPassword = Data("Password:".utf8)
        #expect(PasswordPromptDetector.classify(window: plainPassword) == .password)
        #expect(PasswordPromptDetector.matches(window: plainPassword) == true)

        // user@host's password:
        let userPassword = Data("user@host's password: ".utf8)
        #expect(PasswordPromptDetector.classify(window: userPassword) == .password)

        // A passphrase prompt classifies as .passphrase, and must never be
        // mistaken for .password (so matches() stays false for it).
        let passphrase = Data("Enter passphrase for key '/Users/x/.ssh/id_ed25519':".utf8)
        #expect(PasswordPromptDetector.classify(window: passphrase) == .passphrase)
        #expect(PasswordPromptDetector.classify(window: passphrase) != .password)
        #expect(PasswordPromptDetector.matches(window: passphrase) == false)

        // A banner line containing "password:" followed by a newline is not
        // end-anchored, so it must not classify as either kind.
        let bannerWithNewline = Data("Welcome. Enter password: in the portal\r\n".utf8)
        #expect(PasswordPromptDetector.classify(window: bannerWithNewline) == nil)

        let passwordThenNewline = Data("Password:\n".utf8)
        #expect(PasswordPromptDetector.classify(window: passwordThenNewline) == nil)
    }

    @Test("Instance classify() mirrors the static function through the rolling window")
    func testInstanceClassifyMirrorsStatic() {
        var detector = PasswordPromptDetector()
        detector.append(Data("Enter passphrase for key '/x/id_rsa':".utf8))
        #expect(detector.classify() == .passphrase)
        #expect(detector.matches() == false)

        detector.reset()
        detector.append(Data("Password:".utf8))
        #expect(detector.classify() == .password)
        #expect(detector.matches() == true)
    }
}
