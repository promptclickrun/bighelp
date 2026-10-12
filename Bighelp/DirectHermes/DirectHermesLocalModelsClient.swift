import Foundation

// MARK: - Public local-runtime projections

struct HermesLocalModelPlacement: Equatable, Sendable {
    let window: Int?
    let windowLabel: String?
    let isSpilled: Bool?
    let grantedWindow: Int?
    let grantedWindowLabel: String?
}

struct HermesLocalModelLoadProgress: Equatable, Sendable {
    let stage: String
    let value: Double
    let percent: Double
}

struct HermesLocalStagedModel: Identifiable, Equatable, Sendable {
    let id: String
    let sizeBytes: Int
    let sizeLabel: String
}

struct HermesLocalModelsStatus: Equatable, Sendable {
    let isEnabled: Bool
    let runtimeTag: String
    let configuredRuntimeTag: String
    let isRuntimeUpdateAvailable: Bool
    let isRuntimeInstalled: Bool
    let runtimeBackend: String?
    let isServerRunning: Bool
    let serverBaseURL: URL?
    let activeModelID: String?
    let loadedModels: [String: String]
    let loadingModels: [String: HermesLocalModelLoadProgress]
    let placements: [String: HermesLocalModelPlacement]
    let stagedModels: [HermesLocalStagedModel]
    let modelsDirectory: String
}

struct HermesLocalHardware: Equatable, Sendable {
    let usesUnifiedMemory: Bool
    let totalVRAMBytes: Int
    let usableVRAMBytes: Int
    let totalRAMBytes: Int
    let availableRAMBytes: Int
    let vramLabel: String
    let gpuName: String?
    let gpuUtilizationPercent: Int?
    let usedVRAMBytes: Int?
}

struct HermesLocalCatalogModel: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let summary: String
    let sizeBytes: Int
    let sizeLabel: String
    let nativeContext: Int
    let nativeContextLabel: String
    let isRecommended: Bool
    let recommendationReason: String?
    let isDownloaded: Bool
    let downloadedModelID: String?
    let downloadedQuantization: String?
    let supportsMTP: Bool
    let supportsVision: Bool
    let fitsHost: Bool
    let fitSummary: String
    let fitDetail: String?
    let selectedModelID: String?
    let quantization: String?
    let quantizationReason: String?
    let isQuantizationValidated: Bool?
    let variantCount: Int?
    let startWindow: Int?
    let startWindowLabel: String?
    let isSpilled: Bool?
    let needsNewerRuntime: Bool
    let minimumRuntime: String?
}

struct HermesLocalRuntimeJob: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case activate = "model-activate"
        case download = "model-download"
        case quickstart
        case runtimeInstall = "runtime-install"
    }

    enum State: String, Equatable, Sendable {
        case running
        case done
        case error
    }

    let id: String
    let kind: Kind
    let target: String
    let modelID: String?
    let state: State
    let phase: String
    let detail: String
    let totalBytes: Int?
    let completedBytes: Int
    let percent: Double?
    let startedAt: Date?
    let errorSummary: String?
}

struct HermesLocalModelSearchHit: Identifiable, Equatable, Sendable {
    let repository: String
    let downloads: Int
    let likes: Int
    let updated: String
    let isGated: Bool
    var id: String { repository }
}

struct HermesLocalModelFileGroup: Identifiable, Equatable, Sendable {
    enum Fit: String, Equatable, Sendable {
        case fitsGPU = "fits-gpu"
        case needsRAM = "needs-ram"
        case tooBig = "too-big"
        case unknown
    }

    let label: String
    let paths: [String]
    let totalBytes: Int
    let fit: Fit
    var id: String { paths.joined(separator: "\u{1f}") }
}

struct HermesLocalDownloadAdmission: Equatable, Sendable {
    let job: HermesLocalRuntimeJob?
    let modelID: String
    let wasAlreadyDownloaded: Bool
}

struct HermesLocalQuickstartAdmission: Equatable, Sendable {
    let job: HermesLocalRuntimeJob
    let modelID: String
    let displayName: String
    let needsRuntime: Bool
    let needsDownload: Bool
    let downloadBytes: Int
}

enum HermesLocalServerAction: String, CaseIterable, Identifiable, Sendable {
    case start
    case stop
    var id: Self { self }
}

