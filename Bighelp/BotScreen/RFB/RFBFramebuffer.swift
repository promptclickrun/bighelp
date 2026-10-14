import CoreGraphics
import Foundation

/// The screen's pixels as the server last drew them: one 32-bit word per pixel,
/// 0x00RRGGBB, which on Apple's little-endian chips is the B, G, R, unused byte order
/// `RFBPixelFormat.bgrx` asks the server for. Rectangles are written straight in; a
/// picture is copied out once per finished update, never per rectangle.
///
/// Owned by one `RFBSession`; not thread-safe on its own.
final class RFBFramebuffer {
    private(set) var width: Int
    private(set) var height: Int
    private var pixels: UnsafeMutablePointer<UInt32>

    init(width: Int, height: Int) throws {
        try Self.check(width: width, height: height)
        self.width = width
        self.height = height
        pixels = .allocate(capacity: max(1, width * height))
        pixels.initialize(repeating: 0, count: max(1, width * height))
    }

    deinit { pixels.deallocate() }

    static func check(width: Int, height: Int) throws {
        guard (1...RFB.maximumDimension).contains(width), (1...RFB.maximumDimension).contains(height),
              width * height <= RFB.maximumPixels else {
            throw RFBError.protocolViolation("screen size \(width)×\(height)")
        }
    }

    /// DesktopSize: the screen changed size. What was drawn is gone; the next update redraws it.
    func resize(width: Int, height: Int) throws {
        try Self.check(width: width, height: height)
        guard width != self.width || height != self.height else { return }
        pixels.deallocate()
        pixels = .allocate(capacity: width * height)
        pixels.initialize(repeating: 0, count: width * height)
        self.width = width
        self.height = height
    }

    func pixel(x: Int, y: Int) -> UInt32 { pixels[y * width + x] & 0x00FF_FFFF }

    /// A rectangle has to lie inside the screen; a server that says otherwise is broken.
    func check(_ rect: RFBRect) throws {
        guard rect.width >= 0, rect.height >= 0, rect.x >= 0, rect.y >= 0,
              rect.x + rect.width <= width, rect.y + rect.height <= height else {
            throw RFBError.protocolViolation("rectangle outside the screen")
        }
    }

    /// Raw rows in this buffer's own pixel layout.
    func writeRaw(_ bytes: UnsafeRawBufferPointer, rect: RFBRect) {
        let rowBytes = rect.width * 4
        guard rowBytes > 0, let base = bytes.baseAddress else { return }
        for row in 0..<rect.height {
            let destination = pixels.advanced(by: (rect.y + row) * width + rect.x)
            UnsafeMutableRawPointer(destination).copyMemory(from: base + row * rowBytes, byteCount: rowBytes)
        }
    }

    func fill(_ rect: RFBRect, color: UInt32) {
        for row in 0..<rect.height {
            pixels.advanced(by: (rect.y + row) * width + rect.x).update(repeating: color, count: rect.width)
        }
    }

    /// CopyRect: the region may overlap its source, so rows go in the safe direction.
    func copy(from source: (x: Int, y: Int), to rect: RFBRect) throws {
        try check(RFBRect(x: source.x, y: source.y, width: rect.width, height: rect.height))
        let rows = source.y < rect.y ? Array((0..<rect.height).reversed()) : Array(0..<rect.height)
        for row in rows {
            let from = pixels.advanced(by: (source.y + row) * width + source.x)
            let to = pixels.advanced(by: (rect.y + row) * width + rect.x)
            UnsafeMutableRawPointer(to).copyMemory(from: from, byteCount: rect.width * 4)
        }
    }

    /// Writes one pixel row of a tile; `row` holds exactly `count` colours.
    func writeRow(_ row: UnsafeBufferPointer<UInt32>, x: Int, y: Int) {
        guard let base = row.baseAddress else { return }
        pixels.advanced(by: y * width + x).update(from: base, count: row.count)
    }

    /// One copy of the whole screen for display.
    func makeImage() -> CGImage? {
        let byteCount = width * height * 4
        let data = Data(bytes: pixels, count: byteCount)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct RFBRect: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
}

enum RFBError: Error, Equatable {
    /// The server broke the protocol; the words are for logs, never for people.
    case protocolViolation(String)
    /// The screen asks for a password or another login bighelp can't give.
    case unsupportedSecurity
    /// The server said no during the handshake.
    case refused(String)
}
