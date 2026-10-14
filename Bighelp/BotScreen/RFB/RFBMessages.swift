import Foundation

/// The RFB (VNC, RFC 6143) messages bighelp sends to an agent's screen, and the
/// fixed choices it makes: 32-bit true colour, and Raw, CopyRect, ZRLE and
/// DesktopSize. Pure bytes, so tests check them against hand-built vectors.
enum RFB {
    /// Hermes' screens are a few thousand pixels at most; anything bigger is refused.
    static let maximumDimension = 8_192
    /// 64 MB of pixels: a 4K screen fits, a made-up size can't use up the phone's memory.
    static let maximumPixels = 4_096 * 4_096

    /// The encodings bighelp asks for, best first. ZRLE keeps a full screen small enough for
    /// a phone on cellular; CopyRect makes moved windows cheap; Raw is the fallback every
    /// server has. DesktopSize lets the screen change size without a reconnect.
    static let encodings: [RFBEncoding] = [.zrle, .copyRect, .raw, .desktopSize]
}

enum RFBEncoding: Int32, Sendable {
    case raw = 0
    case copyRect = 1
    case zrle = 16
    case desktopSize = -223
}

/// Version 3.8, 3.7 or 3.3: what the server offers, capped at 3.8.
enum RFBVersion: Equatable, Sendable {
    case v33, v37, v38

    /// `RFB 003.008\n` and friends. Nil for anything that isn't RFB 3.x.
    init?(serverGreeting bytes: [UInt8]) {
        guard bytes.count == 12, let text = String(bytes: bytes, encoding: .ascii),
              text.hasPrefix("RFB "), text.hasSuffix("\n") else { return nil }
        let parts = text.dropFirst(4).dropLast().split(separator: ".")
        guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]), major == 3 else { return nil }
        self = minor >= 8 ? .v38 : minor == 7 ? .v37 : .v33
    }

    var greeting: Data {
        switch self {
        case .v33: Data("RFB 003.003\n".utf8)
        case .v37: Data("RFB 003.007\n".utf8)
        case .v38: Data("RFB 003.008\n".utf8)
        }
    }
}

/// Little-endian 32-bit pixels, red in bits 16–23, green 8–15, blue 0–7: in memory each
/// pixel is B, G, R, unused, which Core Graphics draws directly.
struct RFBPixelFormat: Equatable, Sendable {
    var bitsPerPixel: UInt8 = 32
    var depth: UInt8 = 24
    var bigEndian = false
    var trueColour = true
    var redMax: UInt16 = 255
    var greenMax: UInt16 = 255
    var blueMax: UInt16 = 255
    var redShift: UInt8 = 16
    var greenShift: UInt8 = 8
    var blueShift: UInt8 = 0

    static let bgrx = RFBPixelFormat()

    /// The 16 bytes of PIXEL_FORMAT (RFC 6143 §7.4).
    var bytes: [UInt8] {
        var out: [UInt8] = [bitsPerPixel, depth, bigEndian ? 1 : 0, trueColour ? 1 : 0]
        out.appendBigEndian(redMax)
        out.appendBigEndian(greenMax)
        out.appendBigEndian(blueMax)
        out += [redShift, greenShift, blueShift, 0, 0, 0]
        return out
    }
}

/// Mouse buttons in a PointerEvent. The wheel is buttons 4–7, pressed and released per step.
struct RFBButtons: OptionSet, Sendable, Hashable {
    let rawValue: UInt8
    static let left = RFBButtons(rawValue: 1)
    static let middle = RFBButtons(rawValue: 2)
    static let right = RFBButtons(rawValue: 4)
    static let wheelUp = RFBButtons(rawValue: 8)
    static let wheelDown = RFBButtons(rawValue: 16)
    static let wheelLeft = RFBButtons(rawValue: 32)
    static let wheelRight = RFBButtons(rawValue: 64)
}

/// Client-to-server messages (RFC 6143 §7.5).
enum RFBClientMessage {
    static func setPixelFormat(_ format: RFBPixelFormat) -> Data {
        Data([0, 0, 0, 0] + format.bytes)
    }

    static func setEncodings(_ encodings: [RFBEncoding]) -> Data {
        var out: [UInt8] = [2, 0]
        out.appendBigEndian(UInt16(encodings.count))
        for encoding in encodings { out.appendBigEndian(UInt32(bitPattern: encoding.rawValue)) }
        return Data(out)
    }

    static func updateRequest(incremental: Bool, x: Int = 0, y: Int = 0, width: Int, height: Int) -> Data {
        var out: [UInt8] = [3, incremental ? 1 : 0]
        for value in [x, y, width, height] { out.appendBigEndian(UInt16(clamping: value)) }
        return Data(out)
    }

