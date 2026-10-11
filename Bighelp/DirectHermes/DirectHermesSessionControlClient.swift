import Foundation

/// Adapts controls to the selected live session and verifies mutations by readback.
@MainActor
final class DirectHermesSessionControlClient: SessionRuntimeControlConfirming, SessionRuntimeControlSupporting, SessionFastModeControlling {
    private struct Key: Hashable {
        let sessionID: String
        let kind: BighelpLinkPickerKind
    }

    private struct Picker {
        let id: String
        let key: Key
        let generation: UUID
        let coordinate: WorkspaceSessionCoordinate
        let providers: [BighelpLinkModelProvider]
        let expiresAt: Date
    }

    private struct PendingConfirmation {
        let value: SessionRuntimeModelConfirmation
        let generation: UUID
        let expiresAt: Date
    }

    private struct Proof: Sendable {
        let reasoning: String
        let model: String
        let provider: String
        let fastMode: FastMode?
        let isRunning: Bool
    }

    private struct ModelState {
        let provider: String
        let runtimeProvider: String
        let model: String
        let providers: [BighelpLinkModelProvider]
        let fastMode: FastMode?
        let isRunning: Bool

        var speed: SessionFastMode {
            guard let fastMode else {
                return SessionFastMode(mode: nil, unavailableReason: "Update Hermes to read this chat’s Fast Mode.")
            }
            // Picker aliases are display hints, not proof of a billable route.
            return SessionFastMode(mode: fastMode, unavailableReason: FastMode.unavailableReason(
                provider: providers.first { $0.id == runtimeProvider }, model: model))
        }
    }

    private let workspace: any WorkspaceOperationPerforming
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private let resolveSession: @MainActor (String) -> WorkspaceSessionCoordinate?
    private let now: @MainActor () -> Date
    private let modelCache: DirectHermesModelCatalogCache
    private var generations: [Key: UUID] = [:]
    private var pickers: [String: Picker] = [:]
    private var confirmations: [UUID: PendingConfirmation] = [:]
    private var proofRequests: [WorkspaceSessionCoordinate: Task<Proof, Error>] = [:]

    init(
        workspace: any WorkspaceOperationPerforming,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        resolveSession: @escaping @MainActor (String) -> WorkspaceSessionCoordinate?,
        now: @escaping @MainActor () -> Date = { Date.now },
        modelCache: DirectHermesModelCatalogCache = DirectHermesModelCatalogCache()
    ) {
        self.workspace = workspace
        self.owner = owner
        self.currentOwner = currentOwner
        self.resolveSession = resolveSession
        self.now = now
        self.modelCache = modelCache
    }

    func cachedModelProviders(agentID: String) -> [BighelpLinkModelProvider] {
        guard currentOwner() == owner else { return [] }
        return modelCache.entries[agentID]?.providers ?? []
    }

    func selectionSupport(sessionID: String, agentID: String) -> SessionRuntimeControlSupport {
        let modelReason: String?
        if currentOwner() != owner || workspace.owner != owner {
            modelReason = "The host connection changed. Reopen this chat's controls."
        } else if (try? DirectHermesSessionIdentity.decode(sessionID, owner: owner))
                    .map({ DirectHermesSessionValidation.same($0.profileID, agentID) }) == true {
            // This agent's chat, live or not yet (still starting, or reattaching): its lists
            // show and a choice is made on its own live session when applied (`livePicker`).
            modelReason = AgentActionsPresentation.unavailableMessage(
                workspace.capabilities.availability(for: .sessionModelEdit, owner: owner, profileID: agentID)
            )
        } else {
            modelReason = "This chat is not attached to a current live Hermes session."
        }
        return SessionRuntimeControlSupport(
            modelUnavailableReason: modelReason,
            reasoningUnavailableReason: modelReason ?? AgentActionsPresentation.unavailableMessage(
                workspace.capabilities.availability(for: .reasoningEdit, owner: owner, profileID: agentID)
            )
        )
    }

