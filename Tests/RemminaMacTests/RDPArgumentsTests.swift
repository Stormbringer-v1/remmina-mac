import Testing
import Foundation
@testable import RemminaMac

@Suite("RDP Argument Construction Tests")
struct RDPArgumentsTests {

    @Test("RDP argv builder defaults to /cert:tofu and -clipboard")
    func testBuildArgumentsDefaults() {
        let args = RDPSession.buildArguments(
            host: "rdp.example.com",
            port: 3389,
            username: "testuser",
            domain: "CORP",
            size: (1920, 1080),
            ignoreCert: false,
            clipboard: false
        )

        #expect(args.contains("/v:rdp.example.com:3389"))
        #expect(args.contains("/u:testuser"))
        #expect(args.contains("/d:CORP"))
        #expect(args.contains("/size:1920x1080"))
        #expect(args.contains("/bpp:32"))
        #expect(args.contains("-clipboard"))
        #expect(!args.contains("+clipboard"))
        #expect(args.contains("/cert:tofu"))
        #expect(!args.contains("/cert:ignore"))
        #expect(args.contains("/log-level:WARN"))
    }

    @Test("RDP argv builder includes /cert:ignore when ignoreCert is true")
    func testBuildArgumentsIgnoreCert() {
        let args = RDPSession.buildArguments(
            host: "10.0.0.5",
            port: 3389,
            ignoreCert: true,
            clipboard: false
        )

        #expect(args.contains("/cert:ignore"))
        #expect(!args.contains("/cert:tofu"))
        #expect(args.contains("-clipboard"))
    }

    @Test("RDP argv builder includes +clipboard when clipboard is true")
    func testBuildArgumentsClipboardEnabled() {
        let args = RDPSession.buildArguments(
            host: "10.0.0.5",
            port: 3389,
            ignoreCert: false,
            clipboard: true
        )

        #expect(args.contains("+clipboard"))
        #expect(!args.contains("-clipboard"))
        #expect(args.contains("/cert:tofu"))
    }

    @Test("RDP argv builder handles empty username and domain cleanly")
    func testBuildArgumentsOmitEmptyUserAndDomain() {
        let args = RDPSession.buildArguments(
            host: "10.0.0.5",
            port: 3389,
            username: "",
            domain: "",
            size: (1280, 800),
            ignoreCert: false,
            clipboard: false
        )

        #expect(!args.contains { $0.hasPrefix("/u:") })
        #expect(!args.contains { $0.hasPrefix("/d:") })
        #expect(args.contains("/size:1280x800"))
    }
}
