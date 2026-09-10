import Foundation

/// Detects SSH and RDP password prompts in terminal output streams.
///
/// Implements end-anchored prompt detection to avoid triggering on pre-auth banner text
/// or server-controlled messages containing "password:" earlier in output.
struct PasswordPromptDetector {
    private static let maxPromptBufferBytes = 4096

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

    /// Pure function matching: checks if `window` ends with a valid password prompt.
    ///
    /// Requirements:
    /// - Examine only the bytes after the last `\n` or `\r`
    /// - If content ends with a newline, returns false
    /// - Trim trailing whitespace
    /// - Lowercase
    /// - Match `hasSuffix("password:")` or regex `password( for [^\n:]+)?:$`
    /// - Return false for passphrase prompts like "Enter passphrase for key..."
    static func matches(window: Data) -> Bool {
        guard !window.isEmpty else { return false }

        // Must not end with newline
        guard let lastByte = window.last, lastByte != 0x0A && lastByte != 0x0D else {
            return false
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
            return false
        }

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        let lower = trimmed.lowercased()

        // Explicitly reject passphrase prompts
        if lower.contains("passphrase") {
            return false
        }

        // Match suffix "password:" or regex "password( for [^\n:]+)?:$"
        if lower.hasSuffix("password:") {
            return true
        }

        // Check regex: password( for [^\n:]+)?:$
        if let regex = try? NSRegularExpression(pattern: #"password( for [^\n:]+)?:$"#, options: [.caseInsensitive]) {
            let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
            if regex.firstMatch(in: lower, options: [], range: range) != nil {
                return true
            }
        }

        return false
    }

    /// Checks if the internal rolling window currently matches a password prompt.
    func matches() -> Bool {
        Self.matches(window: window)
    }
}
