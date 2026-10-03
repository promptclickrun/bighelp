import Foundation

enum ChatAttachmentError: Error, Equatable, LocalizedError {
    case invalidID
    case invalidFileName
    case invalidMIMEType
    case invalidSize
    case unsupportedKind
    case unsupportedClient

    var errorDescription: String? {
        switch self {
        case .invalidID: "This attachment has an invalid identifier."
        case .invalidFileName: "This attachment has an unsupported file name."
        case .invalidMIMEType: "This attachment's file type could not be determined."
        case .invalidSize: "This attachment exceeds the supported size."
        case .unsupportedKind: "This attachment type is unavailable on this connection."
        case .unsupportedClient: "Attachments are unavailable on this connection. Nothing was sent."
        }
    }
}

extension ChatAttachmentError {
    /// What to tell the person when a photo or file couldn't be added.
    static func userMessage(for error: any Error) -> String {
        if error as? ChatAttachmentError == .unsupportedClient { return error.localizedDescription }
        if error as? ChatAttachmentError == .unsupportedKind { return DirectHermesFileAttachments.imagesUnavailable }
        if error as? ChatAttachmentError == .invalidSize {
            return "Each attachment can be up to 8 MB, with up to 24 MB in one message."
        }
        if let imageError = error as? ImageAttachmentPreparer.Error {
            switch imageError {
            case .sourceTooLarge, .sourceDimensionsTooLarge, .outputTooLarge:
                return "That image is still too large after preparation. Choose a smaller photo and try again."
            case .invalidData, .unsupportedFormat, .processingFailed:
                break
            }
        }
        return "bighelp could not read that attachment. Choose another file and try again."
    }
}

struct ChatAttachment: Identifiable, Codable, Equatable, Sendable {
    /// User-selected uploads retain the established 8 MiB limit.
    static let maximumBytes = 8 * 1_024 * 1_024
    /// Agent-produced artifacts are fetched from the authenticated, profile-scoped
    /// host cache and may use its bounded per-artifact allowance.
    static let maximumAgentBytes = 25 * 1_024 * 1_024

    enum Kind: String, Codable, Equatable, Sendable {
        case image
        case file
    }

    let id: String
    let fileName: String
    let mimeType: String
    let data: Data

    private enum CodingKeys: String, CodingKey {
        case id
        case fileName
        case mimeType
        case data
    }

    var kind: Kind { mimeType.lowercased().hasPrefix("image/") ? .image : .file }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(String.self, forKey: .id),
            fileName: container.decode(String.self, forKey: .fileName),
            mimeType: container.decode(String.self, forKey: .mimeType),
            data: container.decode(Data.self, forKey: .data),
            maximumBytes: Self.maximumAgentBytes
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(mimeType, forKey: .mimeType)
        try container.encode(data, forKey: .data)
    }

    init(id: String, fileName: String, mimeType: String, data: Data) throws {
        try self.init(
            id: id,
            fileName: fileName,
            mimeType: mimeType,
            data: data,
            maximumBytes: Self.maximumBytes
        )
    }

    static func agentArtifact(
        id: String,
        fileName: String,
        mimeType: String,
        data: Data
    ) throws -> ChatAttachment {
        try ChatAttachment(
            id: id,
            fileName: fileName,
            mimeType: mimeType,
            data: data,
            maximumBytes: maximumAgentBytes
        )
    }

    private init(
        id: String,
        fileName: String,
        mimeType: String,
        data: Data,
        maximumBytes: Int
    ) throws {
        guard (16...128).contains(id.count), id.allSatisfy({
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }) else { throw ChatAttachmentError.invalidID }
        let normalizedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            (1...180).contains(normalizedFileName.count),
            normalizedFileName == fileName,
            normalizedFileName == URL(fileURLWithPath: normalizedFileName).lastPathComponent,
            !normalizedFileName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ChatAttachmentError.invalidFileName }
        let normalizedMIME = mimeType.lowercased()
        guard
            (3...120).contains(normalizedMIME.count),
            normalizedMIME.contains("/"),
            normalizedMIME.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || "!#$&^_.+-/".contains($0))
            })
        else { throw ChatAttachmentError.invalidMIMEType }
        guard (1...maximumBytes).contains(data.count) else {
            throw ChatAttachmentError.invalidSize
        }
        self.id = id
        self.fileName = normalizedFileName
        self.mimeType = normalizedMIME
        self.data = data
    }
}

struct AgentAttachmentTextItem: Equatable, Sendable {
    let id: String
    let text: String
    let role: TimelineRole

    init(id: String, text: String, role: TimelineRole = .assistant) {
        self.id = id
        self.text = text
        self.role = role
    }
}

struct ResolvedAgentAttachmentItem: Equatable, Sendable {
    let id: String
    let text: String
    let attachments: [ChatAttachment]
}

@MainActor
protocol AgentAttachmentResolving: AnyObject {
    func resolve(
        agentID: String,
        storedID: String,
        items: [AgentAttachmentTextItem]
    ) async throws -> [ResolvedAgentAttachmentItem]
}
