import CryptoKit
import Foundation

/// A typed file exposed by Hermes' managed-files policy. Its absolute host path
/// is published only after confinement to an owner-bound configured workspace.
public struct HermesManagedFile: Identifiable, Equatable, Sendable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let byteCount: Int?
    public let modifiedAt: Date
    public let mimeType: String?

    public var id: String { "\(name.utf8.count):\(name)\(path)" }

    public init(
        path: String,
        name: String,
        isDirectory: Bool,
        byteCount: Int?,
        modifiedAt: Date,
        mimeType: String?
    ) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.mimeType = mimeType
    }
}

public struct HermesManagedFileDirectory: Equatable, Sendable {
    public let path: String
    public let parent: String?
    public let files: [HermesManagedFile]

    public init(path: String, parent: String?, files: [HermesManagedFile]) {
        self.path = path
        self.parent = parent
        self.files = files
    }
}

public struct HermesManagedFileContents: Equatable, Sendable {
    public let file: HermesManagedFile
    public let bytes: Data
    public let sha256: String

    public init(file: HermesManagedFile, bytes: Data, sha256: String) {
        self.file = file
        self.bytes = bytes
        self.sha256 = sha256
    }
}

public struct HermesManagedMediaProbe: Equatable, Sendable {
    public let file: HermesManagedFile
    public let acceptsByteRanges: Bool

    public init(file: HermesManagedFile, acceptsByteRanges: Bool) {
        self.file = file
        self.acceptsByteRanges = acceptsByteRanges
    }
}

public struct HermesManagedFileRange: Equatable, Sendable {
    public let file: HermesManagedFile
    public let requested: Range<Int>
    public let totalByteCount: Int
    public let bytes: Data

    public init(file: HermesManagedFile, requested: Range<Int>, totalByteCount: Int, bytes: Data) {
        self.file = file
        self.requested = requested
        self.totalByteCount = totalByteCount
        self.bytes = bytes
    }
}

/// Typed binary response used only by the parent-owned authenticated transport
/// seam. It deliberately does not expose arbitrary headers, methods, or URLs.
struct DirectHermesManagedFileBinaryResponse: Equatable, Sendable {
    let statusCode: Int
    let contentType: String?
    let contentLength: Int?
    let acceptsByteRanges: Bool
    let contentRange: String?
    let bytes: Data
}

struct DirectHermesManagedFileUploadResponse: Equatable, Sendable {
    let acknowledgement: BighelpJSONValue
    let byteCount: Int
    let sha256: String
}

struct DirectHermesManagedFileReadback: Equatable, Sendable {
    let statusCode: Int
    let contentType: String?
    let contentLength: Int?
    let byteCount: Int
    let sha256: String
}

enum DirectHermesManagedFileUploadError: Error, Equatable {
    case outcomeUnknown(byteCount: Int, sha256: String)
}

/// The existing JSON HTTP constructor cannot represent HEAD, Range headers,
/// binary response bodies, or file-backed multipart request bodies. This narrow
/// authenticated seam keeps every route and method app-authored.
@MainActor
protocol DirectHermesManagedFileBinaryHTTP: AnyObject {
    func downloadManagedFile(path: String, scope: DirectHermesWorkspaceFileScope, maximumBytes: Int) async throws
        -> DirectHermesManagedFileBinaryResponse
    func headManagedMedia(path: String, scope: DirectHermesWorkspaceFileScope) async throws
        -> DirectHermesManagedFileBinaryResponse
    func streamManagedMedia(
        path: String,
        scope: DirectHermesWorkspaceFileScope,
        range: Range<Int>,
        maximumBytes: Int
    ) async throws
        -> DirectHermesManagedFileBinaryResponse
    func uploadManagedFile(
        path: String,
        scope: DirectHermesWorkspaceFileScope,
        fileName: String,
        mimeType: String,
        localFile: URL,
        byteCount: Int,
        overwrite: Bool,
        maximumResponseBytes: Int,
        requireOriginalOwner: @escaping @MainActor () throws -> Void
    ) async throws -> DirectHermesManagedFileUploadResponse
    func verifyManagedFile(
        path: String,
        scope: DirectHermesWorkspaceFileScope,
        expectedByteCount: Int,
        maximumBytes: Int
    ) async throws -> DirectHermesManagedFileReadback
}

