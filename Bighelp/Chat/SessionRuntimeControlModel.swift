import Foundation
import Observation

@MainActor
@Observable
final class SessionRuntimeControlModel {
    private static let modelPinLimitMessage =
        "You can pin up to 12 models. Unpin one before adding another."

    private(set) var modelPicker: BighelpLinkModelPicker?
    private(set) var reasoningPicker: BighelpLinkChoicePicker?
    private(set) var currentProvider: String?
    private(set) var currentModel: String?
    private(set) var currentReasoningValue: String?
    private(set) var fastMode: SessionFastMode?
    private(set) var isLoadingFastMode = false
    private(set) var fastModeError: String?
    private(set) var isLoadingModel = false
    private(set) var isLoadingReasoning = false
    private(set) var isApplyingSelection = false
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var pendingModelConfirmation: SessionRuntimeModelConfirmation?
    /// True while Hermes owns an in-flight turn for this session. Changing the
    /// model or reasoning effort mid-turn is not honoured by the runtime until
    /// the next turn, so the session must not accept a selection that would
    /// silently disagree with the answer being streamed.
    private(set) var isTurnActive = false

    let sessionID: String
    let agentID: String

    private let messaging: any BighelpLinkSessionControlMessaging
    private let modelHistory: RecentModelHistoryStore
    private let now: () -> Int
    private var modelLoadGeneration = 0
    private var reasoningLoadGeneration = 0
    private var selectionGeneration = 0
    private var modelLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private var reasoningLoadWaiters: [CheckedContinuation<Void, Never>] = []
    private var cachedModelProviders: [BighelpLinkModelProvider] = []
    private var modelObservedAt = Date.distantPast
    private var reasoningObservedAt = Date.distantPast
    private var fastModeObservedAt = Date.distantPast
    private var allowsAgentDefaults: Bool
    private var confirmationCompletion: (@MainActor () -> Void)?
    private var deferredSelection: BighelpLinkPickerSelection?
    private var deferredObservedAt = Date.distantPast

    init(
        sessionID: String,
        agentID: String,
        messaging: any BighelpLinkSessionControlMessaging,
        modelHistory: RecentModelHistoryStore = RecentModelHistoryStore(),
        allowsAgentDefaults: Bool = true,
        now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.messaging = messaging
        self.modelHistory = modelHistory
        self.allowsAgentDefaults = allowsAgentDefaults
        self.now = now
        cachedModelProviders = (messaging as? any SessionRuntimeControlSupporting)?.cachedModelProviders(agentID: agentID) ?? []
    }

    var modelDisplayName: String {
        guard let currentModel else {
            return allowsAgentDefaults ? "Agent default" : "Session model"
        }
        return ModelNameCatalogStore.shared.displayName(for: currentModel)
    }

    var selectionSupport: SessionRuntimeControlSupport {
        (messaging as? any SessionRuntimeControlSupporting)?
            .selectionSupport(sessionID: sessionID, agentID: agentID) ?? .available
    }

    var hasPendingSelection: Bool {
        pendingModelConfirmation != nil || deferredSelection != nil
    }

    var modelProviders: [BighelpLinkModelProvider] {
        modelPicker?.providers ?? cachedModelProviders
    }

    var quickModelChoices: [RecentModelChoice] {
        let pinnedChoices = pinnedModelChoices
        guard pinnedChoices.isEmpty else { return pinnedChoices }
        return modelHistory.choices(
            providers: modelProviders,
            currentProviderID: currentProvider,
            currentModelID: currentModel
        )
    }

    var pinnedModelChoices: [RecentModelChoice] {
        modelHistory.pinnedChoices(
            providers: modelProviders,
            currentProviderID: currentProvider,
            currentModelID: currentModel
        )
    }

    var hasPinnedModels: Bool {
        !pinnedModelChoices.isEmpty
    }

    func isModelPinned(providerID: String, modelID: String) -> Bool {
        modelHistory.isPinned(providerID: providerID, modelID: modelID)
    }