enum HermesLocalModelsError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case ownerChanged
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case reviewChanged
    case outcomeUnknown
    case readbackFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "This Hermes host does not expose managed local models. No \(BighelpPlatform.isMac ? "Mac" : "iPhone")-local substitute was used."
        case .ownerChanged:
            "The selected host or connection changed. Reopen Local Models before continuing."
        case .invalidRequest:
            "Check the selected model or host-local path and try again."
        case .invalidResponse:
            "Hermes returned an unsupported Local Models response. No change was confirmed."
        case .responseTooLarge:
            "The Local Models response exceeded this screen’s safe display limit."
        case .reviewChanged:
            "Host model state changed after review. Review the current download, model, or server state before continuing."
        case .outcomeUnknown:
            "Hermes did not confirm the operation. Refresh jobs and model status before trying again."
        case .readbackFailed:
            "Hermes accepted the operation, but authoritative model state did not confirm it. Refresh before trying again."
        }
    }
}

@MainActor
protocol HermesLocalModelsManaging: AnyObject, Sendable {
    var owner: WorkspaceOwner { get }
    func status() async throws -> HermesLocalModelsStatus
    func hardware() async throws -> HermesLocalHardware
    func catalog() async throws -> [HermesLocalCatalogModel]
    func jobs() async throws -> [HermesLocalRuntimeJob]
    func job(id: String) async throws -> HermesLocalRuntimeJob
    func search(query: String, limit: Int) async throws -> [HermesLocalModelSearchHit]
    func files(repository: String) async throws -> [HermesLocalModelFileGroup]
    func installRuntime(backend: String?) async throws -> HermesLocalRuntimeJob
    func quickstart(modelID: String?) async throws -> HermesLocalQuickstartAdmission
    func download(modelID: String) async throws -> HermesLocalDownloadAdmission
    func download(repository: String, paths: [String]) async throws -> HermesLocalDownloadAdmission
    func sideload(hostPath: String) async throws -> HermesLocalStagedModel
    func activate(modelID: String) async throws -> HermesLocalRuntimeJob
    func eject(modelID: String) async throws -> HermesLocalModelsStatus
    func delete(modelID: String) async throws -> HermesLocalModelsStatus
    func setServer(_ action: HermesLocalServerAction) async throws -> HermesLocalModelsStatus
}

// MARK: - Fixed owner-bound client

/// Fixed, typed access to the public `/api/local-models/*` family. The `rpc`
/// dependency is intentionally retained in the initializer so the parent can
/// construct every Direct control-plane client from the same authenticated
/// connection without opening another transport. These routes themselves are HTTP.
@MainActor
final class DirectHermesLocalModelsClient: HermesLocalModelsManaging {
    let owner: WorkspaceOwner

    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let currentOwner: @MainActor () -> WorkspaceOwner?

    init(
        rpc: any DirectHermesRPC,
        http: any DirectHermesAuthenticatedHTTP,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?
    ) {
        self.rpc = rpc
        self.http = http
        self.owner = owner
        self.currentOwner = currentOwner
    }

    func status() async throws -> HermesLocalModelsStatus {
        let value = try await request(
            .init(path: "/api/local-models/status", method: .get, maximumResponseBytes: 512 * 1_024),
            capabilityProbe: true
        )
        return try LocalModelsPayload.status(value)
    }

    func hardware() async throws -> HermesLocalHardware {
        try LocalModelsPayload.hardware(try await request(
            .init(path: "/api/local-models/hardware", method: .get, maximumResponseBytes: 64 * 1_024)
        ))
    }

    func catalog() async throws -> [HermesLocalCatalogModel] {
        let object = try LocalModelsPayload.object(try await request(
            .init(path: "/api/local-models/catalog", method: .get, maximumResponseBytes: 2 * 1_024 * 1_024)
        ))
        return try LocalModelsPayload.array(object["models"], maximum: 512).map(LocalModelsPayload.catalogModel)
    }

    func jobs() async throws -> [HermesLocalRuntimeJob] {
        let object = try LocalModelsPayload.object(try await request(
            .init(path: "/api/local-models/jobs", method: .get, maximumResponseBytes: 512 * 1_024)
        ))
        return try LocalModelsPayload.array(object["jobs"], maximum: 20).map(LocalModelsPayload.job)
    }

