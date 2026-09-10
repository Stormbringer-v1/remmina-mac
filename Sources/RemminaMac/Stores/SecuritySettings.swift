import Foundation
import Observation

/// User-controllable security toggles for remote-content side effects.
///
/// RemminaMac connects to remote hosts the user does not necessarily trust.
/// Several terminal / VNC features allow the remote end to drive local
/// resources (clipboard pasteboard, open arbitrary URL schemes) and we
/// default them to the safer choice until the user opts in.
///
/// Backed by `UserDefaults` so the settings persist across launches.
///
/// `@Observable` (not `ObservableObject`, PROBLEMS.md ISSUE-027a): this type
/// has no `@Published` properties, so an `ObservableObject` conformance here
/// would never fire `objectWillChange`. Views bind to it with `@Bindable`.
@Observable
@MainActor
final class SecuritySettings {
    static let shared = SecuritySettings()

    /// Whether the remote end is allowed to write to the local clipboard
    /// (SwiftTerm OSC 52, VNC ServerCutText). Off by default.
    var allowRemoteClipboard: Bool {
        didSet { UserDefaults.standard.set(allowRemoteClipboard, forKey: Keys.allowRemoteClipboard) }
    }

    /// Whether the local clipboard is sent to the remote end on change
    /// (VNC ClientCutText send). Off by default.
    var sendLocalClipboard: Bool {
        didSet { UserDefaults.standard.set(sendLocalClipboard, forKey: Keys.sendLocalClipboard) }
    }

    /// Whether the remote end is allowed to open URLs via `requestOpenLink`.
    /// Off by default. When on, only http, https, and mailto schemes are
    /// opened (no file://, no custom URL schemes, no arbitrary x-callback-url).
    var allowRemoteOpenLink: Bool {
        didSet { UserDefaults.standard.set(allowRemoteOpenLink, forKey: Keys.allowRemoteOpenLink) }
    }

    /// Whether RDP certificate errors should be ignored (/cert:ignore instead of /cert:tofu).
    /// Off by default.
    var rdpIgnoreCertificate: Bool {
        didSet { UserDefaults.standard.set(rdpIgnoreCertificate, forKey: Keys.rdpIgnoreCertificate) }
    }

    private enum Keys {
        static let allowRemoteClipboard = "security.allowRemoteClipboard"
        static let sendLocalClipboard = "security.sendLocalClipboard"
        static let allowRemoteOpenLink = "security.allowRemoteOpenLink"
        static let rdpIgnoreCertificate = "security.rdpIgnoreCertificate"
    }

    private init() {
        // UserDefaults returns false when the key is absent, so these
        // initializers also cover the "first launch" case.
        self.allowRemoteClipboard = UserDefaults.standard.bool(forKey: Keys.allowRemoteClipboard)
        self.sendLocalClipboard = UserDefaults.standard.bool(forKey: Keys.sendLocalClipboard)
        self.allowRemoteOpenLink = UserDefaults.standard.bool(forKey: Keys.allowRemoteOpenLink)
        self.rdpIgnoreCertificate = UserDefaults.standard.bool(forKey: Keys.rdpIgnoreCertificate)
    }

    /// URL schemes we consider safe for a remote-controlled `requestOpenLink`.
    /// http and https for the web; mailto for emails. We deliberately do NOT
    /// include file://, ftp://, ssh://, tel://, or any custom scheme that
    /// another app could register as a URL handler.
    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    /// Returns true if the URL's scheme is one we'd open on behalf of a
    /// remote-controlled `requestOpenLink`. Caller still needs to check
    /// `allowRemoteOpenLink` to know if the user has opted in.
    static func isLinkSchemeAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedLinkSchemes.contains(scheme)
    }
}
