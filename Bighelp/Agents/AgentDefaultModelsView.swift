import SwiftUI

/// A bot's Default Model page (its profile's Default Model): the chat model first, with its
/// thinking level and Fast; then Advanced, which opens in place to Subagents, Scheduled tasks and
/// the helper tasks. Each choice opens its list right under its row and saves when picked.
@MainActor
struct AgentDefaultModelsView: View {
    let defaults: AgentRuntimeDefaultsEditorModel
    /// The bot's helper tasks; nil where the computer can't list them.
    let helpers: AgentHelperModelsModel?
    let botName: String

    /// The one list open on the page.
    @State private var open: Choice?
    @State private var showsAdvanced = false
    /// The setting being saved, so its row says so.
    @State private var saving: Choice?

    enum Choice: Hashable {
        case model(AgentRuntimeScope)
        case reasoning(AgentRuntimeScope)
        case helper(String)
    }

    var body: some View {
        Form {
            if let message = defaults.errorMessage ?? helpers?.errorMessage { errorSection(message) }
            if defaults.hasLoaded {
                chatSection
                advancedSection
                if showsAdvanced {
                    otherWorkSection
                    if let helpers { helperSection(helpers) }
                }
            } else if defaults.isLoading {
                Section {
                    ProgressView("Loading models…").frame(maxWidth: .infinity)
                }
            }
        }
        .bighelpFormSurface()
        .navigationTitle("Default Model")
        .navigationBarTitleDisplayMode(.inline)
        .task { await defaults.loadIfNeeded() }
        .task { await helpers?.loadIfNeeded() }
        .alert("Save this model?", isPresented: Binding(
            get: { defaults.pendingConfirmation != nil },
            set: { if !$0 { defaults.dismissConfirmation() } })) {
            Button("Save") { Task { try? await defaults.confirmPendingSave() } }
            Button("Cancel", role: .cancel) { Task { await defaults.load() } }
        } message: {
            Text(defaults.pendingConfirmation?.message ?? "")
        }
        .alert("Use this model?", isPresented: Binding(
            get: { helpers?.pendingConfirmation != nil },
            set: { if !$0 { helpers?.dismissConfirmation() } })) {
            Button("Use it") { Task { await helpers?.confirmPending() } }
            Button("Cancel", role: .cancel) { helpers?.dismissConfirmation() }
        } message: {
            Text(helpers?.pendingConfirmation?.message ?? "")
        }
        .accessibilityIdentifier("default-models")
    }

    // MARK: Chat model

    private var chatSection: some View {
        Section {
            modelRow(.mainChats)
            if open == .model(.mainChats) {
                chooser(for: .mainChats)
            }
            if defaults.support.reasoningUnavailableReasons[.mainChats] == nil {
                reasoningRow(.mainChats)
                if open == .reasoning(.mainChats) { reasoningChooser(for: .mainChats) }
            }
            fastRow
        } header: {
            Text("Chat model")
        } footer: {
            Text("New chats with \(botName) use this. Chats that are open keep theirs.")
        }
    }

