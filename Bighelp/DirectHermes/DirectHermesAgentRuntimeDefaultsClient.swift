import Foundation

@MainActor
final class DirectHermesAgentRuntimeDefaultsClient: AgentRuntimeDefaultsConfirmingClient {
    private struct Snapshot {
        let defaults: AgentRuntimeDefaults
        let support: AgentRuntimeDefaultsSupport
    }

    private let service: DirectHermesAgentProfileService
    private var baselines: [String: Snapshot] = [:]
    private var providerCache: [String: [BighelpLinkModelProvider]] = [:]
    private var confirmation: AgentRuntimeDefaultsSaveConfirmation?
    private var confirmationExpiresAt: Date?
    private var isSaving = false

    init(workspace: any WorkspaceOperationPerforming, owner: WorkspaceOwner,
         currentOwner: @escaping @MainActor () -> WorkspaceOwner?) {
        service = DirectHermesAgentProfileService(workspace: workspace, owner: owner, currentOwner: currentOwner)
    }

    func loadCatalog(agentID: String) async throws -> AgentRuntimeDefaultsCatalog {
        let snapshot = try await readSnapshot(agentID: agentID)
        let providers = try await loadModelProviders(agentID: agentID)
        baselines[agentID] = snapshot
        return AgentRuntimeDefaultsCatalog(defaults: snapshot.defaults, providers: providers, support: snapshot.support)
    }

    func loadDefaults(agentID: String) async throws -> AgentRuntimeDefaults {
        let snapshot = try await readSnapshot(agentID: agentID)
        baselines[agentID] = snapshot
        return snapshot.defaults
    }

    func loadModelProviders(agentID: String) async throws -> [BighelpLinkModelProvider] {
        _ = try DirectHermesAgentProfileService.profileIdentifier(agentID)
        let response = try await service.request(.modelOptions, ["profile": .string(agentID)],
                                                 capability: .modelsRead, profileID: agentID)
        let providers = try Self.decodeModelProviders(response)
        providerCache[agentID] = providers
        return providers
    }

    /// Hermes' model catalog (`model.options`), read so the picker always has it: a provider
    /// or model the app can't use (a malformed row, a name it couldn't send back, a repeat)
    /// costs only itself, never the list. Real catalogs are big and untidy: one Azure AI
    /// Foundry provider lists 482 models, 17 of them twice. The reply's size limit bounds it.
    static func decodeModelProviders(_ response: [String: BighelpJSONValue]) throws -> [BighelpLinkModelProvider] {
        guard let values = response["providers"]?.array else { throw WorkspaceClientError.invalidResponse }
        var providers: [BighelpLinkModelProvider] = []
        var providerIDs = Set<String>()
        for value in values {
            guard let row = value.object, let id = row["slug"]?.string,
                  (try? WorkspaceAuthority.validateIdentifier(id, maximumBytes: 128)) != nil,
                  providerIDs.insert(id).inserted else { continue }
            let name = row["name"]?.string.flatMap { try? DirectHermesAgentProfileService.text($0, maximumBytes: 800) }
            var modelIDs = Set<String>()
            let models = (row["models"]?.array ?? []).compactMap { value -> String? in
                guard let model = value.string, (try? WorkspaceAuthority.validateIdentifier(model, maximumBytes: 256)) != nil,
                      modelIDs.insert(model).inserted else { return nil }
                return model
            }
            let unavailable = Set((row["unavailable_models"]?.array ?? []).compactMap(\.string))
            providers.append(BighelpLinkModelProvider(
                id: id, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? id,
                isCurrent: row["is_current"]?.boolean ?? false, isCustom: row["is_user_defined"]?.boolean ?? false,
                models: models.filter { !unavailable.contains($0) },
                fastModeModels: row["capabilities"]?.object.map { capabilities in
                    Set(models.filter { capabilities[$0]?.object?["fast"]?.boolean == true })
                },
                plan: ModelProviderPlan(row: row)
            ))
        }
        return providers
    }

