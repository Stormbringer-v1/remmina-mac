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

    /// Which storage backend saved passwords use. Defaults to `.none`:
    /// RemminaMac does not tie itself to Apple Keychain (or to any single
    /// storage backend) so other integrators — and a future Linux/Windows
    /// port — need no changes to the core, and an ad-hoc-signed rebuild no
    /// longer triggers a Keychain ACL dialog. SSH keeps working via SSH
    /// keys/ssh-agent with no backend at all; VNC/RDP profiles that need a
    /// password require the user to opt into Keychain here.
    var credentialBackend: CredentialBackend {
        didSet { UserDefaults.standard.set(credentialBackend.rawValue, forKey: CredentialBackend.defaultsKey) }
    }

    /// The concrete store `credentialBackend` currently resolves to.
    var activeCredentialStore: CredentialStore { credentialBackend.store }

    /// How RDP sessions present their window. Defaults to fullscreen, which
    /// is what a remote desktop is normally for; the previous behaviour was a
    /// fixed 1280x800 window with no way to go fullscreen at all.
    var rdpDisplayMode: RDPDisplayMode {
        didSet { UserDefaults.standard.set(rdpDisplayMode.rawValue, forKey: Keys.rdpDisplayMode) }
    }

    private enum Keys {
        static let rdpDisplayMode = "rdp.displayMode"
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
        self.rdpDisplayMode = RDPDisplayMode(rawValue: UserDefaults.standard.string(forKey: Keys.rdpDisplayMode) ?? "") ?? .fullscreen
        self.credentialBackend = CredentialBackend.current
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

extension SecuritySettings {
    /// Which storage backend is used for saved credentials (passwords).
    /// Persisted under UserDefaults key `security.credentialBackend`.
    enum CredentialBackend: String, CaseIterable, Hashable, Identifiable {
        case none
        case keychain
        case encryptedFile

        var id: String { rawValue }

        /// The concrete store this backend resolves to. `KeychainStore()`
        /// (not `.shared`) because `KeychainStore` holds no state beyond an
        /// immutable service name, so a fresh instance targeting the
        /// production service behaves identically to a shared one — this
        /// avoids a Sources-wide dependency on the singleton.
        ///
        /// `EncryptedFileCredentialStore.shared` is different: it holds the
        /// derived key in memory for the app run. A fresh instance per call
        /// (like `KeychainStore()`) would throw that key away between
        /// calls and leave the store permanently re-locking itself, so this
        /// case must resolve to the singleton.
        var store: CredentialStore {
            switch self {
            case .none: return NullCredentialStore.shared
            case .keychain: return KeychainStore()
            case .encryptedFile: return EncryptedFileCredentialStore.shared
            }
        }

        var displayName: String { store.displayName }

        static let defaultsKey = "security.credentialBackend"

        /// Reads the persisted choice directly from `UserDefaults`,
        /// bypassing the `@MainActor`-isolated `SecuritySettings.shared`.
        /// Nonisolated and thread-safe, so it's safe to use from contexts
        /// that aren't on the main actor — see `ActiveCredentialStore`.
        static var current: CredentialBackend {
            CredentialBackend(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .none
        }
    }
}
