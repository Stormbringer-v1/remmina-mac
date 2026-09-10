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
                .onSubmit(submit)

            if isCreateFlow {
                SecureField("Confirm passphrase", text: $confirmPassphrase)
                    .textContentType(.newPassword)
                    .onSubmit(submit)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onDone(false)
                }
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

    private func submit() {
        guard canSubmit else {
            if isCreateFlow && passphrase != confirmPassphrase {
                errorMessage = "Passphrases do not match."
            }
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            if isCreateFlow {
                try store.createStore(withPassphrase: passphrase)
            } else {
                try store.unlock(withPassphrase: passphrase)
            }
            onDone(true)
        } catch EncryptedStoreError.wrongPassphrase {
            errorMessage = "Incorrect passphrase. Try again."
            passphrase = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
