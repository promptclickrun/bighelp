import Testing
@testable import Bighelp

@MainActor
struct AppStateTests {
    @Test @MainActor func hostSwitchKeepsTheConnectionsScreenButClearsChatOwnership() {
        let state = AppState()
        state.selectedTab = .work
        state.activateConversation(id: "old-host-chat", source: .newChat)
        state.requestVoiceMode(for: "old-host-chat")
        state.path = [.workspaceConnections]
        state.resetForHostBoundary()
        #expect(state.selectedTab == .work)
        #expect(state.path == [.workspaceConnections])
        #expect(state.activeConversationID == nil)
        #expect(state.pendingVoiceConversationID == nil)
    }

    /// Another computer or account: the old one's pages close, and the person stays on their tab.
    @Test func aComputerOrAccountSwitchKeepsTheTabAndClosesItsPages() {
        let state = AppState()
        state.select(.today)
        state.path = [.projects, .chat(conversationID: "old")]
        state.resetForHostBoundary()
        #expect(state.selectedTab == .today)
        #expect(state.path.isEmpty)

        state.path = [.sessions]
        state.resetForAccountBoundary()
        #expect(state.selectedTab == .today)
        #expect(state.path.isEmpty)
    }

    /// Every computer has its own `AppState`. The tab and the first tab's view are the whole app's,
    /// so a chat opened on another computer lands on the place the person was on; each keeps its
    /// own pages.
    @Test func everyComputersStateSharesTheTabAndTheView() {
        let home = HomeSelection()
        let first = AppState(home: home), second = AppState(home: home)
        first.select(.bots)
        first.select(.work)
        first.open(.projects)

        #expect(second.selectedTab == .work)
        #expect(second.home.view == .bots)
        #expect(second.path.isEmpty)
    }

    @Test func aLaunchLandsOnThePlaceThePersonPicked() {
        let home = HomeSelection()
        home.land(on: .bots, view: .chats)
        #expect(home.tab == .conversations)
        #expect(home.view == .bots)
        home.land(on: .chats, view: .bots)
        #expect(home.view == .chats)
        home.land(on: .today, view: .bots)
        #expect(home.tab == .today)
        #expect(home.view == .bots, "Today and Work keep the first tab on the person's own view")
        home.land(on: .work, view: .chats)
        #expect(home.tab == .work)
        #expect(home.view == .chats)
    }

    /// A page that belongs to another tab (Kanban from a link) opens over that tab, so Back goes there.
    @Test func aPageOfAnotherTabOpensOverIt() async {
        let state = AppState()
        state.activateConversation(id: "current", source: .sessions)

        state.select(.work, thenOpen: [.kanban])
        // The Mac pushes a moment after the switch.
        try? await Task.sleep(for: .milliseconds(400))

        #expect(state.selectedTab == .work)
        #expect(state.path == [.kanban])
    }

    @Test func conversationActivationTracksTheCanonicalSessionID() {
        let state = AppState()

        state.activateConversation(id: "session-1", source: .newChat)

        #expect(state.activeConversationID == "session-1")
        #expect(state.path == [.chat(conversationID: "session-1")])
    }

    @Test func newChatReplacesTrailingChatButAChatFromAListIsPushed() {
        let state = AppState()
        state.path = [.chat(conversationID: "old")]
        state.activateConversation(id: "new", source: .newChat)
        #expect(state.path == [.chat(conversationID: "new")])

        state.select(.chats)
        state.activateConversation(id: "saved", source: .sessions)
        #expect(state.selectedTab == .conversations)
        #expect(state.home.view == .chats)
        #expect(state.path == [.chat(conversationID: "saved")])
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
        state.select(.work)
        state.path = [.sessions, .chat(conversationID: "current")]

        state.openNeedsYou()

        #expect(state.isNeedsYouRequested)
        #expect(state.selectedTab == .work)
        #expect(state.path == [.sessions, .chat(conversationID: "current")])
    }

    /// A tab is a root: picking one (the bar, the sidebar, ⌘1–⌘3) closes whatever was pushed.
    @Test func selectingATabClosesWhatWasPushed() {
        let state = AppState()
        state.path = [
            .sessions,
            .chat(conversationID: "stale-session")
        ]

        state.select(.today)

        #expect(state.selectedTab == .today)
        #expect(state.path.isEmpty)
    }
}