    func loadFastMode(sessionID: String, agentID: String) async throws -> SessionFastMode {
        let coordinate = try coordinate(sessionID: sessionID, agentID: agentID)
        let speed = try await modelState(sessionID: sessionID, coordinate: coordinate).speed
        return SessionFastMode(mode: speed.mode, unavailableReason:
            selectionSupport(sessionID: sessionID, agentID: agentID).reasoningUnavailableReason ?? speed.unavailableReason)
    }

    func setFastMode(_ mode: FastMode, sessionID: String, agentID: String) async throws -> SessionFastMode {
        guard mode == .on || mode == .off else { throw WorkspaceClientError.invalidRequest }
        let coordinate = try coordinate(sessionID: sessionID, agentID: agentID)
        guard let runtimeID = coordinate.runtimeSessionID else { throw WorkspaceClientError.invalidRequest }
        let state = try await modelState(sessionID: sessionID, coordinate: coordinate)
        guard state.speed.unavailableReason == nil else { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
        guard !state.isRunning else { throw WorkspaceClientError.conflict }
        let response = try await perform(.configSet, payload: [
            "profile": .string(agentID), "session_id": .string(runtimeID),
            "key": .string("fast"), "value": .string(mode.value), "scope": .string("session")
        ], sessionID: sessionID, coordinate: coordinate, capability: .reasoningEdit)
        guard response["key"]?.string == "fast", let value = response["value"]?.string,
              FastMode(value) == mode else { throw WorkspaceClientError.outcomeUnknown }
        let readback = try await perform(.configGet, payload: [
            "profile": .string(agentID), "session_id": .string(runtimeID), "key": .string("fast")
        ], sessionID: sessionID, coordinate: coordinate, capability: .reasoningEdit)
        guard let verified = readback["value"]?.string, FastMode(verified) == mode else {
            throw WorkspaceClientError.outcomeUnknown
        }
        return SessionFastMode(mode: mode, unavailableReason: nil)
    }

    func openPicker(_ request: BighelpLinkPickerOpenRequest) async throws -> BighelpLinkPicker {
        guard BighelpLinkPickerValidation.opaque(request.requestID, minimum: 16, maximum: 128),
              request.sentAt > 0 else {
            throw WorkspaceClientError.invalidRequest
        }
        // The lists never wait on the chat's live session; a choice does (`liveCoordinate`).
        let coordinate = try listingCoordinate(sessionID: request.sessionID, agentID: request.agentID)
        let nativeCoordinate = try NativeSessionRuntimePickerCoordinate(coordinate)
        prune()
        let key = Key(sessionID: request.sessionID, kind: request.kind)
        guard generations[key] != nil || generations.count < 64 else { throw WorkspaceClientError.capacityExceeded }
        let generation = UUID()
        generations[key] = generation
        pickers = pickers.filter { $0.value.key != key }
        if request.kind == .model {
            confirmations = confirmations.filter { $0.value.value.selection.sessionID != request.sessionID }
        }
        var installed = false
        defer {
            if !installed, generations[key] == generation { generations[key] = nil }
        }
        let id = UUID().uuidString
        let timestamp = Int(now().timeIntervalSince1970)
        let response: BighelpLinkPicker
        let providers: [BighelpLinkModelProvider]
        switch request.kind {
        case .model:
            let state: ModelState
            if coordinate.runtimeSessionID != nil {
                do {
                    state = try await modelState(sessionID: request.sessionID, coordinate: coordinate)
                } catch let error where Self.endsPicker(error) {
                    throw error
                } catch {
                    state = try await catalogState(coordinate)
                }
            } else {
                state = try await catalogState(coordinate)
            }
            providers = state.providers
            response = .model(try BighelpLinkModelPicker(
                pickerID: id, nativeCoordinate: nativeCoordinate, currentModel: state.model,
                currentProvider: state.provider, providers: state.providers, sentAt: timestamp
            ))
        case .reasoning:
            // With no live session to ask, the levels still show, on Auto.
            let proof: Proof
            if coordinate.runtimeSessionID != nil {
                do {
                    proof = try await self.proof(sessionID: request.sessionID, coordinate: coordinate)
                } catch let error where Self.endsPicker(error) {
                    throw error
                } catch {
                    proof = Proof(reasoning: "", model: "", provider: "", fastMode: nil, isRunning: false)
                }
            } else {
                proof = Proof(reasoning: "", model: "", provider: "", fastMode: nil, isRunning: false)
            }
            providers = []
            var choices = try Self.reasoningValues.map { value in
                try BighelpLinkChoice(value: value, label: AgentReasoningOption.option(for: value).title,
                                     isCurrent: value == proof.reasoning)
            }
            if proof.reasoning.isEmpty {
                choices.insert(try BighelpLinkChoice(value: "reset", label: "Auto", isCurrent: true), at: 0)
            }
            response = .choice(try BighelpLinkChoicePicker(
                pickerID: id, nativeCoordinate: nativeCoordinate, kind: .reasoning,
                title: "Reasoning", choices: choices,
                sentAt: timestamp
            ))
        }
        try requireListingCurrent(sessionID: request.sessionID, coordinate: coordinate)
        guard generations[key] == generation else { throw CancellationError() }
        pickers[id] = Picker(
            id: id, key: key, generation: generation, coordinate: coordinate,
            providers: providers, expiresAt: now().addingTimeInterval(300)
        )
        installed = true
        return response
    }

    func selectPicker(_ selection: BighelpLinkPickerSelection) async throws -> BighelpLinkPickerResult {
        prune()
        guard let opened = pickers[selection.pickerID],
              opened.key.sessionID == selection.sessionID, opened.key.kind == selection.kind,
              generations[opened.key] == opened.generation else {
            return try result(selection, status: .expired, message: "Reopen this chat's model picker.")
        }
        let picker = try livePicker(opened)
        try requireCurrent(sessionID: selection.sessionID, coordinate: picker.coordinate)
        if selection.kind == .reasoning {
            return try await applyReasoning(selection, picker: picker)
        }
        guard let provider = selection.provider, let model = selection.model,
              selection.value == nil,
              picker.providers.contains(where: { $0.id == provider && $0.models.contains(model) }) else {
            throw WorkspaceClientError.invalidRequest
        }
        try Self.validateToken(provider, maximumBytes: 128)
        try Self.validateToken(model, maximumBytes: 256)
        pickers[selection.pickerID] = nil
        var awaitingConfirmation = false
        defer {
            if !awaitingConfirmation, generations[picker.key] == picker.generation {
                generations[picker.key] = nil
            }
        }
        do {
            return try await apply(selection, coordinate: picker.coordinate,
                                   generation: picker.generation, confirmed: false)
        } catch let required as SessionRuntimeModelConfirmationRequired {
            awaitingConfirmation = true
            throw required
        }
    }

    func confirmPicker(_ confirmation: SessionRuntimeModelConfirmation) async throws -> BighelpLinkPickerResult {
        prune()
        guard let issued = confirmations[confirmation.id],
              issued.value == confirmation, issued.expiresAt > now() else {
            throw WorkspaceClientError.conflict
        }
        let key = Key(sessionID: confirmation.selection.sessionID, kind: .model)
        try requireSelection(confirmation.selection, coordinate: confirmation.coordinate, generation: issued.generation)
        confirmations[confirmation.id] = nil
        defer { if generations[key] == issued.generation { generations[key] = nil } }
        return try await apply(confirmation.selection, coordinate: confirmation.coordinate,
                               generation: issued.generation, confirmed: true)
    }

    func cancelPickerConfirmation(_ confirmation: SessionRuntimeModelConfirmation) {
        guard let pending = confirmations[confirmation.id], pending.value == confirmation else { return }
        confirmations[confirmation.id] = nil
        let key = Key(sessionID: confirmation.selection.sessionID, kind: confirmation.selection.kind)
        if generations[key] == pending.generation { generations[key] = nil }
    }

    private static let reasoningValues = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    private func applyReasoning(_ selection: BighelpLinkPickerSelection, picker: Picker) async throws -> BighelpLinkPickerResult {
        guard let value = selection.value, Self.reasoningValues.contains(value),
              selection.model == nil, selection.provider == nil,
              let runtimeID = picker.coordinate.runtimeSessionID else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        // Reattach the exact runtime immediately before config.set: Hermes applies
        // reasoning to this live session, whereas a missing session targets defaults.
        _ = try await proof(sessionID: selection.sessionID, coordinate: picker.coordinate)
        try requireSelection(selection, coordinate: picker.coordinate, generation: picker.generation)
        pickers[selection.pickerID] = nil
        defer { if generations[picker.key] == picker.generation { generations[picker.key] = nil } }
        let payload: [String: BighelpJSONValue] = [
            "profile": .string(picker.coordinate.profileID), "session_id": .string(runtimeID),
            "key": .string("reasoning"), "value": .string(value), "scope": .string("session")
        ]
        let response = try await perform(.configSet, payload: payload, sessionID: selection.sessionID,
                                        coordinate: picker.coordinate, capability: .reasoningEdit)
        try requireSelection(selection, coordinate: picker.coordinate, generation: picker.generation)
        guard response["key"]?.string == "reasoning", response["value"]?.string == value else {
            throw WorkspaceClientError.outcomeUnknown
        }
        let readback = try await perform(.configGet, payload: [
            "profile": .string(picker.coordinate.profileID), "session_id": .string(runtimeID), "key": .string("reasoning")
        ], sessionID: selection.sessionID, coordinate: picker.coordinate, capability: .reasoningEdit)
        try requireSelection(selection, coordinate: picker.coordinate, generation: picker.generation)
        guard readback["value"]?.string == value else { throw WorkspaceClientError.outcomeUnknown }
        return try result(selection, status: .completed, message: "Hermes confirmed this chat's reasoning level.")
    }

    private func apply(
        _ selection: BighelpLinkPickerSelection,
        coordinate: WorkspaceSessionCoordinate,
        generation: UUID,
        confirmed: Bool
    ) async throws -> BighelpLinkPickerResult {
        guard let model = selection.model, let provider = selection.provider,
              let runtimeID = coordinate.runtimeSessionID else { throw WorkspaceClientError.invalidRequest }
        try Self.validateToken(model, maximumBytes: 256)
        try Self.validateToken(provider, maximumBytes: 128)
        let beforeSwitch = try await proof(sessionID: selection.sessionID, coordinate: coordinate)
        try requireSelection(selection, coordinate: coordinate, generation: generation)
        if beforeSwitch.model == model, beforeSwitch.provider == provider {
            return try result(selection, status: .completed, message: "Hermes confirmed this chat's model.")
        }
        var payload: [String: BighelpJSONValue] = [
            "profile": .string(coordinate.profileID), "session_id": .string(runtimeID),
            "key": .string("model"), "value": .string("\(model) --provider \(provider) --session")
        ]
        if confirmed { payload["confirm_expensive_model"] = .boolean(true) }
        let response = try await perform(.configSet, payload: payload, sessionID: selection.sessionID,
                                         coordinate: coordinate, capability: .sessionModelEdit)
        try requireSelection(selection, coordinate: coordinate, generation: generation)
        guard response["key"]?.string == "model", response["scope"]?.string == "session",
              let requiresConfirmation = response["confirm_required"]?.boolean,
              let returnedModel = response["value"]?.string else {
            throw WorkspaceClientError.invalidResponse
        }
        _ = try DirectHermesAgentProfileService.text(returnedModel, maximumBytes: 256)
        if requiresConfirmation {
            guard !confirmed, let message = response["confirm_message"]?.string,
                  !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WorkspaceClientError.invalidResponse
            }
            _ = try DirectHermesAgentProfileService.text(message, maximumBytes: 2_000)
            let confirmation = SessionRuntimeModelConfirmation(
                id: UUID(), selection: selection, coordinate: coordinate, message: message
            )
            guard confirmations.count < 32 else { throw WorkspaceClientError.capacityExceeded }
            confirmations[confirmation.id] = PendingConfirmation(
                value: confirmation, generation: generation, expiresAt: now().addingTimeInterval(300)
            )
            throw SessionRuntimeModelConfirmationRequired(confirmation: confirmation)
        }
        if let deferred = response["deferred"] {
            guard let isDeferred = deferred.boolean else { throw WorkspaceClientError.invalidResponse }
            if isDeferred {
                throw SessionRuntimeModelDeferred(
                    selection: selection, coordinate: coordinate,
                    message: "Hermes queued this model for the next turn. The current model has not been confirmed changed; reopen the picker to check."
                )
            }
        }
        if !beforeSwitch.reasoning.isEmpty {
            try await preserveReasoningAfterModelChange(
                beforeSwitch.reasoning,
                selection: selection,
                coordinate: coordinate,
                generation: generation
            )
        }
        let verified = try await proof(sessionID: selection.sessionID, coordinate: coordinate)
        try requireSelection(selection, coordinate: coordinate, generation: generation)
        guard verified.model == model else { throw WorkspaceClientError.outcomeUnknown }
        if verified.provider != provider {
            // Hermes catalogs can list a provider under an alias slug (for example
            // `copilot`) while the live runtime reports its canonical id
            // (`github-copilot`). Only a fresh host catalog read that marks the
            // selected slug current for this session proves equivalence.
            guard try await catalogMarksCurrent(provider: provider, model: model,
                                                sessionID: selection.sessionID, coordinate: coordinate) else {
                throw WorkspaceClientError.outcomeUnknown
            }
            try requireSelection(selection, coordinate: coordinate, generation: generation)
        }
        return try result(selection, status: .completed, message: "Hermes confirmed this chat's model.")
    }