    func job(id: String) async throws -> HermesLocalRuntimeJob {
        let id = try LocalModelsPayload.pathIdentifier(id, maximumBytes: 64)
        let job = try LocalModelsPayload.job(try await request(
            .init(path: "/api/local-models/jobs/\(id)", method: .get, maximumResponseBytes: 64 * 1_024)
        ))
        guard job.id.utf8.elementsEqual(id.utf8) else { throw HermesLocalModelsError.invalidResponse }
        return job
    }

    func search(query: String, limit: Int = 20) async throws -> [HermesLocalModelSearchHit] {
        let query = try LocalModelsPayload.userText(query, maximumBytes: 512)
        guard (1...50).contains(limit) else { throw HermesLocalModelsError.invalidRequest }
        if query.isEmpty { return [] }
        let object = try LocalModelsPayload.object(try await request(.init(
            path: "/api/local-models/search", method: .get,
            query: [.init(name: "q", value: query), .init(name: "limit", value: String(limit))],
            maximumResponseBytes: 512 * 1_024
        )))
        return try LocalModelsPayload.array(object["hits"], maximum: limit).map(LocalModelsPayload.searchHit)
    }

    func files(repository: String) async throws -> [HermesLocalModelFileGroup] {
        let repository = try LocalModelsPayload.repository(repository)
        let object = try LocalModelsPayload.object(try await request(.init(
            path: "/api/local-models/search/files", method: .get,
            query: [.init(name: "repo", value: repository)], maximumResponseBytes: 512 * 1_024
        )))
        return try LocalModelsPayload.array(object["files"], maximum: 256).map(LocalModelsPayload.fileGroup)
    }

    func installRuntime(backend: String? = nil) async throws -> HermesLocalRuntimeJob {
        let backend = try backend.map { try LocalModelsPayload.pathIdentifier($0, maximumBytes: 80) }
        let object = try await mutationObject(.init(
            path: "/api/local-models/runtime/install", method: .post,
            body: ["backend": backend.map(BighelpJSONValue.string) ?? .null], maximumResponseBytes: 32 * 1_024
        ))
        let jobID = try LocalModelsPayload.text(object["job_id"], maximumBytes: 64)
        if let returnedBackend = try LocalModelsPayload.optionalText(object["backend"], maximumBytes: 80),
           let backend, returnedBackend != backend {
            throw HermesLocalModelsError.outcomeUnknown
        }
        return try await job(id: jobID)
    }

    func quickstart(modelID: String? = nil) async throws -> HermesLocalQuickstartAdmission {
        let modelID = try modelID.map(LocalModelsPayload.modelIdentifier)
        let object = try await mutationObject(.init(
            path: "/api/local-models/quickstart", method: .post,
            body: ["model_id": modelID.map(BighelpJSONValue.string) ?? .null], maximumResponseBytes: 32 * 1_024
        ))
        let jobID = try LocalModelsPayload.text(object["job_id"], maximumBytes: 64)
        let returnedModelID = try LocalModelsPayload.text(object["model_id"], maximumBytes: 512)
        let job = try await job(id: jobID)
        guard job.kind == .quickstart else { throw HermesLocalModelsError.readbackFailed }
        return .init(
            job: job,
            modelID: returnedModelID,
            displayName: try LocalModelsPayload.text(object["display_name"], maximumBytes: 512),
            needsRuntime: try LocalModelsPayload.boolean(object["needs_runtime"]),
            needsDownload: try LocalModelsPayload.boolean(object["needs_download"]),
            downloadBytes: try LocalModelsPayload.integer(object["download_bytes"], range: 0...Int.max)
        )
    }

    func download(modelID: String) async throws -> HermesLocalDownloadAdmission {
        let modelID = try LocalModelsPayload.modelIdentifier(modelID)
        let object = try await mutationObject(.init(
            path: "/api/local-models/download", method: .post,
            body: ["model_id": .string(modelID)], maximumResponseBytes: 32 * 1_024
        ))
        return try await downloadAdmission(object)
    }

    func download(repository: String, paths: [String]) async throws -> HermesLocalDownloadAdmission {
        let repository = try LocalModelsPayload.repository(repository)
        let paths = try LocalModelsPayload.ggufPaths(paths)
        let object = try await mutationObject(.init(
            path: "/api/local-models/download-browsed", method: .post,
            body: ["repo": .string(repository), "paths": .array(paths.map(BighelpJSONValue.string))],
            maximumResponseBytes: 32 * 1_024
        ))
        return try await downloadAdmission(object)
    }

