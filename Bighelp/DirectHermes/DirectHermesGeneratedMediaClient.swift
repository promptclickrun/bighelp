import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Resolves explicit deliveries through the authenticated host's existing media
/// or managed-file policy. Never falls back after policy refusal or reads the
/// phone's filesystem. The one outside read is a hosted image tool's own
/// picture address, which the tool reports in place of a host file.
@MainActor
final class DirectHermesGeneratedMediaClient: GeneratedMediaResolving, AgentAttachmentResolving {
    /// Chunks after the first download side by side; a slow link spends its
    /// time on bytes instead of waiting on each round trip in turn.
    static let parallelChunks = 3
    static let chunkRetryDelays: [Duration] = [.seconds(1), .seconds(3)]

    private let workspace: DirectHermesWorkspaceClient
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private let cache: AgentAttachmentCache?
    private let remoteFetch: LinkPreviewLoader.Fetch?

    init(workspace: DirectHermesWorkspaceClient, owner: WorkspaceOwner,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
         cache: AgentAttachmentCache? = nil, remoteFetch: LinkPreviewLoader.Fetch? = nil) {
        self.workspace = workspace
        self.owner = owner
        self.currentOwner = currentOwner
        self.cache = cache
        self.remoteFetch = remoteFetch
    }

    func resolve(agentID: String, storedID: String, event: ChatActivityEvent) async throws -> GeneratedMediaResolution {
        try checkOwner()
        guard let kind = GeneratedMediaProjection.kind(for: event),
              event.lifecycle == .succeeded, let toolCallID = event.toolCallID else {
            return .init(state: .unavailable)
        }
        let paths = Self.outputPaths(event.result).filter { kind == .image ? Self.isImagePath($0) : Self.isVideoPath($0) }
        let addresses = paths.isEmpty ? Self.providerURLs(event.result, kind: kind) : []
        guard !paths.isEmpty || (!addresses.isEmpty && remoteFetch != nil) else { return .init(state: .unavailable) }
        let key = AgentAttachmentCache.key(owner.cacheScopeID, agentID, storedID, "tool", toolCallID, event.result ?? "")
        if let cached = await cache?.entry(for: key) {
            try checkOwner()
            return .init(state: .ready, attachments: cached.attachments)
        }
        let attachments = paths.isEmpty
            ? try await fetchProvider(addresses, kind: kind, scope: agentID + "\0" + storedID)
            : try await fetch(paths, agentID: agentID, storedID: storedID)
        guard !attachments.isEmpty else { return .init(state: .unavailable) }
        await cache?.store(.init(text: "", attachments: attachments), for: key)
        return .init(state: .ready, attachments: attachments,
                     omittedCount: max(0, max(paths.count, addresses.count) - attachments.count))
    }

    func resolve(agentID: String, storedID: String,
                 items: [AgentAttachmentTextItem]) async throws -> [ResolvedAgentAttachmentItem] {
        try checkOwner()
        var resolved: [ResolvedAgentAttachmentItem] = []
        for item in items {
            let key = AgentAttachmentCache.key(owner.cacheScopeID, agentID, storedID, item.role.rawValue, item.text)
            if let cached = await cache?.entry(for: key) {
                try checkOwner()
                resolved.append(.init(id: item.id, text: cached.text, attachments: cached.attachments))
                continue
            }
            if item.role == .assistant, item.text.contains("MEDIA:"),
               let native = try await resolveNatively(item, agentID: agentID, storedID: storedID) {
                if !native.attachments.isEmpty {
                    await cache?.store(.init(text: native.text, attachments: native.attachments), for: key)
                }
                resolved.append(native)
                continue
            }
            let markers = Self.messageMarkers(item.text, role: item.role)
            guard !markers.isEmpty else {
                resolved.append(.init(id: item.id, text: item.text, attachments: []))
                continue
            }
            var seen = Set<Data>()
            let unique = markers.filter { seen.insert(Data($0.path.utf8)).inserted }
            let attachments = try await fetch(unique.map(\.path), agentID: agentID, storedID: storedID,
                                              messageID: item.role == .human ? item.id : nil)
            // Remove only references whose bytes were actually delivered. Preserve
            // every other character, including failed or unsupported references.
            let paths = Set(unique.prefix(attachments.count).map { Data($0.path.utf8) })
            let delivered = Set(markers.filter { paths.contains(Data($0.path.utf8)) }.map { Data($0.line.utf8) })
            let remaining = item.text.components(separatedBy: "\n").filter { !delivered.contains(Data($0.utf8)) }
            let text = remaining.joined(separator: "\n")
            if !attachments.isEmpty {
                await cache?.store(.init(text: text, attachments: attachments), for: key)
            }
            resolved.append(.init(id: item.id, text: text, attachments: attachments))
        }
        return resolved
    }

