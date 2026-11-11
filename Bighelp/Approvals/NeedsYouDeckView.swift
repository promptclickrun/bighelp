import SwiftUI

/// Cross-agent, cross-surface items waiting on the person in the "Needs You" Decision Deck (`1B`).
/// Projects authoritative Hermes prompts, structured dashboard attention items, workflow sign-offs,
/// and waiting Bot Chats without creating any shadow queue or spending AI tokens.
@MainActor
struct NeedsYouEntry: Identifiable {
    enum KindBadge: String {
        case approval = "Approval"
        case question = "Question"
        case signoff = "Sign-off"
        case waiting = "Waiting"
    }

    struct DirectPromptItem {
        let client: DirectHermesConversationClient
        let prompt: DirectHermesPrompt
        let agentID: String
        let agentName: String
        let agentRole: String?
        let hostName: String
        let conversationID: String?
    }

    struct DashboardItem {
        let model: DashboardModel
        let item: DashboardAttentionItem
        let agentID: String
        let agentName: String
        let agentRole: String?
        let hostName: String
    }

    struct WorkflowItem {
        let store: WorkflowsStore
        let run: WorkflowRunSummary
        let agentID: String
        let agentName: String
        let hostName: String
    }

    struct WaitingBotItem {
        let agentID: String
        let agentName: String
        let agentRole: String?
        let hostName: String
    }

    enum Payload {
        case directPrompt(DirectPromptItem)
        case dashboard(DashboardItem)
        case workflow(WorkflowItem)
        case waitingBot(WaitingBotItem)
    }

    let id: String
    let payload: Payload

    var kindBadge: KindBadge {
        switch payload {
        case .directPrompt(let entry):
            entry.prompt.kind == .approval ? .approval : .question
        case .dashboard(let entry):
            switch entry.item.interaction {
            case .approval: .approval
            case .clarification: .question
            case .none: .waiting
            }
        case .workflow:
            .signoff
        case .waitingBot:
            .waiting
        }
    }

    var agentID: String {
        switch payload {
        case .directPrompt(let item): item.agentID
        case .dashboard(let item): item.agentID
        case .workflow(let item): item.agentID
        case .waitingBot(let item): item.agentID
        }
    }

    var agentName: String {
        switch payload {
        case .directPrompt(let item): item.agentName
        case .dashboard(let item): item.agentName
        case .workflow(let item): item.agentName
        case .waitingBot(let item): item.agentName
        }
    }

