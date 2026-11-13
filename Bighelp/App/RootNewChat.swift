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
        let store = newChatCodeStore
        // Send holds stores only, never this view: the message box keeps it while the chat is open.
        let fleet = self.fleet, appState = self.appState
        let relay = NewChatSendRelay(
            session: session, model: model, store: store,
            hostInUse: { fleet?.selectedHostID },
            showProject: { appState.select(.work, thenOpen: [.work(projectID: $0)]) })
        let bot = session.recipients.count == 1 ? session.recipients.first : nil
        let choices: AnyView? = if let store, let bot {
            AnyView(NewChatChoicesHost(model: model, session: session, store: store, agentID: bot.profileID,
                                       onWorktrees: { codeSheet = .worktrees },
                                       onSendAll: { _ = relay.send(holdsReferences: false) }))
        } else {
            nil
        }
        let isBotsChat = bot.map { bot in
            (bot.hostID == nil || bot.hostID == fleet?.selectedHostID) && model.memberIDs == [bot.profileID]
        } ?? false
        return ChatNewChatSlot(
            toRow: AnyView(NewChatToRow(context: context)),
            people: AnyView(NewChatPeopleList(context: context)),
            choicesRow: choices,
            sendOverride: { relay.send(holdsReferences: $0) },
            // A group chat's or a coding session's first message goes as text only.
            offersAttachments: bot != nil && session.project == nil,
            isOneBotsChat: isBotsChat)
    }

    /// The computer in use's Code store, where it can start coding sessions.
    private var newChatCodeStore: CodeHomeStore? {
        guard let store = codeHome, store.scopeID == currentWorkspaceOwner?.cacheScopeID else { return nil }
        return store
    }

    private var newChatRules: NewChatGroupRules {
        NewChatGroupRules(hostInUse: showsEveryHost ? fleet?.selectedHostID : nil,
                          canMakeGroups: botModeRooms.makesGroupChats,
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
            onOpenGroup: { openNewChatGroup($0) },
            onSendRequest: { performNewChatRequest($0) })
    }

    /// The To row changed. One bot picked: the blank chat becomes that bot's, so the message box,
    /// its model control and Send are its own. Text already typed goes with it. A bot on another
    /// computer makes that computer the one in use first; the To row stays (`HomeSelection`).
    /// `fromSend`: Send found the chat wasn't the picked bot's yet, so a wait is said in words.
    private func newChatRecipientsChanged(_ recipients: [SimpleBotsBot], fromSend: Bool = false) {
        let session = newChatSession
        let blank = session.conversationID.flatMap { featureStore.preparedChatModel(id: $0) }
        let pick = NewChatPick.decide(recipients: recipients, blankMembers: blank?.memberIDs,
                                      hasFleet: fleet != nil, hostInUse: fleet?.selectedHostID)
        if pick == .keep { return }
        // Attachments and references can't move to another chat. The pick waits until they're out
        // of the box, and the line under the To row says so.
        if let blank, blank.holdsAttachmentsOrReferences {
            session.show(.pickKeepsAttachments)
            return
        }
        switch pick {
        case .keep:
            return
        case .switchComputer(let hostID, let profileID):
            home.handOffNewChat(NewChatHandoff(text: blank?.draft, followsPick: true, source: blank))
            openFleet(.newChat(profileID: profileID), on: hostID)
        case .start(let profileID):
            // Send moved nothing yet: the line says the bot's chat is on its way, and the text is
            // in its box when it's there.
            if fromSend { session.show(.starting) }
            // One chat starts at a time. This pick gets its chat when the start under way ends
            // (`newChatStartEnded`).
            guard !isStartingNewChat else {
                newChatPickGate.hold()
                return
            }
            if let text = blank?.draft, !text.isEmpty { appState.leaveComposerText(text) }
            startNewChat(explicitAgentID: profileID, tracksNewChat: true)
        }
    }

    /// A chat finished starting (`finishNewChatOpening`). A pick that came meanwhile gets its chat
    /// now: the To row is read again, so the latest pick wins and the To row and the chat under it
    /// agree. Not after a start that failed: its alert and Try Again stand, and Send asks again.
    func newChatStartEnded() {
        let session = newChatSession
        if session.note == .starting, !session.isStartingGroup { session.show(nil) }
        guard newChatPickGate.release(), actionErrorMessage == nil,
              let blankID = session.conversationID, appState.path.last == .chat(conversationID: blankID),
              featureStore.preparedChatModel(id: blankID)?.isBlankForNewChat != false else { return }
        newChatRecipientsChanged(session.recipients)
    }

    /// A group chat the person already has, picked at the bottom of the people list: it opens in
    /// the blank chat's place.
    private func openNewChatGroup(_ group: SimpleBotsGroup) {
        if let hostID = group.hostID, let fleet, hostID != fleet.selectedHostID {
            openFleet(.group(roomID: group.roomID), on: hostID)
        } else if let summary = group.summary, summary.hostedRoomID == nil {
            openSessionSelection(summary)
        } else if let owner = currentWorkspaceOwner {
            openHostedGroup(group.summary?.hostedRoomID ?? group.roomID, owner: owner, settings: false,
                            opened: { if let id = $0 { dropNewChatBlank(under: id) } })
        } else if group.summary != nil {
            actionErrorMessage = "This group is no longer available on the selected host."
        }
    }

    /// What New chat's Send left for the shell (`NewChatSendRelay`, through the To row).
    private func performNewChatRequest(_ request: NewChatRequest) {
        switch request {
        case .followPick: newChatRecipientsChanged(newChatSession.recipients, fromSend: true)
        case .startGroup: startNewChatGroup(newChatSession.recipients)
        }
    }

    /// Two to six bots: a group chat on the first bot's computer, the others joining from theirs,
    /// and the box's text as its first message. The box keeps the text until the group chat has it,
    /// so a group chat that can't be made loses nothing.
    private func startNewChatGroup(_ recipients: [SimpleBotsBot]) {
        let session = newChatSession
        let blank = session.conversationID.flatMap { featureStore.preparedChatModel(id: $0) }
        let text = blank?.draft ?? ""
        let rules = newChatRules
        let parts = NewChatRecipients.split(recipients, rules: rules)
        let peers = NewChatRecipients.peerCandidates(recipients, rules: rules) { fleet?.hostName($0) ?? "" }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        if let home = parts.home.first?.hostID, let fleet, home != fleet.selectedHostID {
            self.home.handOffNewChat(NewChatHandoff(text: message, followsPick: false, source: blank))
            openFleet(.newGroup(profileIDs: parts.home.map(\.profileID), peers: peers), on: home)
        } else {
            createGroupChat(with: parts.home.map(\.profileID), peers: peers, firstMessage: message) { [weak blank] openedID in
                session.groupEnded()
                guard let openedID else { return }
                if let blank, blank.draft == text { blank.draft = "" }
                dropNewChatBlank(under: openedID)
            }
        }
    }

    /// The chat that takes New chat's place (a group chat) leaves no blank chat under it for Back.
    /// Only New chat's own paths call this, and only a chat with nothing sent goes: a chat that
    /// was New chat's and has a message stays on the stack, whatever opens over it.
    func dropNewChatBlank(under conversationID: String) {
        guard let blank = newChatSession.conversationID else { return }
        appState.dropBlankChat(blank, under: conversationID,
                               isBlank: featureStore.preparedChatModel(id: blank)?.isBlankForNewChat == true)
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
