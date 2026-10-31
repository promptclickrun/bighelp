import Foundation

/// Files over `ChatAttachment.maximumBytes` go to the host in pieces through the
/// plugin's `uploads/*` routes (`native-uploads-v1`), never in one socket frame.
/// The host keeps which pieces it has; a dropped connection costs only the
/// pieces that were on their way.
enum BigFileUploads {
    static let feature = "native-uploads-v1"
    /// The plugin's own limit (`MAX_UPLOAD_BYTES`). An 80 MB iPhone video fits three times.
    static let maximumBytes = 256 * 1_024 * 1_024
    /// The largest piece the app accepts the host asking for.
    static let maximumChunkBytes = 16 * 1_024 * 1_024
    static let minimumChunkBytes = 64 * 1_024

    /// What to say when a file is too big for this computer's plugin.
    static let updatePluginMessage =
        "Files over 8 MB need the newest bighelp plugin on this computer. Update it in Settings, under this computer's "
            + "Plugin version, then try again."
    static let tooLargeMessage = "Each file can be up to 256 MB."

    static func isBig(_ byteCount: Int) -> Bool { byteCount > ChatAttachment.maximumBytes }
}

/// Which pieces make the file, and which the host still needs.
struct BigFileUploadPlan: Equatable, Sendable {
    let byteCount: Int
    let chunkBytes: Int

    init(byteCount: Int, chunkBytes: Int) throws {
        guard (1...BigFileUploads.maximumBytes).contains(byteCount),
              (BigFileUploads.minimumChunkBytes...BigFileUploads.maximumChunkBytes).contains(chunkBytes) else {
            throw WorkspaceClientError.invalidResponse
        }
        self.byteCount = byteCount
        self.chunkBytes = chunkBytes
    }

    var chunkCount: Int { (byteCount + chunkBytes - 1) / chunkBytes }

    /// The bytes piece `index` holds: `chunkBytes`, except for the last piece.
    func range(of index: Int) -> Range<Int> {
        precondition((0..<chunkCount).contains(index))
        let start = index * chunkBytes
        return start..<min(start + chunkBytes, byteCount)
    }

    func missing(_ received: Set<Int>) -> [Int] {
        (0..<chunkCount).filter { !received.contains($0) }
    }

    func receivedBytes(_ received: Set<Int>) -> Int {
        received.reduce(0) { $0 + ((0..<chunkCount).contains($1) ? range(of: $1).count : 0) }
    }
}

/// The host's answer to `start`, `status` and `chunk`, read strictly.
struct BigFileUploadReceipt: Equatable, Sendable {
    let uploadID: String
    let byteCount: Int
    let plan: BigFileUploadPlan
    let received: Set<Int>
    let finished: Bool

    init(_ value: [String: BighelpJSONValue], expectedByteCount: Int, expectedUploadID: String? = nil) throws {
        guard let uploadID = value["uploadId"]?.string, Self.isUploadID(uploadID),
              expectedUploadID.map({ $0 == uploadID }) ?? true,
              let byteCount = value["byteCount"]?.integer, byteCount == expectedByteCount,
              let chunkBytes = value["chunkBytes"]?.integer,
              let chunks = value["receivedChunks"]?.array, chunks.count <= 4_096,
              let finished = value["finished"]?.boolean else {
            throw WorkspaceClientError.invalidResponse
        }
        let plan = try BigFileUploadPlan(byteCount: byteCount, chunkBytes: chunkBytes)
        var received = Set<Int>()
        for chunk in chunks {
            guard let index = chunk.integer, (0..<plan.chunkCount).contains(index),
                  received.insert(index).inserted else { throw WorkspaceClientError.invalidResponse }
        }
        if let bytes = value["receivedBytes"]?.integer, bytes != plan.receivedBytes(received) {
            throw WorkspaceClientError.invalidResponse
        }
        self.uploadID = uploadID
        self.byteCount = byteCount
        self.plan = plan
        self.received = received
        self.finished = finished
    }

    static func isUploadID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Where `finish` says the file now is, for Hermes' `file.attach`: the agent's working folder
    /// (`<folder>/uploads/<YYYY-MM-DD>/<name>`, which its Files tab opens), or, for an agent with no folder on
    /// that computer, the plugin's own staging folder for this upload. No other shape is accepted.
    static func finishedFile(_ value: [String: BighelpJSONValue], uploadID: String) throws -> (path: String, inWorkspace: Bool) {
        guard value["finished"]?.boolean == true, value["uploadId"]?.string == uploadID,
              let inWorkspace = value["inWorkspace"]?.boolean,
              let path = value["path"]?.string, (2...4_096).contains(path.utf8.count), path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw WorkspaceClientError.invalidResponse
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(".."), !parts.contains("."), let name = parts.last, !name.isEmpty, !name.hasPrefix(".")
        else { throw WorkspaceClientError.invalidResponse }
        if inWorkspace {
            guard parts.count >= 4, parts[parts.count - 3] == "uploads",
                  parts[parts.count - 2].wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else {
                throw WorkspaceClientError.invalidResponse
            }
        } else {
            guard parts.count >= 7, parts[parts.count - 2] == "file", parts[parts.count - 3] == uploadID,
                  Array(parts[(parts.count - 6)...(parts.count - 4)]) == ["plugin-data", "loopdy", "uploads"] else {
                throw WorkspaceClientError.invalidResponse
            }
        }
        return (path, inWorkspace)
    }
}

/// Why a big file didn't go, in words for the person (the plugin's fixed codes).
enum BigFileUploadFailure: Equatable, Sendable {
    case noSpace
    case busy
    case damaged
    case pluginRequired
    case expired
    case connection
    case other

    init(code: String) {
        switch code {
        case "upload_no_space": self = .noSpace
        case "uploads_busy": self = .busy
        case "upload_corrupt", "upload_chunk_corrupt": self = .damaged
        case "uploads_unavailable", "unsupported_operation": self = .pluginRequired
        case "upload_not_found": self = .expired
        case "upload_chunk_timeout", "request_disconnected": self = .connection
        default: self = .other
        }
    }

    init(_ error: any Error) {
        switch error {
        case WorkspaceClientError.rejected(let code, _): self.init(code: code ?? "")
        case WorkspaceClientError.unavailable: self = .pluginRequired
        case is URLError, WorkspaceClientError.transportUnavailable, WorkspaceClientError.outcomeUnknown,
             DirectHermesError.notConnected, DirectHermesError.disconnected, DirectHermesError.timedOut,
             DirectHermesError.connectionFailed, DirectHermesError.serverUnavailable:
            self = .connection
        default: self = .other
        }
    }

    var message: String {
        switch self {
        case .noSpace: "Not sent. The computer is out of space for this file."
        case .busy: "Not sent. The computer is taking other files right now."
        case .damaged: "Not sent. The file arrived damaged."
        case .pluginRequired: BigFileUploads.updatePluginMessage
        case .expired: "Not sent. The computer let go of this file."
        case .connection: "Not sent. The connection to the computer dropped."
        case .other: "Not sent. The computer didn't take this file."
        }
    }

    /// Worth trying again by itself, before telling the person.
    var retriesQuietly: Bool { self == .connection || self == .busy || self == .damaged || self == .expired }
}
