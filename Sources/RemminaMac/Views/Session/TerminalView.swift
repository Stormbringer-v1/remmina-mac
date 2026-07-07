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

    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator()
    }
}
