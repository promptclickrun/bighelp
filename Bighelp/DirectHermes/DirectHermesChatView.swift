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
                onWorkspaceTap: { store.showSessions() },
                showsWorkspaceButton: true,
                onNewChatTap: { Task { await store.newChat() } },
                sessionControlAccessory: ChatSessionControlAccessory(
                    title: chat.client.modelName,
                    isEnabled: chat.client.connected,
                    accessibilityIdentifier: "direct-hermes.controls",
                    action: { showsControls = true }
                ),
                workspaceButtonLabel: "Sessions")
                .environment(\.chatSurfaceCapabilities, .standaloneDirect)
        }
        .chatAttention(client: chat.client, agentName: agentName, isPresented: $showsAttention,
                       canPopUp: scenePhase == .active && !showsSupport && !showsControls)
        .background(theme.canvas.ignoresSafeArea())
        .sheet(isPresented: $showsSupport) { DirectHermesSupportView().bighelpSheetSize(.standard) }
        .sheet(isPresented: $showsControls) { DirectHermesControlsView(chat: chat).bighelpSheetSize(.standard) }
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
    @Environment(\.dismiss) private var dismiss

    /// Changes when the chat gets a new connection or the list empties or fills.
    private struct Waiting: Hashable {
        let client: ObjectIdentifier
        let isEmpty: Bool
        let isLive: Bool
    }

    var body: some View {
        NavigationStack {
            List {
                // The connection closed while bighelp was away. Hermes sends
                // what's still waiting again once it's back.
                if client.prompts.isEmpty, let status = HostConnectionStatus(chat: .reconnecting) {
                    Section {
                        HStack(spacing: BighelpTokens.space12) {
                            BighelpConnectionIndicator(phase: status.phase)
                            Text(status.label)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("direct-hermes.attention.reconnecting")
                    }
                }
                ForEach(client.prompts) { prompt in
                    DirectHermesPromptResponseView(client: client, prompt: prompt)
                }
                Section {} footer: {
                    Text("Later keeps it waiting. Answer any time from the bar at the top of the chat.")
                }
            }
            .navigationTitle("Needs attention")
            // "Later", not "Done": the card's own Done is what answers.
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() }.keyboardShortcut(.cancelAction).bighelpToolbarText() } }
            .onChange(of: client.prompts.map(\.id)) { _, promptIDs in
                // Answered, here or elsewhere. A dropped connection also empties
                // the list, but then the chat isn't live and this stays open.
                if promptIDs.isEmpty, client.hasAuthoritativeEventCoverage { dismiss() }
            }
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
}

struct DirectHermesPromptResponseView: View {
    let client: DirectHermesConversationClient
    let prompt: DirectHermesPrompt
    var inline = false

    @Environment(\.directHermesWorkspace) private var workspace
    /// One answer in your own words for the whole prompt (`ClarificationAnswers`).
    @State private var ownWords = ""
    @State private var selections: [Int: Set<Int>] = [:]
    @State private var initializedPromptID: String?
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        Group {
            if inline {
                BighelpCard {
                    VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                        Label(prompt.title, systemImage: "questionmark.bubble.fill")
                            .bighelpFont(.sectionTitle)
                        content
                    }
                }
            } else {
                Section {
                    content
                } header: {
                    Text(prompt.title)
                }
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
        perform { try await client.respond(to: prompt, decision: decision) }
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
            perform { try await client.respond(to: prompt, answers: complete) }
        } else if let question = clarification.questions.first,
                  let answer = complete[question.id] {
            perform { try await client.respond(to: prompt, value: answer) }
        }
    }

    private func cancelPrompt() {
        perform { try await client.cancel(prompt) }
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
