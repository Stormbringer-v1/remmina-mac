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
    /// - Returns: Resolved absolute path
    /// - Throws: ValidationError if path is unsafe
    static func validate(_ path: String, isUserSelected: Bool = false) throws -> String {
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
        
        // Check if file exists
        guard fm.fileExists(atPath: absolutePath) else {
            throw ValidationError.doesNotExist
        }
        
        // Resolve symlinks
        let resolvedPath: String
        do {
            resolvedPath = try fm.destinationOfSymbolicLink(atPath: absolutePath)
        } catch {
            // Not a symlink, use absolute path
            resolvedPath = absolutePath
        }
        
        // If not user-selected, must be in ~/.ssh
        if !isUserSelected {
            let sshDir = NSString(string: "~/.ssh").expandingTildeInPath
            if !resolvedPath.hasPrefix(sshDir) {
                throw ValidationError.outsideSshDirectory
            }
        }
        
        // For user-selected files, ensure symlink doesn't escape to dangerous locations
        if isUserSelected && resolvedPath != absolutePath {
            // Symlink detected - ensure it doesn't point to /etc, /System, etc.
            let dangerousPrefixes = ["/etc/", "/System/", "/private/etc/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/"]
            if dangerousPrefixes.contains(where: { resolvedPath.hasPrefix($0) }) {
                throw ValidationError.symlinkEscape
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
}
