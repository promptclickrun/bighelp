import SwiftUI

/// Model settings for one chat: its model (a tap opens All models), the Thinking control and
/// Fast Mode, on one short sheet. Every choice is sent as it's made; there is no Apply.
/// A refused choice falls back to what the chat holds, with the reason on top.
struct ChatModelSettingsSheet: View {
    @Bindable var controls: SessionRuntimeControlModel
    /// The chat is still getting its session; Fast Mode waits for it.
    let isAllocating: Bool
    let onDone: () -> Void

    @AppStorage(BighelpThinkingLook.storageKey) private var look = BighelpThinkingLook.defaultLook
    @State private var showsAllModels: Bool
    @State private var detent: PresentationDetent
    @State private var sender = ThinkingLevelSender()
    /// The levels last read. Hermes hands out a new list after every change, and the control
    /// stays up while that loads.
    @State private var thinking = ChatThinkingLevels()
    @State private var confirmationToSubmit: SessionRuntimeModelConfirmation?

    /// `startsOnAllModels`: the person asked for another model (a failed turn's Use another model),
    /// so the sheet opens tall, on All models. Set as the sheet is made: pushed from a task after
    /// it showed, the stack sometimes wasn't ready and stayed on the short sheet.
    init(controls: SessionRuntimeControlModel, isAllocating: Bool = false, startsOnAllModels: Bool = false,
         onDone: @escaping () -> Void) {
        _controls = Bindable(wrappedValue: controls)
        self.isAllocating = isAllocating
        self.onDone = onDone
        _showsAllModels = State(initialValue: startsOnAllModels)
        _detent = State(initialValue: startsOnAllModels ? .large : .medium)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                    notices
                    card
                }
                .padding(BighelpTokens.space16)
            }
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Model settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ChatModelSettingsDone(action: onDone) }
            .navigationDestination(isPresented: $showsAllModels) {
                ChatAllModelsView(controls: controls, onPick: pick, onDone: onDone)
            }
        }
        .foregroundStyle(theme.primaryText)
        // `.contain` keeps the rows' and the control's own identifiers reachable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.model-settings")
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: showsAllModels) { _, shown in detent = shown ? .large : .medium }
        .task {
            thinking.take(controls)
            await controls.loadPickersIfNeeded()
            await controls.loadFastModeIfNeeded()
        }
        .onChange(of: controls.reasoningPicker?.pickerID) { _, _ in thinking.take(controls) }
        .overlay {
            if controls.isApplyingSelection, !sender.isSending {
                BighelpThinkingOrb(scenario: .working, scale: .inline)
                    .padding(BighelpTokens.space12)
                    .background(.regularMaterial, in: .circle)
                    .accessibilityLabel("Updating this chat")
            }
        }
        .modifier(BighelpModelConfirmationModifier(
            confirmation: controls.pendingModelConfirmation,
            onConfirm: { confirmationToSubmit = $0 },
            onCancel: { controls.cancelModelConfirmation(expected: $0) }
        ))
        .task(id: confirmationToSubmit?.id) {
            guard !Task.isCancelled, let confirmationToSubmit,
                  await controls.confirmModelSelection(confirmationToSubmit), !Task.isCancelled else { return }
            await modelChanged()
        }
        .onDisappear { confirmationToSubmit = nil }
    }

    // MARK: The card

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            modelRow
            Divider()
            thinkingRow
                .padding(.vertical, BighelpTokens.space12)
            if let fastMode = controls.fastMode, fastMode.unavailableReason == nil, fastMode.mode != nil {
                Divider()
                fastModeRow(fastMode)
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .background(theme.surface, in: .rect(cornerRadius: BighelpTokens.radius20))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius20).stroke(theme.border, lineWidth: BighelpTokens.hairline)
        }
    }

    private var modelRow: some View {
        Button { showsAllModels = true } label: {
            HStack(spacing: BighelpTokens.space12) {
                if let providerID = controls.currentProvider {
                    AIProviderMarkView(providerID: providerID, providerName: providerName(for: providerID),
                                       context: .chatSessionCompactControl, size: BighelpTokens.scaled(24))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(controls.modelDisplayName)
                        .bighelpFont(.body, weight: .semibold)
                        .lineLimit(2)
                    Text(modelDetail)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: BighelpTokens.space8)
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote).weight(.semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: BighelpTokens.hitTarget + BighelpTokens.space12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(controls.isApplyingSelection)
        .accessibilityHint("Shows every model you can use.")
        .accessibilityIdentifier("chat.model-settings.model")
    }

    /// "Nous Portal · Medium · 17% left": the provider, the level, and its plan when the computer reports one.
    private var modelDetail: String {
        var parts = [controls.currentProvider.map { providerName(for: $0) } ?? String(localized: "Provider not reported")]
        if let level = controls.currentReasoningLabel { parts.append(level) }
        if let providerID = controls.currentProvider, let modelID = controls.currentModel,
           let plan = controls.modelProviders.first(where: { $0.id == providerID })?.plan {
            let now = Date()
            if let text = plan.modelLimit(modelID, now: now) ?? plan.summary(now: now)?.text { parts.append(text) }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var thinkingRow: some View {
        if !thinking.levels.isEmpty {
            let shown = sender.pendingLevel ?? controls.currentReasoningValue
            BighelpThinkingControl(
                levels: thinking.levels,
                current: shown == ChatThinkingLevels.automaticValue ? nil : shown,
                look: look,
                accent: theme.action,
                automatic: thinking.offersAutomatic
                    ? BighelpThinkingAutomatic(title: String(localized: "Auto"),
                                               isOn: shown == ChatThinkingLevels.automaticValue,
                                               select: { send(ChatThinkingLevels.automaticValue) })
                    : nil,
                isDisabled: controls.selectionSupport.reasoningUnavailableReason != nil
                    || (controls.isApplyingSelection && !sender.isSending),
                isCovered: showsAllModels,
                accessibilityIdentifier: "chat.thinking",
                onCommit: send
            )
        } else if controls.errorMessage != nil, !thinking.isKnown {
            // The levels didn't load: the notice below says why and has Retry.
            EmptyView()
        } else if thinking.isKnown {
            Text("This model has no thinking levels to choose.")
                .bighelpFont(.metadata)
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                .accessibilityIdentifier("chat.thinking-none")
        } else {
            BighelpThinkingOrb(scenario: .searching, scale: .inline, visibleLabel: "Loading thinking levels")
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
        }
    }

    private func fastModeRow(_ fastMode: SessionFastMode) -> some View {
        Toggle(isOn: Binding(
            get: { fastMode.mode == .on },
            set: { isOn in Task { await controls.selectFastMode(isOn ? .on : .off) } }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fast Mode").bighelpFont(.body)
                Text(controls.fastModeError ?? String(localized: "Quicker answers. May cost more."))
                    .bighelpFont(.metadata)
                    .foregroundStyle(controls.fastModeError == nil ? theme.secondaryText : theme.danger)
            }
        }
        .frame(minHeight: BighelpTokens.hitTarget + BighelpTokens.space8)
        .disabled(isAllocating || controls.isApplyingSelection || controls.hasPendingSelection)
        .accessibilityIdentifier("chat.model-settings.fast-mode")
    }

    @ViewBuilder
    private var notices: some View {
        if let errorMessage = controls.errorMessage {
            BighelpInlineNotice(
                message: errorMessage,
                actionTitle: "Retry",
                actionIdentifier: "chat.model-settings.retry",
                isActionEnabled: !(controls.isLoadingModel || controls.isLoadingReasoning),
                action: { Task { await controls.loadPickersIfNeeded() } },
                onDismiss: controls.clearError
            )
        } else if let status = controls.statusMessage {
            BighelpInlineNotice(message: status, tone: .warning)
        } else if let reason = controls.selectionSupport.modelUnavailableReason
                    ?? controls.selectionSupport.reasoningUnavailableReason {
            BighelpInlineNotice(message: reason, tone: .warning)
        }
    }

    // MARK: Changes

    /// One change goes to the computer for each release of the control, the newest winning.
    private func send(_ level: String) {
        sender.request(level) { level in
            await controls.loadReasoningPickerIfNeeded()
            await controls.selectReasoning(value: level)
            guard controls.errorMessage == nil, controls.currentReasoningValue == level else { return false }
            // The next change needs the list Hermes hands out after this one.
            await controls.loadReasoningPickerIfNeeded()
            return true
        }
    }

    /// A model picked in All models. A model Hermes wants confirmed stays on All models until
    /// the question is answered.
    private func pick(providerID: String, modelID: String) {
        guard providerID != controls.currentProvider || modelID != controls.currentModel else {
            showsAllModels = false
            return
        }
        Task {
            await controls.selectModel(providerID: providerID, modelID: modelID)
            guard controls.errorMessage == nil, controls.pendingModelConfirmation == nil else { return }
            // A model Hermes keeps for the next turn: back to the short sheet, which says so. A
            // reload here would read the chat's present model and drop the note.
            guard !controls.hasPendingSelection else {
                showsAllModels = false
                return
            }
            await modelChanged()
        }
    }

    /// Back to the short sheet, with the new model's own levels and speed.
    private func modelChanged() async {
        showsAllModels = false
        guard controls.errorMessage == nil else { return }
        await controls.loadModelPicker()
        guard controls.errorMessage == nil else { return }
        await controls.loadReasoningPicker()
        await controls.loadFastModeIfNeeded()
    }

    private func providerName(for id: String) -> String {
        let name = controls.modelProviders.first { $0.id == id }?.name ?? id
        return AIProviderVisibleIdentity.resolve(providerID: id, providerName: name).visibleProviderName
    }

    @BighelpThemeReader private var theme: BighelpTheme
}

/// Done, in the sheet's top bar. On the Mac, Esc closes it too.
struct ChatModelSettingsDone: ToolbarContent {
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done", action: action)
                #if targetEnvironment(macCatalyst)
                .keyboardShortcut(.cancelAction)
                #endif
                .accessibilityIdentifier("chat.model-settings.done")
        }
    }
}

/// The Thinking levels a chat's model offers, as last read from its computer.
struct ChatThinkingLevels: Equatable {
    /// Hermes' own name for its automatic level.
    static let automaticValue = "reset"
    private static let order = BighelpThinkingLevel.all.map(\.value)

    /// Lowest first, without the automatic level.
    private(set) var levels: [BighelpThinkingLevel] = []
    private(set) var offersAutomatic = false
    /// A list was read, even an empty one.
    private(set) var isKnown = false

    /// Takes the list the chat holds now. While Hermes prepares the next one, the last stays.
    @MainActor
    mutating func take(_ controls: SessionRuntimeControlModel) {
        guard controls.reasoningPicker != nil else { return }
        take(controls.reasoningOptions.map { ($0.value, $0.label) })
    }

    /// Hosts list levels lowest first, but nothing promises it: known levels go in their own
    /// order, and levels bighelp doesn't know follow in the host's.
    mutating func take(_ options: [(value: String, label: String)]) {
        isKnown = true
        offersAutomatic = options.contains { $0.value == Self.automaticValue }
        levels = options.filter { $0.value != Self.automaticValue }
            .enumerated()
            .sorted { lhs, rhs in
                let left = Self.order.firstIndex(of: lhs.element.value) ?? Self.order.count
                let right = Self.order.firstIndex(of: rhs.element.value) ?? Self.order.count
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map { BighelpThinkingLevel(reasoningValue: $0.element.value, title: $0.element.label) }
    }
}

#if targetEnvironment(macCatalyst)
/// The Mac's Model settings pop-up: the same sheet, fitted to the room beside the button.
struct ChatModelSettingsMacPopover: View {
    let controls: SessionRuntimeControlModel
    /// Fits the window; the caller measures the room beside the button.
    let size: CGSize
    var startsOnAllModels = false
    let onDone: () -> Void

    var body: some View {
        ChatModelSettingsSheet(controls: controls, startsOnAllModels: startsOnAllModels, onDone: onDone)
            .frame(width: size.width, height: size.height)
    }
}
#endif
