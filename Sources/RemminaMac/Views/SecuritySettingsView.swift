import SwiftUI

/// Settings window for user-controllable security toggles.
///
/// The remote-content side effects (clipboard sync, URL opening) are
/// opt-in for safety. The defaults are off; this window is where the user
/// turns them on when they want them.
struct SecuritySettingsView: View {
    @Bindable private var settings = SecuritySettings.shared
    @State private var showingEncryptedStoreSheet = false

    var body: some View {
        Form {
            Section {
                Text("Remote content can drive local resources (clipboard, URL opening). These are off by default; turn them on only when you trust the remote host.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Remote Content")
            }

            Section {
                Toggle("Allow remote clipboard to write local pasteboard",
                       isOn: $settings.allowRemoteClipboard)
                Text("A remote SSH or VNC session can replace your local clipboard contents. Off by default. RDP clipboard sharing is all-or-nothing (xfreerdp has no per-direction switch) and is active whenever either clipboard toggle is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Send local clipboard to remote on change",
                       isOn: $settings.sendLocalClipboard)
                Text("When the VNC toggle is on, your local clipboard is sent to the remote on every change. RDP clipboard sharing is all-or-nothing and is active whenever either clipboard toggle is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Allow remote to open links",
                       isOn: $settings.allowRemoteOpenLink)
                Text("When on, only http, https, and mailto links from a remote terminal are opened. Other schemes (file, ssh, custom URL handlers) are always refused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Toggles")
            }

            Section {
                Toggle("Ignore certificate validation errors",
                       isOn: $settings.rdpIgnoreCertificate)
                Text("When enabled, RDP connections accept any server certificate without verification (/cert:ignore). Off by default (/cert:tofu: accept on first use, pin thereafter).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("RDP")
            }

            Section {
                Picker("Store passwords using", selection: $settings.credentialBackend) {
                    ForEach(SecuritySettings.CredentialBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .onChange(of: settings.credentialBackend) { _, newValue in
                    if newValue == .encryptedFile && !EncryptedFileCredentialStore.shared.isUnlocked {
                        showingEncryptedStoreSheet = true
                    }
                }
                Text("\"None\" (the default) saves nothing — RemminaMac isn't tied to any one storage backend. SSH keeps working via SSH keys or ssh-agent, but VNC and RDP profiles that need a password can't connect until you choose Keychain or Encrypted file. \"macOS Keychain\" saves passwords on this Mac only, protected by the system keychain. \"Encrypted file (portable)\" encrypts secrets with a passphrase you choose, stored in a file on this machine — it depends on no OS keychain, so it works the same on a future Linux/Windows build; if the passphrase is lost, the stored secrets cannot be recovered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.credentialBackend == .encryptedFile {
                    HStack {
                        Image(systemName: EncryptedFileCredentialStore.shared.isUnlocked ? "lock.open" : "lock")
                            .foregroundStyle(EncryptedFileCredentialStore.shared.isUnlocked ? .green : .secondary)
                        Text(EncryptedFileCredentialStore.shared.isUnlocked ? "Unlocked for this session" : "Locked")
                        Spacer()
                        Button(unlockButtonTitle) {
                            if EncryptedFileCredentialStore.shared.isUnlocked {
                                EncryptedFileCredentialStore.shared.lock()
                            } else {
                                showingEncryptedStoreSheet = true
                            }
                        }
                    }
                }
            } header: {
                Text("Credential Storage")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 460)
        .sheet(isPresented: $showingEncryptedStoreSheet) {
            EncryptedStorePassphraseView(store: EncryptedFileCredentialStore.shared) { _ in
                showingEncryptedStoreSheet = false
            }
        }
    }

    private var unlockButtonTitle: String {
        if EncryptedFileCredentialStore.shared.isUnlocked { return "Lock" }
        return EncryptedFileCredentialStore.shared.fileExists ? "Unlock" : "Create"
    }
}
