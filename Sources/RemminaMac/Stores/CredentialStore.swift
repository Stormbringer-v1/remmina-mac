import Foundation
import SwiftUI

/// The kind of secret a `CredentialStore` can hold for a profile.
/// Extensible: a passphrase kind (for SSH key passphrases) is planned.
enum SecretKind: Sendable {
    case password

    /// Stable string used to build the `"<profileUUID>.<secretKind>"`
    /// storage key in file-based backends (`EncryptedFileCredentialStore`).
    /// Deliberately not derived from the case name via `String(describing:)`
    /// or similar reflection — a future case rename would silently change
    /// every stored key and orphan existing secrets.
    var storageKey: String {
        switch self {
        case .password: return "password"
        }
    }
}

/// Abstraction over where per-profile secrets (passwords, and in future
/// SSH key passphrases) are stored.
///
/// RemminaMac is an open-source project; the maintainer does not want it
/// tied to Apple Keychain (or to any single storage backend) so that other
/// integrators — and a future Linux/Windows port — need no changes to the
/// core. `KeychainStore` is one conformance; `NullCredentialStore` (stores
/// nothing) is the shipped default.
protocol CredentialStore: AnyObject, Sendable {
    /// Returns the stored secret, or `nil` if none is stored. Throws if the
    /// backend itself failed (e.g. Keychain access denied) — never throws
    /// merely because nothing is stored.
    func secret(_ kind: SecretKind, for profileId: UUID) throws -> String?

    /// Saves (creating or overwriting) a secret for a profile.
    func save(_ secret: String, kind: SecretKind, for profileId: UUID) throws

    /// Deletes a single secret kind for a profile.
    func delete(_ kind: SecretKind, for profileId: UUID) throws

    /// Removes every secret this store holds for a profile (used on profile deletion).
    func deleteAll(for profileId: UUID) throws

    /// False when the backend intentionally persists nothing, so the UI can
    /// say so instead of pretending a typed password was saved.
    var persists: Bool { get }

    /// Short human-readable name for Settings, e.g. "None", "macOS Keychain".
    var displayName: String { get }
}

/// A `CredentialStore` that stores nothing. This is the shipped default:
/// RemminaMac does not tie itself to Apple Keychain (or any storage
/// backend), which also means an ad-hoc-signed rebuild no longer triggers a
/// Keychain ACL dialog. SSH keeps working via SSH keys/ssh-agent with no
/// backend at all. VNC/RDP profiles that need a password require the user
/// to opt into Keychain in Settings → Security.
final class NullCredentialStore: CredentialStore {
    static let shared = NullCredentialStore()

    func secret(_ kind: SecretKind, for profileId: UUID) throws -> String? { nil }
    func save(_ secret: String, kind: SecretKind, for profileId: UUID) throws {}
    func delete(_ kind: SecretKind, for profileId: UUID) throws {}
    func deleteAll(for profileId: UUID) throws {}

    var persists: Bool { false }
    var displayName: String { "None (use SSH keys / ssh-agent)" }
}

/// Default `credentialStore` for `ConnectionManager`: resolves the backend
/// fresh on every call via `SecuritySettings.CredentialBackend.current`, a
/// direct (nonisolated, thread-safe) `UserDefaults` read. This is
/// deliberately NOT `SecuritySettings.shared` (which is `@MainActor`) so
/// this type can be referenced from any context — including default
/// argument expressions evaluated wherever `ConnectionManager()` is
/// constructed — without forcing actor isolation onto callers. The upshot:
/// toggling Settings → Security → Credential Storage takes effect for the
/// next `openSession` call without relaunching the app.
final class ActiveCredentialStore: CredentialStore {
    static let shared = ActiveCredentialStore()
    private init() {}

    private var resolved: CredentialStore { SecuritySettings.CredentialBackend.current.store }

    var persists: Bool { resolved.persists }
    var displayName: String { resolved.displayName }

    func secret(_ kind: SecretKind, for profileId: UUID) throws -> String? {
        try resolved.secret(kind, for: profileId)
    }

    func save(_ secret: String, kind: SecretKind, for profileId: UUID) throws {
        try resolved.save(secret, kind: kind, for: profileId)
    }

    func delete(_ kind: SecretKind, for profileId: UUID) throws {
        try resolved.delete(kind, for: profileId)
    }

    func deleteAll(for profileId: UUID) throws {
        try resolved.deleteAll(for: profileId)
    }
}

// MARK: - SwiftUI environment

private struct CredentialStoreKey: EnvironmentKey {
    static let defaultValue: CredentialStore = NullCredentialStore.shared
}

extension EnvironmentValues {
    /// The active `CredentialStore`, injected from `MainView` (see its
    /// `credentialStore` computed property) so `ProfileEditView` and
    /// `ProfileDetailView` can read it without reaching for a global.
    var credentialStore: CredentialStore {
        get { self[CredentialStoreKey.self] }
        set { self[CredentialStoreKey.self] = newValue }
    }
}
