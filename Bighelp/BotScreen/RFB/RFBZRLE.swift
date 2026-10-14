import Foundation
import zlib

/// ZRLE (RFC 6143 §7.7.6): each rectangle is a piece of one zlib stream that lasts the
/// whole connection, holding 64×64 tiles that are raw, one colour, a small palette or
/// runs. A full screen of a desktop is a few tens of kilobytes this way, which is what
/// makes the screen usable on a phone over cellular.
final class RFBZRLEDecoder {
    private let inflater: RFBInflater

    init() throws { inflater = try RFBInflater() }

    /// `compressed` is the rectangle's zlib data (after its 4-byte length).
    func decode(_ compressed: [UInt8], rect: RFBRect, into framebuffer: RFBFramebuffer) throws {
        try framebuffer.check(rect)
        guard rect.width > 0, rect.height > 0 else { return }
        // The worst case is every pixel its own run: 3 bytes of colour and 1 of length.
        let limit = rect.width * rect.height * 4 + ((rect.width + 63) / 64) * ((rect.height + 63) / 64) * 512 + 1_024
        let tiles = try inflater.inflate(compressed, limit: limit)
        try Self.decodeTiles(tiles, rect: rect, into: framebuffer)
    }

    /// The uncompressed tile data of one rectangle. Separate so tests can build tiles by hand.
    static func decodeTiles(_ data: [UInt8], rect: RFBRect, into framebuffer: RFBFramebuffer) throws {
        try framebuffer.check(rect)
        var reader = TileReader(data)
        var tile = [UInt32](repeating: 0, count: 64 * 64)
        var palette = [UInt32](repeating: 0, count: 128)
        var tileY = 0
        while tileY < rect.height {
            let tileHeight = min(64, rect.height - tileY)
            var tileX = 0
            while tileX < rect.width {
                let tileWidth = min(64, rect.width - tileX)
                let x = rect.x + tileX
                let y = rect.y + tileY
                let count = tileWidth * tileHeight
                let subencoding = try reader.byte()
                switch subencoding {
                case 0:
                    for index in 0..<count { tile[index] = try reader.cpixel() }
                case 1:
                    framebuffer.fill(RFBRect(x: x, y: y, width: tileWidth, height: tileHeight), color: try reader.cpixel())
                    tileX += 64
                    continue
                case 2...16:
                    let size = Int(subencoding)
                    for index in 0..<size { palette[index] = try reader.cpixel() }
                    let bits = size == 2 ? 1 : size <= 4 ? 2 : 4
                    let mask = UInt8((1 << bits) - 1)
                    for line in 0..<tileHeight {
                        var current: UInt8 = 0
                        var left = 0
                        for column in 0..<tileWidth {
                            if left == 0 { current = try reader.byte(); left = 8 }
                            left -= bits
                            let index = Int((current >> UInt8(left)) & mask)
                            guard index < size else { throw RFBError.protocolViolation("ZRLE palette index") }
                            tile[line * tileWidth + column] = palette[index]
                        }
                    }
                case 128:
                    var filled = 0
                    while filled < count {
                        let color = try reader.cpixel()
                        let run = try reader.runLength()
                        guard filled + run <= count else { throw RFBError.protocolViolation("ZRLE run too long") }
                        for index in filled..<(filled + run) { tile[index] = color }
                        filled += run
                    }
                case 130...255:
                    let size = Int(subencoding) - 128
                    for index in 0..<size { palette[index] = try reader.cpixel() }
                    var filled = 0
                    while filled < count {
                        let value = try reader.byte()
                        let index = Int(value & 0x7F)
                        guard index < size else { throw RFBError.protocolViolation("ZRLE palette index") }
                        let run = try value & 0x80 != 0 ? reader.runLength() : 1
                        guard filled + run <= count else { throw RFBError.protocolViolation("ZRLE run too long") }
                        for position in filled..<(filled + run) { tile[position] = palette[index] }
                        filled += run
                    }
                default:
                    throw RFBError.protocolViolation("ZRLE subencoding \(subencoding)")
                }
                tile.withUnsafeBufferPointer { buffer in
                    for line in 0..<tileHeight {
                        let start = line * tileWidth
                        framebuffer.writeRow(UnsafeBufferPointer(rebasing: buffer[start..<(start + tileWidth)]),
                                             x: x, y: y + line)
                    }
                }
                tileX += 64
            }
            tileY += 64
        }
    }

    /// Bounds-checked reads over a rectangle's tiles. A CPIXEL is 3 bytes here: the low
    /// three of a little-endian pixel, so blue, green, red.
    private struct TileReader {
        let data: [UInt8]
        var offset = 0
        init(_ data: [UInt8]) { self.data = data }

        mutating func byte() throws -> UInt8 {
            guard offset < data.count else { throw RFBError.protocolViolation("ZRLE data ended early") }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func cpixel() throws -> UInt32 {
            guard offset + 3 <= data.count else { throw RFBError.protocolViolation("ZRLE data ended early") }
            defer { offset += 3 }
            return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16
        }

        /// 1 + the sum of the bytes, where 255 means another byte follows.
        mutating func runLength() throws -> Int {
            var length = 1
            while true {
                let value = try byte()
                length += Int(value)
                if value != 255 { return length }
                guard length <= 64 * 64 else { throw RFBError.protocolViolation("ZRLE run too long") }
            }
        }
    }
}

/// One zlib stream fed piece by piece. The server flushes after every rectangle, so
/// each piece inflates to exactly that rectangle's tiles.
final class RFBInflater {
    private let stream: UnsafeMutablePointer<z_stream>
    private var scratch = [UInt8](repeating: 0, count: 256 * 1_024)

    init() throws {
        // zlib keeps a pointer back to its z_stream, so it must never move.
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        guard inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            stream.deallocate()
            throw RFBError.protocolViolation("zlib could not start")
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deallocate()
    }

    func inflate(_ input: [UInt8], limit: Int) throws -> [UInt8] {
        var output: [UInt8] = []
        guard !input.isEmpty else { return output }
        try input.withUnsafeBufferPointer { source in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: source.baseAddress)
            stream.pointee.avail_in = uInt(source.count)
            defer { stream.pointee.next_in = nil; stream.pointee.avail_in = 0 }
            while true {
                let produced: Int = try scratch.withUnsafeMutableBufferPointer { buffer in
                    stream.pointee.next_out = buffer.baseAddress
                    stream.pointee.avail_out = uInt(buffer.count)
                    let status = zlib.inflate(stream, Z_SYNC_FLUSH)
                    defer { stream.pointee.next_out = nil }
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw RFBError.protocolViolation("zlib \(status)")
                    }
                    return buffer.count - Int(stream.pointee.avail_out)
                }
                output.append(contentsOf: scratch[0..<produced])
                guard output.count <= limit else { throw RFBError.protocolViolation("ZRLE rectangle too large") }
                // Room to spare means zlib has given everything this input holds; input it
                // couldn't use means the stream is broken.
                if stream.pointee.avail_out != 0 {
                    guard stream.pointee.avail_in == 0 else { throw RFBError.protocolViolation("zlib stalled") }
                    break
                }
            }
        }
        return output
    }
}
