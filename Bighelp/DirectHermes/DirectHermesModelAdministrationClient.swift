import Foundation

struct DirectHermesModelProvider: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let models: [String]
    let unavailableModels: Set<String>
    let isCurrent: Bool
    let isCustom: Bool
    let isAuthenticated: Bool?
    let authType: String?
    let isFreeTier: Bool?
}

struct DirectHermesModelCapabilities: Equatable, Sendable {
    let supportsTools: Bool?
    let supportsVision: Bool?
    let supportsReasoning: Bool?
    let contextWindow: Int?
    let maximumOutputTokens: Int?
    let family: String?
}

struct DirectHermesModelInfo: Equatable, Sendable {
    let providerID: String
    let modelID: String
    let automaticContextLength: Int
    let configuredContextLength: Int
    let effectiveContextLength: Int
    let capabilities: DirectHermesModelCapabilities
}

struct DirectHermesRecommendedModel: Equatable, Sendable {
    let providerID: String
    let modelID: String
    let isFreeTier: Bool?
}

struct DirectHermesAuxiliaryModelAssignment: Identifiable, Equatable, Sendable {
    let task: String
    let providerID: String
    let modelID: String
    let baseURL: String
    let isLocalEndpoint: Bool
    var id: String { task }
}

struct DirectHermesAuxiliaryModels: Equatable, Sendable {
    let mainProviderID: String
    let mainModelID: String
    let tasks: [DirectHermesAuxiliaryModelAssignment]
}

struct DirectHermesMoAModelSlot: Equatable, Sendable {
    var providerID: String
    var modelID: String
    var reasoningEffort: String?
    var isEnabled: Bool
}

struct DirectHermesMoAPreset: Identifiable, Equatable, Sendable {
    let name: String
    var referenceModels: [DirectHermesMoAModelSlot]
    var aggregator: DirectHermesMoAModelSlot
    var referenceTemperature: Double?
    var aggregatorTemperature: Double?
    var referenceTimeout: Double?
    var degradedReferencePolicy: String
    var fanout: String?
    var isEnabled: Bool
    var id: String { name }
}

struct DirectHermesMoAConfiguration: Equatable, Sendable {
    var defaultPreset: String
    var activePreset: String
    var presets: [DirectHermesMoAPreset]
    /// Read-only with the pinned API. `MoaConfigPayload` cannot carry this
    /// field, so a non-empty value blocks a full-document save.
    let privacyFilter: String
}

struct DirectHermesModelAnalytics: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let providerID: String
        let modelID: String
        let inputTokens: Int
        let outputTokens: Int
        let cachedTokens: Int
        let reasoningTokens: Int
        let estimatedCost: Double
        let actualCost: Double
        let sessions: Int
        let apiCalls: Int
        let toolCalls: Int
        let lastUsedAt: Date?
        let averageTokensPerSession: Double
        let capabilities: DirectHermesModelCapabilities
        var id: String { "\(providerID.utf8.count):\(providerID)\(modelID)" }
    }

    struct Totals: Equatable, Sendable {
        let distinctModels: Int
        let inputTokens: Int
        let outputTokens: Int
        let cachedTokens: Int
        let reasoningTokens: Int
        let estimatedCost: Double
        let actualCost: Double
        let sessions: Int
        let apiCalls: Int
    }

    let periodDays: Int
    let rows: [Row]
    let totals: Totals
}

enum DirectHermesModelAssignmentScope: Equatable, Sendable {
    case main
    case auxiliary(task: String)
    /// One helper task back on the chat model (Hermes' `auto`).
    case automaticAuxiliary(task: String)
    case resetAuxiliary
}

struct DirectHermesModelAssignmentRequest: Equatable, Sendable {
    let scope: DirectHermesModelAssignmentScope
    let providerID: String
    let modelID: String
    let reasoningEffort: String?
    let confirmExpensiveModel: Bool

    func confirmingExpensiveModel() -> Self {
        .init(
            scope: scope, providerID: providerID, modelID: modelID,
            reasoningEffort: reasoningEffort, confirmExpensiveModel: true
        )
    }
}

