import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// A file over 8 MB picked for a message. It stays on disk the whole way: the
/// app keeps its own copy (Application Support, so a send can go on after a
/// relaunch) and reads one piece at a time, never the whole file into memory.
struct ChatBigFile: Identifiable, Codable, Equatable, Sendable {
    struct Video: Codable, Equatable, Sendable {
        let seconds: Double
        let width: Int
        let height: Int
    }

    let id: String
    let fileName: String
    let mimeType: String
    let byteCount: Int
    /// The whole file's SHA-256, lowercase hex; the host checks it before it keeps the file.
    let sha256: String
    let video: Video?

    var localURL: URL { BigFileStore.folder(id).appending(path: fileName) }

    /// A line for the agent beside Hermes' own note on the file (its type, size and
    /// where it is): what the phone knows that the agent would otherwise have to work out.
    /// The chat doesn't show it (`HermesUserMessageDisplay`).
    var agentNote: String? {
        guard let video, video.seconds.isFinite, video.seconds > 0 else { return nil }
        let total = Int(video.seconds.rounded())
        let length = total >= 3_600
            ? "\(total / 3_600) h \(total % 3_600 / 60) min"
            : total >= 60 ? "\(total / 60) min \(total % 60) s" : "\(total) s"
        let size = video.width > 0 && video.height > 0 ? ", \(video.width)×\(video.height)" : ""
        return "[Video attached: \(fileName), \(length)\(size)]"
    }
}

enum BigFileStore {
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "BigFileUploads", directoryHint: .isDirectory)
    }

    static var pieces: URL {
        URL.cachesDirectory.appending(path: "BigFileUploads", directoryHint: .isDirectory)
    }

    static func folder(_ id: String) -> URL { root.appending(path: id, directoryHint: .isDirectory) }

    /// Copies a picked file in, reading 1 MB at a time, and works out its checksum and,
    /// for a video, its length and size. Refuses files over the plugin's limit.
    static func prepare(copying source: URL, fileName: String, mimeType: String) async throws -> ChatBigFile {
        try validate(fileName: fileName, mimeType: mimeType)
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let folder = folder(id)
        let prepared = try await Task.detached(priority: .userInitiated) { () throws -> (Int, String) in
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let target = folder.appending(path: fileName)
            do {
                return try copy(source, to: target)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }.value
        let mime = mimeType.lowercased()
        var video: ChatBigFile.Video?
        if UTType(mimeType: mime)?.conforms(to: .movie) == true || mime.hasPrefix("video/") {
            video = await videoInfo(folder.appending(path: fileName))
        }
        return ChatBigFile(id: id, fileName: fileName, mimeType: mime, byteCount: prepared.0,
                           sha256: prepared.1, video: video)
    }

    private static func copy(_ source: URL, to target: URL) throws -> (Int, String) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600,
                                                          .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        else { throw ChatAttachmentError.invalidSize }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var hash = SHA256()
        var total = 0
        while let block = try input.read(upToCount: 1_024 * 1_024), !block.isEmpty {
            total += block.count
            guard total <= BigFileUploads.maximumBytes else { throw ChatAttachmentError.invalidSize }
            hash.update(data: block)
            try output.write(contentsOf: block)
        }
        guard total > 0 else { throw ChatAttachmentError.invalidSize }
        try output.synchronize()
        return (total, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func videoInfo(_ url: URL) async -> ChatBigFile.Video? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        var width = 0, height = 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let shown = size.applying(transform)
            width = Int(abs(shown.width).rounded())
            height = Int(abs(shown.height).rounded())
        }
        return .init(seconds: duration.seconds, width: width, height: height)
    }

    /// Piece `index` of the file, written to its own file for an upload task, with its checksum.
    static func piece(of file: ChatBigFile, index: Int, range: Range<Int>) async throws -> (URL, String) {
        let source = file.localURL
        let folder = pieces.appending(path: file.id, directoryHint: .isDirectory)
        return try await Task.detached(priority: .utility) { () throws -> (URL, String) in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            try input.seek(toOffset: UInt64(range.lowerBound))
            guard let bytes = try input.read(upToCount: range.count), bytes.count == range.count else {
                throw ChatAttachmentError.invalidSize
            }
            let target = folder.appending(path: "\(index).part")
            // Readable while the phone is locked, so iOS can send it from the background.
            try bytes.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return (target, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }.value
    }

    static func removePiece(of file: ChatBigFile, index: Int) {
        try? FileManager.default.removeItem(
            at: pieces.appending(path: file.id, directoryHint: .isDirectory).appending(path: "\(index).part"))
    }

    /// The app's copy and its pieces, once the host has the file or the message is dropped.
    static func remove(_ file: ChatBigFile) {
        try? FileManager.default.removeItem(at: folder(file.id))
        try? FileManager.default.removeItem(at: pieces.appending(path: file.id, directoryHint: .isDirectory))
    }

    /// The same rules as `ChatAttachment` for what a name and a type may be.
    static func validate(fileName: String, mimeType: String) throws {
        let name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...180).contains(name.count), name == fileName,
              name == URL(fileURLWithPath: name).lastPathComponent, !name.hasPrefix("."),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ChatAttachmentError.invalidFileName
        }
        let mime = mimeType.lowercased()
        guard (3...120).contains(mime.count), mime.contains("/"),
              mime.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$&^_.+-/".contains($0)) }) else {
            throw ChatAttachmentError.invalidMIMEType
        }
    }
}
