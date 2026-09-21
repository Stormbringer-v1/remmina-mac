import Testing
import Foundation
import SwiftUI
import AppKit
@testable import RemminaMac

/// Regression guard for `SessionTabView`'s ZStack, which hosts each session's
/// content inside its own `NSHostingView` via the private
/// `SessionContainerView` (an `NSViewRepresentable`). That makes
/// `RDPSessionView` — which reads `@Environment(ConnectionManager.self)`
/// non-optionally on the first line of its body — a nested SwiftUI subtree
/// living inside a second, inner `NSHostingView`.
///
/// This test drives the real `SessionTabView` (not a stand-in) inside its
/// own off-screen window, opens a real (fully stubbed, nothing spawned) RDP
/// session through it, and proves the nested `RDPSessionView` body actually
/// evaluates and renders content rather than merely being constructed as an
/// inert SwiftUI value that's never laid out.
///
/// On the toolchain this was written against (macOS 27 / Swift 6.4),
/// removing `SessionTabView`'s `.environment(connectionManager)`
/// re-injection was verified (manually, see the task notes) to change
/// nothing observable here — the nested `NSHostingView` resolves
/// `@Environment(ConnectionManager.self)` regardless. So this test is a
/// body-evaluation guard (it would still catch `SessionContainerView` or
/// `RDPSessionView` breaking outright, e.g. throwing away content or
/// crashing), not a guard specifically against that one modifier being
/// deleted on this SDK.
@Suite("SessionTabView nested hosting", .serialized)
@MainActor
struct SessionHostingTests {

    /// Thread-safe box for grabbing the concrete `RDPSession` the manager's
    /// factory creates, mirroring the pattern in ConnectionManagerTests.
    private final class CreatedSession: @unchecked Sendable {
        private let lock = NSLock()
        private var value: RDPSession?

        func set(_ session: RDPSession) {
            lock.lock(); defer { lock.unlock() }
            value = session
        }

        var current: RDPSession? {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    @Test("RDPSessionView's body renders when hosted through SessionTabView's nested NSHostingView")
    func testNestedRDPSessionViewBodyEvaluates() async throws {
        let created = CreatedSession()

        // A session that cannot spawn or open anything: no local FreeRDP
        // client and no app registered for the rdp:// scheme, so `connect()`
        // settles into `.error` entirely in-process, with nothing spawned.
        let manager = ConnectionManager(
            sessionFactory: { profile, password in
                let session = RDPSession(profile: profile, password: password)
                session.xfreerdpLocator = { nil }
                session.msrdAvailable = { _ in false }
                created.set(session)
                return session
            },
            credentialStore: FakeCredentialStore(persists: true)
        )

        let profile = ConnectionProfile(name: "HostingTest", protocolType: .rdp, host: "192.0.2.10", port: 3389)
        let result = manager.openSession(for: profile)
        #expect(result == .opened)

        defer { manager.closeAll() }

        guard let session = created.current else {
            Issue.record("sessionFactory never ran — openSession did not create a session")
            return
        }

        // Let the stubbed session settle into `.error` before hosting any
        // view, so what follows isn't racing the session's own async
        // connect() plumbing. This needs `await Task.sleep`, not
        // `RunLoop.main.run(until:)`: in this test harness the latter
        // returns immediately without draining `DispatchQueue.main` at all
        // (verified directly — thousands of pumps in a tight loop never let
        // a queued `DispatchQueue.main.async` block run), whereas suspending
        // the MainActor with `Task.sleep` does.
        let settled = await waitUntil(timeout: 3.0 * ciDeadlineScale) {
            if case .error = manager.status(for: session.id) { return true }
            return false
        }
        #expect(settled, "stubbed RDP session never reached .error — test setup assumption is wrong")

        // Host the real window-root view in its own NSHostingView, exactly
        // as RemminaMacApp does, then hand it the manager the same way the
        // app's window root does.
        let hostingView = NSHostingView(rootView: AnyView(SessionTabView().environment(manager)))
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        // Deliberately never ordered front/visible: the test only needs
        // SwiftUI to build and lay out the real view hierarchy, not to be
        // shown on screen.

        // Force SwiftUI to actually run SessionContainerView.makeNSView and
        // evaluate the nested RDPSessionView body, rather than merely
        // constructing lazily-diffed view values.
        await forceLayoutPass(window: window, hostingView: hostingView)

        // Find the nested NSHostingView that SessionContainerView.makeNSView
        // creates for this session's content. Its mere existence only
        // proves `makeNSView` ran; the assertion below on its own subtree
        // proves SwiftUI actually laid out content inside it (i.e.
        // RDPSessionView's body was evaluated, not skipped) — scoped to
        // that subtree alone so it can't be satisfied by unrelated UI
        // elsewhere in SessionTabView (the tab bar's close button, the
        // session toolbar's Reconnect/Disconnect buttons).
        let nestedHosts = allDescendants(of: hostingView)
            .filter { $0 !== hostingView && $0 is NSHostingView<AnyView> }
        #expect(!nestedHosts.isEmpty, "SessionContainerView never created its own nested NSHostingView")

        guard let nestedHost = nestedHosts.first else { return }
        let nestedSubtree = allDescendants(of: nestedHost)
        #expect(
            nestedSubtree.count > 1,
            "nested NSHostingView has no rendered content of its own — RDPSessionView's body likely never evaluated"
        )
    }

    // MARK: - Helpers

    /// Pumps layout/display and briefly suspends on the MainActor so SwiftUI
    /// has a real chance to materialize the nested view hierarchy. This is a
    /// hang guard scaled test, not a timing assertion — see `ciDeadlineScale`.
    private func forceLayoutPass(window: NSWindow, hostingView: NSHostingView<AnyView>) async {
        hostingView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        hostingView.displayIfNeeded()

        let iterations = pollIterations(20)
        for _ in 0..<iterations {
            try? await Task.sleep(nanoseconds: 20_000_000)
            hostingView.layoutSubtreeIfNeeded()
            hostingView.displayIfNeeded()
        }
    }

    /// Polls `condition` on the MainActor, suspending between checks with
    /// `Task.sleep` (which — unlike `RunLoop.main.run(until:)` in this
    /// harness — actually lets queued `DispatchQueue.main.async` work run)
    /// until it's true or `timeout` elapses.
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allDescendants(of: $0) }
    }
}