    var metadataLine: String {
        switch payload {
        case .directPrompt(let item):
            [item.hostName, item.agentRole].compactMap { $0?.nonEmptyTrimmed }.joined(separator: " · ")
        case .dashboard(let item):
            [item.hostName, item.agentRole].compactMap { $0?.nonEmptyTrimmed }.joined(separator: " · ")
        case .workflow(let item):
            [item.hostName, "Workflows"].compactMap { $0.nonEmptyTrimmed }.joined(separator: " · ")
        case .waitingBot(let item):
            [item.hostName, item.agentRole].compactMap { $0?.nonEmptyTrimmed }.joined(separator: " · ")
        }
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Shell-provided hooks so `NeedsYouDeckView` can see every waiting item across the workspace
/// and jump directly to an agent's chat or workflow sign-off when the person wants full context.
@MainActor
struct NeedsYouDeckContext {
    var currentConversationID: @MainActor () -> String? = { nil }
    var entries: @MainActor () -> [NeedsYouEntry] = { [] }
    var openConversation: @MainActor (String) -> Void = { _ in }
    var openAgentChat: @MainActor (String) -> Void = { _ in }
    var openWorkflowSignoff: @MainActor (String) -> Void = { _ in }
    var refresh: @MainActor () async -> Void = {}
}

private struct NeedsYouDeckContextKey: EnvironmentKey {
    nonisolated(unsafe) static let defaultValue: NeedsYouDeckContext? = nil
}

extension EnvironmentValues {
    var needsYouDeckContext: NeedsYouDeckContext? {
        get { self[NeedsYouDeckContextKey.self] }
        set { self[NeedsYouDeckContextKey.self] = newValue }
    }
}

/// The "Needs You" Decision Deck (`1B`): resolve Hermes approvals, clarification questions, and
/// workflow sign-offs inline in seconds without losing your place or switching chats.
@MainActor
struct NeedsYouDeckView: View {
    var context: NeedsYouDeckContext? = nil
    var focusedClient: DirectHermesConversationClient? = nil
    var focusedAgentName: String? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.needsYouDeckContext) private var environmentDeckContext
    @Environment(\.colorSchemeContrast) private var contrast
    @BighelpThemeReader private var theme

    private var deckContext: NeedsYouDeckContext? { context ?? environmentDeckContext }

    @State private var selectedID: String?
    @State private var resolvedRecords: [ResolvedRecord] = []

    private struct ResolvedRecord: Identifiable, Equatable {
        let id: String
        let badge: String
        let agentID: String
        let agentName: String
        let metadata: String
    }

    private struct DisplaySlot: Identifiable {
        let id: String
        let badge: String
        let live: NeedsYouEntry?
        let resolved: ResolvedRecord?
        var isResolved: Bool { live == nil }
    }

    private var liveEntries: [NeedsYouEntry] {
        var collected: [NeedsYouEntry] = []
        var seenIDs = Set<String>()

        if let focusedClient {
            let fallbackName = focusedAgentName?.nonEmptyTrimmed ?? "Hermes"
            for prompt in focusedClient.prompts {
                let id = "prompt:\(prompt.attentionKey)"
                if seenIDs.insert(id).inserted {
                    collected.append(
                        NeedsYouEntry(
                            id: id,
                            payload: .directPrompt(
                                .init(
                                    client: focusedClient,
                                    prompt: prompt,
                                    agentID: prompt.profile,
                                    agentName: fallbackName,
                                    agentRole: nil,
                                    hostName: "Hermes",
                                    conversationID: nil
                                )
                            )
                        )
                    )
                }
            }
        }

        if let extra = deckContext?.entries() {
            for item in extra {
                if let index = collected.firstIndex(where: { $0.id == item.id }) {
                    // Prefer the shell's richer metadata (real agent name, role, host, conversationID).
                    collected[index] = item
                } else if seenIDs.insert(item.id).inserted {
                    collected.append(item)
                }
            }
        }

        return collected
    }

    private var slots: [DisplaySlot] {
        let live = liveEntries
        let liveSet = Set(live.map(\.id))
        var result = live.map {
            DisplaySlot(id: $0.id, badge: $0.kindBadge.rawValue, live: $0, resolved: nil)
        }
        for record in resolvedRecords where !liveSet.contains(record.id) {
            result.append(DisplaySlot(id: record.id, badge: record.badge, live: nil, resolved: record))
        }
        return result
    }

    private var activeSlot: DisplaySlot? {
        let all = slots
        if let selectedID, let match = all.first(where: { $0.id == selectedID }) {
            return match
        }
        return all.first(where: { !$0.isResolved }) ?? all.first
    }

    var body: some View {
        let waitingCount = liveEntries.count
        let allSlots = slots

        VStack(spacing: BighelpTokens.space12) {
            headerRow(waitingCount: waitingCount)

            if allSlots.count > 1 {
                tabStrip(allSlots)
            }

            if let slot = activeSlot {
                ScrollView {
                    cardSurface(for: slot)
                        .padding(.bottom, BighelpTokens.space8)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else if let focusedClient, !focusedClient.connected,
                      let status = HostConnectionStatus(chat: .reconnecting) {
                reconnectingCard(status: status)
            } else {
                emptyResolvedCard
            }

            Text("Hermes-authoritative · Later keeps items waiting")
                .font(.bighelp(.caption2))
                .foregroundStyle(theme.tertiaryText)
                .multilineTextAlignment(.center)
                .padding(.bottom, BighelpTokens.space4)
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.top, BighelpTokens.space16)
        .padding(.bottom, BighelpTokens.space8)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("needs-you.deck")
        .task {
            await deckContext?.refresh()
            if selectedID == nil {
                selectedID = liveEntries.first?.id
            }
        }
        .onChange(of: liveEntries.map(\.id)) { _, currentIDs in
            if let selectedID, !currentIDs.contains(selectedID),
               let nextWaiting = currentIDs.first {
                self.selectedID = nextWaiting
            } else if selectedID == nil {
                selectedID = currentIDs.first
            }
            if currentIDs.isEmpty, let focusedClient, focusedClient.hasAuthoritativeEventCoverage, resolvedRecords.isEmpty {
                dismiss()
            }
        }
    }

    private func headerRow(waitingCount: Int) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Text("Needs you")
                .font(.bighelp(.title3, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)

            Text(waitingCount == 1 ? String(localized: "1 waiting") : String(localized: "\(waitingCount) waiting"))
                .font(.bighelp(.caption, weight: .bold))
                .foregroundStyle(waitingCount == 0 ? theme.success : theme.warning)
                .padding(.horizontal, BighelpTokens.space8 + 2)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill((waitingCount == 0 ? theme.success : theme.warning).opacity(0.16))
                )
                .accessibilityIdentifier("needs-you.count")

            Spacer(minLength: BighelpTokens.space8)

            Button("Later") {
                dismiss()
            }
            .font(.bighelp(.body, weight: .semibold))
            .foregroundStyle(theme.action)
            .keyboardShortcut(.cancelAction)
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier("needs-you.later")
        }
    }

    private func tabStrip(_ slots: [DisplaySlot]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                    tabButton(index: index, slot: slot)
                }
            }
        }
    }

    private func tabButton(index: Int, slot: DisplaySlot) -> some View {
        let isSelected = slot.id == activeSlot?.id
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius12 - 2, style: .continuous)
        let fillColor = isSelected ? theme.action.opacity(theme.isDarkPalette ? 0.18 : 0.12) : theme.surface
        let borderColor = isSelected ? theme.action : (contrast == .increased ? theme.primaryText : theme.border)

        return Button {
            BighelpHaptics.tap()
            selectedID = slot.id
        } label: {
            HStack(spacing: 4) {
                if slot.isResolved {
                    Image(systemName: "checkmark")
                        .font(.bighelp(.caption2, weight: .bold))
                }
                Text("\(index + 1) · \(slot.badge)")
                    .font(.bighelp(.caption, weight: .semibold))
                    .strikethrough(slot.isResolved)
            }
            .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
            .opacity(slot.isResolved && !isSelected ? 0.6 : 1)
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, 7)
            .background(shape.fill(fillColor))
            .overlay {
                shape.strokeBorder(borderColor, lineWidth: isSelected ? 1.5 : BighelpTokens.hairline)
            }
            .contentShape(shape)
        }
        .bighelpPlainButtonStyle(.rounded(10))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("needs-you.tab.\(index)")
    }

    @ViewBuilder
    private func cardSurface(for slot: DisplaySlot) -> some View {
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)

        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if let entry = slot.live {
                entryHeader(entry)
                switch entry.payload {
                case .directPrompt(let item):
                    NeedsYouDirectPromptCard(client: item.client, prompt: item.prompt) {
                        noteResolved(entry)
                    }
                case .dashboard(let item):
                    NeedsYouDashboardCard(model: item.model, item: item.item) {
                        noteResolved(entry)
                    }
                case .workflow(let item):
                    NeedsYouWorkflowSignoffCard(
                        store: item.store,
                        run: item.run,
                        onOpenFull: {
                            let runID = item.run.id
                            dismiss()
                            deckContext?.openWorkflowSignoff(runID)
                        },
                        onResolved: {
                            noteResolved(entry)
                        }
                    )
                case .waitingBot(let item):
                    VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                        Text("\(item.agentName) has a question or approval waiting in its chat.")
                            .font(.bighelp(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            let id = item.agentID
                            dismiss()
                            deckContext?.openAgentChat(id)
                        } label: {
                            Label("Open chat to answer", systemImage: "arrow.up.right")
                                .font(.bighelp(.subheadline, weight: .semibold))
                                .foregroundStyle(theme.actionForeground)
                                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                        }
                        .bighelpProminentButtonStyle()
                        .tint(theme.action)
                        .accessibilityIdentifier("needs-you.open-waiting-bot.\(item.agentID)")
                    }
                }
            } else if let record = slot.resolved {
                VStack(spacing: BighelpTokens.space8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(theme.success)
                        .accessibilityHidden(true)
                    Text("Sent to \(record.agentName)")
                        .font(.bighelp(.headline, weight: .bold))
                        .foregroundStyle(theme.primaryText)
                    if !record.metadata.isEmpty {
                        Text("Confirmed on \(record.metadata).")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(.vertical, BighelpTokens.space20)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(theme.surface))
        .overlay {
            shape.strokeBorder(
                contrast == .increased ? theme.primaryText : theme.border,
                lineWidth: contrast == .increased ? 1.5 : BighelpTokens.hairline
            )
        }
    }

    private func entryHeader(_ entry: NeedsYouEntry) -> some View {
        HStack(alignment: .center, spacing: BighelpTokens.space8) {
            SimpleBotFace(agentID: entry.agentID, name: entry.agentName, imageURL: nil, size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.agentName)
                    .font(.bighelp(.subheadline, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                if !entry.metadataLine.isEmpty {
                    Text(entry.metadataLine)
                        .font(.bighelp(.caption2))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: BighelpTokens.space8)

            openTargetButton(for: entry)
        }
    }

    @ViewBuilder
    private func openTargetButton(for entry: NeedsYouEntry) -> some View {
        switch entry.payload {
        case .directPrompt(let item):
            if let conversationID = item.conversationID,
               conversationID != deckContext?.currentConversationID() {
                Button {
                    dismiss()
                    deckContext?.openConversation(conversationID)
                } label: {
                    Label("Open chat", systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                        .font(.bighelp(.caption, weight: .semibold))
                        .foregroundStyle(theme.action)
                }
                .bighelpPlainButtonStyle()
                .accessibilityIdentifier("needs-you.open-chat")
            }
        case .dashboard(let item):
            if let sessionID = item.item.sessionID,
               sessionID != deckContext?.currentConversationID() {
                Button {
                    dismiss()
                    deckContext?.openConversation(sessionID)
                } label: {
                    Label("Open chat", systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                        .font(.bighelp(.caption, weight: .semibold))
                        .foregroundStyle(theme.action)
                }
                .bighelpPlainButtonStyle()
                .accessibilityIdentifier("needs-you.open-chat")
            }
        case .workflow(let item):
            Button {
                let runID = item.run.id
                dismiss()
                deckContext?.openWorkflowSignoff(runID)
            } label: {
                Label("Open file", systemImage: "arrow.up.right")
                    .labelStyle(.titleAndIcon)
                    .font(.bighelp(.caption, weight: .semibold))
                    .foregroundStyle(theme.action)
            }
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier("needs-you.open-signoff")
        case .waitingBot:
            EmptyView()
        }
    }

    private func reconnectingCard(status: HostConnectionStatus) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            BighelpConnectionIndicator(phase: status.phase)
            Text(status.label)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.primaryText)
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("direct-hermes.attention.reconnecting")
    }

    private var emptyResolvedCard: some View {
        VStack(spacing: BighelpTokens.space8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.success)
                .accessibilityHidden(true)
            Text("All caught up")
                .font(.bighelp(.headline, weight: .bold))
                .foregroundStyle(theme.primaryText)
            Text("Nothing is waiting on you right now.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(BighelpTokens.space24)
        .frame(maxWidth: .infinity)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
        .accessibilityIdentifier("needs-you.empty")
    }

    private func noteResolved(_ entry: NeedsYouEntry) {
        BighelpHaptics.success()
        if !resolvedRecords.contains(where: { $0.id == entry.id }) {
            resolvedRecords.append(
                ResolvedRecord(
                    id: entry.id,
                    badge: entry.kindBadge.rawValue,
                    agentID: entry.agentID,
                    agentName: entry.agentName,
                    metadata: entry.metadataLine
                )
            )
        }
        let remaining = liveEntries.filter { $0.id != entry.id }
        if let next = remaining.first {
            selectedID = next.id
        } else if focusedClient != nil {
            dismiss()
        }
    }
}

// MARK: - Live DirectHermes Prompt Card

@MainActor
private struct NeedsYouDirectPromptCard: View {
    let client: DirectHermesConversationClient
    let prompt: DirectHermesPrompt
    let onResolved: () -> Void

    @Environment(\.directHermesWorkspace) private var workspace
    @BighelpThemeReader private var theme

    @State private var ownWords = ""
    @State private var selections: [Int: Set<Int>] = [:]
    @State private var initializedPromptID: String?
    @State private var isSubmitting = false
    @State private var showsFullCommand = false
    @State private var error: String?

    private static let commandPreviewLimit = 220

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if let approval = prompt.approval {
                approvalBody(approval)
            } else if let clarification = prompt.clarification {
                clarificationBody(clarification)
            }

            HStack {
                Button("Cancel request", role: .cancel) {
                    perform {
                        try await client.cancel(prompt)
                        onResolved()
                    }
                }
                .font(.bighelp(.caption, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .bighelpPlainButtonStyle()
                .accessibilityHint("Cancels this prompt without sending a chat message.")
                .accessibilityIdentifier("direct-hermes.prompt.cancel.\(prompt.id)")

                Spacer()

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error {
                Text(error)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(isSubmitting || !client.connected)
        .task(id: prompt.id) {
            initializeDrafts()
            guard prompt.presentationAcknowledgement != nil else { return }
            await workspace?.acknowledgePresentation(of: prompt)
        }
        .onChange(of: ownWords) { _, _ in saveDraft() }
        .onChange(of: selections) { _, _ in saveDraft() }
    }

    @ViewBuilder
    private func approvalBody(_ approval: DirectHermesPrompt.Approval) -> some View {
        let headline = approval.description?.nonEmptyTrimmed ?? prompt.title
        let command = approval.command?.nonEmptyTrimmed
        let isLongCommand = (command?.count ?? 0) > Self.commandPreviewLimit
        let requiresExpand = isLongCommand && !showsFullCommand

        Text(headline)
            .font(.bighelp(.headline, weight: .bold))
            .foregroundStyle(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)

        if let command {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Text(requiresExpand ? String(command.prefix(Self.commandPreviewLimit)) + "…" : command)
                    .font(.bighelp(.footnote).monospaced())
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isLongCommand {
                    Button(showsFullCommand ? "Show shorter preview" : "Expand full command before approving") {
                        showsFullCommand.toggle()
                    }
                    .font(.bighelp(.caption, weight: .semibold))
                    .foregroundStyle(theme.action)
                    .bighelpPlainButtonStyle()
                }
            }
            .padding(BighelpTokens.space12)
            .background(theme.raisedSurface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: BighelpTokens.hairline)
            }
        }

        if let tool = approval.toolName?.nonEmptyTrimmed {
            Text("Tool: \(tool)")
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
        }

        NeedsYouDecisionButtonsRow(
            choices: approval.choices,
            requiresExpandFirst: requiresExpand,
            identifierForDecision: { "direct-hermes.approval.\($0.rawValue).\(prompt.id)" }
        ) { decision in
            perform {
                try await client.respond(to: prompt, decision: decision)
                onResolved()
            }
        }
    }

    @ViewBuilder
    private func clarificationBody(_ clarification: DirectHermesPrompt.Clarification) -> some View {
        ForEach(Array(clarification.questions.enumerated()), id: \.offset) { questionIndex, question in
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Text(question.question)
                    .font(.bighelp(.headline, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("direct-hermes.clarification.question.\(questionIndex).\(prompt.id)")

                if let locked = question.lockedAnswer {
                    Label(locked, systemImage: "lock.fill")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityLabel("Locked answer: \(locked)")
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(question.choices.enumerated()), id: \.offset) { choiceIndex, choice in
                            choiceRow(choice, choiceIndex: choiceIndex, questionIndex: questionIndex,
                                      question: question, clarification: clarification)
                        }
                    }
                }
            }
        }

        if ClarificationAnswers.acceptsOwnWords(clarification.questions.map(\.answerShape)) {
            TextField(
                clarification.questions.count > 1 ? "Or answer in your own words" : "Type another response",
                text: Binding(
                    get: { ownWords },
                    set: { value in
                        ownWords = value
                        if clarification.questions.count == 1, !value.isEmpty { selections[0] = [] }
                    }
                ),
                prompt: Text(clarification.questions.count > 1 ? "Or answer in your own words" : "Type another response")
                    .bighelpFieldHint(theme),
                axis: .vertical
            )
            .lineLimit(1...3)
            .font(.bighelp(.subheadline))
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, 9)
            .background(theme.canvas, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: BighelpTokens.hairline)
            }
            .submitLabel(.done)
            .onSubmit { submitClarification(clarification) }
            .accessibilityIdentifier("direct-hermes.clarification.custom.\(prompt.id)")
        }

        if requiresExplicitDone(clarification) || !ownWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || clarification.questions.contains(where: { $0.choices.isEmpty }) {
            Button {
                submitClarification(clarification)
            } label: {
                Text("Done")
                    .font(.bighelp(.subheadline, weight: .bold))
                    .foregroundStyle(theme.actionForeground)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            }
            .bighelpProminentButtonStyle()
            .tint(theme.action)
            .disabled(completeAnswers(for: clarification) == nil)
            .accessibilityIdentifier("direct-hermes.clarification.done.\(prompt.id)")
        }
    }

    private func choiceRow(
        _ choice: String,
        choiceIndex: Int,
        questionIndex: Int,
        question: DirectHermesPrompt.Question,
        clarification: DirectHermesPrompt.Clarification
    ) -> some View {
        let selected = selections[questionIndex, default: []].contains(choiceIndex)
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
        let iconName = selected ? "checkmark.circle.fill" : (question.isMultiSelect ? "circle" : "arrow.right")

        return Button {
            choose(choiceIndex, questionIndex: questionIndex, question: question, clarification: clarification)
        } label: {
            HStack(spacing: BighelpTokens.space8) {
                Text(choice)
                    .font(.bighelp(.subheadline, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: BighelpTokens.space8)
                Image(systemName: iconName)
                    .font(.bighelp(.footnote, weight: .semibold))
                    .foregroundStyle(selected ? theme.action : theme.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            .background(shape.fill(selected ? theme.action.opacity(0.14) : theme.canvas))
            .overlay {
                shape.strokeBorder(selected ? theme.action : theme.border, lineWidth: selected ? 1.5 : BighelpTokens.hairline)
            }
            .contentShape(shape)
        }
        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
        .accessibilityIdentifier(
            "direct-hermes.clarification.question.\(questionIndex).choice.\(choiceIndex).\(prompt.id)"
        )
    }

    private func initializeDrafts() {
        guard initializedPromptID != prompt.id, let clarification = prompt.clarification else { return }
        initializedPromptID = prompt.id
        if let saved = client.promptAnswerDrafts[prompt.attentionKey] {
            ownWords = saved.ownWords
            selections = saved.selections
            return
        }
        ownWords = ""
        selections = [:]
        for index in clarification.questions.indices {
            selections[index] = []
        }
    }

    private func saveDraft() {
        guard initializedPromptID == prompt.id else { return }
        let waiting = Set(client.prompts.map(\.attentionKey))
        client.promptAnswerDrafts = client.promptAnswerDrafts.filter { waiting.contains($0.key) }
        let draft = DirectHermesPromptAnswerDraft(ownWords: ownWords, selections: selections)
        client.promptAnswerDrafts[prompt.attentionKey] = draft.isEmpty ? nil : draft
    }

    private func choose(
        _ choiceIndex: Int,
        questionIndex: Int,
        question: DirectHermesPrompt.Question,
        clarification: DirectHermesPrompt.Clarification
    ) {
        guard question.choices.indices.contains(choiceIndex) else { return }
        var selected = selections[questionIndex, default: []]
        if question.isMultiSelect {
            if selected.contains(choiceIndex) { selected.remove(choiceIndex) }
            else { selected.insert(choiceIndex) }
        } else {
            selected = [choiceIndex]
        }
        if clarification.questions.count == 1 { ownWords = "" }
        selections[questionIndex] = selected
        guard let complete = completeAnswers(for: clarification),
              !requiresExplicitDone(clarification) else { return }
        submitClarification(clarification, complete: complete)
    }

    private func completeAnswers(
        for clarification: DirectHermesPrompt.Clarification
    ) -> [String: String]? {
        guard let values = ClarificationAnswers.answers(
            for: clarification.questions.map(\.answerShape), selections: selections, ownWords: ownWords
        ) else { return nil }
        var result: [String: String] = [:]
        for (question, answer) in zip(clarification.questions, values) {
            guard result.updateValue(answer, forKey: question.id) == nil else { return nil }
        }
        return result.count == clarification.questions.count ? result : nil
    }

    private func requiresExplicitDone(_ clarification: DirectHermesPrompt.Clarification) -> Bool {
        clarification.isBatch
            || ClarificationAnswers.needsDone(clarification.questions.map(\.answerShape), ownWords: ownWords)
    }

    private func submitClarification(_ clarification: DirectHermesPrompt.Clarification) {
        guard let complete = completeAnswers(for: clarification) else { return }
        submitClarification(clarification, complete: complete)
    }

    private func submitClarification(
        _ clarification: DirectHermesPrompt.Clarification,
        complete: [String: String]
    ) {
        if clarification.isBatch {
            perform {
                try await client.respond(to: prompt, answers: complete)
                onResolved()
            }
        } else if let question = clarification.questions.first,
                  let answer = complete[question.id] {
            perform {
                try await client.respond(to: prompt, value: answer)
                onResolved()
            }
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do { try await operation() }
            catch { self.error = DirectHermesConversationClient.safeMessage(error) }
        }
    }
}

// MARK: - Dashboard / Demo Structured Attention Card

@MainActor
private struct NeedsYouDashboardCard: View {
    let model: DashboardModel
    let item: DashboardAttentionItem
    let onResolved: () -> Void

    @BighelpThemeReader private var theme
    @State private var customAnswer = ""

    var body: some View {
        let isResolving = model.resolvingAttentionIDs.contains(item.id)

        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Text(item.title)
                .font(.bighelp(.headline, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch item.interaction {
            case .approval(let approval):
                NeedsYouDecisionButtonsRow(
                    choices: approval.allowedDecisions,
                    requiresExpandFirst: false,
                    identifierForDecision: { "needs-you.dashboard.approval.\($0.rawValue)" }
                ) { decision in
                    Task {
                        await model.respondToApproval(itemID: item.id, decision: decision)
                        if model.snapshot?.attentionItems.contains(where: { $0.id == item.id }) != true {
                            onResolved()
                        }
                    }
                }
            case .clarification(let request):
                if let first = request.questions.first {
                    if first.question != item.title {
                        Text(first.question)
                            .font(.bighelp(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                    }
                    VStack(spacing: 6) {
                        ForEach(Array(first.choices.enumerated()), id: \.offset) { idx, choice in
                            let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
                            Button {
                                Task {
                                    await model.respondToClarification(itemID: item.id, response: choice)
                                    if model.snapshot?.attentionItems.contains(where: { $0.id == item.id }) != true {
                                        onResolved()
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(choice)
                                        .font(.bighelp(.subheadline, weight: .medium))
                                        .foregroundStyle(theme.primaryText)
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .font(.bighelp(.caption, weight: .bold))
                                        .foregroundStyle(theme.secondaryText)
                                }
                                .padding(.horizontal, BighelpTokens.space12)
                                .padding(.vertical, 9)
                                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                                .background(shape.fill(theme.canvas))
                                .overlay { shape.strokeBorder(theme.border, lineWidth: BighelpTokens.hairline) }
                                .contentShape(shape)
                            }
                            .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
                            .accessibilityIdentifier("needs-you.dashboard.choice.\(idx)")
                        }
                    }
                }

                if request.allowsCustomResponse {
                    HStack(spacing: BighelpTokens.space8) {
                        TextField(
                            "Or type your answer…",
                            text: $customAnswer,
                            prompt: Text("Or type your answer…").bighelpFieldHint(theme)
                        )
                        .font(.bighelp(.subheadline))
                        .submitLabel(.send)
                        .onSubmit(sendCustomClarification)
                        .accessibilityIdentifier("needs-you.dashboard.custom")

                        if !customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Send", action: sendCustomClarification)
                                .font(.bighelp(.caption, weight: .bold))
                                .foregroundStyle(theme.action)
                                .bighelpPlainButtonStyle()
                        }
                    }
                    .padding(.horizontal, BighelpTokens.space12)
                    .padding(.vertical, 8)
                    .background(theme.canvas, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
                            .strokeBorder(theme.border, lineWidth: BighelpTokens.hairline)
                    }
                }
            case .none:
                EmptyView()
            }

            if let message = model.mutationErrorMessage {
                Text(message)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.warning)
            }

            if isResolving {
                ProgressView("Sending…")
                    .font(.bighelp(.caption))
            }
        }
        .disabled(isResolving)
    }

    private func sendCustomClarification() {
        let trimmed = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await model.respondToClarification(itemID: item.id, response: trimmed)
            if model.snapshot?.attentionItems.contains(where: { $0.id == item.id }) != true {
                onResolved()
            }
        }
    }
}

// MARK: - Workflow Sign-off Card

@MainActor
private struct NeedsYouWorkflowSignoffCard: View {
    let store: WorkflowsStore
    let run: WorkflowRunSummary
    let onOpenFull: () -> Void
    let onResolved: () -> Void

    @State private var runModel: WorkflowRunModel
    @State private var asksForChanges = false
    @State private var notes = ""
    @BighelpThemeReader private var theme

    init(store: WorkflowsStore, run: WorkflowRunSummary, onOpenFull: @escaping () -> Void, onResolved: @escaping () -> Void) {
        self.store = store
        self.run = run
        self.onOpenFull = onOpenFull
        self.onResolved = onResolved
        _runModel = State(initialValue: WorkflowRunModel(runID: run.id, client: store.client))
    }

    var body: some View {
        let signoff = runModel.detail?.signoff
        let ready = runModel.signoffText != nil && !runModel.isWorking

        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Text("Sign off \(run.workflowName) · Run \(run.number)?")
                .font(.bighelp(.headline, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let signoff {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Stage: \(run.stageTitle ?? signoff.stageKey) · sha256 \(WorkflowSHA.short(signoff.artifactSHA256))")
                        .font(.bighelp(.caption).monospaced())
                        .foregroundStyle(theme.primaryText)

                    if let text = runModel.signoffText?.nonEmptyTrimmed {
                        Text(String(text.prefix(240)) + (text.count > 240 ? "…" : ""))
                            .font(.bighelp(.caption))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(4)
                    } else if runModel.isLoadingFile {
                        ProgressView("Verifying artifact…")
                            .font(.bighelp(.caption))
                    }
                }
                .padding(BighelpTokens.space12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.raisedSurface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: BighelpTokens.hairline)
                }
            } else {
                ProgressView("Loading sign-off details…")
                    .font(.bighelp(.caption))
            }

            Text("Approving hands the verified file to you; nothing is published automatically.")
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)

            if asksForChanges {
                TextField(
                    "What should change?",
                    text: $notes,
                    prompt: Text("Notes for the agent…").bighelpFieldHint(theme),
                    axis: .vertical
                )
                .lineLimit(1...3)
                .font(.bighelp(.subheadline))
                .padding(.horizontal, BighelpTokens.space12)
                .padding(.vertical, 8)
                .background(theme.canvas, in: RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
                        .strokeBorder(theme.border, lineWidth: BighelpTokens.hairline)
                }
                .accessibilityIdentifier("needs-you.signoff.notes")
            }

            if let message = runModel.message {
                Text(message)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.warning)
            }

            HStack(spacing: BighelpTokens.space8) {
                Button {
                    Task {
                        if await runModel.signoff(.approve, notes: "") {
                            await store.load()
                            onResolved()
                        }
                    }
                } label: {
                    Text("Approve sign-off")
                        .font(.bighelp(.subheadline, weight: .bold))
                        .foregroundStyle(theme.actionForeground)
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                }
                .bighelpProminentButtonStyle()
                .tint(theme.action)
                .disabled(!ready)
                .accessibilityIdentifier("needs-you.signoff.approve")

                Button {
                    if !asksForChanges {
                        asksForChanges = true
                    } else {
                        Task {
                            if await runModel.signoff(.changes, notes: notes) {
                                await store.load()
                                onResolved()
                            }
                        }
                    }
                } label: {
                    Text(asksForChanges ? "Send notes" : "Changes")
                        .font(.bighelp(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .padding(.horizontal, BighelpTokens.space12)
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                .buttonStyle(.bordered)
                .disabled(!ready || (asksForChanges && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .accessibilityIdentifier("needs-you.signoff.changes")
            }
        }
        .task {
            await runModel.load()
            await runModel.loadSignoffFile()
        }
    }
}

// MARK: - Shared Approval Decision Row

private struct NeedsYouDecisionButtonsRow: View {
    let choices: [ApprovalDecision]
    let requiresExpandFirst: Bool
    let identifierForDecision: (ApprovalDecision) -> String
    let onDecide: (ApprovalDecision) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @BighelpThemeReader private var theme

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize || choices.count > 3
            ? AnyLayout(VStackLayout(spacing: BighelpTokens.space8))
            : AnyLayout(HStackLayout(spacing: BighelpTokens.space8))

        layout {
            ForEach(choices, id: \.rawValue) { decision in
                decisionButton(decision)
            }
        }
    }

    @ViewBuilder
    private func decisionButton(_ decision: ApprovalDecision) -> some View {
        let isPrimary = decision == .once || (choices.count == 2 && decision != .deny)
        let isDeny = decision == .deny
        let label = shortTitle(for: decision)

        if isPrimary {
            Button {
                onDecide(decision)
            } label: {
                Text(label)
                    .font(.bighelp(.subheadline, weight: .bold))
                    .foregroundStyle(theme.actionForeground)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            }
            .bighelpProminentButtonStyle()
            .tint(theme.action)
            .disabled(requiresExpandFirst)
            .accessibilityHint(decision.accessibilityHint)
            .accessibilityIdentifier(identifierForDecision(decision))
        } else if isDeny {
            let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
            Button(role: .destructive) {
                onDecide(decision)
            } label: {
                Text(label)
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.danger)
                    .padding(.horizontal, BighelpTokens.space12)
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                           minHeight: BighelpTokens.hitTarget)
                    .background(shape.fill(theme.danger.opacity(0.10)))
                    .overlay { shape.strokeBorder(theme.danger.opacity(0.55), lineWidth: 1.25) }
                    .contentShape(shape)
            }
            .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
            .accessibilityHint(decision.accessibilityHint)
            .accessibilityIdentifier(identifierForDecision(decision))
        } else {
            let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
            Button {
                onDecide(decision)
            } label: {
                Text(label)
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .padding(.horizontal, BighelpTokens.space12)
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil,
                           minHeight: BighelpTokens.hitTarget)
                    .background(shape.fill(theme.canvas))
                    .overlay { shape.strokeBorder(theme.border, lineWidth: BighelpTokens.hairline) }
                    .contentShape(shape)
            }
            .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
            .disabled(requiresExpandFirst)
            .accessibilityHint(decision.accessibilityHint)
            .accessibilityIdentifier(identifierForDecision(decision))
        }
    }

    private func shortTitle(for decision: ApprovalDecision) -> String {
        switch decision {
        case .once: String(localized: "Approve once")
        case .session: String(localized: "Session")
        case .always: String(localized: "Always")
        case .deny: String(localized: "Decline")
        }
    }
}
