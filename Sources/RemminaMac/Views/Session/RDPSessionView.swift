import SwiftUI

/// View for RDP sessions, showing xfreerdp output or setup instructions.
struct RDPSessionView: View {
    let session: RDPSession
    @State private var outputText = ""
    @State private var showingSetup = false

    var body: some View {
        VStack(spacing: 0) {
            if case .error(let msg) = session.status {
                setupInstructionsView(error: msg)
            } else if case .connected = session.status {
                connectedView
            } else {
                connectingView
            }
        }
        .onAppear {
            session.onOutputReceived = { text in
                outputText += text
            }
        }
    }

    // MARK: - Connected View

    private var connectedView: some View {
        VStack(spacing: 0) {
            // Output console (xfreerdp runs in its own window)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(outputText.isEmpty ? "RDP session active. The remote desktop is displayed in the xfreerdp window.\n\nIf you don't see a window, check for authentication prompts." : outputText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)))

            // Toolbar
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Connected to \(session.profileName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: {
                    session.sendCtrlAltDel()
                }) {
                    Label("Ctrl+Alt+Del", systemImage: "keyboard")
                        .font(.caption)
                }
                .controlSize(.small)

                Button(action: takeScreenshot) {
                    Label("Screenshot", systemImage: "camera")
                        .font(.caption)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    // MARK: - Connecting View

    private var connectingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Connecting…")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Setup Instructions

    private func setupInstructionsView(error: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "display")
                .font(.system(size: 64))
                .foregroundStyle(.orange)

            Text("RDP Setup Required")
                .font(.title)
                .fontWeight(.bold)

            Text(error)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)

            VStack(alignment: .leading, spacing: 16) {
                Text("Installation Options")
                    .font(.headline)

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("FreeRDP (Recommended)", systemImage: "terminal")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text("Install via Homebrew:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("brew install freerdp")
                                .font(.system(.caption, design: .monospaced))
                                .padding(8)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("brew install freerdp", forType: .string)
                            }
                            .controlSize(.small)
                        }

                        Text("After installing, reconnect to this profile.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(4)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Microsoft Remote Desktop", systemImage: "macwindow")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text("Install from the Mac App Store. RemminaMac will automatically detect and use it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(4)
                }
            }
            .frame(maxWidth: 450)

            Button("Retry Connection") {
                session.reconnect()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func takeScreenshot() {
        // For xfreerdp, screenshot would require integration
        AppLogger.shared.log("RDP: Screenshot not available in external window mode", level: .warning)
    }
}