struct DirectHermesModelAssignmentConfirmation: Identifiable, Equatable, Sendable {
    let id: UUID
    let request: DirectHermesModelAssignmentRequest
    let message: String
}

enum DirectHermesModelAssignmentOutcome: Equatable, Sendable {
    case applied
    case confirmationRequired(DirectHermesModelAssignmentConfirmation)
}

struct DirectHermesModelAdministrationSnapshot: Equatable, Sendable {
    let providers: [DirectHermesModelProvider]
    let info: DirectHermesModelInfo
    let recommendation: DirectHermesRecommendedModel?
    // Extras load on their own: one the host can't answer is left out, not fatal.
    let auxiliary: DirectHermesAuxiliaryModels?
    let moa: DirectHermesMoAConfiguration?
    let analytics: DirectHermesModelAnalytics?
    let runtime: DirectHermesRuntimeStatus?
    var skippedParts: [String] = []
}

@MainActor
final class DirectHermesModelAdministrationClient {
    private let rpc: any DirectHermesRPC
    private let http: any DirectHermesAuthenticatedHTTP
    private let owner: WorkspaceOwner
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

    var ownsScope: Bool { currentOwner() == owner && owner.authority.kind == .direct }

    func loadSnapshot(profileID: String, refreshModels: Bool = false, analyticsDays: Int = 30) async throws -> DirectHermesModelAdministrationSnapshot {
        let profile = try DirectHermesProviderClient.profile(profileID)
        let providers = try await listModelProviders(profileID: profile, refresh: refreshModels)
        var skipped: [String] = []
        func optional<T>(_ name: String, _ load: () async throws -> T) async throws -> T? {
            do { return try await load() } catch is CancellationError { throw CancellationError() } catch {
                skipped.append(name)
                return nil
            }
        }
        // Without model details, the current provider from the list still says what new chats use.
        let info = try await optional("model details") { try await modelInfo(profileID: profile) }
            ?? DirectHermesModelInfo(
                providerID: providers.first(where: \.isCurrent)?.id ?? "", modelID: "",
                automaticContextLength: 0, configuredContextLength: 0, effectiveContextLength: 0,
                capabilities: .init(supportsTools: nil, supportsVision: nil, supportsReasoning: nil,
                                    contextWindow: nil, maximumOutputTokens: nil, family: nil))
        let recommendation: DirectHermesRecommendedModel? = info.providerID.isEmpty ? nil
            : try await optional("recommended model") { try await recommendedDefault(providerID: info.providerID) }
        let auxiliary = try await optional("helper models") { try await auxiliaryModels(profileID: profile) }
        let moa = try await optional("Mixture of Agents") { try await moaConfiguration(profileID: profile) }
        let analytics = try await optional("usage") { try await self.analytics(profileID: profile, days: analyticsDays) }
        let runtime = try await optional("readiness check") { try await runtimeStatus(profileID: profile) }
        return .init(
            providers: providers, info: info, recommendation: recommendation,
            auxiliary: auxiliary, moa: moa, analytics: analytics, runtime: runtime, skippedParts: skipped
        )
    }