enum DirectHermesManagedFilesError: Error, Equatable, LocalizedError {
    case invalidPath
    case invalidName
    case invalidResponse
    case scopeUnavailable
    case scopeChanged
    case fileTooLarge(limit: Int)
    case ownerChanged
    case transferTransportRequired
    case mediaStreamingOnly
    case mutationNotVerified

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            "Choose a file or folder inside this host’s configured workspace."
        case .invalidName:
            "Use a single file or folder name without slashes or control characters."
        case .invalidResponse:
            "Hermes returned an invalid managed-file response. Refresh before trying again."
        case .scopeUnavailable:
            "This computer didn't confirm which folder your agent works in, so bighelp opened no files."
        case .scopeChanged:
            "Hermes’ managed-files policy changed after this workspace was opened. Reopen Files to establish the current boundary."
        case .fileTooLarge(let limit):
            "This file exceeds bighelp’s bounded native transfer limit of \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
        case .ownerChanged:
            "The selected host or account changed. Reopen Files from the current workspace."
        case .transferTransportRequired:
            "This transfer needs authenticated binary, HEAD, Range, or multipart HTTP support that the current Direct transport does not yet expose."
        case .mediaStreamingOnly:
            "Hermes supports range streaming only for its allowlisted audio and video file types."
        case .mutationNotVerified:
            "Hermes did not return authoritative readback for this change. Refresh before trying again."
        }
    }
}

/// Owner-fenced native client whose scope and listings come from the bighelp
/// plugin's explicit configured-workspace contract.
///
/// JSON upload/read preserve the small-file path. The optional binary seam owns
/// fixed download, HEAD, Range, and bounded file-backed multipart operations.
@MainActor
final class DirectHermesManagedFilesClient {
    nonisolated static let maximumJSONUploadBytes = 512 * 1_024
    nonisolated static let maximumJSONDownloadBytes = 2 * 1_024 * 1_024
    nonisolated static let maximumNativeTransferBytes = 16 * 1_024 * 1_024
    nonisolated static let maximumListingResponseBytes = 4 * 1_024 * 1_024
    nonisolated static let maximumMutationResponseBytes = 256 * 1_024

    enum API: String, CaseIterable, Sendable {
        case discover = "MF-SCOPE POST /api/plugins/loopdy/native/workspace-files/scope"
        case list = "MF-LIST POST /api/plugins/loopdy/native/workspace-files/list"
        case read = "MF-READ GET /api/files/read"
        case download = "MF-DOWNLOAD GET /api/files/download"
        case stream = "MF-STREAM GET /api/files/stream"
        case streamHead = "MF-STREAM-HEAD HEAD /api/files/stream"
        case upload = "MF-UPLOAD POST /api/files/upload"
        case uploadStream = "MF-UPLOAD-STREAM POST /api/files/upload-stream"
        case makeDirectory = "MF-MKDIR POST /api/files/mkdir"
        case delete = "MF-DELETE DELETE /api/files"
    }

    private let http: any DirectHermesAuthenticatedHTTP
    private let binaryHTTP: (any DirectHermesManagedFileBinaryHTTP)?
    private let capturedOwner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private let suppliedScopeOwnerMismatch: Bool
    private var establishedScope: DirectHermesWorkspaceFileScope?
    private var configuredWorkspaceClient: DirectHermesArtifactClient?
    /// The agent whose own folder this reads; nil is the plugin's serving agent.
    private let agentID: String?

