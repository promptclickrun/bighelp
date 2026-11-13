import Testing
@testable import Bighelp

@MainActor
struct AppStateTests {
    @Test @MainActor func hostSwitchKeepsTheConnectionsScreenButClearsChatOwnership() {
        let state = AppState()
        state.selectedTab = .agents
        state.activateConversation(id: "old-host-chat", source: .newChat)
        state.requestVoiceMode(for: "old-host-chat")
        state.path = [.workspaceConnections]
        state.resetForHostBoundary()
        #expect(state.selectedTab == .agents)
        #expect(state.path == [.workspaceConnections])
        #expect(state.activeConversationID == nil)
        #expect(state.pendingVoiceConversationID == nil)
    }


    @Test func ordinaryHostSwitchPreservesTheCodexSessionsLanding() {
        let state = AppState()
        state.select(.profile)
        state.path = [.sessions]

        state.resetForHostBoundary()

        #expect(state.selectedTab == .sessions)
        #expect(state.path.isEmpty)
    }

    /// With every computer showing, its lists stay put when the working computer changes;
    /// the old computer's own pages above them go.
    @Test func aComputerSwitchInAllHostsKeepsItsLists() {
        let state = AppState()
        state.path = [.allHostsChats, .projects, .chat(conversationID: "old")]
        state.resetForHostBoundary(keepsAllHostsScreens: true)
        #expect(state.selectedTab == .sessions)
        #expect(state.path == [.allHostsChats])

        state.select(.scheduledTasks)
        state.resetForHostBoundary(keepsAllHostsScreens: true)
        #expect(state.selectedTab == .scheduledTasks, "Every computer's tasks stay up")

        state.path = [.allHostsChats]
        state.resetForHostBoundary()
        #expect(state.path.isEmpty, "One computer: nothing of the old one stays")
    }

    @Test func conversationActivationTracksTheCanonicalSessionID() {
        let state = AppState()

        state.activateConversation(id: "session-1", source: .newChat)

        #expect(state.activeConversationID == "session-1")
        #expect(state.path == [.chat(conversationID: "session-1")])
    }

    @Test func newChatReplacesTrailingChatButSessionsChatPushesFromItsRootTab() {
        let state = AppState()
        state.path = [.chat(conversationID: "old")]
        state.activateConversation(id: "new", source: .newChat)
        #expect(state.path == [.chat(conversationID: "new")])

        state.openSessions()
        state.activateConversation(id: "saved", source: .sessions)
        #expect(state.selectedTab == .sessions)
        #expect(state.path == [.chat(conversationID: "saved")])
    }

    @Test func openingSessionsFromChatReplacesChat() {
        let state = AppState()
        state.activateConversation(id: "current", source: .newChat)

        state.openSessions()

        #expect(state.selectedTab == .sessions)
        #expect(state.path.isEmpty)
        #expect(state.activeConversationID == "current")
    }

    @Test func quickSwitchFromShellAppendsButReplacesTrailingChat() {
        let state = AppState()
        state.activateConversation(id: "first", source: .quickSwitch)
        #expect(state.path == [.chat(conversationID: "first")])

        state.activateConversation(id: "second", source: .quickSwitch)
        #expect(state.path == [.chat(conversationID: "second")])
    }

    /// A notification, widget or link about a chat that's already open goes back to that
    /// chat; a second copy of it would share its model, and Back would show it again.
    @Test func openingAChatAlreadyOpenKeepsOneCopy() {
        let state = AppState()
        state.activateConversation(id: "bob", source: .sessions)
        state.activateConversation(id: "bob", source: .sessions)
        #expect(state.path == [.chat(conversationID: "bob")])

        state.open(.simpleBotProfile(agentID: "bob"))
        state.activateConversation(id: "bob", source: .sessions)
        #expect(state.path == [.chat(conversationID: "bob")], "Back to the chat under its profile")

        state.path = [.chat(conversationID: "first"), .chat(conversationID: "second")]
        state.activateConversation(id: "first", source: .quickSwitch)
        #expect(state.path == [.chat(conversationID: "first")])
        #expect(state.activeConversationID == "first")
    }