    /// A hosted tool's picture, read from the provider's own address: https
    /// only, public hosts only, no cookies, bounded, and checked to be the kind
    /// of media the tool made.
    private func fetchProvider(_ addresses: [URL], kind: GeneratedMediaKind, scope: String) async throws -> [ChatAttachment] {
        guard let remoteFetch else { return [] }
        var attachments: [ChatAttachment] = []
        var total = 0
        for address in addresses.prefix(GeneratedMediaResolution.maximumArtifactCount) {
            try checkOwner()
            let request = LinkPreviewLoader.request(address, accept: kind == .image ? "image/*" : "video/*")
            let (data, response) = try await remoteFetch(request, ChatAttachment.maximumAgentBytes + 1, false)
            try checkOwner()
            let mime = response.mimeType?.lowercased() ?? ""
            guard (200..<300).contains(response.statusCode), !data.isEmpty,
                  data.count <= ChatAttachment.maximumAgentBytes,
                  mime.hasPrefix(kind == .image ? "image/" : "video/") else { throw WorkspaceClientError.invalidResponse }
            if kind == .image {
                guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0,
                      CGImageSourceCreateImageAtIndex(image, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil
                else { throw WorkspaceClientError.invalidResponse }
            }
            let digest = SHA256.hash(data: Data((scope + "\0" + address.absoluteString).utf8))
                .map { String(format: "%02x", $0) }.joined()
            let attachment = try ChatAttachment.agentArtifact(
                id: "native_media_" + digest, fileName: Self.providerFileName(address, mimeType: mime),
                mimeType: mime, data: data)
            if kind == .video { try await Self.validateVideo(attachment) }
            let sum = total.addingReportingOverflow(data.count)
            guard !sum.overflow, sum.partialValue <= GeneratedMediaResolution.maximumTotalBytes else {
                throw ChatAttachmentError.invalidSize
            }
            total = sum.partialValue
            attachments.append(attachment)
        }
        return attachments
    }

    /// The address's own file name when it has a sensible one.
    static func providerFileName(_ address: URL, mimeType: String) -> String {
        let name = address.lastPathComponent
        let usable = (1...120).contains(name.count) && !name.hasPrefix(".")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
            && !URL(fileURLWithPath: name).pathExtension.isEmpty
        if usable { return name }
        let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension ?? (mimeType.hasPrefix("video/") ? "mp4" : "png")
        return (mimeType.hasPrefix("video/") ? "video." : "image.") + ext
    }

    /// Hosted image tools (Nous Portal and FAL among them) report the picture
    /// as the provider's web address instead of a file on the host.
    static func providerURLs(_ result: String?, kind: GeneratedMediaKind) -> [URL] {
        guard let result, result.utf8.count <= 65_536, let data = result.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["success"] as? Bool == true,
              let raw = object[kind == .image ? "image" : "video"] as? String,
              raw.utf8.count <= 2_048, raw.lowercased().hasPrefix("https://"),
              let address = URL(string: raw),
              let loadable = LinkPreviewPolicy.loadableURL(address) else { return [] }
        return [loadable]
    }

    private func fetch(_ paths: [String], agentID: String, storedID: String,
                       messageID: String? = nil) async throws -> [ChatAttachment] {
        guard !agentID.isEmpty, !storedID.isEmpty else { throw WorkspaceClientError.invalidRequest }
        let scope = agentID + "\0" + storedID + (messageID.map { "\0" + owner.cacheScopeID + "\0" + $0 } ?? "")
        var attachments: [ChatAttachment] = []
        var total = 0
        for path in paths.prefix(GeneratedMediaResolution.maximumArtifactCount) {
            try checkOwner()
            let response: BighelpJSONValue
            if Self.isImagePath(path) {
                response = try await workspace.readGeneratedImage(path: path, owner: owner)
            } else {
                response = try await workspace.readDeliveredFile(path: path, owner: owner)
            }
            try checkOwner()
            let attachment = try Self.attachment(response, path: path, scope: scope)
            if Self.isVideoPath(path) { try await Self.validateVideo(attachment) }
            try checkOwner()
            let sum = total.addingReportingOverflow(attachment.data.count)
            guard !sum.overflow, sum.partialValue <= GeneratedMediaResolution.maximumTotalBytes else {
                throw ChatAttachmentError.invalidSize
            }
            total = sum.partialValue
            attachments.append(attachment)
        }
        return attachments
    }

    /// Agent `MEDIA:` deliveries go through the plugin's provenance-bound route,
    /// which applies the gateway's own delivery policy (any file type, spaced or
    /// `MEDIA://` spellings, paths outside the media cache and terminal.cwd) but
    /// only for paths an assistant message in this session actually emitted.
    /// Returns nil when the host does not advertise the route.
    private func resolveNatively(_ item: AgentAttachmentTextItem, agentID: String,
                                 storedID: String) async throws -> ResolvedAgentAttachmentItem? {
        let response: [String: BighelpJSONValue]
        do {
            response = try await workspace.perform(.attachmentsResolve, payload: [
                "agentId": .string(agentID), "storedId": .string(storedID),
                "items": .array([.object(["itemId": .string(item.id), "text": .string(item.text)])])
            ], owner: owner)
        } catch WorkspaceClientError.unavailable {
            return nil
        }
        try checkOwner()
        guard let rows = response["items"]?.array, rows.count == 1, let row = rows[0].object,
              row["itemId"]?.string == item.id, let text = row["text"]?.string,
              let listed = row["attachments"]?.array else { throw WorkspaceClientError.invalidResponse }
        var attachments: [ChatAttachment] = []
        var total = 0
        for value in listed.prefix(GeneratedMediaResolution.maximumArtifactCount) {
            guard let meta = value.object, let id = meta["id"]?.string, let name = meta["fileName"]?.string,
                  let mime = meta["mimeType"]?.string, let size = meta["byteCount"]?.integer,
                  (1...ChatAttachment.maximumAgentBytes).contains(size) else { throw WorkspaceClientError.invalidResponse }
            let sum = total.addingReportingOverflow(size)
            guard !sum.overflow, sum.partialValue <= GeneratedMediaResolution.maximumTotalBytes else { break }
            total = sum.partialValue
            let data = try await fetchNative(id, agentID: agentID, size: size)
            let attachment = try Self.nativeAttachment(id: id, fileName: name, mimeType: mime, data: data)
            if mime.hasPrefix("video/") { try await Self.validateVideo(attachment) }
            attachments.append(attachment)
        }
        // A refused or empty resolution keeps the agent's original text readable.
        return .init(id: item.id, text: attachments.isEmpty ? item.text : text, attachments: attachments)
    }

    /// One file a Feed post carries (plugin `native-agent-board-files-v1`). The phone names
    /// the post and the file's place in it, never a path: the host checks the post refers
    /// to it and applies the same delivery policy as a chat file, then it downloads and is
    /// kept on this phone like one.
    func boardFile(agentID: String, itemID: String, file: AgentBoardItem.File) async throws -> ChatAttachment {
        try checkOwner()
        let key = AgentAttachmentCache.key(owner.cacheScopeID, agentID, "board", itemID, String(file.index),
                                           file.fileName, String(Int(file.addedAt?.timeIntervalSince1970 ?? 0)))
        if let cached = await cache?.entry(for: key)?.attachments.first {
            try checkOwner()
            return cached
        }
        let response = try await workspace.perform(.attachmentsBoard, payload: [
            "agentId": .string(agentID), "itemId": .string(itemID), "index": .integer(file.index),
        ], owner: owner)
        try checkOwner()
        guard let meta = response["attachment"]?.object, let id = meta["id"]?.string,
              let name = meta["fileName"]?.string, let mime = meta["mimeType"]?.string,
              let size = meta["byteCount"]?.integer, (1...ChatAttachment.maximumAgentBytes).contains(size)
        else { throw WorkspaceClientError.invalidResponse }
        let data = try await fetchNative(id, agentID: agentID, size: size)
        let attachment = try Self.nativeAttachment(id: id, fileName: name, mimeType: mime, data: data)
        if mime.lowercased().hasPrefix("video/") { try await Self.validateVideo(attachment) }
        await cache?.store(.init(text: "", attachments: [attachment]), for: key)
        return attachment
    }

    /// The first chunk tells how big each piece is; the rest download a few
    /// at a time. A piece that fails is asked for again from where it was,
    /// so one dropped request doesn't start the whole file over.
    private func fetchNative(_ id: String, agentID: String, size: Int) async throws -> Data {
        let first = try await fetchChunk(id, agentID: agentID, size: size, offset: 0, length: nil)
        guard let next = first.nextOffset else { return first.bytes }
        let length = next
        var pieces: [Int: Data] = [0: first.bytes]
        var offsets = stride(from: length, to: size, by: length).makeIterator()
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            func start(_ offset: Int) {
                let expected = min(length, size - offset)
                group.addTask { [self] in
                    let piece = try await fetchChunk(id, agentID: agentID, size: size, offset: offset, length: expected)
                    return (offset, piece.bytes)
                }
            }
            for _ in 0..<Self.parallelChunks {
                guard let offset = offsets.next() else { break }
                start(offset)
            }
            while let (offset, bytes) = try await group.next() {
                pieces[offset] = bytes
                if let offset = offsets.next() { start(offset) }
            }
        }
        var data = Data(capacity: size)
        for offset in pieces.keys.sorted() {
            guard offset == data.count, let bytes = pieces[offset] else { throw WorkspaceClientError.invalidResponse }
            data.append(bytes)
        }
        guard data.count == size else { throw WorkspaceClientError.invalidResponse }
        return data
    }

