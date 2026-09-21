import Foundation

/// Detects SSH and RDP password prompts in terminal output streams.
///
/// Implements end-anchored prompt detection to avoid triggering on pre-auth banner text
/// or server-controlled messages containing "password:" earlier in output.
struct PasswordPromptDetector {
    private static let maxPromptBufferBytes = 4096

    /// The kind of end-anchored prompt `classify` found, if any.
    enum PromptKind: Equatable {
        /// An account/login password prompt (`Password:`, `user@host's password:`, …).
        case password
        /// A key passphrase prompt (`Enter passphrase for key '...':`). No
        /// passphrase support exists yet, so callers treat this as fatal
        /// rather than something to answer.
        case passphrase
    }

    /// Rolling buffer of recent output data.
    private(set) var window = Data()

    /// Appends data to the rolling window, maintaining a maximum size of 4 KiB.
    mutating func append(_ data: Data) {
        window.append(data)
        if window.count > Self.maxPromptBufferBytes {
            window.removeFirst(window.count - Self.maxPromptBufferBytes)
        }
    }

    /// Clears the rolling window.
    mutating func reset() {
        window.removeAll(keepingCapacity: false)
    }

    /// Pure function classifying the trailing line of `window` as a password
    /// prompt, a passphrase prompt, or neither.
    ///
    /// Requirements (both kinds):
    /// - Examine only the bytes after the last `\n` or `\r`
    /// - If content ends with a newline, there is no prompt
    /// - Trim trailing whitespace, lowercase
    ///
    /// Password: `hasSuffix("password:")` or regex `password( for [^\n:]+)?:$`.
    /// Passphrase: the trailing line contains "passphrase" and ends with
    /// ":" (e.g. "Enter passphrase for key '/Users/x/.ssh/id_ed25519':").
    static func classify(window: Data) -> PromptKind? {
        guard !window.isEmpty else { return nil }

        // Must not end with newline
        guard let lastByte = window.last, lastByte != 0x0A && lastByte != 0x0D else {
            return nil
        }

        // Find index of last \n or \r
        var startIndex = window.startIndex
        for i in window.indices.reversed() {
            let b = window[i]
            if b == 0x0A || b == 0x0D {
                startIndex = window.index(after: i)
                break
            }
        }

        let trailingSlice = window[startIndex...]
        guard let text = String(data: trailingSlice, encoding: .utf8) else {
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()

        // A passphrase prompt is end-anchored the same way a password
        // prompt is: a trailing line mentioning "passphrase" that ends
        // with ":".
        if lower.contains("passphrase") {
            return lower.hasSuffix(":") ? .passphrase : nil
        }

        // Match suffix "password:" or regex "password( for [^\n:]+)?:$"
        if lower.hasSuffix("password:") {
            return .password
        }

        // Check regex: password( for [^\n:]+)?:$
        if let regex = try? NSRegularExpression(pattern: #"password( for [^\n:]+)?:$"#, options: [.caseInsensitive]) {
            let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            if regex.firstMatch(in: lower, options: [], range: range) != nil {
                return .password
            }
        }

        return nil
    }

    /// Pure function matching: checks if `window` ends with a valid password
    /// prompt. Exactly equivalent to `classify(window:) == .password`; kept
    /// so RDPSession (which only ever cares about password prompts) is
    /// unaffected by passphrase classification.
    static func matches(window: Data) -> Bool {
        classify(window: window) == .password
    }

    /// Checks if the internal rolling window currently matches a password prompt.
    func matches() -> Bool {
        Self.matches(window: window)
    }

    /// Classifies the internal rolling window (see `classify(window:)`).
    func classify() -> PromptKind? {
        Self.classify(window: window)
    }
}