    /// Returns the model's resulting pin state. Reaching the twelve-item bound
    /// leaves every saved favorite intact and surfaces an actionable message.
    @discardableResult
    func toggleModelPin(providerID: String, modelID: String) -> Bool {
        let wasPinned = modelHistory.isPinned(providerID: providerID, modelID: modelID)
        let isPinned = modelHistory.togglePin(providerID: providerID, modelID: modelID)
        if !wasPinned, !isPinned, modelHistory.hasReachedPinCapacity {
            errorMessage = Self.modelPinLimitMessage
        } else if errorMessage == Self.modelPinLimitMessage {
            errorMessage = nil
        }
        return isPinned
    }

    var reasoningOptions: [RuntimeReasoningOption] {
        reasoningPicker?.choices.compactMap { choice in
            guard !["show", "hide"].contains(choice.value) else { return nil }
            return RuntimeReasoningOption(
                value: choice.value,
                label: Self.reasoningLabel(for: choice.value, fallback: choice.label),
                detail: selectionSupport.reasoningUnavailableReason ?? Self.reasoningDetail(for: choice.value),
                isCurrent: choice.value == currentReasoningValue
            )
        } ?? []
    }

    var currentReasoningLabel: String? {
        guard let currentReasoningValue else { return nil }
        return reasoningOptions.first(where: { $0.value == currentReasoningValue })?.label
            ?? Self.reasoningLabel(for: currentReasoningValue, fallback: currentReasoningValue)
    }

    var reasoningDisplayLabel: String {
        currentReasoningLabel ?? (isLoadingReasoning ? "Loading" : "Unknown")
    }

    /// Mirrors the chat's active-turn state into the runtime controls.
    ///
    /// Clearing the flag also clears the lockout message so a user who waited
    /// for the turn to finish is not left staring at a stale explanation.
    func setTurnActive(_ isActive: Bool) {
        guard isTurnActive != isActive else { return }
        isTurnActive = isActive
        if !isActive, errorMessage == ChatRuntimeSelectionLockout.message {
            errorMessage = nil
        }
    }

    /// Applies a session observation without replacing a newer accepted choice.
    func reconcileSessionRuntime(_ snapshot: SessionRuntimeSnapshot) {
        guard !isApplyingSelection, snapshot.observedAt >= modelObservedAt,
              !snapshot.model.isEmpty else { return }
        if currentModel != snapshot.model || currentProvider != snapshot.provider {
            modelPicker = nil
            fastMode = nil
        }
        modelObservedAt = snapshot.observedAt
        allowsAgentDefaults = false
        currentModel = snapshot.model
        currentProvider = snapshot.provider
        if let deferredSelection,
           snapshot.observedAt >= deferredObservedAt,
           deferredSelection.model == snapshot.model,
           let provider = snapshot.provider,
           deferredSelection.provider == provider {
            self.deferredSelection = nil
            statusMessage = nil
            modelHistory.record(providerID: provider, modelID: snapshot.model)
        }
    }

    /// Hermes reports the chat's reasoning in each `session.info`, including the
    /// one that starts a turn, so the level is known while the agent works even
    /// when the picker read (which waits for an idle chat) hasn't happened. An
    /// empty value is Hermes' automatic choice. Replayed info is older than any
    /// read or choice made here, so it only fills in an unknown level.
    func reconcileSessionReasoning(_ value: String, observedAt: Date) {
        let value = value.isEmpty ? "reset" : value
        guard !isApplyingSelection, observedAt >= reasoningObservedAt,
              Self.reasoningValues.contains(value) else { return }
        reasoningObservedAt = observedAt
        currentReasoningValue = value
    }