    init(
        http: any DirectHermesAuthenticatedHTTP,
        binaryHTTP: (any DirectHermesManagedFileBinaryHTTP)? = nil,
        owner: WorkspaceOwner,
        scope: DirectHermesWorkspaceFileScope? = nil,
        agentID: String? = nil,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.http = http
        self.binaryHTTP = binaryHTTP
        self.agentID = agentID
        capturedOwner = owner
        suppliedScopeOwnerMismatch = scope != nil && scope?.owner != owner
        establishedScope = scope?.owner == owner ? scope : nil
        self.currentOwner = currentOwner
    }

    var ownsScope: Bool { currentOwner() == capturedOwner }
    var supportsBinaryTransfers: Bool { binaryHTTP != nil }
    var scopePath: String? { establishedScope?.root }

    func workspaceScope() async throws -> DirectHermesWorkspaceFileScope {
        try await scope()
    }

    func list(path requestedPath: String? = nil) async throws -> HermesManagedFileDirectory {
        let scope = try await scope()
        try await verifyConfiguredWorkspace(scope)
        let path = try scope.require(requestedPath ?? scope.root)
        let object = try await workspaceFilesClient().list(path: path, owner: capturedOwner)
        return try scope.managedDirectory(object, expectedPath: path)
    }

    func download(_ file: HermesManagedFile) async throws -> HermesManagedFileContents {
        try checkOwner()
        let scope = try await scope()
        try Self.requireTransferable(file, scope: scope)
        try await verifyListed(file, scope: scope)
        if let binaryHTTP {
            guard let byteCount = file.byteCount,
                  byteCount <= Self.maximumNativeTransferBytes else {
                throw DirectHermesManagedFilesError.fileTooLarge(limit: Self.maximumNativeTransferBytes)
            }
            let response = try await binaryRequest {
                try await binaryHTTP.downloadManagedFile(
                    path: file.path,
                    scope: scope,
                    maximumBytes: Self.maximumNativeTransferBytes
                )
            }
            guard response.statusCode == 200,
                  response.contentRange == nil,
                  response.bytes.count == byteCount,
                  response.contentLength == nil || response.contentLength == byteCount,
                  Self.sameHTTPMIME(response.contentType, file.mimeType),
                  response.bytes.count <= Self.maximumNativeTransferBytes else {
                throw DirectHermesManagedFilesError.invalidResponse
            }
            return Self.contents(file: file, bytes: response.bytes)
        }

        guard let byteCount = file.byteCount,
              byteCount <= Self.maximumJSONDownloadBytes else {
            throw DirectHermesManagedFilesError.fileTooLarge(limit: Self.maximumJSONDownloadBytes)
        }
        let value = try await json(.init(
            path: "/api/files/read",
            method: .get,
            query: [.init(name: "path", value: file.path)],
            maximumResponseBytes: Self.maximumListingResponseBytes
        ))
        guard let object = value.object else { throw DirectHermesManagedFilesError.invalidResponse }
        let contents = try Self.readContents(object, expected: file, scope: scope)
        guard contents.bytes.count <= Self.maximumJSONDownloadBytes else {
            throw DirectHermesManagedFilesError.fileTooLarge(limit: Self.maximumJSONDownloadBytes)
        }
        return contents
    }

    func probeStream(_ file: HermesManagedFile) async throws -> HermesManagedMediaProbe {
        try checkOwner()
        let scope = try await scope()
        try Self.requireStreamable(file, scope: scope)
        try await verifyListed(file, scope: scope)
        guard let binaryHTTP else { throw DirectHermesManagedFilesError.transferTransportRequired }
        let response = try await binaryRequest {
            try await binaryHTTP.headManagedMedia(path: file.path, scope: scope)
        }
        guard response.statusCode == 200,
              response.bytes.isEmpty,
              response.contentRange == nil,
              response.contentLength == nil || response.contentLength == file.byteCount,
              Self.sameHTTPMIME(response.contentType, file.mimeType) else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        return .init(file: file, acceptsByteRanges: response.acceptsByteRanges)
    }