    private func fetchChunk(_ id: String, agentID: String, size: Int, offset: Int,
                            length: Int?) async throws -> (bytes: Data, nextOffset: Int?) {
        var retries = Self.chunkRetryDelays[...]
        while true {
            try checkOwner()
            do {
                let chunk = try await workspace.perform(.attachmentsFetch, payload: [
                    "agentId": .string(agentID), "attachmentId": .string(id), "offset": .integer(offset)
                ], owner: owner)
                try checkOwner()
                guard chunk["attachmentId"]?.string == id, chunk["offset"]?.integer == offset,
                      chunk["byteCount"]?.integer == size, let encoded = chunk["data"]?.string,
                      let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
                      offset + bytes.count <= size, length.map({ $0 == bytes.count }) ?? true
                else { throw WorkspaceClientError.invalidResponse }
                let end = offset + bytes.count
                if chunk["nextOffset"] == nil || chunk["nextOffset"] == .null {
                    guard end == size else { throw WorkspaceClientError.invalidResponse }
                    return (bytes, nil)
                }
                guard chunk["nextOffset"]?.integer == end, end < size else { throw WorkspaceClientError.invalidResponse }
                return (bytes, end)
            } catch let error where Self.retriesChunk(after: error) && !retries.isEmpty {
                try await Task.sleep(for: retries.removeFirst())
            }
        }
    }

