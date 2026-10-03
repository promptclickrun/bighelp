import SwiftUI

/// Leaving bighelp keeps what's typed in new chats that haven't sent anything (`UnsentDraftStore`).
/// Coming back, if such a chat didn't survive, asks "Would you like to continue where you left
/// off?": one draft opens a new chat with that agent and the text in the message box; several
/// let the person pick one.
struct UnsentDraftRecovery: ViewModifier {
    let scenePhase: ScenePhase
    let hostID: UUID?
    let currentDrafts: () -> [(chatID: String, agentID: String, text: String)]
    let agentName: (String) -> String
    let chatExists: (String) -> Bool
    let isReady: () -> Bool
    let onContinue: (UnsentDraft) -> Void
    let onDismiss: () -> Void

    @State private var isAsking = false
    @State private var isPicking = false
    @State private var returnCheck = UUID()

    private var store: UnsentDraftStore { .shared }

    func body(content: Content) -> some View {
        let lost = store.lostDrafts(hostID: hostID)
        content
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { record() }
                if phase == .active { returnCheck = UUID() }
            }
            .task(id: returnCheck) { await checkAfterReturning() }
            .onChange(of: lost.map(\.id)) { _, ids in
                if !ids.isEmpty, scenePhase == .active, !isPicking { isAsking = true }
            }
            .alert("Would you like to continue where you left off?", isPresented: $isAsking,
                   presenting: lost.isEmpty ? nil : lost) { drafts in
                if drafts.count == 1, let draft = drafts.first {
                    Button("Continue") { continueDraft(draft) }
                } else {
                    Button("Choose a draft") { isPicking = true }
                }
                Button("Not now", role: .cancel) { letGo() }
            } message: { drafts in
                Text(Self.message(drafts))
            }
            .sheet(isPresented: $isPicking) {
                UnsentDraftPicker(drafts: lost, onPick: { draft in
                    isPicking = false
                    continueDraft(draft)
                }, onLetGo: {
                    isPicking = false
                    letGo()
                })
                .bighelpSheetSize(.compact)
            }
    }

    static func message(_ drafts: [UnsentDraft]) -> String {
        guard drafts.count == 1, let draft = drafts.first else {
            return "You have \(drafts.count) unsent messages from before you left."
        }
        return "You were writing to \(draft.agentName): “\(snippet(draft.text))”"
    }

    static func snippet(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > 120 ? String(line.prefix(117)) + "…" : line
    }

    private func record() {
        let now = Date()
        store.record(currentDrafts().map { draft in
            UnsentDraft(id: draft.chatID, hostID: hostID, agentID: draft.agentID,
                        agentName: agentName(draft.agentID), text: draft.text, savedAt: now)
        }, hostID: hostID)
    }

    /// Once the connection is back (and has had its say about which chats survived), any kept
    /// draft without its chat is offered back. Drops that happen later arrive through
    /// `markLost` as the chat is retired.
    private func checkAfterReturning() async {
        guard scenePhase == .active, !store.drafts.isEmpty else { return }
        for _ in 0..<40 where !isReady() {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
        }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, isReady() else { return }
        store.markMissing(hostID: hostID, chatExists: chatExists)
        if !store.lostDrafts(hostID: hostID).isEmpty, !isPicking { isAsking = true }
    }

    private func continueDraft(_ draft: UnsentDraft) {
        store.remove(draft.id)
        onContinue(draft)
    }

    private func letGo() {
        store.discardLost(hostID: hostID)
        onDismiss()
    }
}

/// Several unsent drafts: pick the one to continue.
struct UnsentDraftPicker: View {
    let drafts: [UnsentDraft]
    let onPick: (UnsentDraft) -> Void
    let onLetGo: () -> Void

    var body: some View {
        NavigationStack {
            List(drafts) { draft in
                Button { onPick(draft) } label: {
                    VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                        HStack {
                            Text(draft.agentName)
                                .font(.bighelp(.subheadline).weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                            Spacer()
                            Text(draft.savedAt, style: .relative)
                                .font(.bighelp(.caption))
                                .foregroundStyle(theme.secondaryText)
                        }
                        Text(UnsentDraftRecovery.snippet(draft.text))
                            .font(.bighelp(.body))
                            .foregroundStyle(theme.primaryText)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
                    .contentShape(.rect)
                }
                .bighelpPlainButtonStyle()
                .listRowBackground(theme.surface)
                .accessibilityIdentifier("unsent-drafts.draft.\(draft.id)")
            }
            .scrollContentBackground(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .navigationTitle("Continue a draft")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now", action: onLetGo)
                        .accessibilityIdentifier("unsent-drafts.not-now")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unsent-drafts.picker")
    }

    @BighelpThemeReader private var theme
}

extension RootShellView {
    /// Offers back a new chat's draft that leaving the app lost.
    var unsentDraftRecovery: UnsentDraftRecovery {
        UnsentDraftRecovery(
            scenePhase: scenePhase,
            hostID: hostRegistry?.selectedHostID,
            currentDrafts: { featureStore.unsentNewChatDrafts() },
            agentName: { id in agents.profiles.first { $0.id == id }?.name ?? "your agent" },
            chatExists: { featureStore.preparedChatModel(id: $0) != nil },
            isReady: { hostRegistry?.isWorkspaceReady == true && nativeWorkspaceStore?.isConnected == true
                && nativeRuntime?.isRefreshing != true },
            onContinue: { draft in
                leaveLostChat()
                appState.pendingComposerText = draft.text
                startNewChat(explicitAgentID: draft.agentID)
            },
            onDismiss: { leaveLostChat() }
        )
    }

    /// A chat whose session is gone shows "Route unavailable"; step off it.
    private func leaveLostChat() {
        guard case .chat(let id)? = appState.path.last, featureStore.preparedChatModel(id: id) == nil else { return }
        appState.path.removeLast()
    }
}
