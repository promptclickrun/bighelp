import SwiftUI

struct DirectHermesChatView: View {
    let chat: DirectHermesChat
    let store: DirectHermesWorkspaceStore
    @State private var showsSupport = false
    @State private var showsControls = false
    @State private var showsAttention = false
    @State private var composerFocusRequest = 0

    @Environment(\.scenePhase) private var scenePhase
    @BighelpThemeReader private var theme

    private var agentName: String {
        store.profiles.first(where: { $0.id == chat.client.profile })?.name ?? "Hermes"
    }

    var body: some View {
        VStack(spacing: 0) {
            if !chat.client.connected {
                Button("Reconnect to this host", systemImage: "arrow.clockwise") {
                    Task { await store.suspend(); await store.reconnect() }
                }
                .accessibilityIdentifier("direct-hermes.reconnect")
            }
            ChatView(model: chat.model, agentName: agentName, agentRole: chat.client.profile,
                agentStatus: "Direct · \(chat.client.status)",
                directHermesClient: chat.client,
                directHermesClarifications: chat.client.prompts.filter { $0.kind == .clarification },
                composerFocusRequest: composerFocusRequest,
                onAttachmentTap: nil,
                onProjectChangesTap: { showsSupport = true },
                onVoiceTap: { showsSupport = true },
                onApprovalTap: { _ in showsAttention = true },
                onPeopleTap: { showsSupport = true },
                onNewChatTap: { Task { await store.newChat() } },
                sessionControlAccessory: ChatSessionControlAccessory(
                    title: chat.client.modelName,
                    isEnabled: chat.client.connected,
                    accessibilityIdentifier: "direct-hermes.controls",
                    action: { showsControls = true }
                ))
                .environment(\.chatSurfaceCapabilities, .standaloneDirect)
        }
        .chatAttention(client: chat.client, agentName: agentName, isPresented: $showsAttention,
                       canPopUp: scenePhase == .active && !showsSupport && !showsControls)
        .background(theme.canvas.ignoresSafeArea())
        .bighelpSheet(isPresented: $showsSupport) { DirectHermesSupportView().bighelpSheetSize(.standard) }
        .bighelpSheet(isPresented: $showsControls) { DirectHermesControlsView(chat: chat).bighelpSheetSize(.standard) }
        .task(id: chat.id) {
            // Match the app's new-chat preparation: mounting an empty native
            // chat is an explicit request to write, not to reopen account input.
            guard chat.model.items.isEmpty else { return }
            await Task.yield()
            composerFocusRequest += 1
        }
    }
}

private struct DirectHermesControlsView: View {
    let chat: DirectHermesChat
    @Environment(\.dismiss) private var dismiss
    @State private var modelIdentifier = ""
    @State private var commands: [(name: String, detail: String)] = []
    @State private var error: String?
    @State private var isApplying = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Current model", value: chat.client.modelName)
                    TextField("Model or provider:model identifier", text: $modelIdentifier)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("direct-hermes.model")
                    Button("Use for this session") {
                        isApplying = true
                        Task {
                            defer { isApplying = false }
                            do { try await chat.client.setSessionModel(modelIdentifier); error = nil }
                            catch { self.error = DirectHermesConversationClient.safeMessage(error) }
                        }
                    }
                    .disabled(isApplying || chat.model.isSending || modelIdentifier.isEmpty || !chat.client.connected)
                    .accessibilityIdentifier("direct-hermes.model-apply")
                } header: { Text("Model") } footer: {
                    Text("This changes only the native session, not profile defaults. Models stay fixed while a turn is running.")
                }
                if let error { Section { Text(error).foregroundStyle(.secondary) } }
                Section {
                    ForEach(commands, id: \.name) { command in
                        Button {
                            // Stage, never auto-send or erase an existing draft.
                            chat.model.draft += (chat.model.draft.isEmpty ? "" : "\n") + command.name + " "
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(command.name)
                                Text(command.detail).bighelpFont(.metadata).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Advanced · Host commands") } footer: {
                    Text("A command is inserted into your draft, never sent automatically. Review its arguments; some commands change host configuration.")
                }
            }
            .bighelpFormSurface()
            .navigationTitle("Session settings")
            // "Later", not "Done": the card's own Done is what answers.
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
            .task {
                modelIdentifier = chat.client.modelName
                do { commands = try await chat.client.commandCatalog() }
                catch { self.error = DirectHermesConversationClient.safeMessage(error) }
            }
        }
    }
}

