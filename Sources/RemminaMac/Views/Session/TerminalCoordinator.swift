import Foundation
import AppKit
import SwiftTerm

/// Coordinator bridges SwiftTerm's delegate callbacks to the SSHSession.
class TerminalCoordinator: NSObject, SwiftTerm.TerminalViewDelegate {
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
        // The link text comes from the remote program. We refuse to open any
        // URL unless the user has explicitly enabled remote link opening AND
        // the URL's scheme is in the safe allowlist (http, https, mailto).
        // This blocks the remote from invoking file://, ssh://, tel://, or
        // any custom x-callback-url scheme that another app may have
        // registered as a handler.
        guard let url = URL(string: link) else { return }
        MainActor.assumeIsolated {
            guard SecuritySettings.shared.allowRemoteOpenLink else { return }
            guard SecuritySettings.isLinkSchemeAllowed(url) else {
                AppLogger.shared.log("Terminal: refused remote open of \(url.scheme ?? "nil") URL", level: .warning)
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    func bell(source: SwiftTerm.TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        // The clipboard content comes from the remote program (OSC 52). We
        // refuse to overwrite the local pasteboard unless the user has
        // explicitly enabled remote→local clipboard sync. This blocks a
        // hostile or compromised remote from silently replacing clipboard
        // contents (e.g. with a malicious URL the user later pastes into a
        // browser).
        MainActor.assumeIsolated {
            guard SecuritySettings.shared.allowRemoteClipboard else { return }
            guard let str = String(data: content, encoding: .utf8) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}

    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}
