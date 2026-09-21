import SwiftUI
import AppKit

/// Remote desktop view for VNC sessions showing the live framebuffer.
struct VNCDesktopView: NSViewRepresentable {
    let session: VNCSession
    @Binding var currentImage: NSImage?
    /// The union rectangle of pixels that changed in the most recent update,
    /// in framebuffer pixel coordinates. The canvas asks AppKit to repaint
    /// only this region (PROBLEMS.md ISSUE-024).
    @Binding var dirtyRect: NSRect
    let fitToWindow: Bool

    func makeNSView(context: Context) -> VNCCanvasView {
        let canvas = VNCCanvasView()
        canvas.session = session
        canvas.fitToWindow = fitToWindow
        return canvas
    }

    func updateNSView(_ canvas: VNCCanvasView, context: Context) {
        canvas.setFitToWindow(fitToWindow)
        if let image = currentImage {
            canvas.updateImage(image, dirtyRect: dirtyRect)
        }
    }
}

/// Conforms to `SessionFocusable` (PROBLEMS.md ISSUE-003) so
/// `SessionTabView`'s focus search can find this view by type rather than
/// by guessing from a stringified AppKit class name.
extension VNCCanvasView: SessionFocusable {}

/// NSView that renders the VNC framebuffer and handles mouse/keyboard input.
final class VNCCanvasView: NSView {
    var session: VNCSession?
    // `makeNSView` assigns this directly for the initial value; after that,
    // changes must go through `setFitToWindow(_:)` so a toggle triggers a
    // full repaint (see `setFitToWindow`).
    fileprivate(set) var fitToWindow = true
    private var framebufferImage: NSImage?
    private var imageRect: NSRect = .zero
    private var trackingArea: NSTrackingArea?
    /// Modifier flag diffing (PROBLEMS.md ISSUE-023). The first
    /// `flagsChanged` event establishes the baseline; subsequent events
    /// only send key up/down for modifiers that actually changed.
    private var lastFlags: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Focus is owned solely by SessionContainerView.updateActive, which
        // finds the active tab's SessionFocusable view and makes it first
        // responder. Every session view stays alive (hidden) in the
        // ZStack, so grabbing first responder here would steal keyboard
        // focus from the active tab whenever a second VNC tab is opened.
        updateTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldSize = frame.size
        super.setFrameSize(newSize)
        guard newSize != oldSize else { return }
        // A resize invalidates the fit-to-window scale/centering, and no
        // new framebuffer update will arrive on its own to trigger a
        // redraw — repaint the whole canvas at the new size immediately.
        needsDisplay = true
    }

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// Update the fit-to-window mode. SwiftUI's `updateNSView` calls this
    /// on every body re-evaluation, not just when the toggle actually
    /// flips, so only the transition needs a repaint — reassigning the
    /// same value should stay a no-op.
    func setFitToWindow(_ newValue: Bool) {
        guard newValue != fitToWindow else { return }
        fitToWindow = newValue
        // The scale/centering used by `draw(_:)` depends on `fitToWindow`,
        // so the whole canvas is stale, not just the last dirty region.
        needsDisplay = true
    }

    /// Receive a new framebuffer snapshot. We ask AppKit to repaint only
    /// the dirty region (ISSUE-024) rather than the full canvas, which
    /// keeps incremental updates cheap.
    ///
    /// SwiftUI re-invokes `updateNSView` (and thus this call) whenever the
    /// enclosing view re-renders for any reason, including a
    /// `fitToWindow` toggle that brought no new framebuffer with it. In
    /// that case `image` is the same instance already on screen and
    /// `dirtyRect` is left over from the last real server update, so
    /// trusting it here would repaint only that stale sliver. Only act on
    /// `dirtyRect` when the image itself changed.
    func updateImage(_ image: NSImage, dirtyRect: NSRect) {
        let isNewImage = image !== framebufferImage
        framebufferImage = image
        guard isNewImage else { return }
        guard !dirtyRect.isEmpty, !dirtyRect.isNull else {
            needsDisplay = true
            return
        }
        // dirtyRect is in framebuffer coordinates; map to view coords.
        let viewRect = mapDirtyToView(dirtyRect)
        if viewRect.isNull || viewRect.isEmpty {
            needsDisplay = true
        } else {
            setNeedsDisplay(viewRect)
        }
    }

    /// Map a framebuffer-pixel dirty rectangle to the corresponding region
    /// in view coordinates, accounting for fit-to-window scaling and
    /// centering.
    private func mapDirtyToView(_ fbRect: NSRect) -> NSRect {
        guard let image = framebufferImage, imageRect.width > 0, imageRect.height > 0 else { return .null }
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return .null }
        let scaleX = imageRect.width / imgSize.width
        let scaleY = imageRect.height / imgSize.height
        return NSRect(
            x: imageRect.minX + fbRect.minX * scaleX,
            y: imageRect.minY + fbRect.minY * scaleY,
            width: fbRect.width * scaleX,
            height: fbRect.height * scaleY
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image = framebufferImage else {
            NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0).setFill()
            dirtyRect.fill()
            return
        }

        NSColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1.0).setFill()
        bounds.fill()

        if fitToWindow {
            let imageSize = image.size
            let viewSize = bounds.size
            let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
            let scaledSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = NSPoint(
                x: (viewSize.width - scaledSize.width) / 2,
                y: (viewSize.height - scaledSize.height) / 2
            )
            imageRect = NSRect(origin: origin, size: scaledSize)
        } else {
            imageRect = NSRect(origin: .zero, size: image.size)
        }

        image.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1.0)
    }

    // MARK: - Coordinate Translation

    private func translatePoint(_ viewPoint: NSPoint) -> (x: UInt16, y: UInt16)? {
        guard let session = session, imageRect.width > 0, imageRect.height > 0 else { return nil }

        let relX = (viewPoint.x - imageRect.minX) / imageRect.width
        let relY = (viewPoint.y - imageRect.minY) / imageRect.height

        guard relX >= 0, relX <= 1, relY >= 0, relY <= 1 else { return nil }

        let fbWidth = session.framebufferWidth
        let fbHeight = session.framebufferHeight
        guard fbWidth > 0, fbHeight > 0 else { return nil }

        // relX/relY can reach exactly 1.0 at the far edge, which would
        // otherwise yield fbX == fbWidth / fbY == fbHeight — one pixel
        // past the valid framebuffer range.
        let fbX = min(UInt16(relX * CGFloat(fbWidth)), UInt16(fbWidth - 1))
        let fbY = min(UInt16(relY * CGFloat(fbHeight)), UInt16(fbHeight - 1))
        return (fbX, fbY)
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (x, y) = translatePoint(point) else { return }
        session?.sendPointerEvent(buttons: 1, x: x, y: y)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (x, y) = translatePoint(point) else { return }
        session?.sendPointerEvent(buttons: 0, x: x, y: y)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (x, y) = translatePoint(point) else { return }
        session?.sendPointerEvent(buttons: 0, x: x, y: y)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (x, y) = translatePoint(point) else { return }
        session?.sendPointerEvent(buttons: 1, x: x, y: y)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (x, y) = translatePoint(point) else { return }
        session?.sendPointerEvent(buttons: 4, x: x, y: y)
    }

    override func rightMouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (x, y) = translatePoint(point) else { return }
        session?.sendPointerEvent(buttons: 0, x: x, y: y)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (x, y) = translatePoint(point) else { return }

        if event.deltaY > 0 {
            session?.sendPointerEvent(buttons: 8, x: x, y: y)
            session?.sendPointerEvent(buttons: 0, x: x, y: y)
        } else if event.deltaY < 0 {
            session?.sendPointerEvent(buttons: 16, x: x, y: y)
            session?.sendPointerEvent(buttons: 0, x: x, y: y)
        }
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        let keysym = VNCCanvasView.keysym(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            flags: event.modifierFlags
        )
        session?.sendKeyEvent(down: true, key: keysym)
    }

    override func keyUp(with event: NSEvent) {
        let keysym = VNCCanvasView.keysym(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            flags: event.modifierFlags
        )
        session?.sendKeyEvent(down: false, key: keysym)
    }

    /// PROBLEMS.md ISSUE-023: only emit a key up/down for modifiers whose
    /// state actually changed since the previous `flagsChanged` event.
    /// Otherwise we'd send spurious key-ups for modifiers that were never
    /// down, which some servers interpret as real input.
    override func flagsChanged(with event: NSEvent) {
        let modMap: [(NSEvent.ModifierFlags, UInt32)] = [
            (.shift, 0xFFE1),    // XK_Shift_L
            (.control, 0xFFE3),  // XK_Control_L
            (.option, 0xFFE9),   // XK_Alt_L
            (.command, 0xFFE7),  // XK_Meta_L
            (.capsLock, 0xFFE5), // XK_Caps_Lock
        ]

        for (flag, keysym) in modMap {
            let wasPressed = lastFlags.contains(flag)
            let isPressed = event.modifierFlags.contains(flag)
            if wasPressed != isPressed {
                session?.sendKeyEvent(down: isPressed, key: keysym)
            }
        }
        lastFlags = event.modifierFlags
    }

    /// Map macOS key event data to an X11 keysym for the RFB KeyEvent
    /// message (PROBLEMS.md ISSUE-023).
    ///
    /// Rules:
    /// - The special-key table for `keyCode` wins (Return, Tab, arrows,
    ///   F1..F12, etc.) — these have stable keysyms regardless of the
    ///   typed character.
    /// - When Control or Command is held we use
    ///   `charactersIgnoringModifiers` so Ctrl+C produces XK_c (0x63),
    ///   not U+0003. The typed character is what the user *means*, not
    ///   the OS-cooked control glyph.
    /// - Unicode scalars ≥ 0x100 use the `0x01000000 | codepoint` form
    ///   required by the RFB spec for non-Latin-1 input.
    static func keysym(keyCode: UInt16,
                       characters: String?,
                       charactersIgnoringModifiers: String?,
                       flags: NSEvent.ModifierFlags) -> UInt32 {
        // Special keys — independent of modifier state.
        switch keyCode {
        case 36: return 0xFF0D  // Return
        case 48: return 0xFF09  // Tab
        case 51: return 0xFF08  // Backspace
        case 53: return 0xFF1B  // Escape
        case 117: return 0xFFFF // Delete
        case 123: return 0xFF51 // Left
        case 124: return 0xFF53 // Right
        case 125: return 0xFF54 // Down
        case 126: return 0xFF52 // Up
        case 115: return 0xFF50 // Home
        case 119: return 0xFF57 // End
        case 116: return 0xFF55 // PageUp
        case 121: return 0xFF56 // PageDown
        case 122: return 0xFFBE // F1
        case 120: return 0xFFBF // F2
        case 99: return 0xFFC0  // F3
        case 118: return 0xFFC1 // F4
        case 96: return 0xFFC2  // F5
        case 97: return 0xFFC3  // F6
        case 98: return 0xFFC4  // F7
        case 100: return 0xFFC5 // F8
        case 101: return 0xFFC6 // F9
        case 109: return 0xFFC7 // F10
        case 103: return 0xFFC8 // F11
        case 111: return 0xFFC9 // F12
        case 76: return 0xFF8D  // Keypad Enter
        default: break
        }

        // Use the un-modified character when Control or Command is held so
        // the remote sees a plain letter (Ctrl+C → 0x63) rather than the
        // control glyph (0x03). For all other modifiers we use the
        // cooked `characters`, which is what the user sees.
        let base: String?
        if flags.contains(.control) || flags.contains(.command) {
            base = charactersIgnoringModifiers
        } else {
            base = characters
        }

        guard let str = base, let scalar = str.unicodeScalars.first else {
            return 0
        }

        let v = scalar.value
        if v >= 0x100 {
            return 0x01000000 | UInt32(v)
        }
        return UInt32(v)
    }
}
