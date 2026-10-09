import Observation
import SwiftUI

enum ModelAdministrationAssignmentTarget: Identifiable, Equatable {
    case main
    case auxiliary(String)

    var id: String {
        switch self {
        case .main: "main"
        case .auxiliary(let task): "auxiliary:\(task)"
        }
    }

    var title: String {
        switch self {
        case .main: "Default model"
        case .auxiliary(let task): task.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

@MainActor @Observable
final class ModelAdministrationStore {
    let hostName: String
    let profileID: String

    private(set) var snapshot: DirectHermesModelAdministrationSnapshot?
    private(set) var isLoading = false
    private(set) var operationTitle: String?
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var pendingConfirmation: DirectHermesModelAssignmentConfirmation?
    private(set) var isRetired = false

    @ObservationIgnored private let client: DirectHermesModelAdministrationClient
    @ObservationIgnored private var generation = UUID()

    init(hostName: String, profileID: String, client: DirectHermesModelAdministrationClient) {
        self.hostName = hostName
        self.profileID = profileID
        self.client = client
    }

    var ownsScope: Bool { !isRetired && client.ownsScope }
    var isBusy: Bool { isLoading || operationTitle != nil }

    func load(refreshModels: Bool = false) async {
        guard ownsScope, !isBusy else { return }
        let request = UUID()
        generation = request
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == request { isLoading = false } }
        do {
            let value = try await client.loadSnapshot(
                profileID: profileID, refreshModels: refreshModels
            )
            guard ownsScope, generation == request, !Task.isCancelled else { return }
            snapshot = value
        } catch is CancellationError {
        } catch {
            guard ownsScope, generation == request else { return }
            errorMessage = Self.message(error)
        }
    }

    func refresh() async {
        isLoading = false
        await load(refreshModels: true)
    }

    func retire() {
        isRetired = true
        generation = UUID()
        snapshot = nil
        pendingConfirmation = nil
        isLoading = false
        operationTitle = nil
        errorMessage = nil
        successMessage = nil
    }

    func assign(providerID: String, modelID: String, target: ModelAdministrationAssignmentTarget) async -> Bool {
        let scope: DirectHermesModelAssignmentScope
        switch target {
        case .main: scope = .main
        case .auxiliary(let task): scope = .auxiliary(task: task)
        }
        let request = DirectHermesModelAssignmentRequest(
            scope: scope, providerID: providerID, modelID: modelID,
            reasoningEffort: nil, confirmExpensiveModel: false
        )
        guard begin("Saving model assignment") else { return false }
        defer { finish() }
        do {
            let outcome = try await client.setModel(profileID: profileID, request: request)
            guard ownsScope else { return false }
            switch outcome {
            case .applied:
                try await reloadAfterMutation(message: "Hermes confirmed the model assignment for future sessions.")
                return true
            case .confirmationRequired(let confirmation):
                pendingConfirmation = confirmation
                return false
            }
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func confirmAssignment() async -> Bool {
        guard let confirmation = pendingConfirmation, begin("Confirming model assignment") else { return false }
        pendingConfirmation = nil
        defer { finish() }
        do {
            try await client.confirmModelAssignment(profileID: profileID, confirmation: confirmation)
            guard ownsScope else { return false }
            try await reloadAfterMutation(message: "Hermes confirmed the reviewed model assignment.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    func cancelAssignmentConfirmation() { pendingConfirmation = nil }

    func clearError() { errorMessage = nil }

    func resetAuxiliary() async {
        let request = DirectHermesModelAssignmentRequest(
            scope: .resetAuxiliary, providerID: "auto", modelID: "",
            reasoningEffort: nil, confirmExpensiveModel: false
        )
        guard begin("Resetting auxiliary models") else { return }
        defer { finish() }
        do {
            let outcome = try await client.setModel(profileID: profileID, request: request)
            guard outcome == .applied, ownsScope else { throw WorkspaceClientError.outcomeUnknown }
            try await reloadAfterMutation(message: "Hermes reset every auxiliary task to automatic routing.")
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    func saveMoA(_ configuration: DirectHermesMoAConfiguration) async -> Bool {
        guard begin("Saving Mixture of Agents") else { return false }
        defer { finish() }
        do {
            try await client.saveMoAConfiguration(profileID: profileID, configuration: configuration)
            guard ownsScope else { return false }
            try await reloadAfterMutation(message: "Hermes confirmed the complete Mixture of Agents configuration.")
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard ownsScope else { return false }
            errorMessage = Self.message(error)
            return false
        }
    }

    private func reloadAfterMutation(message: String) async throws {
        let value = try await client.loadSnapshot(profileID: profileID)
        guard ownsScope else { throw CancellationError() }
        snapshot = value
        errorMessage = nil
        successMessage = message
    }

    private func begin(_ title: String) -> Bool {
        guard ownsScope, !isBusy else { return false }
        operationTitle = title
        errorMessage = nil
        successMessage = nil
        return true
    }

    private func finish() { operationTitle = nil }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "Hermes could not confirm this model operation. Refresh before trying it again."
    }
}

/// An agent on the host whose default model the page can show and change.
/// Default model › Reasoning: how hard agents think before answering in new chats. Every agent by
/// default, or just the one picked above. Hermes keeps it per agent (`agent.reasoning_effort`), so
/// "every agent" saves it on each, through the same verified path as Agent Studio.
@MainActor @Observable
final class ModelReasoningDefaults {
    private(set) var current: String?
    private(set) var isSaving = false
    private(set) var message: String?
    var appliesToEveryAgent = true

    @ObservationIgnored private let client: any AgentRuntimeDefaultsClient

    init(client: any AgentRuntimeDefaultsClient) { self.client = client }

    func load(agentID: String) async {
        current = try? await client.loadDefaults(agentID: agentID).mainChats.reasoningEffort
    }

    /// Returns how many agents now use it.
    @discardableResult
    func set(_ value: String, agentID: String, every agentIDs: [String]) async -> Int {
        guard !isSaving else { return 0 }
        isSaving = true
        defer { isSaving = false }
        let targets = appliesToEveryAgent && !agentIDs.isEmpty ? agentIDs : [agentID]
        var saved = 0
        for target in targets {
            do {
                var defaults = try await client.loadDefaults(agentID: target)
                if defaults.mainChats.reasoningEffort != value {
                    defaults.mainChats.reasoningEffort = value
                    try await client.saveDefaults(defaults, agentID: target)
                }
                saved += 1
            } catch {}
        }
        await load(agentID: agentID)
        let title = AgentReasoningOption.all.first { $0.value == value }?.title ?? value
        message = saved == targets.count
            ? (targets.count == 1 ? "Reasoning is \(title) for new chats." : "Reasoning is \(title) for every agent's new chats.")
            : "Saved for \(saved) of \(targets.count) agents. Try again for the rest."
        return saved
    }
}

struct ModelAdministrationAgent: Identifiable, Equatable {
    let id: String
    let name: String
    let imageURL: URL?
}

@MainActor
struct ModelAdministrationView: View {
    @State private var store: ModelAdministrationStore
    @State private var assignmentTarget: ModelAdministrationAssignmentTarget?
    @State private var confirmAuxiliaryReset = false
    @State private var isAgentRailOpen = false
    private let client: DirectHermesModelAdministrationClient
    /// The agent the page opened on; the agent runtime defaults belong to it.
    private let openedProfileID: String
    let agents: [ModelAdministrationAgent]
    let onOpenProviderAccounts: (() -> Void)?
    let onOpenAgentDefaults: (() -> Void)?
    @State private var reasoning: ModelReasoningDefaults?
    @State private var fastModeDefaults: AgentRuntimeDefaultsEditorModel?
    private let runtimeDefaults: (any AgentRuntimeDefaultsClient)?

    init(
        hostName: String,
        profileID: String,
        client: DirectHermesModelAdministrationClient,
        agents: [ModelAdministrationAgent] = [],
        reasoningDefaults: (any AgentRuntimeDefaultsClient)? = nil,
        onOpenProviderAccounts: (() -> Void)? = nil,
        onOpenAgentDefaults: (() -> Void)? = nil
    ) {
        runtimeDefaults = reasoningDefaults
        _fastModeDefaults = State(initialValue: reasoningDefaults.map {
            AgentRuntimeDefaultsEditorModel(agentID: profileID, client: $0)
        })
        _reasoning = State(initialValue: reasoningDefaults.map(ModelReasoningDefaults.init(client:)))
        _store = State(initialValue: ModelAdministrationStore(
            hostName: hostName, profileID: profileID, client: client
        ))
        self.client = client
        openedProfileID = profileID
        self.agents = agents
        self.onOpenProviderAccounts = onOpenProviderAccounts
        self.onOpenAgentDefaults = onOpenAgentDefaults
    }

    private var agentName: String {
        agents.first(where: { $0.id == store.profileID })?.name ?? store.profileID
    }

    /// Each agent has its own default; the page shows the chosen one's.
    private func showAgent(_ id: String) {
        guard id != store.profileID, !store.isBusy, fastModeDefaults?.isSaving != true else { return }
        assignmentTarget = nil
        store.retire()
        store = ModelAdministrationStore(hostName: store.hostName, profileID: id, client: client)
        fastModeDefaults = runtimeDefaults.map { AgentRuntimeDefaultsEditorModel(agentID: id, client: $0) }
    }

    var body: some View {
        Group {
            if store.ownsScope {
                List {
                    scopeSection
                    statusSections
                    if let snapshot = store.snapshot {
                        mainModelSection(snapshot)
                        if let fastModeDefaults { fastModeSection(fastModeDefaults) }
                        if let reasoning { reasoningSection(reasoning) }
                        if let runtime = snapshot.runtime { runtimeSection(runtime) }
                        modelCapabilitiesSection(snapshot)
                        if let auxiliary = snapshot.auxiliary { auxiliarySection(auxiliary) }
                        if let moa = snapshot.moa { moaSection(moa) }
                        if let analytics = snapshot.analytics { analyticsSection(analytics) }
                        SkippedPartsNote(parts: snapshot.skippedParts)
                    }
                }
                .listStyle(.insetGrouped)
                .disabled(fastModeDefaults?.isSaving == true)
                .refreshable { await store.refresh() }
            } else {
                ContentUnavailableView(
                    "Models unavailable", systemImage: "cpu",
                    description: Text("The selected host changed. Reopen Models from the current workspace.")
                )
            }
        }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.profileID) {
            async let reasoningLoad: Void? = reasoning?.load(agentID: store.profileID)
            if store.snapshot == nil { await store.load() }
            _ = await reasoningLoad
        }
        .task(id: store.snapshot?.info) {
            if store.snapshot != nil { await fastModeDefaults?.load() }
        }
        .bighelpSheet(item: $assignmentTarget) { target in
            ModelAdministrationPicker(store: store, target: target, agentName: agentName) { assignmentTarget = nil }
                .bighelpSheetSize(.standard)
        }
        .confirmationDialog("Reset every auxiliary assignment?", isPresented: $confirmAuxiliaryReset, titleVisibility: .visible) {
            Button("Reset to Automatic", role: .destructive) { Task { await store.resetAuxiliary() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will explicitly set every auxiliary task to automatic routing. Main and MoA assignments are not changed.")
        }
        .accessibilityIdentifier("models.administration")
    }

    private var scopeSection: some View {
        Section {
            if agents.count > 1 {
                agentPicker
            } else {
                LabeledContent("Agent", value: agentName)
            }
            LabeledContent("Host", value: store.hostName)
        } header: {
            Text("Applies to")
        } footer: {
            Text("Assignments affect future sessions. Change a running chat from its model control.")
        }
    }

    @ViewBuilder
    private var statusSections: some View {
        if store.isLoading || store.operationTitle != nil {
            Section { ProgressView(store.operationTitle ?? "Loading model administration") }
        }
        if let error = store.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                Button("Refresh") { Task { await store.load() } }.disabled(store.isBusy)
            }
            .accessibilityIdentifier("models.error")
        }
        if let success = store.successMessage {
            Section { Label(success, systemImage: "checkmark.circle") }
                .accessibilityIdentifier("models.confirmed")
        }
    }

    /// The chosen agent; tap to see every agent's card and pick another.
    @ViewBuilder
    private var agentPicker: some View {
        Button {
            withAnimation(.snappy) { isAgentRailOpen.toggle() }
        } label: {
            HStack(spacing: BighelpTokens.space12) {
                Text("Agent")
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: BighelpTokens.space8)
                if let agent = agents.first(where: { $0.id == store.profileID }) {
                    AvatarView(stableID: agent.id, displayName: agent.name, imageURL: agent.imageURL, size: 28)
                        .accessibilityHidden(true)
                }
                Text(agentName)
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .rotationEffect(.degrees(isAgentRailOpen ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityLabel("Agent")
        .accessibilityValue(agentName)
        .accessibilityHint(isAgentRailOpen ? "Hides the agents" : "Shows every agent to pick from")
        .accessibilityIdentifier("models.agent")
        if isAgentRailOpen {
            BighelpCardRail {
                ForEach(agents) { agent in
                    agentCard(agent)
                }
            }
            .padding(.vertical, BighelpTokens.space4)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("models.agents")
        }
    }

    private func agentCard(_ agent: ModelAdministrationAgent) -> some View {
        let isSelected = agent.id == store.profileID
        return Button { showAgent(agent.id) } label: {
            BighelpRailCard(isSelected: isSelected, width: 104, alignment: .top) { ink, _ in
                VStack(spacing: BighelpTokens.space8) {
                    AvatarView(stableID: agent.id, displayName: agent.name, imageURL: agent.imageURL, size: 48)
                    Text(agent.name)
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .bighelpPlainButtonStyle()
        .disabled(store.isBusy && !isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(agent.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("models.agent.\(agent.id)")
    }

    private func runtimeSection(_ runtime: DirectHermesRuntimeStatus) -> some View {
        Section("Readiness") {
            LabeledContent("New sessions", value: runtime.isUsable ? "Ready" : "Needs attention")
            if let source = runtime.source { LabeledContent("Credential source", value: source) }
            if let message = runtime.errorMessage { Text(message).font(.bighelp(.footnote)).foregroundStyle(.secondary) }
            if let onOpenProviderAccounts {
                Button("Open Provider Keys", action: onOpenProviderAccounts)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("models.open-provider-keys")
            }
        }
    }

    private func mainModelSection(_ snapshot: DirectHermesModelAdministrationSnapshot) -> some View {
        Section("New chats") {
            BighelpModelChoiceRow(
                providerID: snapshot.info.providerID,
                providerName: providerName(snapshot.info.providerID, in: snapshot),
                modelID: snapshot.info.modelID,
                emptyTitle: "Not configured",
                isEnabled: !store.isBusy && !snapshot.providers.isEmpty
            ) {
                assignmentTarget = .main
            }
            .accessibilityLabel("Choose \(agentName)'s default model")
            .accessibilityValue(snapshot.info.modelID.isEmpty ? "Not configured"
                                : ModelNameCatalogStore.shared.displayName(for: snapshot.info.modelID))
            .accessibilityIdentifier("models.main")
            if snapshot.info.effectiveContextLength > 0 {
                LabeledContent("Context", value: snapshot.info.effectiveContextLength.formatted())
            }

            if let recommendation = snapshot.recommendation, !recommendation.modelID.isEmpty,
               recommendation.modelID != snapshot.info.modelID {
                Text("Recommended for \(recommendation.providerID): \(recommendation.modelID)")
                    .font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
            if let onOpenAgentDefaults, store.profileID == openedProfileID {
                Button("Agent runtime defaults", action: onOpenAgentDefaults)
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
        }
    }

    private func fastModeSection(_ defaults: AgentRuntimeDefaultsEditorModel) -> some View {
        Section {
            AgentFastModeRow(model: defaults, allowsEdits: !store.isBusy && reasoning?.isSaving != true,
                             saveImmediately: true)
            if let error = defaults.errorMessage {
                Text(error).foregroundStyle(theme.danger).font(.bighelp(.footnote))
                Button("Try again") { Task { await defaults.load() } }
            }
        } header: {
            Text("Fast Mode")
        } footer: {
            Text("Default for new chats with \(agentName). Existing chat overrides stay unchanged. Fast Mode may cost more.")
        }
    }

    private func reasoningSection(_ reasoning: ModelReasoningDefaults) -> some View {
        Section {
            Picker(selection: Binding(
                get: { reasoning.current ?? "" },
                set: { value in
                    Task { await reasoning.set(value, agentID: store.profileID, every: agents.map(\.id)) }
                })) {
                ForEach(AgentReasoningOption.all) { option in
                    Text(option.title).tag(option.value)
                }
            } label: {
                Text("Reasoning")
            }
            .disabled(reasoning.current == nil || reasoning.isSaving)
            .accessibilityIdentifier("models.reasoning")
            if agents.count > 1 {
                Picker("Applies to", selection: Binding(get: { reasoning.appliesToEveryAgent },
                                                        set: { reasoning.appliesToEveryAgent = $0 })) {
                    Text("Every agent").tag(true)
                    Text(agentName).tag(false)
                }
                .accessibilityIdentifier("models.reasoning.scope")
            }
            if reasoning.isSaving {
                ProgressView("Saving…")
            } else if let message = reasoning.message {
                Label(message, systemImage: "checkmark.circle")
                    .font(.bighelp(.footnote))
                    .accessibilityIdentifier("models.reasoning.saved")
            }
        } header: {
            Text("Reasoning")
        } footer: {
            Text("How hard agents think before answering in new chats. A running chat changes from its own model control.")
        }
    }

    @ViewBuilder
    private func modelCapabilitiesSection(_ snapshot: DirectHermesModelAdministrationSnapshot) -> some View {
        let caps = snapshot.info.capabilities
        if caps.supportsTools != nil || caps.supportsVision != nil || caps.supportsReasoning != nil {
            Section("Advanced · Capabilities") {
                if let tools = caps.supportsTools { LabeledContent("Tools", value: tools ? "Supported" : "Not reported") }
                if let vision = caps.supportsVision { LabeledContent("Vision", value: vision ? "Supported" : "Not reported") }
                if let reasoning = caps.supportsReasoning { LabeledContent("Reasoning", value: reasoning ? "Supported" : "Not reported") }
            }
        }
    }

    private func auxiliarySection(_ auxiliary: DirectHermesAuxiliaryModels) -> some View {
        Section {
            ForEach(auxiliary.tasks) { task in
                let isAutomatic = task.providerID == "auto"
                BighelpModelChoiceRow(
                    label: ModelAdministrationAssignmentTarget.auxiliary(task.task).title,
                    providerID: isAutomatic ? "" : task.providerID,
                    providerName: isAutomatic ? "Hermes" : providerName(task.providerID, in: store.snapshot),
                    modelID: isAutomatic ? "" : task.modelID,
                    emptyTitle: "Automatic",
                    detail: task.isLocalEndpoint ? "Local endpoint" : nil,
                    isEnabled: !store.isBusy
                ) {
                    assignmentTarget = .auxiliary(task.task)
                }
                .accessibilityIdentifier("models.auxiliary.\(task.task)")
            }
            Button("Reset all auxiliary tasks", role: .destructive) { confirmAuxiliaryReset = true }
                .disabled(store.isBusy)
        } header: { Text("Advanced · Auxiliary tasks") } footer: {
            Text("Reset is explicit; leaving an assignment out does not clear its saved Hermes override.")
        }
    }

    private func moaSection(_ configuration: DirectHermesMoAConfiguration) -> some View {
        Section("Advanced · Mixture of Agents") {
            LabeledContent("Default preset", value: configuration.defaultPreset)
            LabeledContent("Presets", value: configuration.presets.count.formatted())
            NavigationLink("Edit model assignments") {
                ModelAdministrationMoAView(store: store, initial: configuration)
            }
            .disabled(store.isBusy)
            if !configuration.privacyFilter.isEmpty {
                Label("This host has a MoA privacy-filter override. The pinned write API cannot preserve it, so bighelp keeps this page read-only.", systemImage: "lock")
                    .font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
        }
    }

    private func providerName(_ providerID: String, in snapshot: DirectHermesModelAdministrationSnapshot?) -> String {
        snapshot?.providers.first(where: { $0.id == providerID })?.name
            ?? (providerID.isEmpty ? "Hermes" : providerID)
    }

    private func analyticsSection(_ analytics: DirectHermesModelAnalytics) -> some View {
        Section("Usage · Last \(analytics.periodDays) days") {
            LabeledContent("Sessions", value: analytics.totals.sessions.formatted())
            LabeledContent("Models used", value: analytics.totals.distinctModels.formatted())
            LabeledContent("API calls", value: analytics.totals.apiCalls.formatted())
            LabeledContent("Estimated cost", value: analytics.totals.estimatedCost.formatted(.currency(code: "USD")))
            ForEach(analytics.rows.prefix(20)) { row in
                DisclosureGroup("\(row.providerID.isEmpty ? "Provider" : row.providerID) · \(row.modelID)") {
                    LabeledContent("Sessions", value: row.sessions.formatted())
                    LabeledContent("Input tokens", value: row.inputTokens.formatted())
                    LabeledContent("Output tokens", value: row.outputTokens.formatted())
                    LabeledContent("API calls", value: row.apiCalls.formatted())
                    LabeledContent("Estimated cost", value: row.estimatedCost.formatted(.currency(code: "USD")))
                    if let date = row.lastUsedAt { LabeledContent("Last used", value: date.formatted()) }
                }
            }
            if analytics.rows.count > 20 {
                Text("Showing the 20 most-used model routes.").font(.bighelp(.footnote)).foregroundStyle(.secondary)
            }
        }
    }

    @BighelpThemeReader private var theme
}

/// The chat's model picker for an agent's default model or an auxiliary task.
@MainActor
private struct ModelAdministrationPicker: View {
    let store: ModelAdministrationStore
    let target: ModelAdministrationAssignmentTarget
    let agentName: String
    let close: () -> Void

    var body: some View {
        let current = currentSelection
        BighelpModelPickerSheet(
            title: target.title,
            scopeLabel: target == .main
                ? "New chats with \(agentName)"
                : "Auxiliary task for \(agentName)",
            providers: (store.snapshot?.providers ?? []).map(BighelpLinkModelProvider.init(administration:)),
            currentProviderID: current?.providerID,
            currentModelID: current?.modelID,
            isLoading: store.isLoading && store.snapshot == nil,
            isApplying: store.operationTitle != nil,
            errorMessage: store.errorMessage,
            onClearError: store.clearError,
            onRetry: { Task { await store.refresh() } },
            onSelect: { _, _ in },
            applyTitle: target == .main ? "Save as default" : "Save for this task",
            defaultModelTitle: target == .main ? "Not configured" : "Automatic",
            onApply: { draft in
                guard let providerID = draft.providerID, let modelID = draft.modelID else { return }
                Task {
                    if await store.assign(providerID: providerID, modelID: modelID, target: target) { close() }
                }
            }
        )
        .presentationDetents([.large])
        .bighelpSheet(isPresented: Binding(
            get: { store.pendingConfirmation != nil },
            set: { if !$0 { store.cancelAssignmentConfirmation() } }
        )) {
            BighelpModelWarningSheet(
                title: "Confirm model cost?",
                message: store.pendingConfirmation?.message ?? "Review this model assignment before continuing."
            ) {
                Task { if await store.confirmAssignment() { close() } }
            } onCancel: {
                store.cancelAssignmentConfirmation()
            }
        }
        .accessibilityIdentifier("models.picker")
    }

    private var currentSelection: (providerID: String, modelID: String)? {
        guard let snapshot = store.snapshot else { return nil }
        switch target {
        case .main:
            guard !snapshot.info.modelID.isEmpty else { return nil }
            return (snapshot.info.providerID, snapshot.info.modelID)
        case .auxiliary(let taskName):
            guard let task = snapshot.auxiliary?.tasks.first(where: { $0.task == taskName }),
                  task.providerID != "auto", !task.modelID.isEmpty else { return nil }
            return (task.providerID, task.modelID)
        }
    }
}

@MainActor
private struct ModelAdministrationMoAView: View {
    /// A reference or aggregator model being chosen in the shared picker.
    private enum SlotTarget: Identifiable, Hashable {
        case reference(preset: Int, index: Int)
        case aggregator(preset: Int)
        var id: Self { self }
    }

    let store: ModelAdministrationStore
    @State private var configuration: DirectHermesMoAConfiguration
    @State private var confirmSave = false
    @State private var slotTarget: SlotTarget?
    @Environment(\.dismiss) private var dismiss

    init(store: ModelAdministrationStore, initial: DirectHermesMoAConfiguration) {
        self.store = store
        _configuration = State(initialValue: initial)
    }

    private var providers: [DirectHermesModelProvider] {
        (store.snapshot?.providers ?? []).filter { $0.id.lowercased() != "moa" && !$0.models.isEmpty }
    }

    var body: some View {
        Form {
            Section {
                Picker("Default preset", selection: $configuration.defaultPreset) {
                    ForEach(configuration.presets) { Text($0.name).tag($0.name) }
                }
                Picker("Active preset", selection: $configuration.activePreset) {
                    Text("Default").tag("")
                    ForEach(configuration.presets) { Text($0.name).tag($0.name) }
                }
            } header: {
                Text("Preset routing")
            } footer: {
                Text("All visible preset fields are round-tripped together. Hidden host overrides outside this typed document are not cleared.")
            }

            ForEach(configuration.presets.indices, id: \.self) { presetIndex in
                Section(configuration.presets[presetIndex].name) {
                    Toggle("Enabled", isOn: $configuration.presets[presetIndex].isEnabled)
                    Picker("Fan-out", selection: Binding(
                        get: { configuration.presets[presetIndex].fanout ?? "user_turn" },
                        set: { configuration.presets[presetIndex].fanout = $0 }
                    )) {
                        Text("Once per user turn").tag("user_turn")
                        Text("Every tool iteration").tag("per_iteration")
                    }
                    Picker("Failed reference policy", selection: $configuration.presets[presetIndex].degradedReferencePolicy) {
                        Text("Report failures").tag("loud")
                        Text("Continue silently").tag("silent")
                    }
                    ForEach(configuration.presets[presetIndex].referenceModels.indices, id: \.self) { referenceIndex in
                        DisclosureGroup("Reference \(referenceIndex + 1)") {
                            moaSlotEditor(slot: $configuration.presets[presetIndex].referenceModels[referenceIndex],
                                          target: .reference(preset: presetIndex, index: referenceIndex), allowsDisable: true)
                            if configuration.presets[presetIndex].referenceModels.count > 1 {
                                Button("Remove reference", role: .destructive) {
                                    configuration.presets[presetIndex].referenceModels.remove(at: referenceIndex)
                                }
                            }
                        }
                    }
                    Button("Add reference model", systemImage: "plus") {
                        if let provider = providers.first, let model = provider.models.first {
                            configuration.presets[presetIndex].referenceModels.append(.init(
                                providerID: provider.id, modelID: model,
                                reasoningEffort: nil, isEnabled: true
                            ))
                        }
                    }
                    .disabled(providers.isEmpty || configuration.presets[presetIndex].referenceModels.count >= 32)
                    DisclosureGroup("Aggregator") {
                        moaSlotEditor(slot: $configuration.presets[presetIndex].aggregator,
                                      target: .aggregator(preset: presetIndex), allowsDisable: false)
                    }
                }
            }

            if !configuration.privacyFilter.isEmpty {
                Section {
                    Label("Saving is unavailable because this host's MoA privacy filter cannot be represented by the pinned write API without resetting it.", systemImage: "lock")
                }
            }
            Section {
                Button("Review Mixture of Agents changes") { confirmSave = true }
                    .disabled(store.isBusy || !configuration.privacyFilter.isEmpty || providers.isEmpty)
            }
        }
        .navigationTitle("Mixture of Agents")
        .navigationBarTitleDisplayMode(.inline)
        .bighelpSheet(item: $slotTarget) { target in
            slotPicker(target)
                .bighelpSheetSize(.standard)
        }
        .confirmationDialog("Save all MoA preset assignments?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save") {
                let submitted = configuration
                Task { if await store.saveMoA(submitted) { dismiss() } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Hermes will validate and replace the typed MoA preset document for this profile. This can change model spend for future MoA runs.")
        }
    }

    @ViewBuilder
    private func moaSlotEditor(slot: Binding<DirectHermesMoAModelSlot>, target: SlotTarget, allowsDisable: Bool) -> some View {
        if allowsDisable { Toggle("Use this reference", isOn: slot.isEnabled) }
        BighelpModelChoiceRow(
            providerID: slot.wrappedValue.providerID,
            providerName: providers.first(where: { $0.id == slot.wrappedValue.providerID })?.name
                ?? slot.wrappedValue.providerID,
            modelID: slot.wrappedValue.modelID,
            emptyTitle: "Choose a model",
            isEnabled: !providers.isEmpty
        ) {
            slotTarget = target
        }
    }

    /// The chat's model picker for one reference or aggregator slot. The choice is
    /// saved with the rest of the presets when you review and save.
    private func slotPicker(_ target: SlotTarget) -> some View {
        let slot = self.slot(target)
        return BighelpModelPickerSheet(
            title: "Choose model",
            scopeLabel: {
                switch target {
                case .reference(let preset, let index): "\(configuration.presets[preset].name) · Reference \(index + 1)"
                case .aggregator(let preset): "\(configuration.presets[preset].name) · Aggregator"
                }
            }(),
            providers: providers.map(BighelpLinkModelProvider.init(administration:)),
            currentProviderID: slot?.providerID,
            currentModelID: slot?.modelID,
            isLoading: false,
            isApplying: false,
            errorMessage: nil,
            onClearError: {},
            onRetry: nil,
            onSelect: { _, _ in },
            applyTitle: "Use this model",
            onApply: { draft in
                guard let providerID = draft.providerID, let modelID = draft.modelID else { return }
                switch target {
                case .reference(let preset, let index):
                    configuration.presets[preset].referenceModels[index].providerID = providerID
                    configuration.presets[preset].referenceModels[index].modelID = modelID
                case .aggregator(let preset):
                    configuration.presets[preset].aggregator.providerID = providerID
                    configuration.presets[preset].aggregator.modelID = modelID
                }
                slotTarget = nil
            }
        )
        .presentationDetents([.large])
    }

    private func slot(_ target: SlotTarget) -> DirectHermesMoAModelSlot? {
        switch target {
        case .reference(let preset, let index):
            guard configuration.presets.indices.contains(preset),
                  configuration.presets[preset].referenceModels.indices.contains(index) else { return nil }
            return configuration.presets[preset].referenceModels[index]
        case .aggregator(let preset):
            guard configuration.presets.indices.contains(preset) else { return nil }
            return configuration.presets[preset].aggregator
        }
    }
}