    func stream(_ file: HermesManagedFile, range: Range<Int>) async throws -> HermesManagedFileRange {
        try checkOwner()
        let scope = try await scope()
        try Self.requireStreamable(file, scope: scope)
        try await verifyListed(file, scope: scope)
        guard let total = file.byteCount,
              range.lowerBound >= 0,
              range.lowerBound < range.upperBound,
              range.upperBound <= total,
              range.count <= Self.maximumNativeTransferBytes else {
            throw DirectHermesManagedFilesError.invalidPath
        }
        guard let binaryHTTP else { throw DirectHermesManagedFilesError.transferTransportRequired }
        let response = try await binaryRequest {
            try await binaryHTTP.streamManagedMedia(
                path: file.path,
                scope: scope,
                range: range,
                maximumBytes: min(range.count, Self.maximumNativeTransferBytes)
            )
        }
        let expectedRange = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(total)"
        guard response.statusCode == 206,
              response.acceptsByteRanges,
              response.contentRange == expectedRange,
              response.bytes.count == range.count,
              response.contentLength == nil || response.contentLength == range.count,
              Self.sameHTTPMIME(response.contentType, file.mimeType) else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        return .init(file: file, requested: range, totalByteCount: total, bytes: response.bytes)
    }

    func upload(
        bytes: Data,
        fileName: String,
        mimeType: String,
        to directory: String,
        overwrite: Bool = false
    ) async throws -> HermesManagedFile {
        try checkOwner()
        let scope = try await scope()
        let name = try Self.pathComponent(fileName)
        let mimeType = try Self.mimeType(mimeType)
        let destination = try scope.child(name, of: directory)
        let verifiedDirectory = try await list(path: directory)
        guard DirectHermesWorkspaceFileScope.samePath(verifiedDirectory.path, directory) else {
            throw DirectHermesManagedFilesError.mutationNotVerified
        }
        guard !bytes.isEmpty, bytes.count <= Self.maximumNativeTransferBytes else {
            throw DirectHermesManagedFilesError.fileTooLarge(limit: Self.maximumNativeTransferBytes)
        }

        var receipt: HermesManagedFile?
        do {
            let value: BighelpJSONValue
            if bytes.count <= Self.maximumJSONUploadBytes {
                let dataURL = "data:\(mimeType);base64,\(bytes.base64EncodedString())"
                value = try await json(.init(
                    path: "/api/files/upload",
                    method: .post,
                    body: [
                        "path": .string(destination),
                        "data_url": .string(dataURL),
                        "overwrite": .boolean(overwrite),
                    ],
                    maximumResponseBytes: Self.maximumMutationResponseBytes
                ))
            } else {
                guard let binaryHTTP else { throw DirectHermesManagedFilesError.transferTransportRequired }
                let localFile = try await Self.makePrivateUploadSource(bytes)
                defer { try? FileManager.default.removeItem(at: localFile.deletingLastPathComponent()) }
                let upload = try await binaryRequest {
                    try await binaryHTTP.uploadManagedFile(
                        path: destination,
                        scope: scope,
                        fileName: name,
                        mimeType: mimeType,
                        localFile: localFile,
                        byteCount: bytes.count,
                        overwrite: overwrite,
                        maximumResponseBytes: Self.maximumMutationResponseBytes,
                        requireOriginalOwner: { try self.checkOwner() }
                    )
                }
                guard upload.byteCount == bytes.count else {
                    throw DirectHermesManagedFilesError.mutationNotVerified
                }
                value = upload.acknowledgement
            }

            guard let object = value.object else { throw DirectHermesManagedFilesError.invalidResponse }
            receipt = try Self.writeReceipt(
                object,
                expectedPath: destination,
                directory: false,
                scope: scope
            )
            guard receipt?.byteCount == bytes.count else {
                throw DirectHermesManagedFilesError.mutationNotVerified
            }
        } catch WorkspaceClientError.outcomeUnknown {
            // Never replay an uncertain mutation. The same authoritative list
            // and exact-byte readback below are allowed to reconcile it.
            receipt = nil
        } catch DirectHermesManagedFileUploadError.outcomeUnknown(let byteCount, let sha256) {
            guard byteCount == bytes.count, sha256 == Self.sha256(bytes) else {
                throw DirectHermesManagedFilesError.mutationNotVerified
            }
            receipt = nil
        }

        let refreshed = try await list(path: directory)
        guard let listed = refreshed.files.first(where: { $0.path.utf8.elementsEqual(destination.utf8) }),
              listed.byteCount == bytes.count,
              receipt.map({ listed == $0 }) ?? true else {
            throw DirectHermesManagedFilesError.mutationNotVerified
        }
        let readback = try await download(listed)
        guard readback.bytes == bytes else { throw DirectHermesManagedFilesError.mutationNotVerified }
        return listed
    }

