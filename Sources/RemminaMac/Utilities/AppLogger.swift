import Foundation

/// App-wide logger with persistent file output.
///
/// Enterprise logging architecture:
/// - In-memory ring buffer (1000 entries) for UI display
/// - Persistent file output to ~/Library/Logs/RemminaMac/
/// - Automatic log rotation (max 5MB per file, archive old logs)
/// - Flush on app termination
/// - Never logs sensitive data (passwords, keys, credentials)
@Observable
final class AppLogger {
    static let shared = AppLogger()

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let level: LogLevel
    }

    enum LogLevel: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }

    private(set) var entries: [LogEntry] = []

    /// Log directory: ~/Library/Logs/RemminaMac/
    private let logDirectoryURL: URL
    /// Current log file
    private var logFileHandle: FileHandle?
    private let logQueue = DispatchQueue(label: "com.remmina-mac.logger", qos: .utility)
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Maximum log file size before rotation (5 MB)
    private static let maxLogFileSize: UInt64 = 5 * 1024 * 1024

    private init() {
        // Set up log directory
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        logDirectoryURL = libraryURL.appendingPathComponent("Logs/RemminaMac")

        // Create log directory if needed
        try? FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true)

        // Open log file
        openLogFile()
    }

    func log(_ message: String, level: LogLevel = .info, sessionId: UUID? = nil, profileId: UUID? = nil, component: String? = nil) {
        let entry = LogEntry(timestamp: Date(), message: message, level: level)
        DispatchQueue.main.async {
            self.entries.append(entry)
            // Keep last 1000 entries in memory
            if self.entries.count > 1000 {
                self.entries.removeFirst(self.entries.count - 1000)
            }
        }

        // Build structured log line with correlation IDs
        var logContext: [String] = []
        if let sid = sessionId {
            logContext.append("sessionId=\(sid.uuidString.prefix(8))")
        }
        if let pid = profileId {
            logContext.append("profileId=\(pid.uuidString.prefix(8))")
        }
        if let comp = component {
            logContext.append("component=\(comp)")
        }
        
        let contextStr = logContext.isEmpty ? "" : " [\(logContext.joined(separator: ", "))]"
        let formattedLine = "[\(dateFormatter.string(from: entry.timestamp))] [\(level.rawValue)]\(contextStr) \(message)\n"
        
        // Write to file asynchronously
        logQueue.async { [weak self] in
            self?.writeToFile(formattedLine)
        }

        #if DEBUG
        print("[\(level.rawValue)]\(contextStr) \(message)")
        #endif
    }

    func clear() {
        entries.removeAll()
    }

    /// Flush all pending log writes to disk. Call on app termination.
    func flushToDisk() {
        logQueue.sync {
            logFileHandle?.synchronizeFile()
        }
    }

    // MARK: - File Logging

    private func openLogFile() {
        let logFileName = "RemminaMac.log"
        let logFileURL = logDirectoryURL.appendingPathComponent(logFileName)

        // Create file if it doesn't exist
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        logFileHandle = try? FileHandle(forWritingTo: logFileURL)
        logFileHandle?.seekToEndOfFile()
    }

    private func writeToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }

        // Check for log rotation
        if let handle = logFileHandle {
            let currentSize = handle.offsetInFile
            if currentSize > Self.maxLogFileSize {
                rotateLog()
            }
        }

        logFileHandle?.write(data)
    }

    private func rotateLog() {
        logFileHandle?.closeFile()
        logFileHandle = nil

        let logFileURL = logDirectoryURL.appendingPathComponent("RemminaMac.log")
        let archiveFileName = "RemminaMac-\(ISO8601DateFormatter().string(from: Date())).log"
        let archiveURL = logDirectoryURL.appendingPathComponent(archiveFileName)

        // Rotate current file to archive
        try? FileManager.default.moveItem(at: logFileURL, to: archiveURL)

        // Clean up old archives (keep last 3)
        cleanupOldArchives()

        // Open new log file
        openLogFile()
        log("Log rotated — previous log archived as \(archiveFileName)")
    }

    private func cleanupOldArchives() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: logDirectoryURL, includingPropertiesForKeys: [.creationDateKey]) else { return }

        let archives = files
            .filter { $0.lastPathComponent.hasPrefix("RemminaMac-") && $0.pathExtension == "log" }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                let dateB = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
                return dateA < dateB
            }

        // Keep only the last 3 archives
        if archives.count > 3 {
            for archive in archives.prefix(archives.count - 3) {
                try? fm.removeItem(at: archive)
            }
        }
    }
}
