import SwiftUI
import AppKit

/// Remote desktop view for VNC sessions showing the live framebuffer.
struct VNCDesktopView: NSViewRepresentable {
    let session: VNCSession
    @Binding var currentImage: NSImage?
    let fitToWindow: Bool

    func makeNSView(context: Context) -> VNCCanvasView {
        let canvas = VNCCanvasView()
        canvas.session = session
        canvas.fitToWindow = fitToWindow
        return canvas
    }

    func updateNSView(_ canvas: VNCCanvasView, context: Context) {
        canvas.fitToWindow = fitToWindow
        if let image = currentImage {
            canvas.updateImage(image)
        }
    }
}

/// NSView that renders the VNC framebuffer and handles mouse/keyboard input.
final class VNCCanvasView: NSView {
    var session: VNCSession?
    var fitToWindow = true
    private var framebufferImage: NSImage?
    private var imageRect: NSRect = .zero
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
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

    func updateImage(_ image: NSImage) {
        framebufferImage = image
        needsDisplay = true
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
            // Scale to fit while maintaining aspect ratio
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

        let fbX = UInt16(relX * CGFloat(session.framebufferWidth))
        let fbY = UInt16(relY * CGFloat(session.framebufferHeight))
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
            // Scroll up = button 4
            session?.sendPointerEvent(buttons: 8, x: x, y: y)
            session?.sendPointerEvent(buttons: 0, x: x, y: y)
        } else if event.deltaY < 0 {
            // Scroll down = button 5
            session?.sendPointerEvent(buttons: 16, x: x, y: y)
            session?.sendPointerEvent(buttons: 0, x: x, y: y)
        }
    }

    // MARK: - Keyboard Events

    override func keyDown(with event: NSEvent) {
        let keysym = mapKeyToX11Keysym(event)
        session?.sendKeyEvent(down: true, key: keysym)
    }

    override func keyUp(with event: NSEvent) {
        let keysym = mapKeyToX11Keysym(event)
        session?.sendKeyEvent(down: false, key: keysym)
    }

    override func flagsChanged(with event: NSEvent) {
        // Handle modifier keys
        let modMap: [(NSEvent.ModifierFlags, UInt32)] = [
            (.shift, 0xFFE1),    // XK_Shift_L
            (.control, 0xFFE3),  // XK_Control_L
            (.option, 0xFFE9),   // XK_Alt_L
            (.command, 0xFFE7),  // XK_Meta_L
            (.capsLock, 0xFFE5), // XK_Caps_Lock
        ]

        for (flag, keysym) in modMap {
            let isPressed = event.modifierFlags.contains(flag)
            session?.sendKeyEvent(down: isPressed, key: keysym)
        }
    }

    /// Map macOS key events to X11 keysyms used by VNC/RFB.
    private func mapKeyToX11Keysym(_ event: NSEvent) -> UInt32 {
        // Special keys
        switch event.keyCode {
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

        // Regular characters
        if let chars = event.characters, let scalar = chars.unicodeScalars.first {
            return UInt32(scalar.value)
        }

        return 0
    }
}
