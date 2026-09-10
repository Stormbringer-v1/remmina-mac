import Foundation
@testable import RemminaMac

/// Test double conforming to `SessionProtocol` that records calls and drives
/// delegate callbacks synchronously or asynchronously without spawning external processes
/// (PROBLEMS.md ISSUE-020).
final class FakeSession: SessionProtocol {
    let id: UUID
    let profileId: UUID
    let profileName: String
    let protocolType: ProtocolType

    var status: SessionStatus {
        didSet {
            delegate?.sessionDidChangeStatus(self, status: status)
        }
    }

    weak var delegate: SessionDelegate?

    var connectCalls = 0
    var disconnectCalls = 0
    var receivedInputs: [Data] = []

    init(profile: ConnectionProfile, password: String? = nil, initialStatus: SessionStatus = .connected) {
        self.id = UUID()
        self.profileId = profile.id
        self.profileName = profile.name
        self.protocolType = profile.protocolType
        self.status = initialStatus
    }

    init(id: UUID = UUID(), profileId: UUID = UUID(), profileName: String = "Fake", protocolType: ProtocolType = .ssh, initialStatus: SessionStatus = .connected) {
        self.id = id
        self.profileId = profileId
        self.profileName = profileName
        self.protocolType = protocolType
        self.status = initialStatus
    }

    func connect() {
        connectCalls += 1
        delegate?.sessionDidChangeStatus(self, status: status)
    }

    func disconnect() {
        disconnectCalls += 1
        status = .disconnected
    }

    func sendInput(_ data: Data) {
        receivedInputs.append(data)
    }

    func simulateAsyncStatusChange(_ newStatus: SessionStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.status = newStatus
        }
    }
}