    func listModelProviders(profileID: String, refresh: Bool = false) async throws -> [DirectHermesModelProvider] {
        let profile = try DirectHermesProviderClient.profile(profileID)
        let response: BighelpJSONValue
        do {
            response = try await requestHTTP(.init(
                path: "/api/model/options", method: .get,
                query: [
                    .init(name: "profile", value: profile),
                    .init(name: "refresh", value: refresh ? "true" : "false"),
                    .init(name: "include_unconfigured", value: "false"),
                    .init(name: "explicit_only", value: "false"),
                ],
                maximumResponseBytes: 2_097_152
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Same payload as the chat's model picker, which some hosts serve when the route fails.
            response = try await requestRPC("model.options", [
                "profile": .string(profile), "refresh": .boolean(refresh),
                "include_unconfigured": .boolean(false), "explicit_only": .boolean(false),
            ])
        }
        let object = try DirectHermesAdministrationCodec.object(response)
        let rows = try DirectHermesAdministrationCodec.array(object["providers"], maximum: 256)
        var seen = Set<String>()
        return try rows.map { value in
            let row = try DirectHermesAdministrationCodec.object(value)
            let id = try DirectHermesProviderClient.identifier(
                DirectHermesAdministrationCodec.string(row["slug"], maximum: 128)
            )
            guard seen.insert(id).inserted else { throw WorkspaceClientError.invalidResponse }
            let models = try DirectHermesAdministrationCodec.stringArray(
                row["models"], maximumCount: 20_000, maximumBytes: 256, required: false
            )
            let unavailable = Set(try DirectHermesAdministrationCodec.stringArray(
                row["unavailable_models"], maximumCount: 20_000, maximumBytes: 256, required: false
            ))
            return .init(
                id: id,
                name: try DirectHermesAdministrationCodec.string(row["name"], maximum: 800),
                models: models,
                unavailableModels: unavailable,
                isCurrent: try DirectHermesAdministrationCodec.optionalBool(row["is_current"]) ?? false,
                isCustom: try DirectHermesAdministrationCodec.optionalBool(row["is_user_defined"]) ?? false,
                isAuthenticated: try DirectHermesAdministrationCodec.optionalBool(row["authenticated"]),
                authType: try DirectHermesAdministrationCodec.optionalString(row["auth_type"], maximum: 128),
                isFreeTier: try DirectHermesAdministrationCodec.optionalBool(row["free_tier"])
            )
        }
    }

    func modelInfo(profileID: String) async throws -> DirectHermesModelInfo {
        let profile = try DirectHermesProviderClient.profile(profileID)
        let response = try await requestHTTP(.init(
            path: "/api/model/info", method: .get,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 64_000
        ))
        let row = try DirectHermesAdministrationCodec.object(response)
        return .init(
            providerID: try DirectHermesAdministrationCodec.string(row["provider"], maximum: 128),
            modelID: try DirectHermesAdministrationCodec.string(row["model"], maximum: 256),
            automaticContextLength: try DirectHermesAdministrationCodec.int(row["auto_context_length"], minimum: 0),
            configuredContextLength: try DirectHermesAdministrationCodec.int(row["config_context_length"], minimum: 0),
            effectiveContextLength: try DirectHermesAdministrationCodec.int(row["effective_context_length"], minimum: 0),
            capabilities: try Self.capabilities(row["capabilities"])
        )
    }

    func recommendedDefault(providerID: String) async throws -> DirectHermesRecommendedModel {
        let provider = try DirectHermesProviderClient.identifier(providerID)
        let response = try await requestHTTP(.init(
            path: "/api/model/recommended-default", method: .get,
            query: [.init(name: "provider", value: provider)], maximumResponseBytes: 16_384
        ))
        let row = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.string(row["provider"], maximum: 128).lowercased() == provider.lowercased() else {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(
            providerID: provider,
            modelID: try DirectHermesAdministrationCodec.string(row["model"], maximum: 256),
            isFreeTier: try DirectHermesAdministrationCodec.optionalBool(row["free_tier"])
        )
    }

    func auxiliaryModels(profileID: String) async throws -> DirectHermesAuxiliaryModels {
        let profile = try DirectHermesProviderClient.profile(profileID)
        let response = try await requestHTTP(.init(
            path: "/api/model/auxiliary", method: .get,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 128_000
        ))
        let object = try DirectHermesAdministrationCodec.object(response)
        let main = try DirectHermesAdministrationCodec.object(object["main"])
        let rows = try DirectHermesAdministrationCodec.array(object["tasks"], maximum: 128)
        var seen = Set<String>()
        let tasks = try rows.map { value -> DirectHermesAuxiliaryModelAssignment in
            let row = try DirectHermesAdministrationCodec.object(value)
            let task = try DirectHermesProviderClient.identifier(
                DirectHermesAdministrationCodec.string(row["task"], maximum: 128)
            )
            guard seen.insert(task).inserted else { throw WorkspaceClientError.invalidResponse }
            let baseURL = try DirectHermesAdministrationCodec.string(row["base_url"], maximum: 2_048)
            if !baseURL.isEmpty { try DirectHermesProviderClient.validateEndpointURL(baseURL) }
            return .init(
                task: task,
                providerID: try DirectHermesAdministrationCodec.string(row["provider"], maximum: 128),
                modelID: try DirectHermesAdministrationCodec.string(row["model"], maximum: 256),
                baseURL: baseURL,
                isLocalEndpoint: try DirectHermesAdministrationCodec.bool(row["local_endpoint"])
            )
        }
        return .init(
            mainProviderID: try DirectHermesAdministrationCodec.string(main["provider"], maximum: 128),
            mainModelID: try DirectHermesAdministrationCodec.string(main["model"], maximum: 256),
            tasks: tasks
        )
    }

    func moaConfiguration(profileID: String) async throws -> DirectHermesMoAConfiguration {
        let profile = try DirectHermesProviderClient.profile(profileID)
        let response = try await requestHTTP(.init(
            path: "/api/model/moa", method: .get,
            query: [.init(name: "profile", value: profile)], maximumResponseBytes: 512_000
        ))
        return try Self.moa(response)
    }

    func analytics(profileID: String, days: Int = 30) async throws -> DirectHermesModelAnalytics {
        let profile = try DirectHermesProviderClient.profile(profileID)
        guard (1...365).contains(days) else { throw WorkspaceClientError.invalidRequest }
        let response = try await requestHTTP(.init(
            path: "/api/analytics/models", method: .get,
            query: [.init(name: "profile", value: profile), .init(name: "days", value: String(days))],
            maximumResponseBytes: 1_048_576
        ))
        let object = try DirectHermesAdministrationCodec.object(response)
        let period = try DirectHermesAdministrationCodec.int(object["period_days"], minimum: 1)
        guard period == days else { throw WorkspaceClientError.invalidResponse }
        let rawRows = try DirectHermesAdministrationCodec.array(object["models"], maximum: 10_000)
        let rows = try rawRows.map { value -> DirectHermesModelAnalytics.Row in
            let row = try DirectHermesAdministrationCodec.object(value)
            return .init(
                providerID: try DirectHermesAdministrationCodec.string(row["provider"], maximum: 128),
                modelID: try DirectHermesAdministrationCodec.string(row["model"], maximum: 256),
                inputTokens: try DirectHermesAdministrationCodec.optionalInt(row["input_tokens"], minimum: 0) ?? 0,
                outputTokens: try DirectHermesAdministrationCodec.optionalInt(row["output_tokens"], minimum: 0) ?? 0,
                cachedTokens: try DirectHermesAdministrationCodec.optionalInt(row["cache_read_tokens"], minimum: 0) ?? 0,
                reasoningTokens: try DirectHermesAdministrationCodec.optionalInt(row["reasoning_tokens"], minimum: 0) ?? 0,
                estimatedCost: try DirectHermesAdministrationCodec.optionalNumber(row["estimated_cost"]) ?? 0,
                actualCost: try DirectHermesAdministrationCodec.optionalNumber(row["actual_cost"]) ?? 0,
                sessions: try DirectHermesAdministrationCodec.optionalInt(row["sessions"], minimum: 0) ?? 0,
                apiCalls: try DirectHermesAdministrationCodec.optionalInt(row["api_calls"], minimum: 0) ?? 0,
                toolCalls: try DirectHermesAdministrationCodec.optionalInt(row["tool_calls"], minimum: 0) ?? 0,
                lastUsedAt: try DirectHermesAdministrationCodec.optionalDate(row["last_used_at"]),
                averageTokensPerSession: try DirectHermesAdministrationCodec.optionalNumber(row["avg_tokens_per_session"]) ?? 0,
                capabilities: try Self.capabilities(row["capabilities"])
            )
        }
        guard Set(rows.map(\.id)).count == rows.count else { throw WorkspaceClientError.invalidResponse }
        let totals = try DirectHermesAdministrationCodec.object(object["totals"])
        return .init(
            periodDays: period, rows: rows,
            totals: .init(
                distinctModels: try DirectHermesAdministrationCodec.optionalInt(totals["distinct_models"], minimum: 0) ?? 0,
                inputTokens: try DirectHermesAdministrationCodec.optionalInt(totals["total_input"], minimum: 0) ?? 0,
                outputTokens: try DirectHermesAdministrationCodec.optionalInt(totals["total_output"], minimum: 0) ?? 0,
                cachedTokens: try DirectHermesAdministrationCodec.optionalInt(totals["total_cache_read"], minimum: 0) ?? 0,
                reasoningTokens: try DirectHermesAdministrationCodec.optionalInt(totals["total_reasoning"], minimum: 0) ?? 0,
                estimatedCost: try DirectHermesAdministrationCodec.optionalNumber(totals["total_estimated_cost"]) ?? 0,
                actualCost: try DirectHermesAdministrationCodec.optionalNumber(totals["total_actual_cost"]) ?? 0,
                sessions: try DirectHermesAdministrationCodec.optionalInt(totals["total_sessions"], minimum: 0) ?? 0,
                apiCalls: try DirectHermesAdministrationCodec.optionalInt(totals["total_api_calls"], minimum: 0) ?? 0
            )
        )
    }

    func setModel(profileID: String, request: DirectHermesModelAssignmentRequest) async throws -> DirectHermesModelAssignmentOutcome {
        let profile = try DirectHermesProviderClient.profile(profileID)
        let body = try Self.assignmentBody(profile: profile, request: request)
        let response = try await requestHTTP(.init(
            path: "/api/model/set", method: .post, body: body, maximumResponseBytes: 32_768
        ), mutation: true)
        let row = try DirectHermesAdministrationCodec.object(response)
        if try DirectHermesAdministrationCodec.optionalBool(row["confirm_required"]) == true {
            guard !request.confirmExpensiveModel else { throw WorkspaceClientError.rejected(code: nil) }
            let message = try DirectHermesAdministrationCodec.string(row["confirm_message"], maximum: 4_096)
            return .confirmationRequired(.init(id: UUID(), request: request, message: message))
        }
        guard try DirectHermesAdministrationCodec.bool(row["ok"]) else { throw WorkspaceClientError.rejected(code: nil) }
        try await verifyAssignment(profile: profile, request: request)
        return .applied
    }

    func confirmModelAssignment(profileID: String, confirmation: DirectHermesModelAssignmentConfirmation) async throws {
        let outcome = try await setModel(profileID: profileID, request: confirmation.request.confirmingExpensiveModel())
        guard outcome == .applied else { throw WorkspaceClientError.rejected(code: nil) }
    }

    /// Full-document MoA write. The pinned request model does not accept
    /// `privacy_filter`; refuse rather than silently resetting a configured mode.
    func saveMoAConfiguration(profileID: String, configuration: DirectHermesMoAConfiguration) async throws {
        let profile = try DirectHermesProviderClient.profile(profileID)
        guard configuration.privacyFilter.isEmpty else {
            throw WorkspaceClientError.unavailable(.policyRestricted)
        }
        let body = try Self.moaBody(profile: profile, configuration: configuration)
        let response = try await requestHTTP(.init(
            path: "/api/model/moa", method: .put,
            query: [.init(name: "profile", value: profile)], body: body,
            maximumResponseBytes: 512_000
        ), mutation: true)
        let row = try DirectHermesAdministrationCodec.object(response)
        guard try DirectHermesAdministrationCodec.bool(row["ok"]) else { throw WorkspaceClientError.rejected(code: nil) }
        let verified = try await moaConfiguration(profileID: profile)
        guard verified == configuration else { throw WorkspaceClientError.outcomeUnknown }
    }

    func runtimeStatus(profileID: String) async throws -> DirectHermesRuntimeStatus {
        let profile = try DirectHermesProviderClient.profile(profileID)
        let response = try await requestRPC("setup.runtime_check", ["profile": .string(profile)])
        let row = try DirectHermesAdministrationCodec.object(response)
        let returnedProfile = try DirectHermesAdministrationCodec.optionalString(row["profile"], maximum: 128)
        guard returnedProfile == nil || returnedProfile == profile else { throw WorkspaceClientError.invalidResponse }
        return .init(
            isUsable: try DirectHermesAdministrationCodec.bool(row["ok"]),
            providerID: try DirectHermesAdministrationCodec.optionalString(row["provider"], maximum: 128),
            modelID: try DirectHermesAdministrationCodec.optionalString(row["model"], maximum: 256),
            source: try DirectHermesAdministrationCodec.optionalString(row["source"], maximum: 256),
            isFreeTier: try DirectHermesAdministrationCodec.optionalBool(row["free_tier"]),
            profileID: returnedProfile,
            errorMessage: try DirectHermesAdministrationCodec.optionalString(row["error"], maximum: 2_000)
        )
    }

    private func verifyAssignment(profile: String, request: DirectHermesModelAssignmentRequest) async throws {
        switch request.scope {
        case .main:
            let info = try await modelInfo(profileID: profile)
            guard info.providerID == request.providerID, info.modelID == request.modelID else {
                throw WorkspaceClientError.outcomeUnknown
            }
        case .auxiliary(let task):
            let state = try await auxiliaryModels(profileID: profile)
            guard let row = state.tasks.first(where: { $0.task == task }),
                  row.providerID == request.providerID, row.modelID == request.modelID else {
                throw WorkspaceClientError.outcomeUnknown
            }
        case .automaticAuxiliary(let task):
            let state = try await auxiliaryModels(profileID: profile)
            guard let row = state.tasks.first(where: { $0.task == task }),
                  row.providerID == "auto", row.modelID.isEmpty else {
                throw WorkspaceClientError.outcomeUnknown
            }
        case .resetAuxiliary:
            let state = try await auxiliaryModels(profileID: profile)
            guard state.tasks.allSatisfy({ $0.providerID == "auto" && $0.modelID.isEmpty }) else {
                throw WorkspaceClientError.outcomeUnknown
            }
        }
    }

    private static func assignmentBody(
        profile: String, request: DirectHermesModelAssignmentRequest
    ) throws -> [String: BighelpJSONValue] {
        let provider: String
        let model: String
        let scope: String
        let task: String
        switch request.scope {
        case .main:
            scope = "main"; task = ""
            provider = try DirectHermesProviderClient.identifier(request.providerID)
            guard !request.modelID.isEmpty, request.modelID.utf8.count <= 256 else { throw WorkspaceClientError.invalidRequest }
            model = request.modelID
        case .auxiliary(let rawTask):
            scope = "auxiliary"; task = try DirectHermesProviderClient.identifier(rawTask)
            provider = try DirectHermesProviderClient.identifier(request.providerID)
            guard !request.modelID.isEmpty, request.modelID.utf8.count <= 256 else { throw WorkspaceClientError.invalidRequest }
            model = request.modelID
        case .automaticAuxiliary(let rawTask):
            scope = "auxiliary"; task = try DirectHermesProviderClient.identifier(rawTask); provider = "auto"; model = ""
        case .resetAuxiliary:
            scope = "auxiliary"; task = "__reset__"; provider = "auto"; model = ""
        }
        var body: [String: BighelpJSONValue] = [
            "scope": .string(scope), "provider": .string(provider), "model": .string(model),
            "task": .string(task), "base_url": .string(""), "api_key": .string(""),
            "confirm_expensive_model": .boolean(request.confirmExpensiveModel), "profile": .string(profile),
        ]
        if let effort = request.reasoningEffort {
            guard effort.utf8.count <= 64 else { throw WorkspaceClientError.invalidRequest }
            body["reasoning_effort"] = .string(effort)
        }
        return body
    }

    private static func moa(_ response: BighelpJSONValue) throws -> DirectHermesMoAConfiguration {
        let row = try DirectHermesAdministrationCodec.object(response)
        let defaultPreset = try DirectHermesAdministrationCodec.string(row["default_preset"], maximum: 128)
        let activePreset = try DirectHermesAdministrationCodec.string(row["active_preset"], maximum: 128)
        let source = try DirectHermesAdministrationCodec.object(row["presets"])
        guard !source.isEmpty, source.count <= 64 else { throw WorkspaceClientError.invalidResponse }
        let presets = try source.keys.sorted().map { name -> DirectHermesMoAPreset in
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 128 else { throw WorkspaceClientError.invalidResponse }
            let preset = try DirectHermesAdministrationCodec.object(source[name])
            let references = try DirectHermesAdministrationCodec.array(preset["reference_models"], maximum: 32)
                .map { try moaSlot($0, reference: true) }
            guard !references.isEmpty else { throw WorkspaceClientError.invalidResponse }
            let policy = try DirectHermesAdministrationCodec.string(preset["degraded_reference_policy"], maximum: 16)
            guard ["loud", "silent"].contains(policy) else { throw WorkspaceClientError.invalidResponse }
            return .init(
                name: name, referenceModels: references,
                aggregator: try moaSlot(preset["aggregator"], reference: false),
                referenceTemperature: try DirectHermesAdministrationCodec.optionalNumber(preset["reference_temperature"]),
                aggregatorTemperature: try DirectHermesAdministrationCodec.optionalNumber(preset["aggregator_temperature"]),
                referenceTimeout: try DirectHermesAdministrationCodec.optionalNumber(preset["reference_timeout"]),
                degradedReferencePolicy: policy,
                fanout: try DirectHermesAdministrationCodec.optionalString(preset["fanout"], maximum: 64),
                isEnabled: try DirectHermesAdministrationCodec.bool(preset["enabled"])
            )
        }
        guard presets.contains(where: { $0.name == defaultPreset }),
              activePreset.isEmpty || presets.contains(where: { $0.name == activePreset }) else {
            throw WorkspaceClientError.invalidResponse
        }
        return .init(
            defaultPreset: defaultPreset, activePreset: activePreset, presets: presets,
            privacyFilter: try DirectHermesAdministrationCodec.optionalString(row["privacy_filter"], maximum: 16) ?? ""
        )
    }

    private static func moaSlot(_ value: BighelpJSONValue?, reference: Bool) throws -> DirectHermesMoAModelSlot {
        let row = try DirectHermesAdministrationCodec.object(value)
        let provider = try DirectHermesProviderClient.identifier(
            DirectHermesAdministrationCodec.string(row["provider"], maximum: 128)
        )
        guard provider.lowercased() != "moa" else { throw WorkspaceClientError.invalidResponse }
        let model = try DirectHermesAdministrationCodec.string(row["model"], maximum: 256)
        guard !model.isEmpty else { throw WorkspaceClientError.invalidResponse }
        return .init(
            providerID: provider, modelID: model,
            reasoningEffort: try DirectHermesAdministrationCodec.optionalString(row["reasoning_effort"], maximum: 64),
            isEnabled: reference ? (try DirectHermesAdministrationCodec.optionalBool(row["enabled"]) ?? true) : true
        )
    }

    private static func moaBody(
        profile: String, configuration: DirectHermesMoAConfiguration
    ) throws -> [String: BighelpJSONValue] {
        guard !configuration.presets.isEmpty, configuration.presets.count <= 64,
              Set(configuration.presets.map(\.name)).count == configuration.presets.count,
              configuration.presets.contains(where: { $0.name == configuration.defaultPreset }),
              configuration.activePreset.isEmpty || configuration.presets.contains(where: { $0.name == configuration.activePreset }) else {
            throw WorkspaceClientError.invalidRequest
        }
        var presets: [String: BighelpJSONValue] = [:]
        for preset in configuration.presets {
            guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  preset.name.utf8.count <= 128, !preset.referenceModels.isEmpty,
                  preset.referenceModels.count <= 32,
                  ["loud", "silent"].contains(preset.degradedReferencePolicy),
                  preset.referenceTimeout.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw WorkspaceClientError.invalidRequest
            }
            var value: [String: BighelpJSONValue] = [
                "reference_models": .array(try preset.referenceModels.map { try moaSlotBody($0, reference: true) }),
                "aggregator": try moaSlotBody(preset.aggregator, reference: false),
                "degraded_reference_policy": .string(preset.degradedReferencePolicy),
                "enabled": .boolean(preset.isEnabled),
            ]
            value["reference_temperature"] = try numberOrNull(preset.referenceTemperature)
            value["aggregator_temperature"] = try numberOrNull(preset.aggregatorTemperature)
            value["reference_timeout"] = try numberOrNull(preset.referenceTimeout)
            if let fanout = preset.fanout { value["fanout"] = .string(fanout) }
            presets[preset.name] = .object(value)
        }
        return [
            "default_preset": .string(configuration.defaultPreset),
            "active_preset": .string(configuration.activePreset),
            "presets": .object(presets), "profile": .string(profile),
        ]
    }

    private static func moaSlotBody(_ slot: DirectHermesMoAModelSlot, reference: Bool) throws -> BighelpJSONValue {
        let provider = try DirectHermesProviderClient.identifier(slot.providerID)
        guard provider.lowercased() != "moa", !slot.modelID.isEmpty, slot.modelID.utf8.count <= 256 else {
            throw WorkspaceClientError.invalidRequest
        }
        var row: [String: BighelpJSONValue] = [
            "provider": .string(provider), "model": .string(slot.modelID)
        ]
        if let effort = slot.reasoningEffort {
            guard effort.utf8.count <= 64 else { throw WorkspaceClientError.invalidRequest }
            row["reasoning_effort"] = .string(effort)
        }
        if reference { row["enabled"] = .boolean(slot.isEnabled) }
        return .object(row)
    }

    private static func numberOrNull(_ value: Double?) throws -> BighelpJSONValue {
        guard let value else { return .null }
        guard value.isFinite else { throw WorkspaceClientError.invalidRequest }
        return .number(value)
    }

    private static func capabilities(_ value: BighelpJSONValue?) throws -> DirectHermesModelCapabilities {
        if value == nil || value == .null {
            return .init(
                supportsTools: nil, supportsVision: nil, supportsReasoning: nil,
                contextWindow: nil, maximumOutputTokens: nil, family: nil
            )
        }
        let row = try DirectHermesAdministrationCodec.object(value)
        return .init(
            supportsTools: try DirectHermesAdministrationCodec.optionalBool(row["supports_tools"]),
            supportsVision: try DirectHermesAdministrationCodec.optionalBool(row["supports_vision"]),
            supportsReasoning: try DirectHermesAdministrationCodec.optionalBool(row["supports_reasoning"]),
            contextWindow: try DirectHermesAdministrationCodec.optionalInt(row["context_window"], minimum: 0),
            maximumOutputTokens: try DirectHermesAdministrationCodec.optionalInt(row["max_output_tokens"], minimum: 0),
            family: try DirectHermesAdministrationCodec.optionalString(row["model_family"], maximum: 256)
        )
    }

    private func requestHTTP(_ request: DirectHermesHTTPRequest, mutation: Bool = false) async throws -> BighelpJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: checkOwner,
            mapError: { DirectHermesAdministrationCodec.safeError($0, mutation: mutation) }) {
            try await http.request(request)
        }
    }

    private func requestRPC(_ method: String, _ params: [String: BighelpJSONValue], mutation: Bool = false) async throws -> BighelpJSONValue {
        try await DirectHermesCoreRequestScope.checkedRequest(check: checkOwner,
            mapError: { DirectHermesAdministrationCodec.safeError($0, mutation: mutation) }) {
            try await rpc.request(method, params: params)
        }
    }

    private func checkOwner() throws {
        try Task.checkCancellation()
        guard ownsScope else { throw WorkspaceClientError.ownerChanged }
    }
}
