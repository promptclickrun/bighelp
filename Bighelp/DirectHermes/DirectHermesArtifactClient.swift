import Foundation

/// Authenticated adapter for the bighelp plugin's configured-workspace routes.
/// It preserves the public `.filesList` / `.filesRead` vocabulary but never
/// forwards artifact operations through stock Hermes or an arbitrary agent.
@MainActor
final class DirectHermesArtifactClient: WorkspaceOperationPerforming {
    private static let feature = "native-workspace-files-v1"
    private static let recentFeature = "native-workspace-recent-v1"
    /// Plugins that find hosted Hermes' workspace folder (the agent works in Hermes' home).
    private static let hermesHomeFeature = "native-workspace-hermes-home-v1"
    /// Refusals an older or not yet restarted plugin gives on hosted Hermes.
    private static let hermesHomeRefusals: Set<String> = ["workspace_not_configured", "workspace_hermes_folder"]
    private let http: any DirectHermesNativeHTTP
    private let capturedOwner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private let fallback: (any WorkspaceOperationPerforming)?
    private lazy var native = DirectHermesNativePluginClient(
        http: http, owner: capturedOwner, currentOwner: currentOwner
    )

    init(
        http: any DirectHermesNativeHTTP,
        owner: WorkspaceOwner,
        fallback: (any WorkspaceOperationPerforming)? = nil,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.http = http
        capturedOwner = owner
        self.fallback = fallback
        self.currentOwner = currentOwner
    }

    var owner: WorkspaceOwner? {
        guard currentOwner() == capturedOwner,
              fallback == nil || fallback?.owner == capturedOwner else { return nil }
        return capturedOwner
    }

    var capabilities: WorkspaceCapabilities {
        fallback?.capabilities ?? .disconnected
    }

    func perform(
        _ operation: WorkspaceOperation,
        payload: [String: BighelpJSONValue],
        owner expectedOwner: WorkspaceOwner
    ) async throws -> [String: BighelpJSONValue] {
        try check(expectedOwner)
        switch operation {
        case .filesList:
            guard payload.count == 1, let path = payload["path"]?.string else {
                throw WorkspaceClientError.invalidRequest
            }
            return try await list(path: path, owner: expectedOwner)
        case .filesRead:
            guard payload.count == 1, let path = payload["path"]?.string else {
                throw WorkspaceClientError.invalidRequest
            }
            return try await read(path: path, owner: expectedOwner)
        case .filesRecent:
            guard payload.isEmpty else { throw WorkspaceClientError.invalidRequest }
            return try await request("recent", path: nil, maximumResponseBytes: 196_608, owner: expectedOwner,
                                     feature: Self.recentFeature)
        default:
            // The optional source is retained only for owner/capability identity.
            // Artifact transport never delegates to it.
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
    }

    /// A nil path is valid only for workspace discovery and always resolves to
    /// the raw serving profile's configured terminal.cwd on the host.
    func scope(owner expectedOwner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        try await request("scope", path: nil, maximumResponseBytes: 196_608, owner: expectedOwner)
    }

    func list(path: String?, owner expectedOwner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        try await request("list", path: path, maximumResponseBytes: 196_608, owner: expectedOwner)
    }

    func read(path: String, owner expectedOwner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        try await request(
            "read", path: path,
            maximumResponseBytes: DirectHermesHTTP.maximumMediaResponseBytes,
            owner: expectedOwner
        )
    }

    private func request(
        _ operation: String,
        path: String?,
        maximumResponseBytes: Int,
        owner expectedOwner: WorkspaceOwner,
        feature: String = DirectHermesArtifactClient.feature
    ) async throws -> [String: BighelpJSONValue] {
        try check(expectedOwner)
        if let path {
            guard (try? DirectHermesWorkspaceFileScope.path(path)) != nil else {
                throw WorkspaceClientError.invalidRequest
            }
        }
        let context = try await native.loadContext()
        try check(expectedOwner)
        guard context.owner == capturedOwner, context.features.contains(Self.feature),
              context.features.contains(feature) else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        let guardValue = try DirectHermesNativeRequestGuard(etag: context.etag)
        let response: DirectHermesHTTP.Response
        do {
            response = try await http.nativeResponse(
                .init(
                    path: "/api/plugins/loopdy/native/workspace-files/" + operation,
                    method: .post,
                    body: ["path": path.map(BighelpJSONValue.string) ?? .null],
                    maximumResponseBytes: maximumResponseBytes
                ),
                requestGuard: guardValue
            )
            try check(expectedOwner)
        } catch {
            try check(expectedOwner)
            throw error
        }
        guard (200...299).contains(response.http.statusCode) else {
            if [401, 403, 412, 428].contains(response.http.statusCode) {
                _ = try? await native.loadContext(force: true)
            }
            let error = responseError(response)
            // Without the feature the plugin can't find hosted Hermes' workspace
            // folder, so its "set terminal.cwd" reason is the wrong fix.
            if case .rejected(let code?) = error, Self.hermesHomeRefusals.contains(code),
               !context.features.contains(Self.hermesHomeFeature) {
                throw WorkspaceClientError.rejected(code: WorkspaceClientError.workspacePluginOutdated)
            }
            throw error
        }
        guard response.http.value(forHTTPHeaderField: "X-Loopdy-Request-ID") == guardValue.requestIDHeader,
              DirectHermesNativeRequestGuard.contextTag(response.http.value(forHTTPHeaderField: "ETag")) == guardValue.etag,
              response.http.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") == true else {
            throw WorkspaceClientError.invalidResponse
        }
        let object = try response.object()
        guard let workspace = object["workspace"]?.object,
              workspace["source"]?.string == "terminal.cwd",
              let root = workspace["root"]?.string,
              (try? DirectHermesWorkspaceFileScope.path(root)) != nil,
              let profile = workspace["profileId"]?.string,
              profile == context.servingProfileID else {
            throw WorkspaceClientError.invalidResponse
        }
        try check(expectedOwner)
        return object
    }

    private func check(_ expectedOwner: WorkspaceOwner) throws {
        try Task.checkCancellation()
        guard expectedOwner == capturedOwner, owner == capturedOwner,
              capturedOwner.authority.kind == .direct else {
            throw WorkspaceClientError.ownerChanged
        }
    }

    private func responseError(_ response: DirectHermesHTTP.Response) -> WorkspaceClientError {
        // The plugin names why it can't share workspace files; keep that over the status.
        if let code = (try? response.object())?["error"]?.object?["code"]?.string,
           WorkspaceClientError.workspaceFilesMessage(code) != nil {
            return .rejected(code: code)
        }
        switch response.http.statusCode {
        case 401, 403: return .authenticationRequired
        case 409, 412: return .conflict
        case 413: return .capacityExceeded
        case 428, 501: return .unavailable(.unsupportedOperation)
        case 500...599: return .transportUnavailable
        default: break
        }
        if let code = (try? response.object())?["error"]?.object?["code"]?.string,
           !code.isEmpty, code.utf8.count <= 128 {
            return .rejected(code: code)
        }
        return response.http.statusCode == 404
            ? .unavailable(.pluginRequired) : .invalidResponse
    }
}
