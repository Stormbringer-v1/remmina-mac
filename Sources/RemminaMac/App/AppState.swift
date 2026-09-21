import Foundation
import Observation

/// Global application state observable by views and tests.
@Observable
final class AppState {
    /// True whenever the app did not start against the original on-disk
    /// store untouched — either because it recovered into a fresh store at
    /// the same location (`recoveryIsInMemoryOnly == false`) or because it
    /// fell back to an in-memory-only store (`recoveryIsInMemoryOnly ==
    /// true`). `recoveryBackupPath`, when non-nil, is where the original
    /// (possibly corrupted) store was moved.
    var recoveryMode: Bool
    var recoveryBackupPath: String?
    /// Distinguishes the two `recoveryMode` outcomes so the UI can show the
    /// right banner: `false` means recovery created a fresh store at the
    /// original location (data saves normally from here on; only the old
    /// file was moved aside), `true` means even that failed and the app is
    /// running against an in-memory store where nothing typed this session
    /// will be saved.
    var recoveryIsInMemoryOnly: Bool

    init(
        recoveryMode: Bool = false,
        recoveryBackupPath: String? = nil,
        recoveryIsInMemoryOnly: Bool = false
    ) {
        self.recoveryMode = recoveryMode
        self.recoveryBackupPath = recoveryBackupPath
        self.recoveryIsInMemoryOnly = recoveryIsInMemoryOnly
    }
}