    /// Agent defaults describe new chats only, not restored session authority.
    func seedAgentDefaults(_ selection: AgentRuntimeSelection) {
        guard allowsAgentDefaults, modelPicker == nil else { return }

        if currentProvider == nil, currentModel == nil {
            currentProvider = selection.providerID.isEmpty ? nil : selection.providerID
            currentModel = selection.modelID.isEmpty ? nil : selection.modelID
        }

        if reasoningPicker == nil, currentReasoningValue == nil {
            // Hermes represents its automatic reasoning choice as `reset` in
            // the session picker, while agent defaults persist an empty value.
            currentReasoningValue = selection.reasoningEffort.isEmpty
                ? "reset"
                : selection.reasoningEffort
        }
    }

    func seedCachedModelProviders(_ providers: [BighelpLinkModelProvider]) {
        guard modelPicker == nil else { return }
        cachedModelProviders = providers
    }

    /// Loads both catalogs for a visible picker. Model discovery remains lazy.
    /// Restored chats separately read the reasoning choice through bighelp's
    /// correlated control channel, which suppresses textual command fallback.
    func loadPickersIfNeeded() async {
        async let modelLoad: Void = loadModelPickerIfNeeded()
        async let reasoningLoad: Void = loadReasoningPickerIfNeeded()
        _ = await (modelLoad, reasoningLoad)
    }

    /// For showing the chat's model and reasoning (context pop-up, Info, the
    /// avatar's profile). The model is already known from the session; this
    /// reads the reasoning once. Never mid-turn: the read touches the session
    /// (Hermes' session info keeps the level current then).
    func loadSummaryIfNeeded() async {
        guard !isTurnActive, currentReasoningValue == nil, reasoningPicker == nil else { return }
        await loadReasoningPickerIfNeeded()
    }

    func reconcileFastMode(_ mode: FastMode, observedAt: Date) {
        guard !isApplyingSelection, observedAt >= fastModeObservedAt, let current = fastMode else { return }
        fastModeObservedAt = observedAt
        fastMode = SessionFastMode(mode: mode, unavailableReason: current.unavailableReason)
    }

    func loadFastModeIfNeeded() async {
        guard fastMode == nil, !isLoadingFastMode, !isTurnActive, !isApplyingSelection else { return }
        guard let client = messaging as? any SessionFastModeControlling else {
            fastMode = SessionFastMode(mode: nil, unavailableReason: "Fast Mode is unavailable for this chat.")
            return
        }
        isLoadingFastMode = true
        fastModeError = nil
        let generation = selectionGeneration
        let startedAt = Date()
        defer { isLoadingFastMode = false }
        do {
            let value = try await client.loadFastMode(sessionID: sessionID, agentID: agentID)
            guard !Task.isCancelled, generation == selectionGeneration, startedAt >= fastModeObservedAt else { return }
            fastModeObservedAt = startedAt
            fastMode = value
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, generation == selectionGeneration else { return }
            fastModeError = "Couldn’t read Fast Mode. Try again."
        }
    }

    func selectFastMode(_ mode: FastMode) async {
        guard !isApplyingSelection, !isLoadingFastMode, !hasPendingSelection,
              let client = messaging as? any SessionFastModeControlling else { return }
        guard !isTurnActive else {
            fastModeError = ChatRuntimeSelectionLockout.message
            return
        }
        guard mode == .on || mode == .off, fastMode?.unavailableReason == nil, fastMode != nil else { return }
        selectionGeneration += 1
        let generation = selectionGeneration
        isApplyingSelection = true
        fastModeError = nil
        defer { if generation == selectionGeneration { isApplyingSelection = false } }
        do {
            let verified = try await client.setFastMode(mode, sessionID: sessionID, agentID: agentID)
            guard !Task.isCancelled, generation == selectionGeneration else { return }
            fastModeObservedAt = Date()
            fastMode = verified
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, generation == selectionGeneration else { return }
            // A lost acknowledgement is not proof that nothing was saved.
            // Read it back; if that fails, show Unknown, never a guessed value.
            let readback = try? await client.loadFastMode(sessionID: sessionID, agentID: agentID)
            guard !Task.isCancelled, generation == selectionGeneration else { return }
            fastModeObservedAt = Date()
            fastMode = readback
            fastModeError = "The Fast Mode change wasn’t confirmed. Check the current value before trying again."
        }
    }