    /// Uploads a security-scoped local file without converting the file or its
    /// multipart envelope into one whole `Data` value. The caller must keep its
    /// security-scope access alive until this method returns.
    func upload(
        localFile: URL,
        byteCount: Int,
        fileName: String,
        mimeType: String,
        to directory: String,
        overwrite: Bool = false
    ) async throws -> HermesManagedFile {
        try checkOwner()
        guard byteCount > 0, byteCount <= Self.maximumNativeTransferBytes else {
            throw DirectHermesManagedFilesError.fileTooLarge(limit: Self.maximumNativeTransferBytes)
        }
        if byteCount <= Self.maximumJSONUploadBytes {
            let bytes = try await Self.readPrivateUploadSource(localFile, expectedByteCount: byteCount)
            try checkOwner()
            return try await upload(
                bytes: bytes,
                fileName: fileName,
                mimeType: mimeType,
                to: directory,
                overwrite: overwrite
            )
        }

        try checkOwner()
        let scope = try await scope()
        let name = try Self.pathComponent(fileName)
        let mimeType = try Self.mimeType(mimeType)
        let destination = try scope.child(name, of: directory)
        let verifiedDirectory = try await list(path: directory)
        guard DirectHermesWorkspaceFileScope.samePath(verifiedDirectory.path, directory) else {
            throw DirectHermesManagedFilesError.mutationNotVerified
        }
        guard let binaryHTTP else { throw DirectHermesManagedFilesError.transferTransportRequired }

        var receipt: HermesManagedFile?
        var sourceSHA256: String
        do {
            let upload = try await binaryRequest {
                try await binaryHTTP.uploadManagedFile(
                    path: destination,
                    scope: scope,
                    fileName: name,
                    mimeType: mimeType,
                    localFile: localFile,
                    byteCount: byteCount,
                    overwrite: overwrite,
                    maximumResponseBytes: Self.maximumMutationResponseBytes,
                    requireOriginalOwner: { try self.checkOwner() }
                )
            }
            guard upload.byteCount == byteCount else {
                throw DirectHermesManagedFilesError.mutationNotVerified
            }
            sourceSHA256 = upload.sha256
            guard let object = upload.acknowledgement.object else {
                throw DirectHermesManagedFilesError.invalidResponse
            }
            receipt = try Self.writeReceipt(
                object,
                expectedPath: destination,
                directory: false,
                scope: scope
            )
            guard receipt?.byteCount == byteCount else {
                throw DirectHermesManagedFilesError.mutationNotVerified
            }
        } catch DirectHermesManagedFileUploadError.outcomeUnknown(let stagedByteCount, let stagedSHA256) {
            guard stagedByteCount == byteCount else {
                throw DirectHermesManagedFilesError.mutationNotVerified
            }
            sourceSHA256 = stagedSHA256
            receipt = nil
        }

        let refreshed = try await list(path: directory)
        guard let listed = refreshed.files.first(where: { $0.path.utf8.elementsEqual(destination.utf8) }),
              listed.byteCount == byteCount,
              receipt.map({ listed == $0 }) ?? true else {
            throw DirectHermesManagedFilesError.mutationNotVerified
        }
        let readback = try await binaryRequest {
            try await binaryHTTP.verifyManagedFile(
                path: listed.path,
                scope: scope,
                expectedByteCount: byteCount,
                maximumBytes: Self.maximumNativeTransferBytes
            )
        }
        guard readback.statusCode == 200,
              readback.byteCount == byteCount,
              readback.contentLength == nil || readback.contentLength == byteCount,
              Self.sameHTTPMIME(readback.contentType, listed.mimeType),
              readback.sha256 == sourceSHA256 else {
            throw DirectHermesManagedFilesError.mutationNotVerified
        }
        return listed
    }