struct DirectHermesAttentionView: View {
    let client: DirectHermesConversationClient
    var agentName: String? = nil
    @Environment(\.dismiss) private var dismiss

    /// Changes when the chat gets a new connection or the list empties or fills.
    private struct Waiting: Hashable {
        let client: ObjectIdentifier
        let isEmpty: Bool
        let isLive: Bool
    }

    var body: some View {
        NeedsYouDeckView(focusedClient: client, focusedAgentName: agentName)
            .task(id: Waiting(client: ObjectIdentifier(client), isEmpty: client.prompts.isEmpty,
                              isLive: client.hasAuthoritativeEventCoverage)) {
                // Back online with nothing resent: it was answered or expired while away.
                guard client.prompts.isEmpty, client.hasAuthoritativeEventCoverage else { return }
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, client.prompts.isEmpty else { return }
                dismiss()
            }
    }
}

/// One waiting approval or question, and its answer. `card` is the card in the chat; `deck` is its
/// page in Needs you (`NeedsYouDeckView`). Both answer through the same code.
struct DirectHermesPromptResponseView: View {
    enum Look { case card, deck }
    /// How a prompt left: answered, or canceled without one.
    enum Outcome { case answered, canceled }

    let client: DirectHermesConversationClient
    let prompt: DirectHermesPrompt
    var look = Look.card
    /// Called once Hermes took the answer or the cancel.
    var onResolved: ((Outcome) -> Void)? = nil

    @Environment(\.directHermesWorkspace) private var workspace
    @BighelpThemeReader private var theme
    /// One answer in your own words for the whole prompt (`ClarificationAnswers`).
    @State private var ownWords = ""
    @State private var selections: [Int: Set<Int>] = [:]
    @State private var initializedPromptID: String?
    @State private var isSubmitting = false
    @State private var error: String?
    /// Deck: a long command was opened in full, which Approve waits for.
    @State private var showsFullCommand = false