    private func preserveReasoningAfterModelChange(
        _ reasoning: String,
        selection: BighelpLinkPickerSelection,
        coordinate: WorkspaceSessionCoordinate,
        generation: UUID
    ) async throws {
        guard Self.reasoningValues.contains(reasoning), let runtimeID = coordinate.runtimeSessionID else {
            throw WorkspaceClientError.outcomeUnknown
        }
        try requireSelection(selection, coordinate: coordinate, generation: generation)
        let response = try await perform(.configSet, payload: [
            "profile": .string(coordinate.profileID), "session_id": .string(runtimeID),
            "key": .string("reasoning"), "value": .string(reasoning), "scope": .string("session")
        ], sessionID: selection.sessionID, coordinate: coordinate, capability: .reasoningEdit)
        try requireSelection(selection, coordinate: coordinate, generation: generation)
        guard response["key"]?.string == "reasoning", response["value"]?.string == reasoning else {
            throw WorkspaceClientError.outcomeUnknown
        }
        let readback = try await perform(.configGet, payload: [
            "profile": .string(coordinate.profileID), "session_id": .string(runtimeID), "key": .string("reasoning")
        ], sessionID: selection.sessionID, coordinate: coordinate, capability: .reasoningEdit)
        try requireSelection(selection, coordinate: coordinate, generation: generation)
        guard readback["value"]?.string == reasoning else { throw WorkspaceClientError.outcomeUnknown }
    }

