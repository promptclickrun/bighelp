import Compression
import Foundation

/// gzip for the batch body. Apple's `COMPRESSION_ZLIB` writes a raw deflate
/// stream, so the gzip header and trailer (CRC-32 and size) are added here.
enum TelemetryGzip {
    static func compress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 64
        var output = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&output, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        var result = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        result.append(contentsOf: output[0..<written])
        result.append(littleEndian: crc32(data))
        result.append(littleEndian: UInt32(truncatingIfNeeded: data.count))
        return result
    }

    /// Reads back what `compress` wrote, for tests.
    static func decompress(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return nil }
        let body = data.dropFirst(10).dropLast(8)
        let trailer = Array(data.suffix(8))
        let expectedSize = Int(UInt32(trailer[4]) | UInt32(trailer[5]) << 8 | UInt32(trailer[6]) << 16 | UInt32(trailer[7]) << 24)
        guard (1...8_388_608).contains(expectedSize) else { return nil }
        let capacity = expectedSize
        var output = [UInt8](repeating: 0, count: capacity)
        let size = body.withUnsafeBytes { source -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(&output, capacity, base, body.count, nil, COMPRESSION_ZLIB)
        }
        guard size == expectedSize else { return nil }
        let result = Data(output[0..<size])
        let expectedCRC = UInt32(trailer[0]) | UInt32(trailer[1]) << 8 | UInt32(trailer[2]) << 16 | UInt32(trailer[3]) << 24
        return crc32(result) == expectedCRC ? result : nil
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xedb8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffff_ffff
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
                            UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)])
    }
}