    /// A timeout or dropped connection is worth asking again; a refusal, a bad
    /// answer or a changed connection isn't.
    private static func retriesChunk(after error: any Error) -> Bool {
        switch error {
        case is CancellationError: false
        case WorkspaceClientError.ownerChanged, WorkspaceClientError.invalidResponse,
             WorkspaceClientError.invalidRequest, WorkspaceClientError.unavailable: false
        default: true
        }
    }

    static func nativeAttachment(id: String, fileName: String, mimeType: String, data: Data) throws -> ChatAttachment {
        let mime = mimeType.lowercased()
        if mime.hasPrefix("image/") {
            guard let image = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(image) > 0,
                  CGImageSourceCreateImageAtIndex(image, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil
            else { throw WorkspaceClientError.invalidResponse }
        } else if mime == "application/pdf" {
            guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw WorkspaceClientError.invalidResponse }
        }
        let safeID = String(id.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(100))
        return try .agentArtifact(id: "native_att_" + safeID, fileName: fileName, mimeType: mime, data: data)
    }

    /// Scheduling gate: assistant text is resolved whenever it carries any
    /// `MEDIA:` directive, inline or glued, because the host owns parsing.
    static func hasAttachmentDirectives(_ text: String, role: TimelineRole) -> Bool {
        role == .assistant ? text.contains("MEDIA:") : !messageMarkers(text, role: role).isEmpty
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard currentOwner() == owner, workspace.owner == owner else { throw WorkspaceClientError.ownerChanged }
    }