    private func catalogMarksCurrent(provider: String, model: String,
                                     sessionID: String, coordinate: WorkspaceSessionCoordinate) async throws -> Bool {
        guard let runtimeID = coordinate.runtimeSessionID else { throw WorkspaceClientError.invalidRequest }
        let response = try await perform(.modelOptions, payload: [
            "profile": .string(coordinate.profileID), "session_id": .string(runtimeID)
        ], sessionID: sessionID, coordinate: coordinate, capability: .modelsRead)
        let providers = try DirectHermesAgentRuntimeDefaultsClient.decodeModelProviders(response)
        guard response["model"]?.string == model else { return false }
        let current = providers.filter(\.isCurrent)
        return current.count == 1 && current[0].id == provider
    }

    /// Maps the runtime's canonical provider id onto the catalog slug the
    /// picker lists, only when the host marks exactly one catalog row current
    /// and that row offers the live model.
    private static func catalogProvider(for runtimeProvider: String, model: String,
                                        providers: [BighelpLinkModelProvider]) -> String {
        if providers.contains(where: { $0.id == runtimeProvider }) { return runtimeProvider }
        let current = providers.filter(\.isCurrent)
        guard current.count == 1, current[0].models.contains(model) else { return runtimeProvider }
        return current[0].id
    }

