import SwiftUI
import AppKit
import SwiftTerm

/// Professional terminal emulator view using SwiftTerm.
///
/// SwiftTerm provides full VT100/xterm emulation including:
/// - Alternate screen buffer (vim, nano, top, htop, tmux)
/// - Cursor movement and positioning
/// - 256-color and true-color support
/// - Mouse tracking
/// - Scrollback buffer
/// - Copy/paste (⌘C/⌘V)
///
/// This replaces the previous NSTextView + ANSI regex approach which could
/// not handle any full-screen terminal application.
struct TerminalView: NSViewRepresentable {
    let session: SSHSession

    func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let terminalView = SwiftTerm.TerminalView(frame: .zero)

        // Configure appearance
        let fontSize: CGFloat = 13
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminalView.font = font

        // Dark terminal theme
        terminalView.nativeBackgroundColor = NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0)
        terminalView.nativeForegroundColor = NSColor(red: 0.85, green: 0.85, blue: 0.85, alpha: 1.0)
        terminalView.caretColor = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)

        // Set the delegate — coordinator bridges between SwiftTerm and SSHSession
        terminalView.terminalDelegate = context.coordinator

        // Store references in the coordinator
        context.coordinator.terminalView = terminalView
        context.coordinator.session = session

        // Register the coordinator as the SSH output receiver
        session.terminalFeedHandler = { [weak terminalView] data in
            guard let terminalView = terminalView else { return }
            let bytes = Array(data)
            // Feed raw bytes directly to SwiftTerm — it handles ALL escape sequences
            terminalView.feed(byteArray: bytes[...])
        }

        return terminalView
    }

    func updateNSView(_ terminalView: SwiftTerm.TerminalView, context: Context) {
        // Make the terminal the first responder on initial appearance
        if !context.coordinator.hasFocused {
            if let window = terminalView.window {
                window.makeFirstResponder(terminalView)
                context.coordinator.hasFocused = true
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Coordinator bridges SwiftTerm's delegate callbacks to the SSHSession.
    class Coordinator: NSObject, SwiftTerm.TerminalViewDelegate {
        weak var terminalView: SwiftTerm.TerminalView?
        weak var session: SSHSession?
        var hasFocused = false

        // MARK: - TerminalViewDelegate

        /// Called when the user types — forward raw bytes to SSH
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            session?.sendInput(Data(data))
        }

        /// Called when the terminal size changes — propagate to PTY via TIOCSWINSZ
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            session?.resize(cols: newCols, rows: newRows)
        }

        /// Called when the running program sets the terminal title
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {
            // Could update the tab title in the future
        }

        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            }
        }

        func bell(source: SwiftTerm.TerminalView) {
            NSSound.beep()
        }

        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            if let str = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            }
        }

        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