    var body: some View {
        Group {
            switch look {
            case .card:
                BighelpCard {
                    VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                        Label(prompt.title, systemImage: "questionmark.bubble.fill")
                            .bighelpFont(.sectionTitle)
                        content
                    }
                }
            case .deck:
                VStack(alignment: .leading, spacing: BighelpTokens.space12) { deckContent }
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
    private var content: some View {
        if let approval = prompt.approval {
            if let command = approval.command, !command.isEmpty {
                Text(command)
                    .font(.bighelp(.body).monospaced())
                    .textSelection(.enabled)
            }
            if let description = approval.description, !description.isEmpty {
                Text(description).textSelection(.enabled)
            }
            ForEach(approval.choices, id: \.rawValue) { decision in
                Button(role: decision == .deny ? .destructive : nil) {
                    submitApproval(decision)
                } label: {
                    Text(decision.buttonTitle)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .accessibilityHint(decision.accessibilityHint)
                .accessibilityIdentifier("direct-hermes.approval.\(decision.rawValue).\(prompt.id)")
            }
        } else if let clarification = prompt.clarification {
            ForEach(Array(clarification.questions.enumerated()), id: \.offset) { questionIndex, question in
                clarificationQuestion(question, questionIndex: questionIndex, clarification: clarification)
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
                    axis: .vertical
                )
                .lineLimit(1...4)
                .submitLabel(.done)
                .onSubmit { submitClarification(clarification) }
                .accessibilityIdentifier("direct-hermes.clarification.custom.\(prompt.id)")
            }
            Button("Done") { submitClarification(clarification) }
                .disabled(completeAnswers(for: clarification) == nil)
                .accessibilityIdentifier("direct-hermes.clarification.done.\(prompt.id)")
        }

        Button("Cancel request", role: .cancel) { cancelPrompt() }
            .accessibilityHint("Cancels this prompt without sending a chat message.")
            .accessibilityIdentifier("direct-hermes.prompt.cancel.\(prompt.id)")

        if let error {
            Text(error).bighelpFont(.metadata).foregroundStyle(.secondary)
        }
        if isSubmitting { ProgressView("Sending response") }
    }

    @ViewBuilder
    private func clarificationQuestion(
        _ question: DirectHermesPrompt.Question,
        questionIndex: Int,
        clarification: DirectHermesPrompt.Clarification
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question)
                .textSelection(.enabled)
                .accessibilityIdentifier(
                    "direct-hermes.clarification.question.\(questionIndex).\(prompt.id)"
                )
            if let locked = question.lockedAnswer {
                Label(locked, systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Locked answer: \(locked)")
            } else {
                ForEach(Array(question.choices.enumerated()), id: \.offset) { choiceIndex, choice in
                    let selected = selections[questionIndex, default: []].contains(choiceIndex)
                    Button {
                        choose(
                            choiceIndex,
                            questionIndex: questionIndex,
                            question: question,
                            clarification: clarification
                        )
                    } label: {
                        Label(choice, systemImage: selected ? "checkmark.circle.fill" : "circle")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "direct-hermes.clarification.question.\(questionIndex).choice.\(choiceIndex).\(prompt.id)"
                    )
                }
            }
        }
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

    private func submitApproval(_ decision: ApprovalDecision) {
        perform(.answered) { try await client.respond(to: prompt, decision: decision) }
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
            perform(.answered) { try await client.respond(to: prompt, answers: complete) }
        } else if let question = clarification.questions.first,
                  let answer = complete[question.id] {
            perform(.answered) { try await client.respond(to: prompt, value: answer) }
        }
    }

    private func cancelPrompt() {
        perform(.canceled) { try await client.cancel(prompt) }
    }

    private func perform(_ outcome: Outcome, _ operation: @escaping @MainActor () async throws -> Void) {
        guard !isSubmitting else { return }
        isSubmitting = true
        error = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await operation()
                onResolved?(outcome)
            } catch { self.error = DirectHermesConversationClient.safeMessage(error) }
        }
    }

    // MARK: Needs you

    /// A command longer than this opens in full before it can be approved.
    private static let commandPreviewLimit = 220

    @ViewBuilder
    private var deckContent: some View {
        if let approval = prompt.approval {
            deckApproval(approval)
        } else if let clarification = prompt.clarification {
            deckClarification(clarification)
        }

        HStack {
            Button("Cancel request", role: .cancel) { cancelPrompt() }
                .font(.bighelp(.caption, weight: .semibold))
                .foregroundStyle(theme.secondaryText)
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
                .bighelpPlainButtonStyle()
                .accessibilityHint("Cancels this prompt without sending a chat message.")
                .accessibilityIdentifier("direct-hermes.prompt.cancel.\(prompt.id)")
            Spacer()
            if isSubmitting { ProgressView().controlSize(.small) }
        }

        if let error {
            Text(error)
                .font(.bighelp(.caption))
                .foregroundStyle(theme.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func deckApproval(_ approval: DirectHermesPrompt.Approval) -> some View {
        let description = approval.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = approval.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isLongCommand = command.count > Self.commandPreviewLimit
        let mustOpenCommand = isLongCommand && !showsFullCommand

        Text(description.isEmpty ? prompt.title : description)
            .font(.bighelp(.headline, weight: .bold))
            .foregroundStyle(theme.primaryText)
            .fixedSize(horizontal: false, vertical: true)

        if !command.isEmpty {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(mustOpenCommand ? String(command.prefix(Self.commandPreviewLimit)) + "…" : command)
                    .font(.bighelp(.footnote).monospaced())
                    .foregroundStyle(theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isLongCommand {
                    NeedsYouShowAllButton(showsAll: $showsFullCommand)
                        .accessibilityIdentifier("direct-hermes.approval.show-all.\(prompt.id)")
                }
            }
            .needsYouInset(theme)
        }

        if let tool = approval.toolName, !tool.isEmpty {
            Text("Tool: \(tool)")
                .font(.bighelp(.caption))
                .foregroundStyle(theme.secondaryText)
        }

        NeedsYouDecisionButtons(
            choices: approval.choices,
            approveIsLocked: mustOpenCommand,
            identifier: { "direct-hermes.approval.\($0.rawValue).\(prompt.id)" },
            onDecide: submitApproval
        )
    }

    @ViewBuilder
    private func deckClarification(_ clarification: DirectHermesPrompt.Clarification) -> some View {
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
                            let selected = selections[questionIndex, default: []].contains(choiceIndex)
                            NeedsYouChoiceRow(
                                title: choice,
                                symbol: selected ? "checkmark.circle.fill" : (question.isMultiSelect ? "circle" : "arrow.right"),
                                isSelected: selected
                            ) {
                                choose(choiceIndex, questionIndex: questionIndex, question: question,
                                       clarification: clarification)
                            }
                            .accessibilityIdentifier(
                                "direct-hermes.clarification.question.\(questionIndex).choice.\(choiceIndex).\(prompt.id)"
                            )
                        }
                    }
                }
            }
        }

        let ownWordsTitle: LocalizedStringKey = clarification.questions.count > 1
            ? "Or answer in your own words" : "Type another response"
        if ClarificationAnswers.acceptsOwnWords(clarification.questions.map(\.answerShape)) {
            TextField(
                ownWordsTitle,
                text: Binding(
                    get: { ownWords },
                    set: { value in
                        ownWords = value
                        if clarification.questions.count == 1, !value.isEmpty { selections[0] = [] }
                    }
                ),
                prompt: Text(ownWordsTitle).bighelpFieldHint(theme),
                axis: .vertical
            )
            .lineLimit(1...3)
            .font(.bighelp(.subheadline))
            .submitLabel(.done)
            .onSubmit { submitClarification(clarification) }
            .needsYouField(theme)
            .accessibilityIdentifier("direct-hermes.clarification.custom.\(prompt.id)")
        }

        // One tap on a choice answers a single question; Done is for everything else.
        if requiresExplicitDone(clarification) || !ownWords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || clarification.questions.contains(where: { $0.choices.isEmpty }) {
            Button { submitClarification(clarification) } label: {
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
}

struct DirectHermesSupportView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Native Hermes") {
                    Text("Messages, reasoning, tools, subagents, profiles, and saved sessions come directly from Hermes.")
                    Text("Stop, steer, queued prompts, approvals, clarification, and commands use native requests. Acceptance does not prove a queued prompt or steer was consumed; review retained submissions after an interrupted connection.")
                }
                Section("Separate integrations") {
                    Text("Wiki, Cards and forms, phone tools, voice, project changes, and notifications need their own supported integrations. They are never silently forwarded through Link.")
                    Text("Standalone hosts do not yet expose attachments, full provider picking, multi-question clarification, or subagent control windows in bighelp. Hermes may support more than this client shows.")
                }
                Section("History & recovery") {
                    Text("Saved history can have tool summaries without live IDs or results and may be less detailed than the live stream. Local text and uncertain submissions stay bound to the exact account, host, and profile.")
                    Text("Reopening reattaches without resending prompts. If the runtime is gone, choose a saved session. \(BighelpPlatform.isMac ? "macOS" : "iOS") can suspend sockets; notifications require separate verified enrollment.")
                }
            }
            .navigationTitle("Host support")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// A host without an activity feed must not masquerade as an empty inbox or
