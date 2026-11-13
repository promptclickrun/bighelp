import SwiftUI

/// One thing waiting on the person, for the Needs you deck: a Hermes approval or question, a
/// workflow sign-off, or a bot whose chat has something waiting. Each is read from where it
/// already lives; the deck keeps no list of its own.
@MainActor
struct NeedsYouEntry: Identifiable {
    enum Kind {
        case approval, question, signoff, waiting

        var title: String {
            switch self {
            case .approval: String(localized: "Approval")
            case .question: String(localized: "Question")
            case .signoff: String(localized: "Sign-off")
            case .waiting: String(localized: "Waiting")
            }
        }
    }

    /// A prompt in a chat the app holds open: answered over that chat's own connection.
    struct DirectPromptItem {
        let client: DirectHermesConversationClient
        let prompt: DirectHermesPrompt
        let agentID: String
        let agentName: String
        let agentRole: String?
        let hostName: String
        let conversationID: String?
    }

    /// A prompt in a chat that isn't open here, as the Dashboard lists it.
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

    var kind: Kind {
        switch payload {
        case .directPrompt(let entry):
            entry.prompt.kind == .approval ? .approval : .question
        case .dashboard(let entry):
            switch entry.item.interaction {
            case .approval: .approval
            case .clarification: .question
            case .none: .waiting
            }
        case .workflow: .signoff
        case .waitingBot: .waiting
        }
    }

    /// The agent asking, for its face. A workflow run isn't one agent's, so it has none.
    var agent: (id: String, name: String)? {
        switch payload {
        case .directPrompt(let item): (item.agentID, item.agentName)
        case .dashboard(let item): (item.agentID, item.agentName)
        case .workflow: nil
        case .waitingBot(let item): (item.agentID, item.agentName)
        }
    }

    /// Who is asking: the agent's name, or the workflow's.
    var title: String {
        switch payload {
        case .workflow(let item): item.run.workflowName
        default: agent?.name ?? ""
        }
    }