    func loadModelPickerIfNeeded() async {
        guard modelPicker == nil else { return }
        await loadModelPicker()
    }

    func loadReasoningPickerIfNeeded() async {
        guard reasoningPicker == nil else { return }
        await loadReasoningPicker()
    }

    func loadModelPicker() async {
        if isLoadingModel {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                modelLoadWaiters.append(continuation)
            }
            return
        }
        modelLoadGeneration += 1
        let readStartedAt = Date()
        let generation = modelLoadGeneration
        isLoadingModel = true
        errorMessage = nil
        defer {
            if generation == modelLoadGeneration { isLoadingModel = false }
            let waiters = modelLoadWaiters
            modelLoadWaiters.removeAll(keepingCapacity: true)
            waiters.forEach { $0.resume() }
        }
        do {
            let response = try await BighelpLinkTransientRetry.perform {
                try await self.messaging.openPicker(
                    BighelpLinkPickerOpenRequest(
                        requestID: Self.requestID(),
                        sessionID: self.sessionID,
                        agentID: self.agentID,
                        kind: .model,
                        sentAt: self.now()
                    )
                )
            }
            guard generation == modelLoadGeneration else { return }
            guard let picker = response.model, picker.sessionID == sessionID else {
                throw BighelpLinkLiveSocketError.invalidPickerResponse
            }
            modelPicker = picker
            guard readStartedAt >= modelObservedAt else { return }
            modelObservedAt = readStartedAt
            allowsAgentDefaults = false
            currentProvider = picker.currentProvider
            currentModel = picker.currentModel
            if readStartedAt >= deferredObservedAt {
                deferredSelection = nil
                statusMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == modelLoadGeneration else { return }
            errorMessage = (error as? WorkspaceClientError)?.localizedDescription
                ?? "Couldn’t load models. Check your Hermes connection and try again."
        }
    }