    func createDirectory(named name: String, in directory: String) async throws -> HermesManagedFile {
        let scope = try await scope()
        let destination = try scope.child(name, of: directory)
        let verifiedDirectory = try await list(path: directory)
        guard DirectHermesWorkspaceFileScope.samePath(verifiedDirectory.path, directory) else {
            throw DirectHermesManagedFilesError.mutationNotVerified
        }
        var receipt: HermesManagedFile?
        do {
            let value = try await json(.init(
                path: "/api/files/mkdir",
                method: .post,
                body: ["path": .string(destination)],
                maximumResponseBytes: Self.maximumMutationResponseBytes
            ))
            guard let object = value.object else { throw DirectHermesManagedFilesError.invalidResponse }
            receipt = try Self.writeReceipt(
                object,
                expectedPath: destination,
                directory: true,
                scope: scope
            )
        } catch WorkspaceClientError.outcomeUnknown {
            receipt = nil
        }
        let refreshed = try await list(path: directory)
        guard let listed = refreshed.files.first(where: {
            $0.path.utf8.elementsEqual(destination.utf8) && $0.isDirectory
        }),
              receipt.map({ listed == $0 }) ?? true else {
            throw DirectHermesManagedFilesError.mutationNotVerified
        }
        return listed
    }

    func delete(_ selectedFile: HermesManagedFile) async throws {
        try checkOwner()
        let scope = try await scope()
        try Self.requireTransferable(selectedFile, scope: scope)
        guard !DirectHermesWorkspaceFileScope.samePath(selectedFile.path, scope.root) else {
            throw DirectHermesManagedFilesError.invalidPath
        }
        let parent = try scope.parent(of: selectedFile.path)
        let before = try await list(path: parent)
        guard before.files.contains(selectedFile) else {
            throw DirectHermesManagedFilesError.mutationNotVerified
        }

        var responseConfirmed = false
        do {
            let value = try await json(.init(
                path: "/api/files",
                method: .delete,
                body: [
                    "path": .string(selectedFile.path),
                    "recursive": .boolean(false),
                ],
                maximumResponseBytes: Self.maximumMutationResponseBytes
            ))
            guard let object = value.object,
                  object["ok"]?.boolean == true,
                  let returnedPath = object["path"]?.string,
                  returnedPath.utf8.elementsEqual(selectedFile.path.utf8) else {
                throw DirectHermesManagedFilesError.invalidResponse
            }
            try scope.validatePolicy(object)
            responseConfirmed = true
        } catch WorkspaceClientError.outcomeUnknown {
            responseConfirmed = false
        }

        let after = try await list(path: parent)
        guard !after.files.contains(where: { $0.path.utf8.elementsEqual(selectedFile.path.utf8) }) else {
            if responseConfirmed { throw DirectHermesManagedFilesError.mutationNotVerified }
            throw WorkspaceClientError.outcomeUnknown
        }
    }