    var detail: String {
        let parts: [String?] = switch payload {
        case .directPrompt(let item): [item.hostName, item.agentRole]
        case .dashboard(let item): [item.hostName, item.agentRole]
        case .workflow(let item): [item.hostName, String(localized: "Workflows")]
        case .waitingBot(let item): [item.hostName, item.agentRole]
        }
        return parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

extension DashboardAttentionItem {
    /// The Hermes prompt behind a Dashboard item. The same prompt also arrives on its open chat's
    /// connection, and this matches the two so it shows once.
    var promptID: String? {
        switch interaction {
        case .approval(let approval): approval.approvalID
        case .clarification(let request): request.requestID
        case .none: nil
        }
    }
}

/// What the shell gives the deck: everything waiting across the computer in use, and the way to
/// the chat or sign-off page behind an entry.
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

/// Needs you: every approval, question and sign-off that waits on the person, one per tab, each
/// answered here. It opens from ☰ and, for a chat's own prompts (`focusedClient`), from that chat.
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
    /// What was answered while the deck was open: its tab stays, checked off.
    @State private var resolved: [Resolved] = []

    private struct Resolved: Identifiable, Equatable {
        let id: String
        let kindTitle: String
        let message: String
    }

    private struct Slot: Identifiable {
        let id: String
        let kindTitle: String
        let live: NeedsYouEntry?
        let resolved: Resolved?
        var isResolved: Bool { live == nil }
    }

    private var liveEntries: [NeedsYouEntry] {
        var collected: [NeedsYouEntry] = []
        var seenIDs = Set<String>()

        if let focusedClient {
            let name = focusedAgentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            for prompt in focusedClient.prompts {
                let id = "prompt:\(prompt.id)"
                guard seenIDs.insert(id).inserted else { continue }
                collected.append(NeedsYouEntry(id: id, payload: .directPrompt(.init(
                    client: focusedClient, prompt: prompt, agentID: prompt.profile,
                    agentName: name.isEmpty ? "Hermes" : name, agentRole: nil, hostName: "",
                    conversationID: nil))))
            }
        }

        for item in deckContext?.entries() ?? [] {
            if let index = collected.firstIndex(where: { $0.id == item.id }) {
                // The shell knows the agent's role, its computer and the chat.
                collected[index] = item
            } else if seenIDs.insert(item.id).inserted {
                collected.append(item)
            }
        }
        return collected
    }

    private var slots: [Slot] {
        let live = liveEntries
        let liveIDs = Set(live.map(\.id))
        return live.map { Slot(id: $0.id, kindTitle: $0.kind.title, live: $0, resolved: nil) }
            + resolved.filter { !liveIDs.contains($0.id) }
                .map { Slot(id: $0.id, kindTitle: $0.kindTitle, live: nil, resolved: $0) }
    }

    private func activeSlot(in slots: [Slot]) -> Slot? {
        if let selectedID, let match = slots.first(where: { $0.id == selectedID }) { return match }
        return slots.first { !$0.isResolved } ?? slots.first
    }

    var body: some View {
        let waitingCount = liveEntries.count
        let allSlots = slots
        let active = activeSlot(in: allSlots)

        VStack(spacing: BighelpTokens.space12) {
            header(waitingCount: waitingCount)

            if allSlots.count > 1 {
                // Wraps: every tab stays on screen at a large text size.
                BighelpFlowLayout(spacing: 6, lineSpacing: 0) {
                    ForEach(Array(allSlots.enumerated()), id: \.element.id) { index, slot in
                        tab(index: index, slot: slot, isSelected: slot.id == active?.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let active {
                ScrollView {
                    card(for: active)
                        .padding(.bottom, BighelpTokens.space16)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else if let focusedClient, !focusedClient.connected,
                      let status = HostConnectionStatus(chat: .reconnecting) {
                reconnectingCard(status: status)
            } else {
                emptyCard
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.top, BighelpTokens.space8)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("needs-you.deck")
        .task {
            await deckContext?.refresh()
            if selectedID == nil { selectedID = liveEntries.first?.id }
        }
        .onChange(of: liveEntries.map(\.id)) { _, currentIDs in
            if let selectedID, !currentIDs.contains(selectedID), !resolved.contains(where: { $0.id == selectedID }),
               let next = currentIDs.first {
                self.selectedID = next
            } else if selectedID == nil {
                selectedID = currentIDs.first
            }
            // Answered somewhere else: a chat's own deck has nothing left to show.
            if currentIDs.isEmpty, let focusedClient, focusedClient.hasAuthoritativeEventCoverage, resolved.isEmpty {
                dismiss()
            }
        }
    }

    private func header(waitingCount: Int) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Text("Needs you")
                .font(.bighelp(.title3, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)

            let tint = waitingCount == 0 ? theme.success : theme.warning
            Text("\(waitingCount) waiting")
                .font(.bighelp(.caption, weight: .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, BighelpTokens.space8 + 2)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.16)))
                .accessibilityIdentifier("needs-you.count")

            Spacer(minLength: BighelpTokens.space8)

            // "Later", not "Done": answering is what's done. What's left keeps waiting.
            Button { dismiss() } label: {
                Text("Later")
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(theme.action)
                    .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget, alignment: .trailing)
                    .contentShape(.rect)
            }
            .keyboardShortcut(.cancelAction)
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier("needs-you.later")
        }
    }

    private func tab(index: Int, slot: Slot, isSelected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius12 - 2, style: .continuous)
        let fill = isSelected ? theme.action.opacity(theme.isDarkPalette ? 0.18 : 0.12) : theme.surface
        let border = isSelected ? theme.action : (contrast == .increased ? theme.primaryText : theme.border)

        return Button {
            BighelpHaptics.tap()
            selectedID = slot.id
        } label: {
            HStack(spacing: 4) {
                if slot.isResolved {
                    Image(systemName: "checkmark")
                        .font(.bighelp(.caption2, weight: .bold))
                }
                Text(verbatim: "\(index + 1) · \(slot.kindTitle)")
                    .font(.bighelp(.caption, weight: .semibold))
                    .strikethrough(slot.isResolved)
            }
            .foregroundStyle(isSelected ? theme.primaryText : theme.secondaryText)
            .opacity(slot.isResolved && !isSelected ? 0.6 : 1)
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, 7)
            .background(shape.fill(fill))
            .overlay { shape.strokeBorder(border, lineWidth: isSelected ? 1.5 : BighelpTokens.hairline) }
            // The pill is small; the whole row height takes the tap.
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle(.rounded(10))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("needs-you.tab.\(index)")
    }

    @ViewBuilder
    private func card(for slot: Slot) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            if let entry = slot.live {
                entryHeader(entry)
                switch entry.payload {
                case .directPrompt(let item):
                    DirectHermesPromptResponseView(client: item.client, prompt: item.prompt, look: .deck) { outcome in
                        noteResolved(entry, canceled: outcome == .canceled)
                    }
                    // A new prompt in this tab starts from its own answers.
                    .id(item.prompt.id)
                case .dashboard(let item):
                    NeedsYouDashboardCard(model: item.model, item: item.item) { noteResolved(entry) }
                case .workflow(let item):
                    NeedsYouSignoffCard(store: item.store, run: item.run) { noteResolved(entry) }
                        .id(item.run.id)
                case .waitingBot(let item):
                    Text("\(item.agentName) has something waiting in its chat.")
                        .font(.bighelp(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        let id = item.agentID
                        dismiss()
                        deckContext?.openAgentChat(id)
                    } label: {
                        Label("Open chat", systemImage: "arrow.up.right")
                            .font(.bighelp(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.actionForeground)
                            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                    }
                    .bighelpProminentButtonStyle()
                    .tint(theme.action)
                    .accessibilityIdentifier("needs-you.open-waiting-bot.\(item.agentID)")
                }
            } else if let record = slot.resolved {
                VStack(spacing: BighelpTokens.space8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(theme.success)
                        .accessibilityHidden(true)
                    Text(record.message)
                        .font(.bighelp(.headline, weight: .bold))
                        .foregroundStyle(theme.primaryText)
                        .multilineTextAlignment(.center)
                }
                .padding(.vertical, BighelpTokens.space20)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("needs-you.resolved")
            }
        }
        .padding(BighelpTokens.space16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .needsYouSurface(theme, contrast: contrast)
    }

    private func entryHeader(_ entry: NeedsYouEntry) -> some View {
        HStack(alignment: .center, spacing: BighelpTokens.space8) {
            if let agent = entry.agent {
                SimpleBotFace(agentID: agent.id, name: agent.name, imageURL: nil, size: 28)
            } else {
                BighelpIconTile(systemName: "flowchart")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .font(.bighelp(.subheadline, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.bighelp(.caption2))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: BighelpTokens.space8)

            openButton(for: entry)
        }
    }

    /// The way to the chat or page behind an entry, when that isn't where the person already is.
    @ViewBuilder
    private func openButton(for entry: NeedsYouEntry) -> some View {
        switch entry.payload {
        case .directPrompt(let item):
            if let conversationID = item.conversationID, conversationID != deckContext?.currentConversationID() {
                openLink("Open chat", identifier: "needs-you.open-chat") {
                    deckContext?.openConversation(conversationID)
                }
            }
        case .dashboard(let item):
            if let sessionID = item.item.sessionID, sessionID != deckContext?.currentConversationID() {
                openLink("Open chat", identifier: "needs-you.open-chat") {
                    deckContext?.openConversation(sessionID)
                }
            }
        case .workflow(let item):
            openLink("Open file", identifier: "needs-you.open-signoff") {
                deckContext?.openWorkflowSignoff(item.run.id)
            }
        case .waitingBot:
            EmptyView()
        }
    }

    private func openLink(_ title: LocalizedStringKey, identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            Label(title, systemImage: "arrow.up.right")
                .labelStyle(.titleAndIcon)
                .font(.bighelp(.caption, weight: .semibold))
                .foregroundStyle(theme.action)
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier(identifier)
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
        .needsYouSurface(theme, contrast: contrast)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("direct-hermes.attention.reconnecting")
    }

    private var emptyCard: some View {
        VStack(spacing: BighelpTokens.space8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(theme.success)
                .accessibilityHidden(true)
            Text("All caught up")
                .font(.bighelp(.headline, weight: .bold))
                .foregroundStyle(theme.primaryText)
        }
        .padding(BighelpTokens.space24)
        .frame(maxWidth: .infinity)
        .needsYouSurface(theme, contrast: contrast)
        .accessibilityIdentifier("needs-you.empty")
    }

    private func noteResolved(_ entry: NeedsYouEntry, canceled: Bool = false) {
        BighelpHaptics.success()
        if !resolved.contains(where: { $0.id == entry.id }) {
            let message = canceled ? String(localized: "Request canceled")
                : entry.agent.map { String(localized: "Sent to \($0.name)") } ?? String(localized: "Sent")
            resolved.append(Resolved(id: entry.id, kindTitle: entry.kind.title, message: message))
        }
        if let next = liveEntries.first(where: { $0.id != entry.id }) {
            selectedID = next.id
        } else if focusedClient != nil {
            dismiss()
        }
    }
}

// MARK: - A prompt in a chat that isn't open here

@MainActor
private struct NeedsYouDashboardCard: View {
    let model: DashboardModel
    let item: DashboardAttentionItem
    let onResolved: () -> Void

    @BighelpThemeReader private var theme
    @State private var customAnswer = ""
    @State private var asksToRemove = false

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
                NeedsYouDecisionButtons(
                    choices: approval.allowedDecisions,
                    approveIsLocked: false,
                    identifier: { "needs-you.dashboard.approval.\($0.rawValue)" }
                ) { decision in
                    resolve { await model.respondToApproval(itemID: item.id, decision: decision) }
                }
            case .clarification(let request):
                if let first = request.questions.first {
                    if first.question != item.title, first.question != item.detail {
                        Text(first.question)
                            .font(.bighelp(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(spacing: 6) {
                        ForEach(Array(first.choices.enumerated()), id: \.offset) { index, choice in
                            NeedsYouChoiceRow(title: choice, symbol: "arrow.right", isSelected: false) {
                                resolve { await model.respondToClarification(itemID: item.id, response: choice) }
                            }
                            .accessibilityIdentifier("needs-you.dashboard.choice.\(index)")
                        }
                    }
                }

                if request.allowsCustomResponse {
                    HStack(spacing: BighelpTokens.space8) {
                        TextField("Type another response", text: $customAnswer,
                                  prompt: Text("Type another response").bighelpFieldHint(theme))
                            .font(.bighelp(.subheadline))
                            .submitLabel(.send)
                            .onSubmit(sendCustomAnswer)
                            .accessibilityIdentifier("needs-you.dashboard.custom")

                        if !customAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Send", action: sendCustomAnswer)
                                .font(.bighelp(.caption, weight: .bold))
                                .foregroundStyle(theme.action)
                                .bighelpPlainButtonStyle()
                        }
                    }
                    .needsYouField(theme)
                }
            case .none:
                EmptyView()
            }

            if let message = model.mutationErrorMessage {
                Text(message)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isResolving { ProgressView().controlSize(.small) }

            removeButton
        }
        .disabled(isResolving)
    }

    /// For an item that has nothing left to answer (its chat was deleted): out of Needs you, never out
    /// of its chat. A button, not a swipe, so the Mac has it too.
    private var removeButton: some View {
        Button { asksToRemove = true } label: {
            Text("Remove")
                .font(.bighelp(.caption, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("needs-you.dashboard.remove")
        .confirmationDialog("Remove this from Needs you?", isPresented: $asksToRemove, titleVisibility: .visible) {
            // The deck drops the tab itself once the item leaves the Dashboard's list.
            Button("Remove", role: .destructive) { Task { await model.dismissAttention(id: item.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stays in its chat.")
        }
    }

    private func sendCustomAnswer() {
        let answer = customAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        resolve { await model.respondToClarification(itemID: item.id, response: answer) }
    }

    /// Answered only once the Dashboard dropped the item: a refused answer leaves it, with why.
    private func resolve(_ answer: @escaping @MainActor () async -> Void) {
        Task {
            await answer()
            if model.snapshot?.attentionItems.contains(where: { $0.id == item.id }) != true { onResolved() }
        }
    }
}

// MARK: - Workflow sign-off

/// A sign-off in the deck. It approves the same checked file as the sign-off page
/// (`WorkflowRunModel.signoff`), and only once the whole file is on screen.
@MainActor
private struct NeedsYouSignoffCard: View {
    let store: WorkflowsStore
    let run: WorkflowRunSummary
    let onResolved: () -> Void

    @State private var runModel: WorkflowRunModel
    @State private var showsWholeFile = false
    @State private var asksForChanges = false
    @State private var notes = ""
    @BighelpThemeReader private var theme

    /// A file longer than this opens in full before it can be approved.
    private static let previewLimit = 240

    init(store: WorkflowsStore, run: WorkflowRunSummary, onResolved: @escaping () -> Void) {
        self.store = store
        self.run = run
        self.onResolved = onResolved
        _runModel = State(initialValue: WorkflowRunModel(runID: run.id, client: store.client))
    }

    var body: some View {
        let signoff = runModel.detail?.signoff
        let text = runModel.signoffText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isLong = text.count > Self.previewLimit
        let mustOpenFile = isLong && !showsWholeFile
        let ready = runModel.signoffText != nil && !runModel.isWorking

        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Text("Sign off \(run.workflowName) · Run \(run.number)?")
                .font(.bighelp(.headline, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)

            if let signoff {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "\(run.stageTitle ?? signoff.stageKey) · sha256 \(WorkflowSHA.short(signoff.artifactSHA256))")
                        .font(.bighelp(.caption).monospaced())
                        .foregroundStyle(theme.secondaryText)

                    if !text.isEmpty {
                        Text(mustOpenFile ? String(text.prefix(Self.previewLimit)) + "…" : text)
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.primaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if isLong {
                            NeedsYouShowAllButton(showsAll: $showsWholeFile)
                                .accessibilityIdentifier("needs-you.signoff.show-all")
                        }
                    } else if runModel.isLoadingFile {
                        ProgressView().controlSize(.small)
                    }
                }
                .needsYouInset(theme)
            } else {
                ProgressView().controlSize(.small)
            }

            if asksForChanges {
                TextField("What should change?", text: $notes,
                          prompt: Text("What should change?").bighelpFieldHint(theme), axis: .vertical)
                    .lineLimit(1...3)
                    .font(.bighelp(.subheadline))
                    .needsYouField(theme)
                    .accessibilityIdentifier("needs-you.signoff.notes")
            }

            if let message = runModel.message {
                Text(message)
                    .font(.bighelp(.caption))
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: BighelpTokens.space8) { buttons(ready: ready, mustOpenFile: mustOpenFile) }
                VStack(spacing: BighelpTokens.space8) { buttons(ready: ready, mustOpenFile: mustOpenFile) }
            }
        }
        .task {
            await runModel.load()
            await runModel.loadSignoffFile()
        }
    }

    @ViewBuilder
    private func buttons(ready: Bool, mustOpenFile: Bool) -> some View {
        Button {
            send(.approve, notes: "")
        } label: {
            Text("Approve")
                .font(.bighelp(.subheadline, weight: .bold))
                .foregroundStyle(theme.actionForeground)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
        }
        .bighelpProminentButtonStyle()
        .tint(theme.action)
        .disabled(!ready || mustOpenFile)
        .accessibilityIdentifier("needs-you.signoff.approve")

        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
        Button {
            if asksForChanges { send(.changes, notes: notes) } else { asksForChanges = true }
        } label: {
            Text(asksForChanges ? "Send notes" : "Changes")
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .padding(.horizontal, BighelpTokens.space12)
                .frame(minHeight: BighelpTokens.hitTarget)
                .background(shape.fill(theme.canvas))
                .overlay { shape.strokeBorder(theme.border, lineWidth: BighelpTokens.hairline) }
                .contentShape(shape)
        }
        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
        .disabled(!ready || (asksForChanges && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        .accessibilityIdentifier("needs-you.signoff.changes")
    }

    private func send(_ decision: WorkflowSignoffDecision, notes: String) {
        Task {
            guard await runModel.signoff(decision, notes: notes) else { return }
            await store.load()
            onResolved()
        }
    }
}

// MARK: - Shared pieces (the deck and `DirectHermesPromptResponseView`'s deck look)

/// An approval's choices, in one order everywhere: once, this session, always, decline. The first
/// approving choice is the filled button.
struct NeedsYouDecisionButtons: View {
    let choices: [ApprovalDecision]
    /// Something must be read in full first: only Decline works until then.
    let approveIsLocked: Bool
    let identifier: (ApprovalDecision) -> String
    let onDecide: (ApprovalDecision) -> Void

    @BighelpThemeReader private var theme

    private static let order: [ApprovalDecision] = [.once, .session, .always, .deny]

    var body: some View {
        let ordered = Self.order.filter(choices.contains)
        let primary = ordered.first { $0 != .deny }
        // Side by side while they fit; one under another at a large text size.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BighelpTokens.space8) {
                ForEach(ordered, id: \.rawValue) { button($0, isPrimary: $0 == primary, fills: $0 == primary) }
            }
            VStack(spacing: BighelpTokens.space8) {
                ForEach(ordered, id: \.rawValue) { button($0, isPrimary: $0 == primary, fills: true) }
            }
        }
    }

    @ViewBuilder
    private func button(_ decision: ApprovalDecision, isPrimary: Bool, fills: Bool) -> some View {
        if isPrimary {
            Button { onDecide(decision) } label: {
                Text(title(decision))
                    .font(.bighelp(.subheadline, weight: .bold))
                    .foregroundStyle(theme.actionForeground)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            }
            .bighelpProminentButtonStyle()
            .tint(theme.action)
            .disabled(approveIsLocked)
            .accessibilityHint(decision.accessibilityHint)
            .accessibilityIdentifier(identifier(decision))
        } else {
            let isDeny = decision == .deny
            let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
            Button(role: isDeny ? .destructive : nil) { onDecide(decision) } label: {
                Text(title(decision))
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(isDeny ? theme.danger : theme.primaryText)
                    .padding(.horizontal, BighelpTokens.space12)
                    .frame(maxWidth: fills ? .infinity : nil, minHeight: BighelpTokens.hitTarget)
                    .background(shape.fill(isDeny ? theme.danger.opacity(0.10) : theme.canvas))
                    .overlay {
                        shape.strokeBorder(isDeny ? theme.danger.opacity(0.55) : theme.border,
                                           lineWidth: isDeny ? 1.25 : BighelpTokens.hairline)
                    }
                    .contentShape(shape)
            }
            .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
            .disabled(approveIsLocked && !isDeny)
            .accessibilityHint(decision.accessibilityHint)
            .accessibilityIdentifier(identifier(decision))
        }
    }

    private func title(_ decision: ApprovalDecision) -> String {
        switch decision {
        case .once: String(localized: "Approve once")
        case .session: String(localized: "Session")
        case .always: String(localized: "Always")
        case .deny: String(localized: "Decline")
        }
    }
}

/// One answer to pick, as a full-width row.
struct NeedsYouChoiceRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @BighelpThemeReader private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
        Button(action: action) {
            HStack(spacing: BighelpTokens.space8) {
                Text(title)
                    .font(.bighelp(.subheadline, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: BighelpTokens.space8)
                Image(systemName: symbol)
                    .font(.bighelp(.footnote, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.action : theme.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            .background(shape.fill(isSelected ? theme.action.opacity(0.14) : theme.canvas))
            .overlay {
                shape.strokeBorder(isSelected ? theme.action : theme.border,
                                   lineWidth: isSelected ? 1.5 : BighelpTokens.hairline)
            }
            .contentShape(shape)
        }
        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "Show all" under a long command or file, which its Approve waits for.
struct NeedsYouShowAllButton: View {
    @Binding var showsAll: Bool
    @BighelpThemeReader private var theme

    var body: some View {
        Button { showsAll.toggle() } label: {
            Text(showsAll ? "Show less" : "Show all")
                .font(.bighelp(.caption, weight: .semibold))
                .foregroundStyle(theme.action)
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
    }
}

extension View {
    /// A card in the deck.
    func needsYouSurface(_ theme: BighelpTheme, contrast: ColorSchemeContrast) -> some View {
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous)
        return background(shape.fill(theme.surface))
            .overlay {
                shape.strokeBorder(contrast == .increased ? theme.primaryText : theme.border,
                                   lineWidth: contrast == .increased ? 1.5 : BighelpTokens.hairline)
            }
    }

    /// What's being approved (a command, a file), set into its card.
    func needsYouInset(_ theme: BighelpTheme) -> some View {
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
        return padding(BighelpTokens.space12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(theme.raisedSurface))
            .overlay { shape.strokeBorder(theme.border, lineWidth: BighelpTokens.hairline) }
    }

    /// A text field in a card.
    func needsYouField(_ theme: BighelpTheme) -> some View {
        let shape = RoundedRectangle(cornerRadius: BighelpTokens.radius12, style: .continuous)
        return padding(.horizontal, BighelpTokens.space12)
            .padding(.vertical, 9)
            .frame(minHeight: BighelpTokens.hitTarget)
            .background(shape.fill(theme.canvas))
            .overlay { shape.strokeBorder(theme.border, lineWidth: BighelpTokens.hairline) }
    }
}
