import Compression
import Foundation

/// Unpacks one folder of a .zip, the way an on-device voice model arrives. It reads the archive
/// mapped, not loaded, and streams each file to disk. Only stored and deflated files without
/// ZIP64 or encryption are read; anything else fails before a file is written. Integrity comes
/// from the caller: the archive's pinned SHA-256 and the model's own file list.
enum ZipArchiveExtractor {
    enum Failure: Error, Equatable {
        case notAZip
        case unsupported
        case unsafePath(String)
        case tooLarge
        case damaged
    }

    struct Limits: Sendable {
        var entries = 512
        var totalBytes: Int64 = 1 << 30
    }

    private struct Entry {
        let path: [String]
        let isDirectory: Bool
        let method: Int
        let compressedSize: Int
        let size: Int
        let localHeader: Int
    }

    /// Writes every file under `folder/` in `archive` into `destination` (made if needed), at its
    /// path below `folder`. Files outside `folder` are left out.
    static func extract(_ archive: URL, folder: String, to destination: URL, limits: Limits = .init()) throws {
        let data = try Data(contentsOf: archive, options: .alwaysMapped)
        let entries = try centralDirectory(data, folder: folder, limits: limits)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for entry in entries {
            let url = entry.path.reduce(destination) { $0.appending(path: $1) }
            if entry.isDirectory {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(entry, from: data, to: url)
        }
    }

    private static func centralDirectory(_ data: Data, folder: String, limits: Limits) throws -> [Entry] {
        guard let end = endOfCentralDirectory(data) else { throw Failure.notAZip }
        let count = try data.le16(end + 10)
        let size = try data.le32(end + 12)
        let start = try data.le32(end + 16)
        guard count != 0xFFFF, size != 0xFFFF_FFFF, start != 0xFFFF_FFFF else { throw Failure.unsupported }
        guard count <= limits.entries else { throw Failure.tooLarge }
        guard start + size <= end else { throw Failure.damaged }

        let prefix = folder + "/"
        var entries: [Entry] = []
        var total: Int64 = 0
        var offset = start
        for _ in 0..<count {
            guard try data.le32(offset) == 0x0201_4b50 else { throw Failure.damaged }
            let flags = try data.le16(offset + 8)
            let method = try data.le16(offset + 10)
            let compressedSize = try data.le32(offset + 20)
            let size = try data.le32(offset + 24)
            let nameLength = try data.le16(offset + 28)
            let extraLength = try data.le16(offset + 30)
            let commentLength = try data.le16(offset + 32)
            let localHeader = try data.le32(offset + 42)
            let name = try data.text(offset + 46, nameLength)
            offset += 46 + nameLength + extraLength + commentLength

            guard flags & 1 == 0, [0, 8].contains(method),
                  compressedSize != 0xFFFF_FFFF, size != 0xFFFF_FFFF else { throw Failure.unsupported }
            guard name.hasPrefix(prefix) else { continue }
            let isDirectory = name.hasSuffix("/")
            let path = name.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
                .map(String.init)
            let parts = isDirectory ? Array(path.dropLast()) : path
            if parts.isEmpty, isDirectory { continue }
            guard !parts.isEmpty, parts.allSatisfy(isSafe) else { throw Failure.unsafePath(name) }
            total += Int64(size)
            guard total <= limits.totalBytes else { throw Failure.tooLarge }
            entries.append(Entry(path: parts, isDirectory: isDirectory, method: method,
                                 compressedSize: compressedSize, size: size, localHeader: localHeader))
        }
        return entries
    }

    private static func isSafe(_ part: String) -> Bool {
        !part.isEmpty && part != "." && part != ".." && !part.contains("\\") && part.utf8.count <= 255
            && !part.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// The end record sits in the last 64 KB (its comment is at most 65,535 bytes).
    private static func endOfCentralDirectory(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        for offset in stride(from: data.count - 22, through: lowest, by: -1)
        where (try? data.le32(offset)) == 0x0605_4b50 {
            return offset
        }
        return nil
    }

    private static func write(_ entry: Entry, from data: Data, to url: URL) throws {
        guard try data.le32(entry.localHeader) == 0x0403_4b50 else { throw Failure.damaged }
        let start = entry.localHeader + 30 + (try data.le16(entry.localHeader + 26))
            + (try data.le16(entry.localHeader + 28))
        guard start + entry.compressedSize <= data.count else { throw Failure.damaged }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let chunk = 1 << 20
        var written = 0
        if entry.method == 0 {
            guard entry.compressedSize == entry.size else { throw Failure.damaged }
            for offset in stride(from: start, to: start + entry.size, by: chunk) {
                try handle.write(contentsOf: data[offset..<min(offset + chunk, start + entry.size)])
            }
            return
        }
        let limit = entry.size
        let filter = try OutputFilter(.decompress, using: .zlib) { output in
            guard let output else { return }
            written += output.count
            guard written <= limit else { throw Failure.damaged }
            try handle.write(contentsOf: output)
        }
        let end = start + entry.compressedSize
        for offset in stride(from: start, to: end, by: chunk) {
            try filter.write(data[offset..<min(offset + chunk, end)])
        }
        try filter.finalize()
        guard written == entry.size else { throw Failure.damaged }
    }
}

private extension Data {
    func le16(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= count else { throw ZipArchiveExtractor.Failure.damaged }
        let base = startIndex + offset
        return Int(self[base]) | Int(self[base + 1]) << 8
    }

    func le32(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= count else { throw ZipArchiveExtractor.Failure.damaged }
        let base = startIndex + offset
        return Int(self[base]) | Int(self[base + 1]) << 8 | Int(self[base + 2]) << 16 | Int(self[base + 3]) << 24
    }

    func text(_ offset: Int, _ length: Int) throws -> String {
        guard offset >= 0, offset + length <= count,
              let value = String(data: self[(startIndex + offset)..<(startIndex + offset + length)], encoding: .utf8)
        else { throw ZipArchiveExtractor.Failure.damaged }
        return value
    }
}