    private func modelState(sessionID: String, coordinate: WorkspaceSessionCoordinate) async throws -> ModelState {
        let cacheReadAt = now()
        if let cached = modelCache.entries[coordinate.profileID],
           cacheReadAt.timeIntervalSince(cached.fetchedAt) >= 0,
           cacheReadAt.timeIntervalSince(cached.fetchedAt) < 60 {
            let current = try await proof(sessionID: sessionID, coordinate: coordinate)
            return ModelState(
                provider: Self.catalogProvider(for: current.provider, model: current.model, providers: cached.providers),
                runtimeProvider: current.provider, model: current.model, providers: cached.providers,
                fastMode: current.fastMode, isRunning: current.isRunning
            )
        }

        guard let runtimeID = coordinate.runtimeSessionID else { throw WorkspaceClientError.invalidRequest }
        async let current = proof(sessionID: sessionID, coordinate: coordinate)
        async let response = perform(.modelOptions, payload: [
            "profile": .string(coordinate.profileID), "session_id": .string(runtimeID)
        ], sessionID: sessionID, coordinate: coordinate, capability: .modelsRead)
        let verified = try await current
        let providers = try DirectHermesAgentRuntimeDefaultsClient.decodeModelProviders(try await response)
        try requireCurrent(sessionID: sessionID, coordinate: coordinate)
        if modelCache.entries.count < 128 || modelCache.entries[coordinate.profileID] != nil {
            modelCache.entries[coordinate.profileID] = .init(providers: providers, fetchedAt: now())
        }
        return ModelState(
            provider: Self.catalogProvider(for: verified.provider, model: verified.model, providers: providers),
            runtimeProvider: verified.provider, model: verified.model, providers: providers,
            fastMode: verified.fastMode, isRunning: verified.isRunning
        )
    }

