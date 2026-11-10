import SwiftUI

/// The chat's context window for its Model settings sheet: what Hermes last reported, and how to
/// read what fills it (nil where there's no computer to ask).
struct ChatContextWindow {
    let snapshot: SessionContextSnapshot
    var loadBreakdown: (@MainActor () async throws -> DirectHermesContextBreakdown)?
}

/// Model settings for one chat: its model (a tap opens All models), the Thinking control, how full
/// its context window is, and Fast Mode, on one short sheet. Every choice is sent as it's made;
/// there is no Apply. A refused choice falls back to what the chat holds, with the reason on top.
struct ChatModelSettingsSheet: View {
    @Bindable var controls: SessionRuntimeControlModel
    /// The chat is still getting its session; Fast Mode waits for it.
    let isAllocating: Bool
    /// Nil until Hermes reports the chat's context window (after the agent's first reply).
    let contextWindow: ChatContextWindow?
    let onDone: () -> Void

    @AppStorage(BighelpThinkingLook.storageKey) private var look = BighelpThinkingLook.defaultLook
    @Environment(\.nerdModeEnabled) private var nerdModeEnabled
    @State private var showsAllModels: Bool
    @State private var showsContext = false
    @State private var detent: PresentationDetent
    @State private var sender = ThinkingLevelSender()
    /// The levels last read. Hermes hands out a new list after every change, and the control
    /// stays up while that loads.
    @State private var thinking = ChatThinkingLevels()
    @State private var confirmationToSubmit: SessionRuntimeModelConfirmation?

    /// `startsOnAllModels`: the person asked for another model (a failed turn's Use another model),
    /// so the sheet opens tall, on All models. Set as the sheet is made: pushed from a task after
    /// it showed, the stack sometimes wasn't ready and stayed on the short sheet.
    init(controls: SessionRuntimeControlModel, isAllocating: Bool = false, contextWindow: ChatContextWindow? = nil,
         startsOnAllModels: Bool = false, onDone: @escaping () -> Void) {
        _controls = Bindable(wrappedValue: controls)
        self.isAllocating = isAllocating
        self.contextWindow = contextWindow
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
            .navigationDestination(isPresented: $showsContext) {
                if let load = contextWindow?.loadBreakdown { ChatContextPage(load: load, onDone: onDone) }
            }
        }
        .foregroundStyle(theme.primaryText)
        // `.contain` keeps the rows' and the control's own identifiers reachable.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.model-settings")
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .onChange(of: showsAllModels) { _, shown in detent = shown ? .large : .medium }
        .onChange(of: showsContext) { _, shown in detent = shown ? .large : .medium }
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
            if let line = contextWindow.flatMap({
                SessionContextPresentation.windowLine(for: $0.snapshot, showsTokens: nerdModeEnabled)
            }) {
                Divider()
                contextRow(line)
            }
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
                isCovered: showsAllModels || showsContext,
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

