import Foundation

/// How an RDP session should present its window.
///
/// FreeRDP is told nothing about sizing unless we ask, and the previous code
/// hard-coded `/size:1280x800`, which pinned every session to a small fixed
/// window with no route to fullscreen. `Ctrl`+`Alt`+`Enter` toggles fullscreen
/// at runtime in FreeRDP regardless of the launch mode.
enum RDPDisplayMode: String, CaseIterable, Identifiable, Codable {
    /// Launch fullscreen (`/f`). The sensible default for a remote desktop.
    case fullscreen
    /// Open a window and scale the remote desktop into it (`/smart-sizing`).
    case fitWindow
    /// Open a window at a fixed size, no scaling.
    case fixedWindow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fullscreen:  return "Fullscreen"
        case .fitWindow:   return "Window (scale to fit)"
        case .fixedWindow: return "Window (fixed size)"
        }
    }

    var detail: String {
        switch self {
        case .fullscreen:  return "Opens fullscreen. Ctrl+Alt+Enter toggles back to a window."
        case .fitWindow:   return "Opens in a window and scales the remote desktop to fit it."
        case .fixedWindow: return "Opens in a window at the configured size, without scaling."
        }
    }
}