    func sideload(hostPath: String) async throws -> HermesLocalStagedModel {
        let path = try LocalModelsPayload.hostGGUFPath(hostPath)
        let object = try await mutationObject(.init(
            path: "/api/local-models/sideload", method: .post,
            body: ["path": .string(path)], maximumResponseBytes: 32 * 1_024
        ))
        guard object["ok"]?.boolean == true else { throw HermesLocalModelsError.outcomeUnknown }
        let modelID = try LocalModelsPayload.text(object["model_id"], maximumBytes: 512)
        let canonicalID = LocalModelsPayload.canonicalSideloadID(modelID)
        let readback = try await status()
        guard let row = readback.stagedModels.first(where: { $0.id == modelID || $0.id == canonicalID }) else {
            throw HermesLocalModelsError.readbackFailed
        }
        return row
    }

    func activate(modelID: String) async throws -> HermesLocalRuntimeJob {
        let modelID = try LocalModelsPayload.modelIdentifier(modelID)
        let object = try await mutationObject(.init(
            path: "/api/local-models/activate", method: .post,
            body: ["model_id": .string(modelID)], maximumResponseBytes: 32 * 1_024
        ))
        let launched = try await job(id: LocalModelsPayload.text(object["job_id"], maximumBytes: 64))
        guard launched.kind == .activate, launched.modelID == modelID else {
            throw HermesLocalModelsError.readbackFailed
        }
        return launched
    }

    func eject(modelID: String) async throws -> HermesLocalModelsStatus {
        let modelID = try LocalModelsPayload.modelIdentifier(modelID)
        let object = try await mutationObject(.init(
            path: "/api/local-models/eject", method: .post,
            body: ["model_id": .string(modelID)], maximumResponseBytes: 16 * 1_024
        ))
        guard object["ok"]?.boolean == true else { throw HermesLocalModelsError.outcomeUnknown }
        let readback = try await status()
        guard readback.loadedModels[modelID] == nil, readback.loadingModels[modelID] == nil else {
            throw HermesLocalModelsError.readbackFailed
        }
        return readback
    }

    func delete(modelID: String) async throws -> HermesLocalModelsStatus {
        let modelID = try LocalModelsPayload.modelIdentifier(modelID)
        let object = try await mutationObject(.init(
            path: "/api/local-models/models/\(LocalModelsPayload.pathIdentifier(modelID, maximumBytes: 512))",
            method: .delete, maximumResponseBytes: 16 * 1_024
        ))
        guard object["ok"]?.boolean == true else { throw HermesLocalModelsError.outcomeUnknown }
        let readback = try await status()
        guard readback.stagedModels.allSatisfy({ $0.id != modelID }),
              readback.loadedModels[modelID] == nil else {
            throw HermesLocalModelsError.readbackFailed
        }
        return readback
    }

    func setServer(_ action: HermesLocalServerAction) async throws -> HermesLocalModelsStatus {
        let object = try await mutationObject(.init(
            path: "/api/local-models/server", method: .post,
            body: ["action": .string(action.rawValue)], maximumResponseBytes: 16 * 1_024
        ))
        guard object["ok"]?.boolean == true, object["action"]?.string == action.rawValue else {
            throw HermesLocalModelsError.outcomeUnknown
        }
        let readback = try await status()
        guard readback.isServerRunning == (action == .start),
              action != .stop || !readback.isEnabled else {
            throw HermesLocalModelsError.readbackFailed
        }
        return readback
    }

    private func downloadAdmission(
        _ object: [String: BighelpJSONValue]
    ) async throws -> HermesLocalDownloadAdmission {
        let modelID = try LocalModelsPayload.text(object["model_id"], maximumBytes: 512)
        let already = object["already_downloaded"]?.boolean == true
        let jobID = try LocalModelsPayload.optionalText(object["job_id"], maximumBytes: 64)
        if already {
            guard jobID == nil,
                  try await status().stagedModels.contains(where: { $0.id == modelID }) else {
                throw HermesLocalModelsError.readbackFailed
            }
            return .init(job: nil, modelID: modelID, wasAlreadyDownloaded: true)
        }
        guard let jobID else { throw HermesLocalModelsError.outcomeUnknown }
        let job = try await job(id: jobID)
        guard job.kind == .download else { throw HermesLocalModelsError.readbackFailed }
        return .init(job: job, modelID: modelID, wasAlreadyDownloaded: false)
    }