    static func key(_ keysym: UInt32, down: Bool) -> Data {
        var out: [UInt8] = [4, down ? 1 : 0, 0, 0]
        out.appendBigEndian(keysym)
        return Data(out)
    }

    static func pointer(x: Int, y: Int, buttons: RFBButtons) -> Data {
        var out: [UInt8] = [5, buttons.rawValue]
        out.appendBigEndian(UInt16(clamping: max(0, x)))
        out.appendBigEndian(UInt16(clamping: max(0, y)))
        return Data(out)
    }
}

/// X keysyms for what people type. Hermes runs its screen with a US keymap, and Xvnc
/// works out Shift itself from the keysym, so "A" is sent as the keysym for A.
enum RFBKeysym {
    static let returnKey: UInt32 = 0xFF0D
    static let backSpace: UInt32 = 0xFF08
    static let tab: UInt32 = 0xFF09
    static let escape: UInt32 = 0xFF1B
    static let delete: UInt32 = 0xFFFF
    static let home: UInt32 = 0xFF50
    static let left: UInt32 = 0xFF51
    static let up: UInt32 = 0xFF52
    static let right: UInt32 = 0xFF53
    static let down: UInt32 = 0xFF54
    static let pageUp: UInt32 = 0xFF55
    static let pageDown: UInt32 = 0xFF56
    static let end: UInt32 = 0xFF57
    static let insert: UInt32 = 0xFF63
    static let keypadEnter: UInt32 = 0xFF8D
    static let shiftLeft: UInt32 = 0xFFE1
    static let shiftRight: UInt32 = 0xFFE2
    static let controlLeft: UInt32 = 0xFFE3
    static let controlRight: UInt32 = 0xFFE4
    static let capsLock: UInt32 = 0xFFE5
    static let altLeft: UInt32 = 0xFFE9
    static let altRight: UInt32 = 0xFFEA

    /// F1 is 0xFFBE; F1–F12 follow in order.
    static func function(_ number: Int) -> UInt32? {
        (1...12).contains(number) ? 0xFFBE + UInt32(number - 1) : nil
    }

    /// One character: Latin-1 keysyms are the code point itself, the rest of Unicode is
    /// 0x01000000 plus the code point. Control characters other than Return and Tab have none.
    static func forScalar(_ scalar: Unicode.Scalar) -> UInt32? {
        switch scalar.value {
        case 0x0A, 0x0D: returnKey
        case 0x09: tab
        case 0x08, 0x7F: backSpace
        case 0x20...0x7E, 0xA0...0xFF: scalar.value
        case 0x00...0x1F, 0x80...0x9F: nil
        default: 0x0100_0000 | scalar.value
        }
    }

    /// What the software keyboard typed, in order. "\r\n" counts once.
    static func forText(_ text: String) -> [UInt32] {
        text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.compactMap(forScalar)
    }

    /// A hardware key (USB HID usage page 7, as `UIKey.keyCode` reports it). Special keys go by
    /// their place on the keyboard; the rest by the character they make. With Control or Option
    /// held the plain character is sent, since the screen applies the modifier itself.
    static func forHardwareKey(usage: Int, characters: String, charactersIgnoringModifiers: String,
                               controlOrAlt: Bool) -> UInt32? {
        if let special = specialKeys[usage] { return special }
        if (0x3A...0x45).contains(usage) { return function(usage - 0x3A + 1) }
        let text = controlOrAlt || characters.isEmpty ? charactersIgnoringModifiers : characters
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return nil }
        return forScalar(scalar)
    }

    /// Modifier keys. Command is the Mac's own (⌘W, ⌘Q) and never reaches the screen.
    static func forModifier(usage: Int) -> UInt32? {
        switch usage {
        case 0xE0: controlLeft
        case 0xE1: shiftLeft
        case 0xE2: altLeft
        case 0xE4: controlRight
        case 0xE5: shiftRight
        case 0xE6: altRight
        case 0x39: capsLock
        default: nil
        }
    }

    private static let specialKeys: [Int: UInt32] = [
        0x28: returnKey, 0x29: escape, 0x2A: backSpace, 0x2B: tab, 0x2C: 0x20,
        0x49: insert, 0x4A: home, 0x4B: pageUp, 0x4C: delete, 0x4D: end, 0x4E: pageDown,
        0x4F: right, 0x50: left, 0x51: down, 0x52: up, 0x58: keypadEnter,
    ]
}

extension Array where Element == UInt8 {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(value >> 8)); append(UInt8(value & 0xFF))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(value >> 24)); append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF)); append(UInt8(value & 0xFF))
    }
}
