import SwiftUI

/// Settings window for user-controllable security toggles.
///
/// The remote-content side effects (clipboard sync, URL opening) are
/// opt-in for safety. The defaults are off; this window is where the user
/// turns them on when they want them.
struct SecuritySettingsView: View {
    @Bindable private var settings = SecuritySettings.shared

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
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 420)
    }
}
