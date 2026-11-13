import SwiftUI

// New chat: the round button beside the bar opens the new chat's own screen, which is the ordinary
// chat with a To row, the bots to pick from and, for one bot, the choices that make it a coding
// session (`ChatNewChatSlot`). One bot is a chat, two to six a group chat.
extension RootShellView {
    var newChatSession: NewChatSession { home.newChat }

    /// The round button, ⌘N and the New chat swipe. Nobody is picked yet: the blank chat under the
    /// To row is the primary bot's until a pick makes it another bot's.
    func openNewChat() {
        newChatSession.start()
        startNewChat(explicitAgentID: nil, tracksNewChat: true)
    }

    /// New chat's parts for its own blank chat, and nil for every other chat. Decided from the
    /// chat's id, never from its messages: the chat stops drawing them once something is sent.
    func newChatSlot(forChat id: String, model: ChatModel) -> ChatNewChatSlot? {
        guard id == newChatSession.conversationID else { return nil }
        let session = newChatSession
        let context = newChatContext
        let choices: AnyView? = if session.recipients.count == 1, let store = newChatCodeStore,
                                   let bot = session.recipients.first {
            AnyView(NewChatChoicesHost(model: model, session: session, store: store, agentID: bot.profileID,
                                       onWorktrees: { codeSheet = .worktrees },
                                       onSendAll: { _ = sendNewChat(from: model) }))
        } else {
            nil
        }
        return ChatNewChatSlot(
            toRow: AnyView(NewChatToRow(context: context)),
            people: AnyView(NewChatPeopleList(context: context)),
            choicesRow: choices,
            sendOverride: { sendNewChat(from: model) },
            // A group chat's or a coding session's first message goes as text only.
            offersAttachments: session.recipients.count == 1 && session.project == nil)
    }

    /// The computer in use's Code store, where it can start coding sessions.
    private var newChatCodeStore: CodeHomeStore? {
        guard let store = codeHome, store.scopeID == currentWorkspaceOwner?.cacheScopeID else { return nil }
        return store
    }

    private var newChatRules: NewChatGroupRules {
        NewChatGroupRules(hostInUse: showsEveryHost ? fleet?.selectedHostID : nil,
                          canMakeGroups: botModeRooms.offersNewGroupChat,
                          seatableProfiles: botModeRooms.nativeCapabilities?.seatableProfiles)
    }

    private var newChatContext: NewChatContext {
        let bots = homeBots
        let groups = simpleBotsGateways?.groups ?? SimpleBotsHomeProjection.groups(
            sessionCatalog.recentSummaries(includeCronSessions: false), rooms: botModeRooms.catalogRooms,
            hostID: nil, bots: bots)
        return NewChatContext(
            session: newChatSession, bots: bots,
            hosts: showsEveryHost ? fleet?.hosts ?? [] : [],
            groups: groups, rules: newChatRules,
            activity: botChatActivity, activitySource: botChatActivitySource,
            isLoading: bots.isEmpty && !agents.knowsProfiles && !usesWorkspaceFixtures,
            onRecipientsChanged: { newChatRecipientsChanged($0) },
            onOpenGroup: { openNewChatGroup($0) })
    }

    /// One bot picked: the blank chat becomes that bot's, so the message box, its model control and
    /// Send are its own. Text already typed goes with it. A bot on another computer makes that
    /// computer the one in use first; the To row stays (`HomeSelection`).
    private func newChatRecipientsChanged(_ recipients: [SimpleBotsBot]) {
        guard recipients.count == 1, let bot = recipients.first else { return }
        let blank = newChatSession.conversationID.flatMap { featureStore.preparedChatModel(id: $0) }
        if let hostID = bot.hostID, let fleet, hostID != fleet.selectedHostID {
            home.newChatText = blank?.draft
            home.newChatFollowsPick = true
            openFleet(.newChat(profileID: bot.profileID), on: hostID)
            return
        }
        guard blank?.memberIDs != [bot.profileID] else { return }
        if let text = blank?.draft, !text.isEmpty { appState.leaveComposerText(text) }
        startNewChat(explicitAgentID: bot.profileID, tracksNewChat: true)
    }