    func loadReasoningPicker() async {
        if isLoadingReasoning {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                reasoningLoadWaiters.append(continuation)
            }
            return
        }
        reasoningLoadGeneration += 1
        let readStartedAt = Date()
        let generation = reasoningLoadGeneration
        isLoadingReasoning = true
        errorMessage = nil
        defer {
            if generation == reasoningLoadGeneration { isLoadingReasoning = false }
            let waiters = reasoningLoadWaiters
            reasoningLoadWaiters.removeAll(keepingCapacity: true)
            waiters.forEach { $0.resume() }
        }
        do {
            let response = try await BighelpLinkTransientRetry.perform {
                try await self.messaging.openPicker(
                    BighelpLinkPickerOpenRequest(
                        requestID: Self.requestID(),
                        sessionID: self.sessionID,
                        agentID: self.agentID,
                        kind: .reasoning,
                        sentAt: self.now()
                    )
                )
            }
            guard generation == reasoningLoadGeneration else { return }
            guard let picker = response.choice,
                  picker.sessionID == sessionID,
                  picker.kind == .reasoning else {
                throw BighelpLinkLiveSocketError.invalidPickerResponse
            }
            reasoningPicker = picker
            let currentChoices = picker.choices.filter(\.isCurrent)
            guard readStartedAt >= reasoningObservedAt,
                  currentChoices.count == 1,
                  let current = currentChoices.first?.value,
                  Self.reasoningValues.contains(current)
            else { return }
            reasoningObservedAt = readStartedAt
            currentReasoningValue = current
        } catch is CancellationError {
            return
        } catch {
            guard generation == reasoningLoadGeneration else { return }
            errorMessage = (error as? WorkspaceClientError)?.localizedDescription
                ?? "Couldn’t load reasoning choices. Check your Hermes connection and try again."
        }
    }

    func selectModel(providerID: String, modelID: String) async {
        guard !isApplyingSelection else { return }
        if let reason = selectionSupport.modelUnavailableReason {
            errorMessage = reason
            return
        }
        if pendingModelConfirmation != nil {
            cancelModelConfirmation()
            modelPicker = nil
        }
        deferredSelection = nil
        statusMessage = nil
        guard !isTurnActive else {
            errorMessage = ChatRuntimeSelectionLockout.message
            return
        }
        if modelPicker == nil {
            await loadModelPicker()
        }
        guard
            let picker = modelPicker,
            picker.sessionID == sessionID,
            picker.providers.contains(where: { $0.id == providerID && $0.models.contains(modelID) })
        else {
            errorMessage = "That model is no longer available. Reopen the picker."
            return
        }
        await apply(
            kind: .model,
            selection: try? BighelpLinkPickerSelection(
                pickerID: picker.pickerID,
                sessionID: sessionID,
                kind: .model,
                provider: providerID,
                model: modelID,
                value: nil,
                sentAt: now(),
                nativeCoordinate: picker.nativeCoordinate
            )
        ) { [weak self] in
            self?.modelObservedAt = Date()
            self?.allowsAgentDefaults = false
            self?.currentProvider = providerID
            self?.currentModel = modelID
            self?.fastMode = nil
            self?.modelHistory.record(providerID: providerID, modelID: modelID)
        }
    }

    func selectReasoning(value: String) async {
        guard !isApplyingSelection else { return }
        if let reason = selectionSupport.reasoningUnavailableReason {
            errorMessage = reason
            return
        }
        guard !isTurnActive else {
            errorMessage = ChatRuntimeSelectionLockout.message
            return
        }
        guard
            let picker = reasoningPicker,
            picker.sessionID == sessionID,
            reasoningOptions.contains(where: { $0.value == value })
        else {
            errorMessage = "That reasoning choice is no longer available. Reopen the picker."
            return
        }
        await apply(
            kind: .reasoning,
            selection: try? BighelpLinkPickerSelection(
                pickerID: picker.pickerID,
                sessionID: sessionID,
                kind: .reasoning,
                provider: nil,
                model: nil,
                value: value,
                sentAt: now(),
                nativeCoordinate: picker.nativeCoordinate
            )
        ) { [weak self] in
            self?.reasoningObservedAt = Date()
            self?.currentReasoningValue = value
        }
    }

    func apply(_ draft: SessionRuntimeSelectionDraft) async {
        guard !isTurnActive else {
            errorMessage = ChatRuntimeSelectionLockout.message
            return
        }
        let modelChanged = draft.providerID != draft.originalProviderID
            || draft.modelID != draft.originalModelID
        let reasoningChanged = draft.reasoningValue != draft.originalReasoningValue

        if modelChanged, let providerID = draft.providerID, let modelID = draft.modelID {
            await selectModel(providerID: providerID, modelID: modelID)
            guard errorMessage == nil, !hasPendingSelection else { return }
        }

        if reasoningChanged, let reasoningValue = draft.reasoningValue {
            await selectReasoning(value: reasoningValue)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func cancelModelConfirmation(expected: SessionRuntimeModelConfirmation? = nil) {
        if let expected, pendingModelConfirmation != expected { return }
        if let pendingModelConfirmation,
           let client = messaging as? any SessionRuntimeControlConfirming {
            client.cancelPickerConfirmation(pendingModelConfirmation)
        }
        pendingModelConfirmation = nil
        confirmationCompletion = nil
        statusMessage = nil
    }

    @discardableResult
    func confirmModelSelection(_ expected: SessionRuntimeModelConfirmation) async -> Bool {
        guard !isApplyingSelection else { return false }
        guard let confirmation = pendingModelConfirmation,
              confirmation == expected,
              let completion = confirmationCompletion,
              let client = messaging as? any SessionRuntimeControlConfirming else {
            errorMessage = "This model confirmation is no longer available. Reopen the picker."
            return false
        }
        pendingModelConfirmation = nil
        confirmationCompletion = nil
        selectionGeneration += 1
        let generation = selectionGeneration
        isApplyingSelection = true
        errorMessage = nil
        statusMessage = nil
        defer { if generation == selectionGeneration { isApplyingSelection = false } }
        do {
            let result = try await client.confirmPicker(confirmation)
            guard generation == selectionGeneration else { return false }
            try validate(result, selection: confirmation.selection)
            guard result.status == .completed else {
                errorMessage = result.message
                return false
            }
            completion()
            invalidateNativeModelPicker()
            return true
        } catch let deferred as SessionRuntimeModelDeferred {
            guard generation == selectionGeneration else { return false }
            guard deferred.selection == confirmation.selection else {
                errorMessage = "Hermes returned a different model selection."
                return false
            }
            acceptDeferred(deferred)
            return false
        } catch is CancellationError {
            return false
        } catch {
            guard generation == selectionGeneration else { return false }
            errorMessage = (error as? WorkspaceClientError)?.localizedDescription
                ?? "The model change could not be confirmed. Reopen the picker to check the current model."
            return false
        }
    }

    /// Keeps a failed agent-default hydration visible to the session without
    /// replacing any existing session selection. The picker clears this
    /// recoverable message when the user asks it to load again.
    func markAgentDefaultsLoadFailed() {
        errorMessage = "Couldn’t load agent defaults. Check your Hermes connection and try again."
    }

    private func apply(
        kind: BighelpLinkPickerKind,
        selection: BighelpLinkPickerSelection?,
        onCompleted: @escaping @MainActor () -> Void
    ) async {
        guard let selection else {
            errorMessage = "That choice could not be sent securely."
            return
        }
        selectionGeneration += 1
        let generation = selectionGeneration
        isApplyingSelection = true
        errorMessage = nil
        defer {
            if generation == selectionGeneration { isApplyingSelection = false }
        }
        var activeSelection = selection
        do {
            var result = try await messaging.selectPicker(activeSelection)
            guard generation == selectionGeneration else { return }
            try validate(result, selection: activeSelection)
            if result.status == .expired {
                guard let refreshedSelection = await refreshedSelection(
                    original: activeSelection, kind: kind, generation: generation
                ) else {
                    if errorMessage == nil {
                        errorMessage = kind == .model
                            ? "That model is no longer available. Reopen the picker."
                            : "That reasoning choice is no longer available. Reopen the picker."
                    }
                    return
                }
                activeSelection = refreshedSelection
                result = try await messaging.selectPicker(activeSelection)
                guard generation == selectionGeneration else { return }
                try validate(result, selection: activeSelection)
            }
            switch result.status {
            case .completed:
                onCompleted()
                statusMessage = nil
                if kind == .model {
                    invalidateNativeModelPicker()
                } else {
                    reasoningPicker = nil
                }
            case .failed:
                errorMessage = kind == .model
                    ? "Hermes could not apply that model."
                    : "Hermes could not apply that reasoning choice."
            case .expired:
                if kind == .model {
                    modelPicker = nil
                } else {
                    reasoningPicker = nil
                }
                errorMessage = kind == .model
                    ? "That model choice expired. Reopen the picker."
                    : "That reasoning choice expired. Reopen the picker."
            }
        } catch let required as SessionRuntimeModelConfirmationRequired {
            guard generation == selectionGeneration else { return }
            guard required.confirmation.selection == activeSelection,
                  required.confirmation.coordinate.profileID == agentID else {
                errorMessage = "Hermes returned a different model confirmation."
                return
            }
            pendingModelConfirmation = required.confirmation
            confirmationCompletion = onCompleted
            statusMessage = "Review the host's confirmation before applying this model."
            invalidateNativeModelPicker()
        } catch let deferred as SessionRuntimeModelDeferred {
            guard generation == selectionGeneration else { return }
            guard deferred.selection == activeSelection else {
                errorMessage = "Hermes returned a different model selection."
                return
            }
            acceptDeferred(deferred)
        } catch is CancellationError {
            return
        } catch {
            guard generation == selectionGeneration else { return }
            errorMessage = (error as? WorkspaceClientError)?.localizedDescription
                ?? "The session setting could not be updated. Try again."
        }
    }

    private func refreshedSelection(
        original: BighelpLinkPickerSelection,
        kind: BighelpLinkPickerKind,
        generation: Int
    ) async -> BighelpLinkPickerSelection? {
        guard generation == selectionGeneration, original.sessionID == sessionID else { return nil }
        switch kind {
        case .model:
            guard let provider = original.provider, let model = original.model else { return nil }
            modelPicker = nil
            await loadModelPicker()
            guard generation == selectionGeneration,
                  let picker = modelPicker,
                  picker.sessionID == sessionID,
                  picker.providers.contains(where: { $0.id == provider && $0.models.contains(model) }) else {
                return nil
            }
            return try? BighelpLinkPickerSelection(
                pickerID: picker.pickerID,
                sessionID: sessionID,
                kind: .model,
                provider: provider,
                model: model,
                value: nil,
                sentAt: now(),
                nativeCoordinate: picker.nativeCoordinate
            )
        case .reasoning:
            guard let value = original.value else { return nil }
            reasoningPicker = nil
            await loadReasoningPicker()
            guard generation == selectionGeneration,
                  let picker = reasoningPicker,
                  picker.sessionID == sessionID,
                  picker.kind == .reasoning,
                  picker.choices.contains(where: {
                      $0.value == value && !["show", "hide"].contains($0.value)
                  }) else {
                return nil
            }
            return try? BighelpLinkPickerSelection(
                pickerID: picker.pickerID,
                sessionID: sessionID,
                kind: .reasoning,
                provider: nil,
                model: nil,
                value: value,
                sentAt: now(),
                nativeCoordinate: picker.nativeCoordinate
            )
        }
    }

    private func validate(_ result: BighelpLinkPickerResult, selection: BighelpLinkPickerSelection) throws {
        guard result.pickerID == selection.pickerID, result.sessionID == sessionID,
              result.kind == selection.kind else { throw BighelpLinkLiveSocketError.invalidPickerResponse }
    }

    private func invalidateNativeModelPicker() {
        guard messaging is any SessionRuntimeControlSupporting else { return }
        cachedModelProviders = modelProviders
        modelPicker = nil
    }

    private func acceptDeferred(_ deferred: SessionRuntimeModelDeferred) {
        deferredSelection = deferred.selection
        deferredObservedAt = Date()
        statusMessage = deferred.message
        errorMessage = nil
        invalidateNativeModelPicker()
    }

    private static let reasoningValues: Set<String> = [
        "reset", "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"
    ]

    private static func requestID() -> String {
        "picker_request_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private static func reasoningLabel(for value: String, fallback: String) -> String {
        switch value {
        case "reset": "Auto"
        case "none": "Off"
        case "minimal": "Minimal"
        case "low": "Low"
        case "medium": "Medium"
        case "high": "High"
        case "xhigh": "X-High"
        case "max": "Max"
        case "ultra": "Ultra"
        default: fallback
        }
    }

    private static func reasoningDetail(for value: String) -> String {
        switch value {
        case "reset": "Uses the agent’s configured default"
        case "none": "Fastest responses without extended reasoning"
        case "minimal": "A quick check before answering"
        case "low": "Faster responses with light reasoning"
        case "medium": "Balanced for most tasks"
        case "high": "More deliberate reasoning"
        case "xhigh": "Thorough work for difficult tasks"
        case "max": "Deep reasoning for complex work"
        case "ultra": "Maximum depth for the hardest problems"
        default: "Hermes reasoning setting"
        }
    }
}