    private func scope() async throws -> DirectHermesWorkspaceFileScope {
        try checkOwner()
        guard !suppliedScopeOwnerMismatch else {
            throw DirectHermesManagedFilesError.ownerChanged
        }
        if let establishedScope {
            guard establishedScope.owner == capturedOwner else {
                throw DirectHermesManagedFilesError.ownerChanged
            }
            return establishedScope
        }

        let listing: [String: BighelpJSONValue]
        do {
            listing = try await workspaceFilesClient().scope(owner: capturedOwner)
        } catch let error as WorkspaceClientError {
            // The host's own reason (no working folder, old plugin…) says what to fix.
            try checkOwner()
            throw error
        } catch {
            try checkOwner()
            throw DirectHermesManagedFilesError.scopeUnavailable
        }
        let discovered: DirectHermesWorkspaceFileScope
        do {
            discovered = try DirectHermesWorkspaceFileScope.pluginReported(
                workspaceListing: listing,
                owner: capturedOwner
            )
        } catch {
            throw DirectHermesManagedFilesError.scopeUnavailable
        }
        try checkOwner()
        establishedScope = discovered
        return discovered
    }

    private func verifyListed(
        _ file: HermesManagedFile,
        scope: DirectHermesWorkspaceFileScope
    ) async throws {
        let parent = try scope.parent(of: file.path)
        let directory = try await list(path: parent)
        guard directory.files.contains(file) else {
            throw DirectHermesManagedFilesError.mutationNotVerified
        }
    }

    private func verifyConfiguredWorkspace(
        _ scope: DirectHermesWorkspaceFileScope
    ) async throws {
        let object: [String: BighelpJSONValue]
        do {
            object = try await workspaceFilesClient().scope(owner: capturedOwner)
        } catch {
            try checkOwner()
            throw DirectHermesManagedFilesError.scopeChanged
        }
        guard let current = try? DirectHermesWorkspaceFileScope.pluginReported(
                workspaceListing: object, owner: capturedOwner
              ), current == scope else {
            throw DirectHermesManagedFilesError.scopeChanged
        }
    }

    private func workspaceFilesClient() throws -> DirectHermesArtifactClient {
        try checkOwner()
        if let configuredWorkspaceClient { return configuredWorkspaceClient }
        guard let transport = http as? any DirectHermesNativeHTTP else {
            throw DirectHermesManagedFilesError.scopeUnavailable
        }
        let client = DirectHermesArtifactClient(
            http: transport, owner: capturedOwner, agentID: agentID, currentOwner: currentOwner
        )
        configuredWorkspaceClient = client
        return client
    }


    private func json(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        try checkOwner()
        do {
            let value = try await http.request(request)
            try checkOwner()
            return value
        } catch {
            try checkOwner()
            throw error
        }
    }