    /// How full the chat's context window is. Everyone gets one plain line; Nerd Mode gets the
    /// token counts and a tap through to the Context page, which is all numbers.
    @ViewBuilder
    private func contextRow(_ line: SessionContextWindowLine) -> some View {
        let opensPage = nerdModeEnabled && contextWindow?.loadBreakdown != nil
        let tint = line.isAlmostFull ? theme.warning : theme.primaryText
        let content = VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                Text("Context window")
                    .bighelpFont(.label)
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: BighelpTokens.space8)
                Text(verbatim: line.value)
                    .bighelpFont(.label, weight: .semibold)
                    .foregroundStyle(line.isCompacting ? theme.secondaryText : tint)
                    .monospacedDigit()
                    .lineLimit(1)
                if opensPage {
                    Image(systemName: "chevron.right")
                        .font(.bighelp(.footnote).weight(.semibold))
                        .foregroundStyle(theme.tertiaryText)
                        .accessibilityHidden(true)
                }
            }
            ChatContextMeter(fraction: line.fraction, tint: tint.opacity(line.isCompacting ? 0.35 : 1),
                             track: theme.primaryText.opacity(0.08))
            Text(verbatim: line.caption)
                .bighelpFont(.metadata)
                .foregroundStyle(line.isAlmostFull ? theme.warning : theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        if opensPage {
            Button { showsContext = true } label: { content.contentShape(.rect) }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Context window"))
                .accessibilityValue(Text(verbatim: "\(line.value), \(line.caption)"))
                .accessibilityHint("Shows what fills it.")
                .accessibilityIdentifier("chat.model-settings.context")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Context window"))
                .accessibilityValue(Text(verbatim: "\(line.value), \(line.caption)"))
                .accessibilityIdentifier("chat.model-settings.context")
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

/// The context window's bar: no motion, only the share in use.
private struct ChatContextMeter: View {
    let fraction: Double
    let tint: Color
    let track: Color

    var body: some View {
        Capsule().fill(track)
            .frame(height: 8)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    // A sliver stays round; nothing in use draws nothing.
                    Capsule().fill(tint).frame(width: fraction > 0 ? max(8, proxy.size.width * fraction) : 0)
                }
            }
            .accessibilityHidden(true)
    }
}

/// What fills the context window, read from the computer when the page opens (Nerd Mode).
private struct ChatContextPage: View {
    let load: @MainActor () async throws -> DirectHermesContextBreakdown
    let onDone: () -> Void
    @State private var breakdown: DirectHermesContextBreakdown?
    @State private var didFail = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if let breakdown {
                SessionContextBreakdownView(breakdown: breakdown)
            } else if didFail {
                ContentUnavailableView {
                    Label("Context didn't load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Your computer didn't answer. Try again.")
                } actions: {
                    Button("Try Again") {
                        didFail = false
                        attempt += 1
                    }
                    .accessibilityIdentifier("chat.model-settings.context.retry")
                }
            } else {
                BighelpThinkingOrb(scenario: .searching, scale: .inline, visibleLabel: "Loading context")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Context")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ChatModelSettingsDone(action: onDone) }
        .task(id: attempt) {
            do {
                breakdown = try await load()
            } catch is CancellationError {
            } catch {
                didFail = true
            }
        }
    }
}

extension ChatModel {
    /// This chat's context window for its Model settings sheet; nil until Hermes reports one.
    var contextWindow: ChatContextWindow? {
        guard let snapshot = sessionContext else { return nil }
        if let native = nativeConversationClient {
            return ChatContextWindow(snapshot: snapshot) { [weak native] in
                guard let native else { throw WorkspaceClientError.ownerChanged }
                return try await native.sessionActions.contextBreakdown()
            }
        }
        // The demo answers from its own sample, so the page shows without a computer.
        guard client is ConversationFixtureClient else { return ChatContextWindow(snapshot: snapshot) }
        return ChatContextWindow(snapshot: snapshot) { .demo(for: snapshot) }
    }
}

private extension DirectHermesContextBreakdown {
    /// The demo chat's own numbers, split the way a computer splits them.
    static func demo(for snapshot: SessionContextSnapshot) -> Self {
        let parts = [("messages", "Messages", 62), ("tools", "Tool definitions", 24),
                     ("system", "System prompt", 10), ("memory", "Memory", 4)]
        return DirectHermesContextBreakdown(
            categories: parts.map { .init(id: $0.0, label: $0.1, tokens: snapshot.contextUsed * $0.2 / 100, color: "") },
            contextMax: snapshot.contextMax, contextPercent: snapshot.contextPercent,
            contextUsed: snapshot.contextUsed, estimatedTotal: snapshot.contextUsed, contextEstimated: false,
            contextSource: "", model: snapshot.model)
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
    var contextWindow: ChatContextWindow? = nil
    var startsOnAllModels = false
    let onDone: () -> Void

    var body: some View {
        ChatModelSettingsSheet(controls: controls, contextWindow: contextWindow, startsOnAllModels: startsOnAllModels,
                               onDone: onDone)
            .frame(width: size.width, height: size.height)
    }
}
#endif