    private func mutationObject(_ requestValue: DirectHermesHTTPRequest) async throws -> [String: BighelpJSONValue] {
        do {
            return try LocalModelsPayload.object(try await request(requestValue))
        } catch WorkspaceClientError.outcomeUnknown {
            throw HermesLocalModelsError.outcomeUnknown
        } catch let error as DirectHermesError where error.outcomeIsUnknown {
            throw HermesLocalModelsError.outcomeUnknown
        }
    }

    private func request(
        _ requestValue: DirectHermesHTTPRequest,
        capabilityProbe: Bool = false
    ) async throws -> BighelpJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: requireOwner, mapError: { error in
            switch error {
            case DirectHermesError.unsupportedAuthentication:
                return capabilityProbe ? HermesLocalModelsError.unavailable : HermesLocalModelsError.invalidRequest
            case DirectHermesError.rpcRejected(let code, _) where capabilityProbe && (code == -32601 || code == 404):
                return HermesLocalModelsError.unavailable
            case DirectHermesError.messageTooLarge:
                return HermesLocalModelsError.responseTooLarge
            default:
                return error
            }
        }) {
            try await http.request(requestValue)
        }
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard owner.authority.kind == .direct, currentOwner() == owner else {
            throw HermesLocalModelsError.ownerChanged
        }
    }
}

// MARK: - Bounded decoding and input validation

private enum LocalModelsPayload: DirectHermesPayloadDecoding {
    static var invalidResponse: any Error { HermesLocalModelsError.invalidResponse }
    static var arrayOverflow: any Error { HermesLocalModelsError.responseTooLarge }
    static let requiresNonemptyText = true