    private func binaryRequest<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        try checkOwner()
        do {
            let value = try await operation()
            try checkOwner()
            return value
        } catch {
            try checkOwner()
            throw error
        }
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard ownsScope else { throw DirectHermesManagedFilesError.ownerChanged }
    }

    private static func writeReceipt(
        _ object: [String: BighelpJSONValue],
        expectedPath: String,
        directory: Bool,
        scope: DirectHermesWorkspaceFileScope
    ) throws -> HermesManagedFile {
        guard object["ok"]?.boolean == true,
              let returnedPath = object["path"]?.string,
              returnedPath.utf8.elementsEqual(expectedPath.utf8),
              let entry = object["entry"]?.object else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        try scope.validatePolicy(object)
        let file = try scope.managedFile(entry)
        guard DirectHermesWorkspaceFileScope.samePath(file.path, expectedPath),
              file.isDirectory == directory else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        return file
    }

    private static func readContents(
        _ object: [String: BighelpJSONValue],
        expected file: HermesManagedFile,
        scope: DirectHermesWorkspaceFileScope
    ) throws -> HermesManagedFileContents {
        try scope.validatePolicy(object)
        guard let path = object["path"]?.string,
              scope.contains(path),
              DirectHermesWorkspaceFileScope.samePath(path, file.path),
              let name = object["name"]?.string,
              name.utf8.elementsEqual(file.name.utf8),
              let size = object["size"]?.integer,
              size == file.byteCount,
              let mime = object["mime_type"]?.string,
              sameMIME(mime, file.mimeType),
              let dataURL = object["data_url"]?.string,
              dataURL.utf8.count <= ((size + 2) / 3) * 4 + 256,
              let separator = dataURL.range(of: ";base64,"),
              dataURL.hasPrefix("data:"),
              String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<separator.lowerBound]).lowercased() == mime.lowercased(),
              let bytes = Data(base64Encoded: String(dataURL[separator.upperBound...])),
              bytes.count == size else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        return contents(file: file, bytes: bytes)
    }

    private static func contents(file: HermesManagedFile, bytes: Data) -> HermesManagedFileContents {
        .init(file: file, bytes: bytes, sha256: sha256(bytes))
    }

    private nonisolated static func readPrivateUploadSource(
        _ url: URL,
        expectedByteCount: Int
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            guard expectedByteCount > 0, expectedByteCount <= maximumJSONUploadBytes else {
                throw DirectHermesManagedFilesError.fileTooLarge(limit: maximumJSONUploadBytes)
            }
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            let before = try url.resourceValues(forKeys: keys)
            guard before.isRegularFile == true,
                  before.isSymbolicLink != true,
                  before.fileSize == expectedByteCount else {
                throw DirectHermesManagedFilesError.invalidResponse
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var result = Data()
            result.reserveCapacity(expectedByteCount)
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                let next = result.count.addingReportingOverflow(chunk.count)
                guard !next.overflow, next.partialValue <= expectedByteCount else {
                    throw DirectHermesManagedFilesError.fileTooLarge(limit: maximumJSONUploadBytes)
                }
                result.append(chunk)
                try Task.checkCancellation()
            }
            let after = try url.resourceValues(forKeys: keys)
            guard result.count == expectedByteCount,
                  after.isRegularFile == true,
                  after.isSymbolicLink != true,
                  after.fileSize == expectedByteCount else {
                throw DirectHermesManagedFilesError.invalidResponse
            }
            return result
        }.value
    }

    private nonisolated static func makePrivateUploadSource(_ bytes: Data) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let folder = FileManager.default.temporaryDirectory
                .appending(path: "LoopdyManagedFileUploadSources", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            do {
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true,
                    attributes: [
                        .protectionKey: FileProtectionType.completeUnlessOpen,
                        .posixPermissions: 0o700,
                    ]
                )
                var privateFolder = folder
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try privateFolder.setResourceValues(values)
                let file = folder.appending(path: "source", directoryHint: .notDirectory)
                try bytes.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return file
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }.value
    }

    private nonisolated static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func requireTransferable(
        _ file: HermesManagedFile,
        scope: DirectHermesWorkspaceFileScope
    ) throws {
        guard !file.isDirectory, scope.contains(file.path), file.byteCount != nil else {
            throw DirectHermesManagedFilesError.invalidPath
        }
    }

    private static func requireStreamable(
        _ file: HermesManagedFile,
        scope: DirectHermesWorkspaceFileScope
    ) throws {
        try requireTransferable(file, scope: scope)
        let allowed = ["audio/", "video/"]
        guard let type = file.mimeType, allowed.contains(where: type.hasPrefix) else {
            throw DirectHermesManagedFilesError.mediaStreamingOnly
        }
    }


    private static func pathComponent(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= 255,
              value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !value.unicodeScalars.contains(where: { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) }) else {
            throw DirectHermesManagedFilesError.invalidName
        }
        return value
    }

    private static func mimeType(_ value: String) throws -> String {
        let normalized = value.lowercased()
        guard !normalized.isEmpty, normalized.utf8.count <= 120,
              normalized.contains("/"),
              normalized.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || "!#$&^_.+-/".contains($0))
              }) else {
            throw DirectHermesManagedFilesError.invalidResponse
        }
        return normalized
    }

    private static func sameMIME(_ returned: String?, _ expected: String?) -> Bool {
        guard let returned, let expected else { return returned == nil && expected == nil }
        return returned.lowercased() == expected.lowercased()
    }

    private static func sameHTTPMIME(_ returned: String?, _ expected: String?) -> Bool {
        guard let returned, let expected else { return false }
        let base = returned.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return base == expected.lowercased()
    }

}
