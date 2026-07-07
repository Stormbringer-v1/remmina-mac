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
