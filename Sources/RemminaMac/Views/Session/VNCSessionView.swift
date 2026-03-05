import SwiftUI

/// Container view for a VNC session with toolbar and desktop view.
struct VNCSessionView: View {
    let session: VNCSession
    @State private var currentImage: NSImage?
    @State private var fitToWindow = true
    @State private var clipboardSync = true
    @State private var fbInfo = ""

    var body: some View {
        VStack(spacing: 0) {
            // VNC Desktop
            VNCDesktopView(
                session: session,
                currentImage: $currentImage,
                fitToWindow: fitToWindow
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)))

            // VNC-specific toolbar
            HStack(spacing: 16) {
                // Resolution info
                Text(fbInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Fit to window toggle
                Toggle(isOn: $fitToWindow) {
                    Label("Fit to Window", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)

                // Clipboard sync
                Toggle(isOn: $clipboardSync) {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)

                // Refresh
                Button(action: {
                    session.requestFullUpdate()
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .controlSize(.small)

                // Screenshot
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
        .onAppear {
            session.onFramebufferUpdate = { [weak session] image in
                currentImage = image
                if let s = session {
                    fbInfo = "\(s.serverName) – \(s.framebufferWidth)×\(s.framebufferHeight)"
                }
            }

            // Clipboard sync: monitor pasteboard
            if clipboardSync {
                setupClipboardSync()
            }
        }
        .onChange(of: clipboardSync) { _, enabled in
            if enabled {
                setupClipboardSync()
            }
        }
    }

    private func takeScreenshot() {
        guard let image = currentImage else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(session.profileName)_screenshot.png"

        if panel.runModal() == .OK, let url = panel.url {
            if let tiffData = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                try? pngData.write(to: url)
                AppLogger.shared.log("VNC: Screenshot saved to \(url.path)")
            }
        }
    }

    private func setupClipboardSync() {
        // Poll clipboard changes periodically
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            guard clipboardSync, session.status == .connected else {
                timer.invalidate()
                return
            }

            if let text = NSPasteboard.general.string(forType: .string) {
                // Send to remote (could add change detection)
                _ = text
            }
        }
    }
}
