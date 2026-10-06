import Testing
@testable import Bighelp

@MainActor
struct AppStateTests {
    @Test @MainActor func hostSwitchKeepsTheConnectionsScreenButClearsChatOwnership() {
        let state = AppState()
        state.selectedTab = .workspace
        state.activateConversation(id: "old-host-chat", source: .newChat)
        state.requestVoiceMode(for: "old-host-chat")
        state.path = [.workspaceConnections]
        state.resetForHostBoundary()
        #expect(state.selectedTab == .workspace)
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

    @Test func legacyInboxNotificationOpensWorkspaceActivity() {
        let state = AppState()
        state.select(.agents)
        state.path = [.sessions, .chat(conversationID: "current")]

        state.openInbox()

        #expect(state.selectedTab == .workspace)
        #expect(state.path == [.workspaceActivity])
    }

    @Test func legacyInboxTabSelectionNormalizesToWorkspaceActivity() {
        let state = AppState()
        state.select(.agents)
        state.path = [.sessions]

        state.select(.inbox)

        #expect(state.selectedTab == .workspace)
        #expect(state.path == [.workspaceActivity])
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
}
