import SwiftUI

/// Sheet that creates or unlocks the encrypted-file credential store by
/// prompting for a passphrase.
///
/// Two flows, chosen automatically from whether a store file already
/// exists on disk (`store.fileExists`):
/// - **Create** (no file yet): asks for the passphrase twice to catch typos,
///   since there is no recovery if it's mistyped and forgotten.
/// - **Unlock** (file exists): asks once; a wrong passphrase shows a clear
///   message and lets the user retry without dismissing the sheet.
struct EncryptedStorePassphraseView: View {
    let store: EncryptedFileCredentialStore
    /// Called with `true` once the store is unlocked/created, or `false` if
    /// the user cancels. The caller is responsible for dismissing.
    var onDone: (Bool) -> Void

    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    private var isCreateFlow: Bool { !store.fileExists }

    private var canSubmit: Bool {
        guard !passphrase.isEmpty, !isWorking else { return false }
        if isCreateFlow { return passphrase == confirmPassphrase }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isCreateFlow ? "Create Encrypted Credential Store" : "Unlock Encrypted Credential Store")
                .font(.headline)

            if isCreateFlow {
                Text("Choose a passphrase to protect secrets stored in this file. It is not saved anywhere — if it's lost, the stored secrets cannot be recovered.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Enter the passphrase you chose when this store was created.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField("Passphrase", text: $passphrase)
                .textContentType(isCreateFlow ? .newPassword : .password)
                .disabled(isWorking)
                .onSubmit { submit() }

            if isCreateFlow {
                SecureField("Confirm passphrase", text: $confirmPassphrase)
                    .textContentType(.newPassword)
                    .disabled(isWorking)
                    .onSubmit { submit() }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Cancel") {
                    onDone(false)
                }
                .disabled(isWorking)
                Button(isCreateFlow ? "Create" : "Unlock") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// `@MainActor` explicitly: a plain (non-isolated) method here would
    /// make the isolation of the `Task { }` below — and therefore of the
    /// state mutations after its `await` — depend on inference rules that
    /// don't actually apply to arbitrary helper methods (only `body` itself
    /// is `@MainActor`-isolated by the `View` protocol requirement). Marking
    /// `submit()` itself `@MainActor` makes that isolation explicit and
    /// compiler-checked instead of assumed.
    @MainActor
    private func submit() {
        guard canSubmit else {
            if isCreateFlow && passphrase != confirmPassphrase {
                errorMessage = "Passphrases do not match."
            }
            return
        }
        isWorking = true
        errorMessage = nil

        // PBKDF2 at 600,000 iterations takes hundreds of milliseconds; run
        // it off the main thread so `isWorking`/the progress indicator
        // actually get to render instead of the UI freezing for the
        // duration. `store` is Sendable (its derived key lives behind an
        // internal lock), so it's safe to use from the detached task.
        let enteredPassphrase = passphrase
        let creating = isCreateFlow
        let targetStore = store
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if creating {
                        try targetStore.createStore(withPassphrase: enteredPassphrase)
                    } else {
                        try targetStore.unlock(withPassphrase: enteredPassphrase)
                    }
                }.value
                // Back on the main actor: this Task runs on the MainActor
                // because `submit()` (its enclosing, isolation-inferring
                // context) is `@MainActor`; only the detached child above
                // ran off-main.
                isWorking = false
                onDone(true)
            } catch EncryptedStoreError.wrongPassphrase {
                isWorking = false
                errorMessage = "Incorrect passphrase. Try again."
                passphrase = ""
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
