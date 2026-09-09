import Foundation

/// Validates SSH key paths to prevent path traversal and unauthorized file access.
enum SSHKeyValidator {
    enum ValidationError: Error, LocalizedError, Equatable {
        case empty
        case pathTraversal
        case outsideSshDirectory
        case worldWritable
        case notReadable
        case symlinkEscape
        case doesNotExist
        
        var errorDescription: String? {
            switch self {
            case .empty:
                return "SSH key path cannot be empty"
            case .pathTraversal:
                return "Path traversal detected in SSH key path"
            case .outsideSshDirectory:
                return "SSH key must be in ~/.ssh directory or user-selected location"
            case .worldWritable:
                return "SSH key file is world-writable (insecure permissions)"
            case .notReadable:
                return "SSH key file is not readable"
            case .symlinkEscape:
                return "SSH key symlink points outside allowed directories"
            case .doesNotExist:
                return "SSH key file does not exist"
            }
        }
    }
    
    /// Validate SSH key path for security
    /// - Parameters:
    ///   - path: The file path to validate
    ///   - isUserSelected: If true, path came from NSOpenPanel (user explicitly chose it)
    ///   - allowMissing: If true, a missing file is a warning rather than an
    ///     error. Use this when importing profiles on a new machine where the
    ///     key file might not exist yet — we want to record the path so the
    ///     user can put the key in place, not hard-fail the import.
    /// - Returns: Resolved absolute path
    /// - Throws: ValidationError if path is unsafe
    static func validate(_ path: String, isUserSelected: Bool = false, allowMissing: Bool = false) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty path is OK (means use SSH agent)
        if trimmed.isEmpty {
            return ""
        }

        let fm = FileManager.default

        // Expand ~ to home directory
        let expandedPath = NSString(string: trimmed).expandingTildeInPath

        // Block obvious path traversal attempts
        if trimmed.contains("../") || trimmed.contains("/..") {
            throw ValidationError.pathTraversal
        }

        // Resolve to absolute path
        guard let absolutePath = URL(fileURLWithPath: expandedPath).standardized.path as String? else {
            throw ValidationError.pathTraversal
        }

        let dangerousPrefixes = ["/etc/", "/System/", "/private/etc/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/"]
        if dangerousPrefixes.contains(where: { absolutePath.hasPrefix($0) }) {
            throw ValidationError.symlinkEscape
        }

        let sshDir = NSString(string: "~/.ssh").expandingTildeInPath

        // If not user-selected, the path must start within ~/.ssh/
        if !isUserSelected {
            if !absolutePath.hasPrefix(sshDir + "/") {
                throw ValidationError.outsideSshDirectory
            }
        }

        // Check if file exists
        guard fm.fileExists(atPath: absolutePath) else {
            if allowMissing {
                // Caller (e.g. an import) accepts that the key file isn't
                // present yet. Return the absolute path as-is so the user
                // can later drop the key in place.
                return absolutePath
            }
            throw ValidationError.doesNotExist
        }

        // Walk the full symlink chain. `destinationOfSymbolicLink` only
        // resolves a single hop, so a chain `a -> b -> /etc/passwd` would
        // otherwise look like `a -> b` and pass our prefix checks.
        let resolvedPath = try resolveSymlinkChain(startingAt: absolutePath, maxDepth: 16)

        // Ensure resolved target doesn't point to dangerous locations
        if dangerousPrefixes.contains(where: { resolvedPath.hasPrefix($0) }) {
            throw ValidationError.symlinkEscape
        }

        // If not user-selected, the resolved target must be in ~/.ssh/
        if !isUserSelected {
            if !resolvedPath.hasPrefix(sshDir + "/") {
                throw ValidationError.outsideSshDirectory
            }
        }

        // Check file permissions
        do {
            let attrs = try fm.attributesOfItem(atPath: resolvedPath)
            let posixPerms = attrs[.posixPermissions] as? NSNumber

            // Check if world-writable (dangerous for SSH keys)
            if let perms = posixPerms?.uint16Value {
                let worldWritable = (perms & 0o002) != 0
                if worldWritable {
                    throw ValidationError.worldWritable
                }
            }

            // Verify file is readable
            guard fm.isReadableFile(atPath: resolvedPath) else {
                throw ValidationError.notReadable
            }
        } catch let error as ValidationError {
            throw error
        } catch {
            throw ValidationError.notReadable
        }

        return resolvedPath
    }

    /// Resolves a symlink chain starting at `path`, walking up to `maxDepth`
    /// hops. Returns the final target (or the input if no symlink was found).
    /// Detects symlink loops and bails out rather than spinning forever.
    private static func resolveSymlinkChain(startingAt path: String, maxDepth: Int) throws -> String {
        let fm = FileManager.default
        var current = path
        var visited: Set<String> = [path]
        for _ in 0..<maxDepth {
            let attrs = try? fm.attributesOfItem(atPath: current)
            if let type = attrs?[.type] as? FileAttributeType, type != .typeSymbolicLink {
                return current
            }
            let next = try fm.destinationOfSymbolicLink(atPath: current)
            // If `destinationOfSymbolicLink` returned a relative path, resolve
            // it against the current symlink's directory.
            let resolvedNext: String
            if next.hasPrefix("/") {
                resolvedNext = next
            } else {
                let parent = (current as NSString).deletingLastPathComponent
                resolvedNext = (parent as NSString).appendingPathComponent(next)
            }
            // Loop detection.
            if visited.contains(resolvedNext) {
                throw ValidationError.symlinkEscape
            }
            visited.insert(resolvedNext)
            current = (resolvedNext as NSString).standardizingPath
        }
        // Hit the depth limit. The symlink chain is either very long or
        // circular; treat as a suspicious escape.
        throw ValidationError.symlinkEscape
    }
}
