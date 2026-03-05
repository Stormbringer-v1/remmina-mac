import Testing
import Foundation
@testable import RemminaMac

@Suite("ProfileStore Tests")
struct ProfileStoreTests {
    // Note: These tests verify the ConnectionProfile model logic.
    // Full integration tests with SwiftData ModelContext require
    // an in-memory container setup in a real test target.

    @Test("Profile creation with defaults")
    func testProfileCreation() {
        let profile = ConnectionProfile(
            name: "Test Server",
            protocolType: .ssh,
            host: "192.168.1.100",
            username: "admin"
        )

        #expect(profile.name == "Test Server")
        #expect(profile.protocolType == .ssh)
        #expect(profile.host == "192.168.1.100")
        #expect(profile.port == 22)
        #expect(profile.username == "admin")
        #expect(profile.domain == "")
        #expect(profile.isFavorite == false)
        #expect(profile.connectOnOpen == false)
        #expect(profile.tags.isEmpty)
    }

    @Test("Protocol default ports")
    func testDefaultPorts() {
        let ssh = ConnectionProfile(name: "SSH", protocolType: .ssh, host: "host")
        let vnc = ConnectionProfile(name: "VNC", protocolType: .vnc, host: "host")
        let rdp = ConnectionProfile(name: "RDP", protocolType: .rdp, host: "host")

        #expect(ssh.port == 22)
        #expect(vnc.port == 5900)
        #expect(rdp.port == 3389)
    }

    @Test("Custom port override")
    func testCustomPort() {
        let profile = ConnectionProfile(
            name: "Custom",
            protocolType: .ssh,
            host: "host",
            port: 2222
        )

        #expect(profile.port == 2222)
    }

    @Test("Tags serialization")
    func testTags() {
        let profile = ConnectionProfile(
            name: "Tagged",
            protocolType: .ssh,
            host: "host",
            tags: ["web", "production", "linux"]
        )

        #expect(profile.tags.count == 3)
        #expect(profile.tags.contains("web"))
        #expect(profile.tags.contains("production"))
        #expect(profile.tags.contains("linux"))
        #expect(profile.tagsRawValue == "web,production,linux")
    }

    @Test("Connection string formatting")
    func testConnectionString() {
        let withUser = ConnectionProfile(
            name: "Test",
            protocolType: .ssh,
            host: "example.com",
            username: "admin"
        )
        #expect(withUser.connectionString == "admin@example.com")

        let withPort = ConnectionProfile(
            name: "Test",
            protocolType: .ssh,
            host: "example.com",
            port: 2222,
            username: "admin"
        )
        #expect(withPort.connectionString == "admin@example.com:2222")

        let noUser = ConnectionProfile(
            name: "Test",
            protocolType: .vnc,
            host: "10.0.0.1"
        )
        #expect(noUser.connectionString == "10.0.0.1")
    }

    @Test("Protocol type computed property")
    func testProtocolType() {
        let profile = ConnectionProfile(
            name: "Test",
            protocolType: .ssh,
            host: "host"
        )

        #expect(profile.protocolType == .ssh)
        #expect(profile.protocolRawValue == "SSH")

        profile.protocolType = .rdp
        #expect(profile.protocolType == .rdp)
        #expect(profile.protocolRawValue == "RDP")
    }

    @Test("Favorite toggle")
    func testFavorite() {
        let profile = ConnectionProfile(
            name: "Test",
            protocolType: .ssh,
            host: "host"
        )

        #expect(profile.isFavorite == false)
        profile.isFavorite = true
        #expect(profile.isFavorite == true)
    }

    @Test("Empty tags returns empty array")
    func testEmptyTags() {
        let profile = ConnectionProfile(
            name: "Test",
            protocolType: .ssh,
            host: "host"
        )

        #expect(profile.tags.isEmpty)
        #expect(profile.tagsRawValue == "")
    }

    @Test("Last connected timestamp")
    func testLastConnected() {
        let profile = ConnectionProfile(
            name: "Test",
            protocolType: .ssh,
            host: "host"
        )

        #expect(profile.lastConnectedAt == nil)

        let now = Date()
        profile.lastConnectedAt = now
        #expect(profile.lastConnectedAt == now)
    }
}