    func cachedModelProviders(agentID: String) -> [BighelpLinkModelProvider]? {
        guard service.currentOwner() == service.owner, service.workspace.owner == service.owner else { return nil }
        return providerCache[agentID]
    }

    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String) async throws {
        try await save(defaults, agentID: agentID, confirmed: false)
    }

    func saveDefaults(_ defaults: AgentRuntimeDefaults, agentID: String,
                      confirmation: AgentRuntimeDefaultsSaveConfirmation) async throws {
        guard self.confirmation == confirmation, confirmation.agentID == agentID,
              confirmation.defaults == defaults, let expiresAt = confirmationExpiresAt,
              expiresAt > Date.now else { throw WorkspaceClientError.conflict }
        self.confirmation = nil
        confirmationExpiresAt = nil
        try await save(defaults, agentID: agentID, confirmed: true)
    }

    private func save(_ desired: AgentRuntimeDefaults, agentID: String, confirmed: Bool) async throws {
        guard !isSaving, let baseline = baselines[agentID] else { throw WorkspaceClientError.conflict }
        try service.requireCapability(.agentDefaultsEdit, profileID: agentID)
        isSaving = true
        defer { isSaving = false }
        let current = try await readSnapshot(agentID: agentID)
        guard current.defaults == baseline.defaults, current.support == baseline.support else {
            throw WorkspaceClientError.conflict
        }
        try validate(desired, baseline: current, agentID: agentID)
        let mainModelChanged = desired.mainChats.providerID != current.defaults.mainChats.providerID
            || desired.mainChats.modelID != current.defaults.mainChats.modelID
        let mainReasoningChanged = desired.mainChats.reasoningEffort != current.defaults.mainChats.reasoningEffort
        let fastModeChanged = desired.mainChats.fastMode != current.defaults.mainChats.fastMode
        var childConfig = Self.childChanges(desired, old: current.defaults)
        if mainReasoningChanged, desired.mainChats.reasoningEffort.isEmpty {
            childConfig["agent"] = .object(["reasoning_effort": .string("")])
        }
        guard mainModelChanged || mainReasoningChanged || fastModeChanged || !childConfig.isEmpty else { return }
        var didSubmitMutation = false
        do {
            if mainModelChanged {
                var payload: [String: BighelpJSONValue] = [
                    "name": .string(agentID), "provider": .string(desired.mainChats.providerID),
                    "model": .string(desired.mainChats.modelID)
                ]
                if confirmed { payload["confirm_expensive_model"] = .boolean(true) }
                didSubmitMutation = true
                let response = try await service.request(.profilesConfigure, payload,
                                                         capability: .agentDefaultsEdit, profileID: agentID)
                if response["confirm_required"]?.boolean == true {
                    guard !confirmed, let message = response["confirm_message"]?.string, !message.isEmpty else {
                        throw WorkspaceClientError.invalidResponse
                    }
                    _ = try DirectHermesAgentProfileService.text(message, maximumBytes: 4_096)
                    let token = AgentRuntimeDefaultsSaveConfirmation(
                        id: UUID(), agentID: agentID, defaults: desired, message: message
                    )
                    confirmation = token
                    confirmationExpiresAt = Date.now.addingTimeInterval(300)
                    throw AgentRuntimeDefaultsConfirmationRequired(confirmation: token)
                }
                guard response["applied"]?.object?["model"]?.boolean == true else {
                    throw WorkspaceClientError.rejected(code: nil)
                }
            }
            if mainReasoningChanged, !desired.mainChats.reasoningEffort.isEmpty {
                didSubmitMutation = true
                let result = try await service.request(.configSet, [
                    "profile": .string(agentID), "key": .string("reasoning"),
                    "value": .string(desired.mainChats.reasoningEffort), "scope": .string("global")
                ], capability: .agentDefaultsEdit, profileID: agentID)
                guard result["key"]?.string == "reasoning",
                      try Self.effort(result["value"]) == desired.mainChats.reasoningEffort else {
                    throw WorkspaceClientError.invalidResponse
                }
            }
            if fastModeChanged {
                didSubmitMutation = true
                // No session ID: the host writes this profile's default, never
                // a currently open conversation's explicit override.
                let result = try await service.request(.configSet, [
                    "profile": .string(agentID), "key": .string("fast"),
                    "value": .string(desired.mainChats.fastMode.value), "scope": .string("global")
                ], capability: .agentDefaultsEdit, profileID: agentID)
                guard result["key"]?.string == "fast", let value = result["value"]?.string,
                      FastMode(value) == desired.mainChats.fastMode else {
                    throw WorkspaceClientError.outcomeUnknown
                }
            }
            if !childConfig.isEmpty {
                didSubmitMutation = true
                let result = try await service.request(.agentDefaultsSet, [
                    "profile": .string(agentID), "config": .object(childConfig)
                ], capability: .agentDefaultsEdit, profileID: agentID)
                guard result["ok"]?.boolean == true else { throw WorkspaceClientError.rejected(code: nil) }
            }
            let verified = try await readSnapshot(agentID: agentID)
            baselines[agentID] = verified
            guard verified.defaults == desired else {
                throw AgentRuntimeDefaultsPartialSaveError(committed: verified.defaults)
            }
        } catch let required as AgentRuntimeDefaultsConfirmationRequired {
            throw required
        } catch let partial as AgentRuntimeDefaultsPartialSaveError {
            throw partial
        } catch {
            try service.requireOwner()
            guard didSubmitMutation else { throw error }
            let verified: Snapshot
            do { verified = try await readSnapshot(agentID: agentID) }
            catch { try service.requireOwner(); throw WorkspaceClientError.outcomeUnknown }
            baselines[agentID] = verified
            throw AgentRuntimeDefaultsPartialSaveError(committed: verified.defaults)
        }
    }

    private func readSnapshot(agentID: String) async throws -> Snapshot {
        _ = try DirectHermesAgentProfileService.profileIdentifier(agentID)
        let described = try await service.request(.profilesDescribe, ["name": .string(agentID)],
                                                  capability: .modelsRead, profileID: agentID)
        guard described["name"]?.string == agentID, let model = described["model"]?.object,
              let provider = model["provider"]?.string, let modelID = model["default"]?.string else {
            throw WorkspaceClientError.invalidResponse
        }
        let payload = try await service.request(.agentDefaultsGet, ["profile": .string(agentID)],
                                                capability: .modelsRead, profileID: agentID)
        let agent = try DirectHermesAgentProfileService.object(payload["agent"])
        let delegation = try DirectHermesAgentProfileService.object(payload["delegation"])
        let cron = try DirectHermesAgentProfileService.object(payload["cron"])
        guard let hasEndpointOverride = delegation["has_base_url_override"]?.boolean else {
            throw WorkspaceClientError.invalidResponse
        }
        var support = AgentRuntimeDefaultsSupport()
        support.reasoningUnavailableReasons[.scheduledTasks] =
            "Scheduled tasks use their own reasoning override, or Hermes' main and per-model defaults."
        support.reasoningNotes[.mainChats] =
            "This is the global default. Hermes may apply a model-specific reasoning override."
        if hasEndpointOverride {
            support.modelUnavailableReasons[.subagents] =
                "Hermes uses a custom endpoint for subagents. Change that override on the host before choosing a different provider here."
        }
        let defaults = AgentRuntimeDefaults(
            mainChats: AgentRuntimeSelection(providerID: provider, modelID: modelID,
                reasoningEffort: try Self.effort(agent["reasoning_effort"]),
                fastMode: FastMode(try Self.string(agent["service_tier"]))),
            subagents: AgentRuntimeSelection(
                providerID: try Self.string(delegation["provider"]), modelID: try Self.string(delegation["model"]),
                reasoningEffort: try Self.effort(delegation["reasoning_effort"])
            ),
            scheduledTasks: AgentRuntimeSelection(
                providerID: try Self.string(cron["model_provider"]), modelID: try Self.string(cron["model"]),
                reasoningEffort: ""
            )
        )
        for scope in AgentRuntimeScope.allCases {
            _ = try DirectHermesAgentProfileService.text(defaults[scope].providerID, maximumBytes: 128)
            _ = try DirectHermesAgentProfileService.text(defaults[scope].modelID, maximumBytes: 256)
        }
        return Snapshot(defaults: defaults, support: support)
    }

    private func validate(_ desired: AgentRuntimeDefaults, baseline: Snapshot, agentID: String) throws {
        guard desired.scheduledTasks.reasoningEffort.isEmpty,
              desired.scheduledTasks.fastMode == baseline.defaults.scheduledTasks.fastMode,
              desired.subagents.fastMode == baseline.defaults.subagents.fastMode else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        if desired.mainChats.fastMode != baseline.defaults.mainChats.fastMode {
            guard desired.mainChats.fastMode == .on || desired.mainChats.fastMode == .off else {
                throw WorkspaceClientError.invalidRequest
            }
            // Turning it off is always safe, including a default left behind
            // after switching to an unsupported model on another client.
            if desired.mainChats.fastMode == .on {
                let providers = providerCache[agentID] ?? []
                guard FastMode.unavailableReason(provider: providers.first { $0.id == desired.mainChats.providerID },
                                                 model: desired.mainChats.modelID) == nil else {
                    throw WorkspaceClientError.unavailable(.unsupportedOperation)
                }
            }
        }
        for scope in AgentRuntimeScope.allCases {
            let new = desired[scope], old = baseline.defaults[scope]
            if new.providerID != old.providerID || new.modelID != old.modelID {
                guard baseline.support.modelUnavailableReasons[scope] == nil else {
                    throw WorkspaceClientError.unavailable(.policyRestricted)
                }
                if scope == .mainChats || !new.providerID.isEmpty || !new.modelID.isEmpty {
                    guard providerCache[agentID]?.contains(where: {
                        $0.id == new.providerID && $0.models.contains(new.modelID)
                    }) == true else { throw WorkspaceClientError.invalidRequest }
                }
            }
            if new.reasoningEffort != old.reasoningEffort,
               !AgentReasoningOption.all.contains(where: { $0.value == new.reasoningEffort }) {
                throw WorkspaceClientError.invalidRequest
            }
        }
    }

    private static func childChanges(_ desired: AgentRuntimeDefaults, old: AgentRuntimeDefaults) -> [String: BighelpJSONValue] {
        var config: [String: BighelpJSONValue] = [:]
        var delegation: [String: BighelpJSONValue] = [:]
        if desired.subagents.providerID != old.subagents.providerID { delegation["provider"] = .string(desired.subagents.providerID) }
        if desired.subagents.modelID != old.subagents.modelID { delegation["model"] = .string(desired.subagents.modelID) }
        if desired.subagents.reasoningEffort != old.subagents.reasoningEffort {
            delegation["reasoning_effort"] = desired.subagents.reasoningEffort == "none" ? .boolean(false) : .string(desired.subagents.reasoningEffort)
        }
        if !delegation.isEmpty { config["delegation"] = .object(delegation) }
        var cron: [String: BighelpJSONValue] = [:]
        if desired.scheduledTasks.providerID != old.scheduledTasks.providerID { cron["model_provider"] = .string(desired.scheduledTasks.providerID) }
        if desired.scheduledTasks.modelID != old.scheduledTasks.modelID { cron["model"] = .string(desired.scheduledTasks.modelID) }
        if !cron.isEmpty { config["cron"] = .object(cron) }
        return config
    }

    private static func string(_ value: BighelpJSONValue?) throws -> String {
        try DirectHermesAgentProfileService.optionalText(value, maximumBytes: 256) ?? ""
    }

    private static func effort(_ value: BighelpJSONValue?) throws -> String {
        if value == .boolean(false) { return "none" }
        if value == .boolean(true) { return "" }
        let raw = try DirectHermesAgentProfileService.optionalText(value, maximumBytes: 64) ?? ""
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["none", "false", "disabled"].contains(normalized) { return "none" }
        guard normalized.isEmpty || AgentReasoningOption.all.contains(where: { $0.value == normalized }) else {
            throw WorkspaceClientError.invalidResponse
        }
        return normalized
    }
}
