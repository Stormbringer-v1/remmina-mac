import SwiftUI

/// Container view for a VNC session with toolbar and desktop view.
struct VNCSessionView: View {
    let session: VNCSession
    @State private var currentImage: NSImage?
    @State private var dirtyRect: NSRect = .null
    @State private var fitToWindow = true
    @State private var fbInfo = ""
    @Bindable private var security = SecuritySettings.shared

    /// Local clipboard polling state. The poller only fires while the
    /// session is connected and the user has enabled
    /// SecuritySettings.sendLocalClipboard. We seed `lastSentChangeCount`
    /// from the current change count so that enabling the toggle does
    /// NOT immediately send the existing pasteboard content (PROBLEMS.md
    /// ISSUE-021) — only a subsequent change triggers a send.
    ///
    /// PROBLEMS.md ISSUE-030: this used to be a `Timer` whose closure read
    /// `security` (a `@MainActor` type) directly — a warning under Swift 5
    /// and a hard error under Swift 6, since a `Timer` closure is
    /// `@Sendable`. Driving the poll from a `.task(id:)` instead keeps the
    /// whole loop on the main actor with no Sendable boundary to cross.
    @State private var lastSentChangeCount: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            VNCDesktopView(
                session: session,
                currentImage: $currentImage,
                dirtyRect: $dirtyRect,
                fitToWindow: fitToWindow
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)))

            HStack(spacing: 16) {
                Text(fbInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle(isOn: $fitToWindow) {
                    Label("Fit to Window", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)

                Toggle(isOn: $security.sendLocalClipboard) {
                    Label("Clipboard", systemImage: "doc.on.clipboard")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .controlSize(.small)

                Button(action: {
                    session.requestFullUpdate()
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
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
        .onAppear {
            session.onFramebufferUpdate = { [weak session] image, rect in
                currentImage = image
                dirtyRect = rect
                if let s = session {
                    fbInfo = "\(s.serverName) – \(s.framebufferWidth)×\(s.framebufferHeight)"
                }
            }
        }
        // Restarts automatically whenever the toggle flips, and is cancelled
        // automatically when the view disappears — replaces the old
        // Timer + onAppear/onDisappear/onChange trio.
        .task(id: security.sendLocalClipboard) {
            await runClipboardSyncLoop()
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

    /// The local→remote clipboard poller (PROBLEMS.md ISSUE-021), driven by
    /// `.task(id:)` on `security.sendLocalClipboard`. Runs entirely on the
    /// main actor — no `Timer`, no `Sendable` closure, no cross-actor
    /// capture of `security` (PROBLEMS.md ISSUE-030).
    ///
    /// Seed `lastSentChangeCount` with the current pasteboard change count
    /// BEFORE the first poll. This is the bug fix: previously the field was
    /// -1, so the first tick after enabling the toggle unconditionally sent
    /// whatever was on the pasteboard to the remote — including a password
    /// the user had just copied from a password manager.
    ///
    /// We also skip:
    ///   - pasteboards whose types include `org.nspasteboard.ConcealedType`
    ///     (1Password, Bitwarden, etc. mark sensitive content this way)
    ///   - strings larger than 64 KiB (matches the implicit VNC client
    ///     limit and prevents a giant paste from hogging the write queue)
    private func runClipboardSyncLoop() async {
        guard security.sendLocalClipboard else { return }
        // Seed: don't send the current contents.
        lastSentChangeCount = NSPasteboard.general.changeCount
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return // cancelled during sleep
            }
            if Task.isCancelled { return }
            guard security.sendLocalClipboard, session.status == .connected else { continue }
            let pb = NSPasteboard.general
            let changeCount = pb.changeCount
            guard VNCSessionView.shouldSend(changeCount: changeCount, lastSent: lastSentChangeCount) else {
                continue
            }
            // Concealed pasteboard (password managers).
            if let types = pb.types,
               types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) {
                lastSentChangeCount = changeCount
                continue
            }
            guard let text = pb.string(forType: .string), !text.isEmpty else {
                lastSentChangeCount = changeCount
                continue
            }
            // Cap outgoing size at 64 KiB.
            guard text.utf8.count <= 65_536 else {
                lastSentChangeCount = changeCount
                continue
            }
            lastSentChangeCount = changeCount
            session.sendClipboardText(text)
        }
    }

    /// Pure decision for the clipboard-poller change detection (PROBLEMS.md
    /// ISSUE-021 acceptance: a static function unit-tested in isolation).
    /// Returns true if the poller should send the new pasteboard contents
    /// given the most recent change count and the change count we last
    /// sent.
    static func shouldSend(changeCount: Int, lastSent: Int) -> Bool {
        // A change-count of 0 is the OS's "no clipboard" sentinel; never
        // treat that as content to forward.
        guard changeCount > 0 else { return false }
        return changeCount != lastSent
    }
}
