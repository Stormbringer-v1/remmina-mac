import Foundation
import AppKit

/// Native RFB (Remote Framebuffer) protocol client for VNC connections.
/// Implements RFB 3.8 protocol with Raw and CopyRect encodings.
final class VNCSession: SessionProtocol {
    let id = UUID()
    let profileId: UUID
    let profileName: String
    let protocolType: ProtocolType = .vnc
    weak var delegate: SessionDelegate?

    private(set) var status: SessionStatus = .disconnected {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.sessionDidChangeStatus(self, status: self.status)
            }
        }
    }

    // Connection
    private let host: String
    private let port: Int
    private let password: String?
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var streamQueue = DispatchQueue(label: "com.remmina-mac.vnc.stream", qos: .userInitiated)
    private var isRunning = false
    private var timeoutWorkItem: DispatchWorkItem?

    /// Connection timeout in seconds
    private static let connectionTimeoutSeconds: Double = 15

    // Framebuffer
    private(set) var framebufferWidth: Int = 0
    private(set) var framebufferHeight: Int = 0
    private(set) var serverName: String = ""
    private var framebuffer: [UInt8] = []
    private let bytesPerPixel = 4  // BGRA32

    // Callback for framebuffer updates
    var onFramebufferUpdate: ((NSImage) -> Void)?

    init(profile: ConnectionProfile, password: String?) {
        self.profileId = profile.id
        self.profileName = profile.name
        self.host = profile.host
        self.port = profile.port
        self.password = password
    }

    deinit {
        isRunning = false
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
        timeoutWorkItem?.cancel()
    }

    func connect() {
        guard !status.isActive else { return }
        status = .connecting
        AppLogger.shared.log("VNC: Connecting to \(host):\(port)")

        startConnectionTimeout()

        streamQueue.async { [weak self] in
            self?.performConnection()
        }
    }

    func disconnect() {
        isRunning = false
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        inputStream?.close()
        outputStream?.close()
        inputStream = nil
        outputStream = nil
        if status != .disconnected {
            status = .disconnected
            AppLogger.shared.log("VNC: Disconnected from \(host)")
        }
    }

    func reconnect() {
        disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.connect()
        }
    }

    func sendInput(_ data: Data) {
        // Handled via specific VNC input methods below
    }

    // MARK: - Mouse & Keyboard Input

    func sendPointerEvent(buttons: UInt8, x: UInt16, y: UInt16) {
        guard isRunning else { return }
        streamQueue.async { [weak self] in
            var msg = Data()
            msg.append(5) // message type: PointerEvent
            msg.append(buttons)
            msg.append(contentsOf: x.bigEndianBytes)
            msg.append(contentsOf: y.bigEndianBytes)
            self?.writeData(msg)
        }
    }

    func sendKeyEvent(down: Bool, key: UInt32) {
        guard isRunning else { return }
        streamQueue.async { [weak self] in
            var msg = Data()
            msg.append(4) // message type: KeyEvent
            msg.append(down ? 1 : 0)
            msg.append(contentsOf: [0, 0]) // padding
            msg.append(contentsOf: key.bigEndianBytes)
            self?.writeData(msg)
        }
    }

    func sendClipboardText(_ text: String) {
        guard isRunning, let textData = text.data(using: .isoLatin1) else { return }
        streamQueue.async { [weak self] in
            var msg = Data()
            msg.append(6) // ClientCutText
            msg.append(contentsOf: [0, 0, 0]) // padding
            let length = UInt32(textData.count)
            msg.append(contentsOf: length.bigEndianBytes)
            msg.append(textData)
            self?.writeData(msg)
        }
    }

    func requestFullUpdate() {
        guard isRunning else { return }
        streamQueue.async { [weak self] in
            self?.sendFramebufferUpdateRequest(incremental: false)
        }
    }

    // MARK: - RFB Protocol Implementation

    // MARK: - Connection Timeout

    private func startConnectionTimeout() {
        timeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if self.status == .connecting {
                    self.status = .error("Connection timed out after \(Int(VNCSession.connectionTimeoutSeconds))s — check host and port")
                    AppLogger.shared.log("VNC: Connection timeout for \(self.host)", level: .error)
                    self.disconnect()
                }
            }
        }
        timeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + VNCSession.connectionTimeoutSeconds, execute: work)
    }

    private func performConnection() {
        // Create TCP streams
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?

        CFStreamCreatePairWithSocketToHost(
            nil,
            host as CFString,
            UInt32(port),
            &readStream,
            &writeStream
        )

        guard let input = readStream?.takeRetainedValue() as InputStream?,
              let output = writeStream?.takeRetainedValue() as OutputStream? else {
            DispatchQueue.main.async { [weak self] in
                self?.timeoutWorkItem?.cancel()
                self?.status = .error("Failed to create network socket")
            }
            return
        }

        self.inputStream = input
        self.outputStream = output

        input.open()
        output.open()

        // Poll for stream open with backoff instead of blocking Thread.sleep
        let deadline = Date().addingTimeInterval(5.0)
        var pollInterval: TimeInterval = 0.05
        while Date() < deadline {
            let inStatus = input.streamStatus
            let outStatus = output.streamStatus
            if inStatus == .open || inStatus == .reading,
               outStatus == .open || outStatus == .writing {
                break
            }
            if inStatus == .error || outStatus == .error {
                break
            }
            Thread.sleep(forTimeInterval: pollInterval)
            pollInterval = min(pollInterval * 1.5, 0.5) // Exponential backoff, max 500ms
        }

        guard input.streamStatus == .open || input.streamStatus == .reading,
              output.streamStatus == .open || output.streamStatus == .writing else {
            let errMsg = input.streamError?.localizedDescription ?? "Connection refused — verify host and port"
            DispatchQueue.main.async { [weak self] in
                self?.timeoutWorkItem?.cancel()
                self?.status = .error(errMsg)
            }
            AppLogger.shared.log("VNC: Connection failed: \(errMsg)", level: .error)
            return
        }

        do {
            try performHandshake()
            isRunning = true
            DispatchQueue.main.async { [weak self] in
                self?.timeoutWorkItem?.cancel()
                self?.status = .connected
            }
            AppLogger.shared.log("VNC: Connected to \(serverName) (\(framebufferWidth)x\(framebufferHeight))")

            // Request initial full framebuffer
            sendFramebufferUpdateRequest(incremental: false)

            // Enter message loop
            messageLoop()
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.timeoutWorkItem?.cancel()
                self?.status = .error(error.localizedDescription)
            }
            AppLogger.shared.log("VNC: Handshake failed: \(error)", level: .error)
        }
    }

    private func performHandshake() throws {
        // 1. Read server protocol version
        let versionBytes = try readExact(count: 12)
        let versionStr = String(bytes: versionBytes, encoding: .ascii) ?? ""
        AppLogger.shared.log("VNC: Server version: \(versionStr.trimmingCharacters(in: .whitespacesAndNewlines))")

        // 2. Send our protocol version (3.8)
        let clientVersion = "RFB 003.008\n"
        writeData(Data(clientVersion.utf8))

        // 3. Security handshake
        let numSecTypes = try readExact(count: 1)[0]
        if numSecTypes == 0 {
            // Server sends reason for failure
            let reasonLen = try readUInt32()
            let reasonBytes = try readExact(count: Int(reasonLen))
            let reason = String(bytes: reasonBytes, encoding: .utf8) ?? "Unknown"
            throw VNCError.connectionFailed(reason)
        }

        let secTypes = try readExact(count: Int(numSecTypes))
        AppLogger.shared.log("VNC: Security types: \(secTypes.map { String($0) }.joined(separator: ", "))")

        if secTypes.contains(1) {
            // None - no authentication
            writeData(Data([1]))
        } else if secTypes.contains(2) {
            // VNC Authentication
            writeData(Data([2]))
            try performVNCAuth()
        } else {
            throw VNCError.unsupportedSecurity
        }

        // 4. Read security result
        let result = try readUInt32()
        if result != 0 {
            // Try to read reason if RFB 3.8
            var reason = "Authentication failed"
            if let reasonLen = try? readUInt32(), reasonLen > 0 && reasonLen < 1024 {
                if let reasonBytes = try? readExact(count: Int(reasonLen)) {
                    reason = String(bytes: reasonBytes, encoding: .utf8) ?? reason
                }
            }
            throw VNCError.authFailed(reason)
        }

        // 5. ClientInit (shared = true)
        writeData(Data([1]))

        // 6. Read ServerInit
        let fbWidthBytes = try readExact(count: 2)
        let fbHeightBytes = try readExact(count: 2)
        framebufferWidth = Int(UInt16(fbWidthBytes[0]) << 8 | UInt16(fbWidthBytes[1]))
        framebufferHeight = Int(UInt16(fbHeightBytes[0]) << 8 | UInt16(fbHeightBytes[1]))

        // Pixel format (16 bytes)
        let pixelFormat = try readExact(count: 16)
        AppLogger.shared.log("VNC: Server pixel format - bpp: \(pixelFormat[0]), depth: \(pixelFormat[1]), bigEndian: \(pixelFormat[2]), trueColor: \(pixelFormat[3])")

        // Server name
        let nameLen = try readUInt32()
        let nameBytes = try readExact(count: Int(nameLen))
        serverName = String(bytes: nameBytes, encoding: .utf8) ?? "Unknown"

        // Allocate framebuffer
        framebuffer = [UInt8](repeating: 0, count: framebufferWidth * framebufferHeight * bytesPerPixel)

        // Set pixel format to BGRA32 (our preferred format)
        sendSetPixelFormat()

        // Set encodings (Raw + CopyRect)
        sendSetEncodings()
    }

    private func performVNCAuth() throws {
        // Read 16-byte challenge
        let challenge = try readExact(count: 16)

        guard let pwd = password, !pwd.isEmpty else {
            throw VNCError.authFailed("Password required but not provided")
        }

        // DES encrypt the challenge with the password
        let response = vncEncryptChallenge(challenge: challenge, password: pwd)
        writeData(Data(response))
    }

    /// VNC DES encryption: password is truncated/padded to 8 bytes,
    /// each byte is bit-reversed, then used as DES key to encrypt the challenge.
    private func vncEncryptChallenge(challenge: [UInt8], password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        let pwdBytes = Array(password.utf8)
        for i in 0..<min(8, pwdBytes.count) {
            key[i] = pwdBytes[i]
        }

        // VNC reverses bits in each key byte
        for i in 0..<8 {
            key[i] = reverseBits(key[i])
        }

        // DES-ECB encrypt two 8-byte blocks
        var result = [UInt8](repeating: 0, count: 16)
        desEncrypt(block: Array(challenge[0..<8]), key: key, output: &result, offset: 0)
        desEncrypt(block: Array(challenge[8..<16]), key: key, output: &result, offset: 8)

        return result
    }

    private func reverseBits(_ b: UInt8) -> UInt8 {
        var result: UInt8 = 0
        var input = b
        for _ in 0..<8 {
            result = (result << 1) | (input & 1)
            input >>= 1
        }
        return result
    }

    // MARK: - Message Loop

    private func messageLoop() {
        while isRunning {
            guard let msgType = try? readExact(count: 1).first else {
                if isRunning {
                    DispatchQueue.main.async { [weak self] in
                        self?.disconnect()
                    }
                }
                break
            }

            do {
                switch msgType {
                case 0: // FramebufferUpdate
                    try handleFramebufferUpdate()
                case 1: // SetColourMapEntries
                    try handleSetColourMap()
                case 2: // Bell
                    NSSound.beep()
                case 3: // ServerCutText
                    try handleServerCutText()
                default:
                    AppLogger.shared.log("VNC: Unknown message type: \(msgType)", level: .warning)
                    break
                }
            } catch {
                if isRunning {
                    AppLogger.shared.log("VNC: Message error: \(error)", level: .error)
                    DispatchQueue.main.async { [weak self] in
                        self?.disconnect()
                    }
                }
                break
            }
        }
    }

    private func handleFramebufferUpdate() throws {
        _ = try readExact(count: 1) // padding
        let numRects = Int(try readUInt16())

        for _ in 0..<numRects {
            let x = Int(try readUInt16())
            let y = Int(try readUInt16())
            let w = Int(try readUInt16())
            let h = Int(try readUInt16())
            let encoding = try readInt32()

            switch encoding {
            case 0: // Raw
                try handleRawRect(x: x, y: y, w: w, h: h)
            case 1: // CopyRect
                try handleCopyRect(x: x, y: y, w: w, h: h)
            default:
                AppLogger.shared.log("VNC: Unsupported encoding \(encoding), skipping", level: .warning)
            }
        }

        // Render framebuffer to image and notify
        if let image = renderFramebuffer() {
            DispatchQueue.main.async { [weak self] in
                self?.onFramebufferUpdate?(image)
            }
        }

        // Request next incremental update
        sendFramebufferUpdateRequest(incremental: true)
    }

    private func handleRawRect(x: Int, y: Int, w: Int, h: Int) throws {
        let pixelData = try readExact(count: w * h * bytesPerPixel)
        let rowBytes = w * bytesPerPixel
        for row in 0..<h {
            let srcOffset = row * rowBytes
            let dstOffset = ((y + row) * framebufferWidth + x) * bytesPerPixel
            guard dstOffset + rowBytes <= framebuffer.count else { continue }
            // Use direct memory copy for 10-50x speedup over byte-by-byte
            _ = pixelData.withUnsafeBufferPointer { srcBuf in
                framebuffer.withUnsafeMutableBufferPointer { dstBuf in
                    memcpy(dstBuf.baseAddress! + dstOffset, srcBuf.baseAddress! + srcOffset, rowBytes)
                }
            }
        }
    }

    private func handleCopyRect(x: Int, y: Int, w: Int, h: Int) throws {
        let srcX = Int(try readUInt16())
        let srcY = Int(try readUInt16())

        // Copy from source to destination in framebuffer
        var temp = [UInt8](repeating: 0, count: w * h * bytesPerPixel)
        for row in 0..<h {
            let srcOffset = ((srcY + row) * framebufferWidth + srcX) * bytesPerPixel
            let tmpOffset = row * w * bytesPerPixel
            for col in 0..<(w * bytesPerPixel) {
                if srcOffset + col < framebuffer.count {
                    temp[tmpOffset + col] = framebuffer[srcOffset + col]
                }
            }
        }
        for row in 0..<h {
            let dstOffset = ((y + row) * framebufferWidth + x) * bytesPerPixel
            let tmpOffset = row * w * bytesPerPixel
            for col in 0..<(w * bytesPerPixel) {
                if dstOffset + col < framebuffer.count {
                    framebuffer[dstOffset + col] = temp[tmpOffset + col]
                }
            }
        }
    }

    private func handleSetColourMap() throws {
        _ = try readExact(count: 1) // padding
        _ = try readUInt16() // firstColor
        let numColors = Int(try readUInt16())
        _ = try readExact(count: numColors * 6) // RGB values
    }

    private func handleServerCutText() throws {
        _ = try readExact(count: 3) // padding
        let length = Int(try readUInt32())
        let textBytes = try readExact(count: length)
        if let text = String(bytes: textBytes, encoding: .isoLatin1) {
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            AppLogger.shared.log("VNC: Received clipboard text (\(text.count) chars)")
        }
    }

    // MARK: - Client Messages

    private func sendSetPixelFormat() {
        var msg = Data()
        msg.append(0) // SetPixelFormat
        msg.append(contentsOf: [0, 0, 0]) // padding

        // Pixel format (16 bytes):
        msg.append(32)  // bits-per-pixel
        msg.append(24)  // depth
        msg.append(0)   // big-endian (0 = little)
        msg.append(1)   // true-color
        msg.append(contentsOf: UInt16(255).bigEndianBytes) // red-max
        msg.append(contentsOf: UInt16(255).bigEndianBytes) // green-max
        msg.append(contentsOf: UInt16(255).bigEndianBytes) // blue-max
        msg.append(16)  // red-shift
        msg.append(8)   // green-shift
        msg.append(0)   // blue-shift
        msg.append(contentsOf: [0, 0, 0]) // padding

        writeData(msg)
    }

    private func sendSetEncodings() {
        var msg = Data()
        msg.append(2) // SetEncodings
        msg.append(0) // padding
        let numEncodings: UInt16 = 2
        msg.append(contentsOf: numEncodings.bigEndianBytes)
        // CopyRect (1) - preferred first
        msg.append(contentsOf: Int32(1).bigEndianBytes)
        // Raw (0)
        msg.append(contentsOf: Int32(0).bigEndianBytes)

        writeData(msg)
    }

    private func sendFramebufferUpdateRequest(incremental: Bool) {
        var msg = Data()
        msg.append(3) // FramebufferUpdateRequest
        msg.append(incremental ? 1 : 0)
        msg.append(contentsOf: UInt16(0).bigEndianBytes) // x
        msg.append(contentsOf: UInt16(0).bigEndianBytes) // y
        msg.append(contentsOf: UInt16(framebufferWidth).bigEndianBytes)
        msg.append(contentsOf: UInt16(framebufferHeight).bigEndianBytes)

        writeData(msg)
    }

    // MARK: - Framebuffer Rendering

    private func renderFramebuffer() -> NSImage? {
        guard framebufferWidth > 0 && framebufferHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)

        guard let context = CGContext(
            data: &framebuffer,
            width: framebufferWidth,
            height: framebufferHeight,
            bitsPerComponent: 8,
            bytesPerRow: framebufferWidth * bytesPerPixel,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        guard let cgImage = context.makeImage() else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: framebufferWidth, height: framebufferHeight))
    }

    // MARK: - Stream I/O

    private func readExact(count: Int) throws -> [UInt8] {
        guard let stream = inputStream, count > 0 else {
            throw VNCError.streamClosed
        }

        var buffer = [UInt8](repeating: 0, count: count)
        var totalRead = 0

        while totalRead < count {
            let remaining = count - totalRead
            let bytesRead = buffer.withUnsafeMutableBufferPointer { bufferPtr in
                stream.read(bufferPtr.baseAddress! + totalRead, maxLength: remaining)
            }

            if bytesRead <= 0 {
                throw VNCError.streamClosed
            }
            totalRead += bytesRead
        }

        return buffer
    }

    private func readUInt16() throws -> UInt16 {
        let bytes = try readExact(count: 2)
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    private func readUInt32() throws -> UInt32 {
        let bytes = try readExact(count: 4)
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    private func readInt32() throws -> Int32 {
        let u = try readUInt32()
        return Int32(bitPattern: u)
    }

    private func writeData(_ data: Data) {
        guard let stream = outputStream else { return }
        data.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            let typedPtr = baseAddress.assumingMemoryBound(to: UInt8.self)
            var written = 0
            while written < data.count {
                let result = stream.write(typedPtr + written, maxLength: data.count - written)
                if result <= 0 { break }
                written += result
            }
        }
    }

    // MARK: - DES Encryption (for VNC Auth)

    /// Minimal DES-ECB implementation for VNC authentication.
    private func desEncrypt(block: [UInt8], key: [UInt8], output: inout [UInt8], offset: Int) {
        let keyData = key
        let blockData = block
        var outData = [UInt8](repeating: 0, count: 8)

        let keyLength = 8
        let dataLength = 8
        var numBytesEncrypted: Int = 0

        keyData.withUnsafeBufferPointer { keyBuf in
            blockData.withUnsafeBufferPointer { dataBuf in
                outData.withUnsafeMutableBufferPointer { outBuf in
                    _ = CCCrypt(
                        UInt32(0), // kCCEncrypt
                        UInt32(1), // kCCAlgorithmDES
                        UInt32(1), // kCCOptionECBMode
                        keyBuf.baseAddress!, keyLength,
                        nil, // no IV for ECB
                        dataBuf.baseAddress!, dataLength,
                        outBuf.baseAddress!, dataLength,
                        &numBytesEncrypted
                    )
                }
            }
        }

        for i in 0..<8 {
            output[offset + i] = outData[i]
        }
    }
}