    static func pathIdentifier(_ value: String, maximumBytes: Int) throws -> String {
        guard !value.isEmpty, value.utf8.count <= maximumBytes, value != ".", value != "..",
              value.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                      || $0 == 45 || $0 == 46 || $0 == 95
              }) else { throw HermesLocalModelsError.invalidRequest }
        return value
    }

    static func modelIdentifier(_ value: String) throws -> String {
        try pathIdentifier(value, maximumBytes: 512)
    }

    static func canonicalSideloadID(_ value: String) -> String {
        value.replacingOccurrences(
            of: "-[0-9]{5}-of-[0-9]{5}$",
            with: "",
            options: .regularExpression
        )
    }

    static func userText(_ value: String, maximumBytes: Int) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HermesLocalModelsError.invalidRequest
        }
        return value
    }

    static func repository(_ value: String) throws -> String {
        let value = try userText(value, maximumBytes: 256)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.count <= 128 && part.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 46 || $0 == 95
            }
        }) else { throw HermesLocalModelsError.invalidRequest }
        return value
    }

    static func ggufPaths(_ values: [String]) throws -> [String] {
        guard !values.isEmpty, values.count <= 32 else { throw HermesLocalModelsError.invalidRequest }
        var seen = Set<Data>()
        return try values.map { value in
            guard !value.isEmpty, value.utf8.count <= 1_024,
                  value.lowercased().hasSuffix(".gguf"), !value.hasPrefix("/"),
                  !value.contains("\\"), !value.contains("//"),
                  !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  seen.insert(Data(value.utf8)).inserted else {
                throw HermesLocalModelsError.invalidRequest
            }
            return value
        }
    }

    static func hostGGUFPath(_ value: String) throws -> String {
        let windowsAbsolute = value.range(
            of: "^[A-Za-z]:[\\\\/]",
            options: .regularExpression
        ) != nil
        let isAbsolute = value.hasPrefix("/") || value.hasPrefix("\\\\") || windowsAbsolute
        guard !value.isEmpty, value.utf8.count <= 4_096,
              isAbsolute,
              value.lowercased().hasSuffix(".gguf"),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw HermesLocalModelsError.invalidRequest
        }
        return value
    }

    static func status(_ value: BighelpJSONValue) throws -> HermesLocalModelsStatus {
        let row = try object(value)
        let loaded = try stringMap(row["loaded_models"], maximum: 256, valueBytes: 80)
        let loadingObject = try optionalObject(row["loading"], maximum: 256)
        let loading = try loadingObject.mapValues { value in
            let item = try object(value)
            return HermesLocalModelLoadProgress(
                stage: try text(item["stage"], maximumBytes: 128),
                value: try number(item["value"], range: 0...Double.greatestFiniteMagnitude),
                percent: try number(item["percent"], range: 0...100)
            )
        }
        let placementObject = try optionalObject(row["placement"], maximum: 256)
        let placements = try placementObject.mapValues { value in
            let item = try object(value)
            return HermesLocalModelPlacement(
                window: try optionalInteger(item["window"], range: 0...Int.max),
                windowLabel: try optionalText(item["window_label"], maximumBytes: 80),
                isSpilled: try optionalBoolean(item["spilled"]),
                grantedWindow: try optionalInteger(item["granted_window"], range: 0...Int.max),
                grantedWindowLabel: try optionalText(item["granted_window_label"], maximumBytes: 80)
            )
        }
        let serverURL: URL?
        if let raw = try optionalText(row["server_base_url"], maximumBytes: 4_096) {
            guard let parts = URLComponents(string: raw),
                  ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
                  parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
                  let url = parts.url else { throw HermesLocalModelsError.invalidResponse }
            serverURL = url
        } else { serverURL = nil }
        return .init(
            isEnabled: try boolean(row["enabled"]),
            runtimeTag: try text(row["tag"], maximumBytes: 128),
            configuredRuntimeTag: try text(row["configured_tag"], maximumBytes: 128),
            isRuntimeUpdateAvailable: try boolean(row["update_available"]),
            isRuntimeInstalled: try boolean(row["runtime_installed"]),
            runtimeBackend: try optionalText(row["runtime_backend"], maximumBytes: 80),
            isServerRunning: try boolean(row["server_running"]),
            serverBaseURL: serverURL,
            activeModelID: try optionalText(row["active_model_id"], maximumBytes: 512),
            loadedModels: loaded,
            loadingModels: loading,
            placements: placements,
            stagedModels: try array(row["models"], maximum: 512).map(stagedModel),
            modelsDirectory: try text(row["models_dir"], maximumBytes: 4_096)
        )
    }

    static func hardware(_ value: BighelpJSONValue) throws -> HermesLocalHardware {
        let row = try object(value)
        return .init(
            usesUnifiedMemory: try boolean(row["uma"]),
            totalVRAMBytes: try integer(row["vram_total_bytes"], range: 0...Int.max),
            usableVRAMBytes: try integer(row["vram_usable_bytes"], range: 0...Int.max),
            totalRAMBytes: try integer(row["ram_total_bytes"], range: 0...Int.max),
            availableRAMBytes: try integer(row["ram_available_bytes"], range: 0...Int.max),
            vramLabel: try text(row["vram_label"], maximumBytes: 80),
            gpuName: try optionalText(row["gpu_name"], maximumBytes: 512),
            gpuUtilizationPercent: try optionalInteger(row["gpu_util_percent"], range: 0...100),
            usedVRAMBytes: try optionalInteger(row["vram_used_bytes"], range: 0...Int.max)
        )
    }

    static func stagedModel(_ value: BighelpJSONValue) throws -> HermesLocalStagedModel {
        let row = try object(value)
        return .init(
            id: try text(row["id"], maximumBytes: 512),
            sizeBytes: try integer(row["size_bytes"], range: 0...Int.max),
            sizeLabel: try text(row["size_label"], maximumBytes: 80)
        )
    }

    static func catalogModel(_ value: BighelpJSONValue) throws -> HermesLocalCatalogModel {
        let row = try object(value)
        return .init(
            id: try text(row["id"], maximumBytes: 512),
            displayName: try text(row["display_name"], maximumBytes: 512),
            summary: try text(row["description"], maximumBytes: 8_192, required: false),
            sizeBytes: try integer(row["size_bytes"], range: 0...Int.max),
            sizeLabel: try text(row["size_label"], maximumBytes: 80),
            nativeContext: try integer(row["native_context"], range: 0...Int.max),
            nativeContextLabel: try text(row["native_context_label"], maximumBytes: 80),
            isRecommended: try boolean(row["recommended"]),
            recommendationReason: try optionalText(row["recommended_reason"], maximumBytes: 1_024),
            isDownloaded: try boolean(row["downloaded"]),
            downloadedModelID: try optionalText(row["downloaded_model_id"], maximumBytes: 512),
            downloadedQuantization: try optionalText(row["downloaded_quant"], maximumBytes: 128),
            supportsMTP: try boolean(row["mtp"]),
            supportsVision: try optionalBoolean(row["vision"]) ?? false,
            fitsHost: try boolean(row["fits"]),
            fitSummary: try text(row["fit_summary"], maximumBytes: 2_048),
            fitDetail: try optionalText(row["fit_detail"], maximumBytes: 2_048),
            selectedModelID: try optionalText(row["model_id"], maximumBytes: 512),
            quantization: try optionalText(row["quant"], maximumBytes: 128),
            quantizationReason: try optionalText(row["quant_reason"], maximumBytes: 2_048),
            isQuantizationValidated: try optionalBoolean(row["quant_validated"]),
            variantCount: try optionalInteger(row["variant_count"], range: 0...10_000),
            startWindow: try optionalInteger(row["start_window"], range: 0...Int.max),
            startWindowLabel: try optionalText(row["start_window_label"], maximumBytes: 80),
            isSpilled: try optionalBoolean(row["spilled"]),
            needsNewerRuntime: try optionalBoolean(row["needs_engine"]) ?? false,
            minimumRuntime: try optionalText(row["min_engine"], maximumBytes: 128)
        )
    }

    static func job(_ value: BighelpJSONValue) throws -> HermesLocalRuntimeJob {
        let row = try object(value)
        guard let kind = HermesLocalRuntimeJob.Kind(rawValue: try text(row["kind"], maximumBytes: 80)),
              let state = HermesLocalRuntimeJob.State(rawValue: try text(row["status"], maximumBytes: 32)) else {
            throw HermesLocalModelsError.invalidResponse
        }
        let started = try optionalNumber(row["started_at"], range: 0...Double.greatestFiniteMagnitude)
        return .init(
            id: try pathIdentifier(try text(row["job_id"], maximumBytes: 64), maximumBytes: 64),
            kind: kind,
            target: try text(row["target"], maximumBytes: 1_024),
            modelID: try optionalText(row["model_id"], maximumBytes: 512),
            state: state,
            phase: try text(row["phase"], maximumBytes: 256),
            detail: try text(row["detail"], maximumBytes: 4_096, required: false),
            totalBytes: try optionalInteger(row["total_bytes"], range: 0...Int.max),
            completedBytes: try integer(row["done_bytes"], range: 0...Int.max),
            percent: try optionalNumber(row["percent"], range: 0...100),
            startedAt: started.map { Date(timeIntervalSince1970: $0) },
            errorSummary: try optionalText(row["error"], maximumBytes: 4_096)
        )
    }

    static func searchHit(_ value: BighelpJSONValue) throws -> HermesLocalModelSearchHit {
        let row = try object(value)
        return .init(
            repository: try repository(try text(row["repo"], maximumBytes: 256)),
            downloads: try integer(row["downloads"], range: 0...Int.max),
            likes: try integer(row["likes"], range: 0...Int.max),
            updated: try text(row["updated"], maximumBytes: 128),
            isGated: try boolean(row["gated"])
        )
    }

    static func fileGroup(_ value: BighelpJSONValue) throws -> HermesLocalModelFileGroup {
        let row = try object(value)
        let paths = try array(row["paths"], maximum: 32).map {
            try text($0, maximumBytes: 1_024)
        }
        let safePaths = try ggufPaths(paths)
        guard let fit = HermesLocalModelFileGroup.Fit(rawValue: try text(row["fit"], maximumBytes: 32)) else {
            throw HermesLocalModelsError.invalidResponse
        }
        return .init(
            label: try text(row["label"], maximumBytes: 512),
            paths: safePaths,
            totalBytes: try integer(row["total_bytes"], range: 0...Int.max),
            fit: fit
        )
    }

    private static func optionalBoolean(_ value: BighelpJSONValue?) throws -> Bool? {
        guard let value, value != .null else { return nil }
        return try boolean(value)
    }

    private static func optionalObject(
        _ value: BighelpJSONValue?, maximum: Int
    ) throws -> [String: BighelpJSONValue] {
        guard let value, value != .null else { return [:] }
        let object = try object(value)
        guard object.count <= maximum,
              object.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.contains("\0") }) else {
            throw HermesLocalModelsError.responseTooLarge
        }
        return object
    }

    private static func stringMap(
        _ value: BighelpJSONValue?, maximum: Int, valueBytes: Int
    ) throws -> [String: String] {
        let object = try optionalObject(value, maximum: maximum)
        var result: [String: String] = [:]
        for (key, value) in object {
            result[key] = try text(value, maximumBytes: valueBytes)
        }
        return result
    }
}