    @Test func forkPushesFromTheOriginalCheckpointChatAndTracksTheNewSession() {
        let state = AppState()
        state.path = [.chat(conversationID: "original")]

        state.activateConversation(id: "forked", source: .fork)

        #expect(state.path == [
            .chat(conversationID: "original"),
            .chat(conversationID: "forked"),
        ])
        #expect(state.activeConversationID == "forked")
    }

    @Test func anAlertWithoutAChatAsksForNeedsYouAndLeavesThePlaceAlone() {
        let state = AppState()
        state.select(.agents)
        state.path = [.sessions, .chat(conversationID: "current")]

        state.openNeedsYou()

        #expect(state.isNeedsYouRequested)
        #expect(state.selectedTab == .agents)
        #expect(state.path == [.sessions, .chat(conversationID: "current")])
    }

    @Test func legacyInboxTabSelectionOpensChat() {
        let state = AppState()
        state.select(.agents)
        state.path = [.sessions]

        state.select(.inbox)

        #expect(state.selectedTab == .sessions)
        #expect(state.path.isEmpty)
        #expect(AppTab.allCases == [.sessions, .feed, .ideas, .goals, .apps])
    }

    @Test func selectingARootTabClearsAnyStaleNavigationPath() {
        let state = AppState()
        state.path = [
            .sessions,
            .chat(conversationID: "stale-session")
        ]

        state.select(.agents)

        #expect(state.selectedTab == .agents)
        #expect(state.path.isEmpty)
    }

    @Test func drawerHighlightsOnlyTheRootDestinationThatIsActuallyVisible() {
        let state = AppState()
        state.select(.agents)

        #expect(state.drawerSelectedTab == .agents)

        state.activateConversation(id: "session-current", source: .newChat)

        #expect(state.selectedTab == .agents)
        #expect(state.drawerSelectedTab == nil)
    }

    @Test func rootRouteOpenersReplaceAnyStaleNavigationStack() {
        let state = AppState()

        state.path = [
            .scheduledTasks,
            .scheduledTask(id: "stale-task")
        ]
        state.openSessions()
        #expect(state.selectedTab == .sessions)
        #expect(state.path.isEmpty)

        state.path = [
            .sessions,
            .chat(conversationID: "stale-chat")
        ]
        state.openScheduledTasks()
        #expect(state.selectedTab == .scheduledTasks)
        #expect(state.path.isEmpty)
    }

    /// Leaving a chat for any other place holds it, as it was opened, for the tab it was under.
    @Test func leavingAChatForAnotherPlaceHoldsIt() {
        for tab in [AppTab.ideas, .feed, .apps, .agents, .kanban, .projects] {
            let state = AppState()
            state.chatOpenedFromList = true
            state.activateConversation(id: "chat-1", source: .sessions)
            #expect(state.heldChat == nil)

            state.select(tab)

            #expect(state.path.isEmpty)
            #expect(state.heldChat == HeldChat(conversationID: "chat-1", openedFromList: true), "\(tab)")
        }
    }

    /// Chat and Sessions share a root: moving between them, or opening a chat, holds nothing.
    @Test func chatAndSessionsAndOpeningAChatHoldNothing() {
        let state = AppState()
        state.activateConversation(id: "chat-1", source: .sessions)
        state.select(.sessionList)
        #expect(state.heldChat == nil)

        state.activateConversation(id: "chat-1", source: .sessions)
        state.select(.ideas)
        #expect(state.heldChat != nil)
        state.select(.feed)
        #expect(state.heldChat?.conversationID == "chat-1", "Board to board keeps it")
        state.select(.sessions)
        state.activateConversation(id: "chat-2", source: .sessions)
        #expect(state.heldChat == nil, "The chat on screen is the one held next")
    }

    /// The held chat belongs to this computer and this account.
    @Test func hostAndAccountBoundariesForgetTheHeldChat() {
        let state = AppState()
        state.activateConversation(id: "chat-1", source: .sessions)
        state.select(.goals)
        state.resetForHostBoundary()
        #expect(state.heldChat == nil)

        state.select(.sessions)
        state.activateConversation(id: "chat-1", source: .sessions)
        state.select(.goals)
        state.resetForAccountBoundary()
        #expect(state.heldChat == nil)
    }

    /// Chat opens its own chat and, without Sessions in the bar, a chat from the list too. With
    /// Sessions in the bar, a chat from the list is Sessions'.
    @Test func theTabAChatWasUnderOpensItAgain() {
        let own = HeldChat(conversationID: "own", openedFromList: false)
        let listed = HeldChat(conversationID: "listed", openedFromList: true)
        #expect(own.tab(sessionsInBar: false) == .sessions)
        #expect(own.tab(sessionsInBar: true) == .sessions)
        #expect(listed.tab(sessionsInBar: false) == .sessions)
        #expect(listed.tab(sessionsInBar: true) == .sessionList)
    }

    /// Chat opens a 1:1 chat again only while its agent is the one in use; a group chat always.
    @Test func chatHoldsAOneToOneChatOnlyForItsAgent() {
        #expect(HeldChat.fitsChat(members: ["finance"], agentInUse: "finance"),
                "A board from a 1:1 chat makes its agent the one in use")
        #expect(!HeldChat.fitsChat(members: ["finance"], agentInUse: "travel"))
        #expect(!HeldChat.fitsChat(members: ["finance"], agentInUse: nil))
        #expect(HeldChat.fitsChat(members: ["finance", "travel"], agentInUse: "home"))
    }
}
