import Foundation

/// Status of a remote session.
enum SessionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var displayName: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .connected: return true
        default: return false
        }
    }
}

/// Delegate protocol for session status callbacks.
protocol SessionDelegate: AnyObject {
    func sessionDidChangeStatus(_ session: any SessionProtocol, status: SessionStatus)
    func sessionDidReceiveOutput(_ session: any SessionProtocol, data: Data)
}

/// Common protocol for all remote sessions (SSH, VNC, RDP).
protocol SessionProtocol: AnyObject {
    var id: UUID { get }
    var profileId: UUID { get }
    var profileName: String { get }
    var protocolType: ProtocolType { get }
    var status: SessionStatus { get }
    var delegate: SessionDelegate? { get set }

    func connect()
    func disconnect()
    func reconnect()
    func sendInput(_ data: Data)
}

extension SessionProtocol {
    func reconnect() {
        disconnect()
        connect()
    }
}
