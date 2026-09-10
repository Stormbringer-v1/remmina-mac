import Foundation
import Observation

/// Global application state observable by views and tests.
@Observable
final class AppState {
    var recoveryMode: Bool
    var recoveryBackupPath: String?

    init(recoveryMode: Bool = false, recoveryBackupPath: String? = nil) {
        self.recoveryMode = recoveryMode
        self.recoveryBackupPath = recoveryBackupPath
    }
}