    static func outputPaths(_ result: String?) -> [String] {
        guard let result, result.utf8.count <= DirectHermesWire.maximumMessageBytes else { return [] }
        if let data = result.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard object["success"] as? Bool == true else { return [] }
            // Stock image_generate preserves the host-deliverable `image` path.
            // Do not read source/edit inputs, agent-visible container aliases,
            // arbitrary nested text, or third-party provider URLs.
            if let path = object["image"] as? String, isImagePath(path) { return [path] }
            if let path = object["video"] as? String, isVideoPath(path) { return [path] }
            return []
        }
        return mediaMarkers(result).map(\.path)
    }

    static func mediaMarkers(_ text: String) -> [(line: String, path: String)] {
        guard text.utf8.count <= DirectHermesWire.maximumMessageBytes else { return [] }
        var seen = Set<Data>()
        return text.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("MEDIA:") else { return nil }
            let path = String(line.dropFirst("MEDIA:".count))
            guard isImagePath(path) || isDeliveredFilePath(path), seen.insert(Data(path.utf8)).inserted else { return nil }
            return (line, path)
        }
    }

    /// User uploads use whole-line stock references, not assistant MEDIA delivery
    /// syntax. Relative/context-range references cannot authorize a guessed read.
    static func messageMarkers(_ text: String, role: TimelineRole) -> [(line: String, path: String)] {
        guard role == .human else { return mediaMarkers(text) }
        guard text.utf8.count <= DirectHermesWire.maximumMessageBytes else { return [] }
        return text.components(separatedBy: "\n").compactMap { line in
            let image = line.hasPrefix("@image:")
            guard image || line.hasPrefix("@file:"),
                  let path = DirectHermesFileAttachments.referenceValue(String(line.dropFirst(image ? 7 : 6))),
                  image ? isImagePath(path) : isDeliveredFilePath(path) else { return nil }
            return (line, path)
        }
    }

    /// The files a finished message names that haven't reached this device
    /// yet, and its words without them: the files show as loading tiles.
    static func pendingFiles(_ text: String, role: TimelineRole) -> (text: String, fileNames: [String]) {
        guard role == .assistant else { return (text, []) }
        let markers = mediaMarkers(text)
        guard !markers.isEmpty else { return (text, []) }
        let lines = Set(markers.map { Data($0.line.utf8) })
        let remaining = text.components(separatedBy: "\n").filter { !lines.contains(Data($0.utf8)) }
        return (remaining.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                markers.map { URL(fileURLWithPath: $0.path).lastPathComponent })
    }

    /// Preserve raw references for retry and canonical reconciliation, but do not
    /// expose host paths when bytes are still pending or the host refuses access.
    static func unresolvedMessageText(_ text: String, role: TimelineRole) -> String {
        if role == .assistant {
            let pending = Dictionary(mediaMarkers(text).map {
                (Data($0.line.utf8), "Loading " + URL(fileURLWithPath: $0.path).lastPathComponent + "…")
            }, uniquingKeysWith: { first, _ in first })
            guard !pending.isEmpty else { return text }
            return text.components(separatedBy: "\n").map { pending[Data($0.utf8)] ?? $0 }.joined(separator: "\n")
        }
        guard role == .human else { return text }
        let labels = Dictionary(messageMarkers(text, role: role).map {
            (Data($0.line.utf8), "Attachment unavailable: " + URL(fileURLWithPath: $0.path).lastPathComponent)
        }, uniquingKeysWith: { first, _ in first })
        guard !labels.isEmpty else { return text }
        return text.components(separatedBy: "\n").map { labels[Data($0.utf8)] ?? $0 }.joined(separator: "\n")
    }

    /// What a finished message says once its files still can't be read.
    static func unavailableMessageText(_ text: String) -> String {
        let labels = Dictionary(mediaMarkers(text).map {
            (Data($0.line.utf8), "Couldn't load " + URL(fileURLWithPath: $0.path).lastPathComponent
                + ". Reopen this chat to try again.")
        }, uniquingKeysWith: { first, _ in first })
        return text.components(separatedBy: "\n").map { labels[Data($0.utf8)] ?? $0 }.joined(separator: "\n")
    }

    static func isImagePath(_ path: String) -> Bool {
        isOutputPath(path) && ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    static func isVideoPath(_ path: String) -> Bool {
        isOutputPath(path) && ["mp4", "m4v", "mov", "webm"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Only supported inert document/archive and audio/video deliveries receive
    /// the larger managed-file response budget. Images keep their stricter route.
    static func isDeliveredFilePath(_ path: String) -> Bool {
        guard isOutputPath(path) else { return false }
        return isVideoPath(path) || [
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "csv", "tsv",
            "rtf", "odt", "ods", "odp", "epub", "zip", "mp3", "m4a", "wav", "ogg", "flac", "aac"
        ].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func isOutputPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4_096
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !path.contains("//")
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
            && !path.unicodeScalars.contains(where: { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) })
    }

    static func attachment(_ value: BighelpJSONValue, path: String, scope: String) throws -> ChatAttachment {
        let isImage = isImagePath(path)
        let isVideo = isVideoPath(path)
        guard isImage || isDeliveredFilePath(path), let dataURL = value.object?["data_url"]?.string,
              let separator = dataURL.range(of: ";base64,"), dataURL.hasPrefix("data:"),
              dataURL.utf8.count <= ((ChatAttachment.maximumAgentBytes + 2) / 3) * 4 + 256,
              let data = Data(base64Encoded: String(dataURL[separator.upperBound...])),
              !data.isEmpty, data.count <= ChatAttachment.maximumAgentBytes else {
            throw WorkspaceClientError.invalidResponse
        }
        let mime = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<separator.lowerBound])
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if isImage {
            guard mime.hasPrefix("image/"), let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(image) > 0,
              CGImageSourceCreateImageAtIndex(image, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
                throw WorkspaceClientError.invalidResponse
            }
        } else if isVideo {
            guard mime.hasPrefix("video/") else { throw WorkspaceClientError.invalidResponse }
        } else {
            let expected = UTType(filenameExtension: ext)?.preferredMIMEType
            // Python's platform MIME database uses several historical aliases
            // that differ from Apple's preferred spelling. Keep them type-bound.
            let aliases: [String: Set<String>] = [
                "md": ["text/markdown", "text/plain", "application/octet-stream"],
                "rtf": ["application/rtf", "text/rtf"],
                "m4a": ["audio/mp4", "audio/mp4a-latm", "audio/x-m4a"],
                "wav": ["audio/wav", "audio/x-wav", "audio/vnd.wave"],
                "flac": ["audio/flac", "audio/x-flac"],
                "aac": ["audio/aac", "audio/x-aac"],
                "ogg": ["audio/ogg", "application/ogg"],
            ]
            guard mime == expected || aliases[ext]?.contains(mime) == true
                    || (["odt", "ods", "odp", "epub", "zip"].contains(ext) && mime == "application/octet-stream") else {
                throw WorkspaceClientError.invalidResponse
            }
            if ext == "pdf" {
                guard mime == "application/pdf", let document = PDFDocument(data: data), document.pageCount > 0 else {
                    throw WorkspaceClientError.invalidResponse
                }
            }
        }
        let digest = SHA256.hash(data: Data((scope + "\0" + path).utf8)).map { String(format: "%02x", $0) }.joined()
        return try .agentArtifact(id: "native_media_" + digest,
                                  fileName: URL(fileURLWithPath: path).lastPathComponent, mimeType: mime, data: data)
    }
    private static func validateVideo(_ attachment: ChatAttachment) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: attachment.fileName)
        try attachment.data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        guard try await AVURLAsset(url: file).load(.isPlayable) else { throw WorkspaceClientError.invalidResponse }
    }
}