// MARK: - Helpers

extension UInt16 {
    var bigEndianBytes: [UInt8] {
        [UInt8(self >> 8), UInt8(self & 0xFF)]
    }
}

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8(self >> 24), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
    }
}

extension Int32 {
    var bigEndianBytes: [UInt8] {
        let u = UInt32(bitPattern: self)
        return u.bigEndianBytes
    }
}

// MARK: - Errors

enum VNCError: Error, LocalizedError {
    case connectionFailed(String)
    case unsupportedSecurity
    case authFailed(String)
    case streamClosed
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .unsupportedSecurity: return "No supported security type"
        case .authFailed(let msg): return "Authentication failed: \(msg)"
        case .streamClosed: return "Connection closed"
        case .protocolError(let msg): return "Protocol error: \(msg)"
        }
    }
}

// MARK: - CCCrypt binding

@_silgen_name("CCCrypt")
private func CCCrypt(
    _ op: UInt32,
    _ alg: UInt32,
    _ options: UInt32,
    _ key: UnsafeRawPointer,
    _ keyLength: Int,
    _ iv: UnsafeRawPointer?,
    _ dataIn: UnsafeRawPointer,
    _ dataInLength: Int,
    _ dataOut: UnsafeMutableRawPointer,
    _ dataOutAvailable: Int,
    _ dataOutMoved: UnsafeMutablePointer<Int>
) -> Int32