    /// A group chat the person already has, picked at the bottom of the people list: it opens in
    /// the blank chat's place.
    private func openNewChatGroup(_ group: SimpleBotsGroup) {
        if let hostID = group.hostID, let fleet, hostID != fleet.selectedHostID {
            openFleet(.group(roomID: group.roomID), on: hostID)
        } else if let summary = group.summary {
            openSessionSelection(summary)
        } else if let owner = currentWorkspaceOwner {
            openHostedGroup(group.roomID, owner: owner, settings: false)
        }
    }

    /// New chat's Send, asked before the chat's own (`ChatNewChatSlot.sendOverride`). True when the
    /// message went elsewhere (a group chat, a coding session) or can't go yet; false sends it in
    /// this chat as any chat does.
    private func sendNewChat(from model: ChatModel) -> Bool {
        let session = newChatSession
        let store = newChatCodeStore
        // Nobody picked: the message box's Send can't be turned off, so it does nothing.
        guard let send = NewChatSend.decide(session, stagedJobs: store?.projectStaged.count ?? 0) else { return true }
        switch send {
        case .chat:
            guard let bot = session.recipients.first else { return true }
            let isHere = bot.hostID == nil || bot.hostID == fleet?.selectedHostID
            if isHere, model.memberIDs == [bot.profileID] { return false }
            // The blank chat isn't this bot's yet: make it so, with the text. Send again sends it.
            newChatRecipientsChanged(session.recipients)
            return true
        case .group:
            let text = model.draft
            model.draft = ""
            startNewChatGroup(session.recipients, firstMessage: text)
            return true
        case .coding:
            guard let store, let project = session.project, store.send(model.draft) else { return true }
            model.draft = ""
            showOverWork([.work(projectID: project.id)])
            return true
        case .staged:
            guard let store, let project = session.project, store.sendAll(including: model.draft) != nil else {
                return true
            }
            model.draft = ""
            showOverWork([.work(projectID: project.id)])
            return true
        }
    }

    /// Two to six bots: a group chat on the first bot's computer, the others joining from theirs,
    /// and the typed text as its first message.
    private func startNewChatGroup(_ recipients: [SimpleBotsBot], firstMessage: String) {
        let rules = newChatRules
        let parts = NewChatRecipients.split(recipients, rules: rules)
        let peers = NewChatRecipients.peerCandidates(recipients, rules: rules) { fleet?.hostName($0) ?? "" }
        let message = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : firstMessage
        if let home = parts.home.first?.hostID, let fleet, home != fleet.selectedHostID {
            self.home.newChatText = message
            openFleet(.newGroup(profileIDs: parts.home.map(\.profileID), peers: peers), on: home)
        } else {
            createGroupChat(with: parts.home.map(\.profileID), peers: peers, firstMessage: message)
        }
    }

    /// The chat that takes New chat's place (a group chat) leaves no blank chat under it for Back.
    func dropNewChatBlank(under conversationID: String) {
        guard let blank = newChatSession.conversationID, blank != conversationID else { return }
        appState.path.removeAll { $0 == .chat(conversationID: blank) }
    }

    /// Pull requests and Worktrees for the Code store's project, over New chat or a project's Work.
    func codeSheets<Content: View>(_ content: Content) -> some View {
        content.bighelpSheet(item: $codeSheet) { sheet in
            if let store = codeHome { codeSheetView(sheet, store: store) }
        }
    }
}

/// New chat's choices row for the one picked bot. The message box's text shape is read here, so a
/// key redraws this small view and never the shell that built it.
private struct NewChatChoicesHost: View {
    let model: ChatModel
    let session: NewChatSession
    let store: CodeHomeStore
    let agentID: String
    let onWorktrees: @MainActor () -> Void
    let onSendAll: @MainActor () -> Void

    var body: some View {
        NewChatChoicesRow(context: NewChatChoicesContext(
            session: session, store: store, agentID: agentID, hasText: model.draftShape.hasText,
            draft: { model.draft }, clearDraft: { model.draft = "" },
            onWorktrees: onWorktrees, onSendAll: onSendAll))
            .equatable()
    }
}
