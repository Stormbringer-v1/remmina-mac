import Foundation

/// Supported remote connection protocol types.
enum ProtocolType: String, Codable, CaseIterable, Identifiable {
    case ssh = "SSH"
    case vnc = "VNC"
    case rdp = "RDP"

    var id: String { rawValue }

    /// Default port for each protocol.
    var defaultPort: Int {
        switch self {
        case .ssh: return 22
        case .vnc: return 5900
        case .rdp: return 3389
        }
    }

    /// SF Symbol icon name.
    var iconName: String {
        switch self {
        case .ssh: return "terminal"
        case .vnc: return "desktopcomputer"
        case .rdp: return "display"
        }
    }

    /// Human-readable display name.
    var displayName: String {
        rawValue
    }
}
