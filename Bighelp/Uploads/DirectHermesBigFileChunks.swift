import Foundation

/// One piece of a big file, as the plugin's `uploads/chunk` takes it: the raw
/// bytes as the body, the upload and offset in headers, and the same sign-in,
/// access headers and context guard as every native route. The request is built
/// whole so a background session, which runs outside this process, can send it.
struct DirectHermesBigFileChunk: Equatable, Sendable {
    static let route = "/api/plugins/loopdy/native/uploads/chunk"

    let uploadID: String
    let offset: Int
    let length: Int
    /// The piece's SHA-256, lowercase hex. The host refuses a piece that doesn't match.
    let sha256: String

    init(uploadID: String, offset: Int, length: Int, sha256: String) throws {
        guard BigFileUploadReceipt.isUploadID(uploadID),
              (0..<BigFileUploads.maximumBytes).contains(offset),
              (1...BigFileUploads.maximumChunkBytes).contains(length),
              sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw WorkspaceClientError.invalidRequest
        }
        self.uploadID = uploadID
        self.offset = offset
        self.length = length
        self.sha256 = sha256
    }
}

extension DirectHermesHTTP {
    func bigFileChunkRequest(_ chunk: DirectHermesBigFileChunk, bearer: String?, legacyToken: String?,
                             nativeGuard: DirectHermesNativeRequestGuard) throws -> URLRequest {
        guard (bearer != nil) != (legacyToken != nil) else { throw DirectHermesError.unsupportedAuthentication }
        var request = URLRequest(url: try endpoint.url(for: DirectHermesBigFileChunk.route),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        // A background session has none of this session's own headers.
        applyAccessHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(nativeGuard.etag, forHTTPHeaderField: "If-Match")
        request.setValue(nativeGuard.requestIDHeader, forHTTPHeaderField: "X-Loopdy-Request-ID")
        request.setValue(chunk.uploadID, forHTTPHeaderField: "X-Loopdy-Upload-ID")
        request.setValue(String(chunk.offset), forHTTPHeaderField: "X-Loopdy-Upload-Offset")
        request.setValue(chunk.sha256, forHTTPHeaderField: "X-Loopdy-Chunk-SHA256")
        if let bearer {
            try DirectHermesSecretValidation.validate(bearer)
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        if let legacyToken {
            try DirectHermesSecretValidation.validate(legacyToken)
            request.setValue(legacyToken, forHTTPHeaderField: "X-Hermes-Session-Token")
        }
        return request
    }
}

/// Sends one prepared piece from a file on disk and gives back the host's answer.
protocol BigFileChunkSending: AnyObject, Sendable {
    func send(_ request: URLRequest, fromFile file: URL,
              onSent: @escaping @Sendable (Int64) -> Void) async throws -> (Data, HTTPURLResponse)
}

/// The selected computer's connection, as a big file's upload sees it. Each call
/// reads the connection that is current now, so a reconnect mid-upload just
/// carries on with the new one.
@MainActor
final class DirectHermesBigFileUploadHost: BigFileUploadHost {
    struct Connection {
        let workspace: DirectHermesWorkspaceClient
        let client: DirectHermesClient
        let owner: WorkspaceOwner
    }

    private let current: @MainActor () -> Connection?

    init(current: @escaping @MainActor () -> Connection?) { self.current = current }

    private func connection() throws -> Connection {
        guard let connection = current() else { throw DirectHermesError.notConnected }
        return connection
    }

    func supportsBigFiles() async -> Bool {
        guard let connection = try? connection() else { return false }
        if let context = connection.workspace.nativeContext {
            return context.features.contains(BigFileUploads.feature)
        }
        guard let value = try? await connection.workspace.perform(.nativeContext, payload: [:], owner: connection.owner),
              let features = value["features"]?.array else { return false }
        return features.contains(.string(BigFileUploads.feature))
    }

    func perform(_ operation: WorkspaceOperation,
                 payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        let connection = try connection()
        return try await connection.workspace.perform(operation, payload: payload, owner: connection.owner)
    }

    func chunkRequest(_ chunk: DirectHermesBigFileChunk) async throws -> URLRequest {
        let connection = try connection()
        if connection.workspace.nativeContext == nil { try await reloadContext() }
        guard let etag = connection.workspace.nativeContext?.etag else { throw WorkspaceClientError.invalidResponse }
        return try await connection.client.bigFileChunkRequest(chunk, nativeGuard: .init(etag: etag))
    }

    func reloadContext() async throws {
        let connection = try connection()
        _ = try await connection.workspace.perform(.nativeContext, payload: [:], owner: connection.owner)
    }
}