@MainActor
final class DirectHermesStoreMediaProxy: GeneratedMediaResolving, AgentAttachmentResolving {
    private let makeClient: @MainActor () throws -> DirectHermesGeneratedMediaClient
    init(makeClient: @escaping @MainActor () throws -> DirectHermesGeneratedMediaClient) { self.makeClient = makeClient }
    func resolve(agentID: String, storedID: String, event: ChatActivityEvent) async throws -> GeneratedMediaResolution {
        try await makeClient().resolve(agentID: agentID, storedID: storedID, event: event)
    }
    func resolve(agentID: String, storedID: String, items: [AgentAttachmentTextItem]) async throws -> [ResolvedAgentAttachmentItem] {
        try await makeClient().resolve(agentID: agentID, storedID: storedID, items: items)
    }
}

@MainActor
final class WorkspaceGeneratedMediaProxy: GeneratedMediaResolving, AgentAttachmentResolving {
    let box: WorkspaceOwnedClientBox<DirectHermesGeneratedMediaClient>
    init(box: WorkspaceOwnedClientBox<DirectHermesGeneratedMediaClient>) { self.box = box }
    func resolve(agentID: String, storedID: String, event: ChatActivityEvent) async throws -> GeneratedMediaResolution {
        try await box.value().resolve(agentID: agentID, storedID: storedID, event: event)
    }
    func resolve(agentID: String, storedID: String,
                 items: [AgentAttachmentTextItem]) async throws -> [ResolvedAgentAttachmentItem] {
        try await box.value().resolve(agentID: agentID, storedID: storedID, items: items)
    }
}