    @ViewBuilder
    private var fastRow: some View {
        let isOn = defaults.draft.mainChats.fastMode == .on
        // Fast shows where the model has it, and stays visible while it's on so it can be turned off.
        if isOn || defaults.fastModeUnavailableReason == nil {
            Toggle(isOn: Binding(get: { isOn }, set: { on in
                Task { await defaults.saveFastMode(on ? .on : .off) }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fast").font(.bighelp(.body))
                    Text("Answers sooner, on a faster and costlier tier.")
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .tint(theme.success)
            .disabled(defaults.isSaving)
            .accessibilityIdentifier("default-models.fast")
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        Section {
            Button {
                withAnimation(reduceMotion ? nil : .snappy) {
                    showsAdvanced.toggle()
                    if !showsAdvanced { open = open.flatMap { $0.isAdvanced ? nil : $0 } }
                }
            } label: {
                HStack(spacing: BighelpTokens.space12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Advanced")
                            .font(.bighelp(.body, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                        Text(advancedSummary)
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    Image(systemName: showsAdvanced ? "chevron.up" : "chevron.down")
                        .font(.bighelp(.footnote, weight: .bold))
                        .foregroundStyle(theme.tertiaryText)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsAdvanced ? Text("Open") : Text("Closed"))
            .accessibilityIdentifier("default-models.advanced")
        }
    }

    /// What Advanced holds, in words: who follows the chat model and who has a model of its own.
    private var advancedSummary: String {
        let agents = [AgentRuntimeScope.subagents, .scheduledTasks].filter { !usesChatModel($0) }.count
        let own = agents + (helpers?.ownModelCount ?? 0)
        if own == 1 { return String(localized: "1 task uses a model of its own") }
        if own > 1 { return String(localized: "\(own.formatted()) tasks use a model of their own") }
        if let count = helpers?.tasks.count, count > 0 {
            return String(localized: "Subagents, scheduled tasks and \(count.formatted()) helper tasks use the chat model")
        }
        return String(localized: "Subagents and scheduled tasks use the chat model")
    }

    private var otherWorkSection: some View {
        Section {
            modelRow(.subagents)
            if open == .model(.subagents) { chooser(for: .subagents) }
            if !usesChatModel(.subagents), defaults.support.reasoningUnavailableReasons[.subagents] == nil {
                reasoningRow(.subagents)
                if open == .reasoning(.subagents) { reasoningChooser(for: .subagents) }
            }
            modelRow(.scheduledTasks)
            if open == .model(.scheduledTasks) { chooser(for: .scheduledTasks) }
        } header: {
            Text("Other work")
        } footer: {
            Text(defaults.support.modelUnavailableReasons[.subagents]
                 ?? String(localized: "A scheduled task with a model of its own keeps it."))
        }
    }

    private func helperSection(_ helpers: AgentHelperModelsModel) -> some View {
        Section {
            if !helpers.hasLoaded, helpers.isLoading {
                ProgressView("Loading helper tasks…").frame(maxWidth: .infinity)
            }
            ForEach(helpers.tasks) { task in
                helperRow(task, helpers: helpers)
                if open == .helper(task.task) {
                    BighelpInlineModelChooser(
                        providers: defaults.providers,
                        currentProviderID: task.usesChatModel ? nil : task.providerID,
                        currentModelID: task.usesChatModel ? nil : task.modelID,
                        onSameAsChat: { pickHelper(task.task, helpers: helpers, providerID: nil, modelID: nil) },
                        isEnabled: helpers.savingTask == nil,
                        identifier: "default-models.helper.\(task.task)"
                    ) { provider, model in
                        pickHelper(task.task, helpers: helpers, providerID: provider, modelID: model)
                    }
                }
            }
            if helpers.ownModelCount > 0 {
                Button(helpers.savingTask == AgentHelperModelsModel.allTasks
                       ? "Saving…" : "Use the chat model for all") {
                    open = nil
                    Task { await helpers.useChatModelForAll() }
                }
                .disabled(helpers.savingTask != nil)
                .accessibilityIdentifier("default-models.helpers.reset")
            }
        } header: {
            Text("Helper tasks")
        } footer: {
            Text("Small jobs Hermes does beside a chat. Same as chat uses the chat model.")
        }
    }

    // MARK: Rows

    private func modelRow(_ scope: AgentRuntimeScope) -> some View {
        let selection = defaults.draft[scope]
        let followsChat = usesChatModel(scope)
        let shown = followsChat ? defaults.draft.mainChats : selection
        let modelName = shown.modelID.isEmpty
            ? String(localized: "Automatic") : ModelNameCatalogStore.shared.displayName(for: shown.modelID)
        let unavailable = defaults.support.modelUnavailableReasons[scope]
        let detail: String
        if saving == .model(scope) {
            detail = String(localized: "Saving…")
        } else if scope == .mainChats {
            detail = providerName(selection.providerID)
        } else if followsChat {
            detail = String(localized: "Same as chat")
        } else {
            detail = "\(modelName) · \(providerName(selection.providerID))"
        }
        return disclosureRow(
            title: scope == .mainChats ? modelName : scope.title, detail: detail,
            providerID: shown.providerID, dimsMark: followsChat, isOpen: open == .model(scope),
            id: "default-models.\(scope.rawValue).model"
        ) { toggle(.model(scope)) }
        .disabled(unavailable != nil || defaults.isSaving)
    }

    private func reasoningRow(_ scope: AgentRuntimeScope) -> some View {
        let value = defaults.draft[scope].reasoningEffort
        let title = AgentReasoningOption.all.first { $0.value == value }?.title ?? value
        return Button { toggle(.reasoning(scope)) } label: {
            HStack(spacing: BighelpTokens.space12) {
                Text("Thinking").font(.bighelp(.body)).foregroundStyle(theme.primaryText)
                Spacer(minLength: BighelpTokens.space8)
                Text(saving == .reasoning(scope) ? String(localized: "Saving…") : title)
                    .font(.bighelp(.body))
                    .foregroundStyle(theme.secondaryText)
                Image(systemName: open == .reasoning(scope) ? "chevron.up" : "chevron.down")
                    .font(.bighelp(.footnote, weight: .bold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(defaults.isSaving)
        .accessibilityIdentifier("default-models.\(scope.rawValue).reasoning")
    }

    private func helperRow(_ task: DirectHermesAuxiliaryModelAssignment, helpers: AgentHelperModelsModel) -> some View {
        let detail: String
        if helpers.savingTask == task.task || helpers.savingTask == AgentHelperModelsModel.allTasks {
            detail = String(localized: "Saving…")
        } else if task.isSetOnComputer {
            detail = String(localized: "Set on the computer")
        } else if task.usesChatModel {
            detail = String(localized: "Same as chat")
        } else {
            detail = "\(ModelNameCatalogStore.shared.displayName(for: task.modelID)) · \(providerName(task.providerID))"
        }
        return disclosureRow(
            title: task.title, detail: detail,
            providerID: task.usesChatModel ? defaults.draft.mainChats.providerID : task.providerID,
            dimsMark: task.usesChatModel, isOpen: open == .helper(task.task),
            id: "default-models.helper.\(task.task)"
        ) { toggle(.helper(task.task)) }
        .disabled(task.isSetOnComputer || helpers.savingTask != nil)
    }

    /// A row with the provider's logo, a name and one line, that opens its list under it.
    private func disclosureRow(title: String, detail: String, providerID: String, dimsMark: Bool, isOpen: Bool,
                               id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: BighelpTokens.space12) {
                AIProviderMarkView(providerID: providerID, providerName: providerName(providerID),
                                   context: .agentRuntimeSelection, size: 32)
                    .frame(width: 40, height: 40)
                    .opacity(dimsMark ? 0.4 : 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: BighelpTokens.space8)
                Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                    .font(.bighelp(.footnote, weight: .bold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOpen ? Text("Open") : Text("Closed"))
        .accessibilityIdentifier(id)
    }

    private func chooser(for scope: AgentRuntimeScope) -> some View {
        let selection = defaults.draft[scope]
        return BighelpInlineModelChooser(
            providers: defaults.providers,
            currentProviderID: selection.modelID.isEmpty ? (scope == .mainChats ? nil : defaults.draft.mainChats.providerID)
                                                         : selection.providerID,
            currentModelID: selection.modelID.isEmpty ? nil : selection.modelID,
            onSameAsChat: scope == .mainChats ? nil : { save(.model(scope)) { defaults.useChatModel(for: scope) } },
            isEnabled: !defaults.isSaving,
            identifier: "default-models.\(scope.rawValue).choices"
        ) { provider, model in
            save(.model(scope)) { defaults.selectModel(providerID: provider, modelID: model, for: scope) }
        }
    }

    private func reasoningChooser(for scope: AgentRuntimeScope) -> some View {
        BighelpInlineReasoningChooser(current: defaults.draft[scope].reasoningEffort, isEnabled: !defaults.isSaving,
                                      identifier: "default-models.\(scope.rawValue).thinking") { value in
            save(.reasoning(scope)) { defaults.selectReasoning(value, for: scope) }
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") {
                defaults.clearError()
                helpers?.clearError()
                Task {
                    if defaults.isDirty { try? await defaults.saveIfNeeded() } else { await defaults.load() }
                    await helpers?.load()
                }
            }
            .accessibilityIdentifier("default-models.retry")
        }
    }

    // MARK: Actions

    private func toggle(_ choice: Choice) {
        withAnimation(reduceMotion ? nil : .snappy) { open = open == choice ? nil : choice }
    }

    /// Makes one change and saves it straight away. A model Hermes wants confirmed asks first.
    private func save(_ choice: Choice, change: () -> Void) {
        change()
        guard defaults.errorMessage == nil else { return }
        withAnimation(reduceMotion ? nil : .snappy) { open = nil }
        // Picking what's already chosen just closes the list.
        guard defaults.isDirty else { return }
        saving = choice
        Task {
            defer { saving = nil }
            try? await defaults.saveIfNeeded()
        }
    }

    private func pickHelper(_ task: String, helpers: AgentHelperModelsModel, providerID: String?, modelID: String?) {
        withAnimation(reduceMotion ? nil : .snappy) { open = nil }
        let current = helpers.tasks.first { $0.task == task }
        if let current, providerID == nil ? current.usesChatModel
            : (current.providerID == providerID && current.modelID == modelID) { return }
        Task {
            if let providerID, let modelID {
                await helpers.choose(task, providerID: providerID, modelID: modelID)
            } else {
                await helpers.useChatModel(task)
            }
        }
    }

    private func usesChatModel(_ scope: AgentRuntimeScope) -> Bool {
        scope != .mainChats && defaults.draft[scope].modelID.isEmpty
    }

    private func providerName(_ providerID: String) -> String {
        let name = defaults.providers.first { $0.id == providerID }?.name ?? providerID
        return AIProviderVisibleIdentity.resolve(providerID: providerID, providerName: name).visibleProviderName
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme
}

private extension AgentDefaultModelsView.Choice {
    /// Lists under Advanced close with it.
    var isAdvanced: Bool {
        switch self {
        case .model(let scope), .reasoning(let scope): scope != .mainChats
        case .helper: true
        }
    }
}