    private func proof(sessionID: String, coordinate: WorkspaceSessionCoordinate) async throws -> Proof {
        if let request = proofRequests[coordinate] {
            return try await request.value
        }
        let request = Task { @MainActor [weak self] in
            guard let self else { throw WorkspaceClientError.ownerChanged }
            return try await self.fetchProof(sessionID: sessionID, coordinate: coordinate)
        }
        proofRequests[coordinate] = request
        defer { proofRequests[coordinate] = nil }
        return try await request.value
    }

    private func fetchProof(sessionID: String, coordinate: WorkspaceSessionCoordinate) async throws -> Proof {
        guard let runtimeID = coordinate.runtimeSessionID, let storedID = coordinate.storedSessionID else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        // Activation attaches/touches an existing runtime; it never creates or builds one.
        // A chat whose agent isn't built yet (Hermes `lazy`: not started, or its provider has
        // no login) reports its model but may leave out the provider and reasoning. Its
        // model can still be switched for this chat alone, which is how a person gets out
        // of a provider that can't start; so it counts, with the provider unknown and
        // reasoning on Auto. A built chat must report all three.
        let response = try await perform(.sessionActivate, payload: [
            "session_id": .string(runtimeID), "omit_messages": .boolean(true)
        ], sessionID: sessionID, coordinate: coordinate, capability: .sessionsRead)
        guard response["session_id"]?.string == runtimeID,
              response["session_key"]?.string == storedID,
              response["messages_omitted"]?.boolean == true,
              response["messages"]?.array?.isEmpty == true,
              response["running"]?.boolean != nil,
              let info = response["info"]?.object,
              info["stored_session_id"]?.string == storedID,
              info["profile_name"]?.string == coordinate.profileID,
              let model = info["model"]?.string else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        let isBuilt = info["lazy"] == nil || info["lazy"] == .boolean(false)
        guard let provider = info["provider"]?.string ?? (isBuilt ? nil : ""),
              let reasoning = info["reasoning_effort"]?.string ?? (isBuilt ? nil : "") else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        try WorkspaceAuthority.validateIdentifier(model, maximumBytes: 256)
        if !provider.isEmpty { try WorkspaceAuthority.validateIdentifier(provider, maximumBytes: 128) }
        guard reasoning.isEmpty || ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].contains(reasoning) else {
            throw WorkspaceClientError.invalidResponse
        }
        let tier = try DirectHermesAdministrationCodec.optionalString(info["service_tier"], maximum: 64)
        return Proof(reasoning: reasoning, model: model, provider: provider,
                     fastMode: tier.map(FastMode.init), isRunning: response["running"]?.boolean == true)
    }

    private func perform(
        _ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
        sessionID: String, coordinate: WorkspaceSessionCoordinate, capability: WorkspaceCapability
    ) async throws -> [String: BighelpJSONValue] {
        try requireCurrent(sessionID: sessionID, coordinate: coordinate)
        let availability = workspace.capabilities.availability(for: capability, owner: owner, profileID: coordinate.profileID)
        guard availability.isAvailable else {
            if case .unavailable(let reason) = availability { throw WorkspaceClientError.unavailable(reason) }
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        let response = try await workspace.perform(operation, payload: payload, owner: owner)
        try requireCurrent(sessionID: sessionID, coordinate: coordinate)
        return response
    }

    private func coordinate(sessionID: String, agentID: String) throws -> WorkspaceSessionCoordinate {
        let identity = try DirectHermesSessionIdentity.decode(sessionID, owner: owner)
        guard DirectHermesSessionValidation.same(identity.profileID, agentID) else {
            throw WorkspaceClientError.invalidRequest
        }
        guard let coordinate = resolveSession(sessionID), coordinate.owner == owner,
              DirectHermesSessionValidation.same(coordinate.sessionID, sessionID),
              DirectHermesSessionValidation.same(coordinate.profileID, agentID),
              coordinate.runtimeSessionID != nil, coordinate.storedSessionID != nil else {
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        try requireCurrent(sessionID: sessionID, coordinate: coordinate)
        return coordinate
    }

    /// The chat's coordinate for listing models and levels: its live session when it has
    /// one, or just its identity before it does (not reattached yet, or still starting).
    private func listingCoordinate(sessionID: String, agentID: String) throws -> WorkspaceSessionCoordinate {
        if let live = try? coordinate(sessionID: sessionID, agentID: agentID) { return live }
        let identity = try DirectHermesSessionIdentity.decode(sessionID, owner: owner)
        guard DirectHermesSessionValidation.same(identity.profileID, agentID) else { throw WorkspaceClientError.invalidRequest }
        // Only this chat's own mapping: never another chat's session in its place.
        if let known = resolveSession(sessionID), known.owner == owner,
           DirectHermesSessionValidation.same(known.sessionID, sessionID),
           DirectHermesSessionValidation.same(known.profileID, agentID) {
            return known
        }
        return try WorkspaceSessionCoordinate(owner: owner, profileID: identity.profileID, sessionID: sessionID,
                                              storedSessionID: nil, runtimeSessionID: nil)
    }

    private func requireListingCurrent(sessionID: String, coordinate: WorkspaceSessionCoordinate) throws {
        guard coordinate.runtimeSessionID != nil else {
            try Task.checkCancellation()
            guard currentOwner() == owner, workspace.owner == owner else { throw WorkspaceClientError.ownerChanged }
            return
        }
        try requireCurrent(sessionID: sessionID, coordinate: coordinate)
    }

    /// A picker opened before the chat had a live session chooses on the one it has now.
    private func livePicker(_ picker: Picker) throws -> Picker {
        guard picker.coordinate.runtimeSessionID == nil else { return picker }
        guard let live = try? coordinate(sessionID: picker.key.sessionID, agentID: picker.coordinate.profileID) else {
            throw WorkspaceClientError.unavailable(.notConnected)
        }
        return Picker(id: picker.id, key: picker.key, generation: picker.generation, coordinate: live,
                      providers: picker.providers, expiresAt: picker.expiresAt)
    }

    /// Cancellation or a changed owner ends a picker; anything else falls back to the catalog.
    private static func endsPicker(_ error: any Error) -> Bool {
        error is CancellationError || (error as? WorkspaceClientError) == .ownerChanged
    }

    /// The agent's own catalog (`model.options` for its profile), for a chat with no live
    /// session or one whose check failed: the list always shows, the current model from
    /// what Hermes says for the profile.
    private func catalogState(_ coordinate: WorkspaceSessionCoordinate) async throws -> ModelState {
        try Task.checkCancellation()
        guard currentOwner() == owner, workspace.owner == owner else { throw WorkspaceClientError.ownerChanged }
        let availability = workspace.capabilities.availability(for: .modelsRead, owner: owner, profileID: coordinate.profileID)
        guard availability.isAvailable else {
            if case .unavailable(let reason) = availability { throw WorkspaceClientError.unavailable(reason) }
            throw WorkspaceClientError.unavailable(.unsupportedOperation)
        }
        let response = try await workspace.perform(.modelOptions, payload: ["profile": .string(coordinate.profileID)],
                                                   owner: owner)
        guard currentOwner() == owner, workspace.owner == owner else { throw WorkspaceClientError.ownerChanged }
        let providers = try DirectHermesAgentRuntimeDefaultsClient.decodeModelProviders(response)
        let model = response["model"]?.string ?? ""
        let provider = response["provider"]?.string ?? providers.first(where: \.isCurrent)?.id ?? ""
        return ModelState(provider: provider, runtimeProvider: provider, model: model, providers: providers,
                          fastMode: nil, isRunning: false)
    }

    private func requireCurrent(sessionID: String, coordinate: WorkspaceSessionCoordinate) throws {
        try Task.checkCancellation()
        guard currentOwner() == owner, workspace.owner == owner,
              coordinate.owner == owner,
              DirectHermesSessionValidation.same(coordinate.sessionID, sessionID),
              resolveSession(sessionID) == coordinate else {
            throw WorkspaceClientError.ownerChanged
        }
    }

    private func requireSelection(_ selection: BighelpLinkPickerSelection,
                                  coordinate: WorkspaceSessionCoordinate, generation: UUID) throws {
        try requireCurrent(sessionID: selection.sessionID, coordinate: coordinate)
        guard generations[Key(sessionID: selection.sessionID, kind: selection.kind)] == generation else {
            throw CancellationError()
        }
    }

    private func result(_ selection: BighelpLinkPickerSelection, status: BighelpLinkPickerResult.Status,
                        message: String) throws -> BighelpLinkPickerResult {
        let identity = try DirectHermesSessionIdentity.decode(selection.sessionID, owner: owner)
        let coordinate = try listingCoordinate(sessionID: selection.sessionID, agentID: identity.profileID)
        return try BighelpLinkPickerResult(
            pickerID: selection.pickerID, nativeCoordinate: NativeSessionRuntimePickerCoordinate(coordinate),
            kind: selection.kind, status: status, message: message, sentAt: Int(now().timeIntervalSince1970)
        )
    }

    private func prune() {
        let date = now()
        let expired = pickers.values.filter { $0.expiresAt <= date }
        for picker in expired {
            pickers[picker.id] = nil
            if generations[picker.key] == picker.generation { generations[picker.key] = nil }
        }
        for (id, pending) in confirmations where pending.expiresAt <= date {
            let key = Key(sessionID: pending.value.selection.sessionID, kind: pending.value.selection.kind)
            if generations[key] == pending.generation { generations[key] = nil }
            confirmations[id] = nil
        }
    }

    private static func validateToken(_ token: String, maximumBytes: Int) throws {
        try WorkspaceAuthority.validateIdentifier(token, maximumBytes: maximumBytes)
        guard !token.hasPrefix("-"),
              !token.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0)
                      || (0x2010...0x2015).contains($0.value)
                      || [0x2212, 0xFE58, 0xFE63, 0xFF0D].contains($0.value)
              }) else { throw WorkspaceClientError.invalidRequest }
    }
}

/// One bounded catalog per host authority; connection generations keep their own mutation proofs.
@MainActor final class DirectHermesModelCatalogCache {
    struct Entry {
        let providers: [BighelpLinkModelProvider]
        let fetchedAt: Date
    }
    var entries: [String: Entry] = [:]
    func clear() { entries.removeAll() }
}
