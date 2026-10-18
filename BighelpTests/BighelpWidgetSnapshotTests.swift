import Foundation
import Testing
@testable import Bighelp

@MainActor
struct BighelpWidgetSnapshotTests {
    @Test func widgetDeepLinksRouteToTheirDestinations() throws {
        #expect(BighelpIncomingURLRoute.parse(BighelpWidgetSnapshot.newChatURL(agentID: "default")) == .newChat(agentID: "default"))
        #expect(BighelpIncomingURLRoute.parse(BighelpWidgetSnapshot.newChatURL(agentID: nil)) == .newChat(agentID: nil))
        #expect(BighelpIncomingURLRoute.parse(BighelpWidgetSnapshot.tasksURL) == .scheduledTasks)
        #expect(BighelpIncomingURLRoute.parse(BighelpWidgetSnapshot.sessionsURL) == .sessions)
        #expect(BighelpIncomingURLRoute.parse(BighelpWidgetSnapshot.chatURL("abc_123")) == .chat(sessionID: "abc_123"))
        #expect(BighelpIncomingURLRoute.parse(BighelpWidgetSnapshot.taskURL("job_42")) == .scheduledTask(id: "job_42"))
    }

    @Test func externalSessionOpensAreConsumedExactlyOnce() {
        let center = BighelpExternalSessionOpenCenter()
        center.request(profileID: "default", storedSessionID: "20260923_101500_abc")
        let first = try! #require(center.pending)
        #expect(first.target == .stored(profileID: "default", storedSessionID: "20260923_101500_abc"))
        center.request(catalogSessionID: "session-1")
        #expect(!center.consume(first))
        let second = try! #require(center.pending)
        #expect(center.consume(second))
        #expect(center.pending == nil)
        #expect(!center.consume(second))
    }

    @Test func snapshotRoundTripsAndOrdersRunningSessionsFirst() throws {
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = BighelpWidgetSnapshot(defaultAgentID: "default", defaultAgentName: "Juno", sessions: [
            .init(id: "idle-new", title: "Idle", agentName: "Juno", status: "Replied", preview: "Done",
                  isRunning: false, updatedAt: old.addingTimeInterval(600)),
            .init(id: "running-old", title: "Running", agentName: "Juno", status: "Working", preview: nil,
                  isRunning: true, updatedAt: old),
        ], tasks: [], generatedAt: old)
        let data = try JSONEncoder.bighelpWidget.encode(snapshot)
        let decoded = try JSONDecoder.bighelpWidget.decode(BighelpWidgetSnapshot.self, from: data)
        #expect(decoded == snapshot)
        #expect(decoded.feedSessions.map(\.id) == ["running-old", "idle-new"])
        #expect(decoded.runningSessions.map(\.id) == ["running-old"])
    }

    /// bighelp woken in the background (a Shortcut, the Watch, a widget refresh) or launched before the
    /// computer answers: nothing it doesn't know yet replaces what the widgets show.
    @Test func whatThisRunDoesNotKnowYetStaysOnTheWidgets() async throws {
        let home = "0D0D0D0D-0000-4000-8000-000000000001"
        let palette = BighelpWidgetSnapshot.Palette(canvasHex: "#000000", surfaceHex: "#111111", primaryTextHex: "#FFFFFF",
                                                    secondaryTextHex: "#AAAAAA", accentHex: "#33CC66",
                                                    accentForegroundHex: "#000000")
        var saved = BighelpWidgetSnapshot(
            defaultAgentID: "finance", defaultAgentName: "Finley",
            sessions: [.init(id: "chat", title: "Budget", agentName: "Finley", status: "Replied", preview: "Done.",
                             isRunning: false, updatedAt: .now)],
            tasks: [], generatedAt: .now,
            feed: [.init(id: "post", title: "Market brief", icon: "📈", date: .now)],
            lightPalette: palette, darkPalette: palette,
            pinnedAgents: [.init(agentID: AgentProfile.financeFixture.id, name: "Finley", hostID: home)])
        saved.hostID = home
        var writes: [BighelpWidgetSnapshot] = []
        let notLoaded = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
                                            defaults: isolatedDefaults())
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [])
        let waiting = BighelpWidgetSnapshotPublisher(sessions: catalog, scheduledTasks: nil, agents: notLoaded,
            hostID: home, extras: BighelpWidgetExtras(), interval: .milliseconds(1), saved: saved,
            write: { writes.append($0) })
        waiting.publishNow()
        #expect(writes.isEmpty, "Its agents aren't known yet: nothing is written")

        try await notLoaded.load()
        waiting.publishNow()
        let written = try #require(writes.last)
        #expect(written.defaultAgentName == AgentProfile.financeFixture.name)
        #expect(written.sessions.map(\.id) == ["chat"], "Chats not loaded yet stay")
        #expect(written.feed?.map(\.id) == ["post"], "No screen filled the Feed in this run")
        #expect(written.lightPalette == palette && written.pinnedAgents?.count == 1)
        waiting.retire()
    }

    /// Another gateway takes over: widgets that follow the one in use show its copy from its last visit.
    @Test func switchingGatewaysShowsTheNextOnesSavedCopy() {
        var next = BighelpWidgetSnapshot.empty
        next.defaultAgentName = "Rio"
        next.hostID = "0D0D0D0D-0000-4000-8000-000000000002"
        var writes: [BighelpWidgetSnapshot] = []
        let publisher = BighelpWidgetSnapshotPublisher(
            sessions: SessionCatalogStore(client: DemoSessionCatalogClient(), records: []), scheduledTasks: nil,
            agents: AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: []), defaults: isolatedDefaults()),
            interval: .milliseconds(1), write: { writes.append($0) })
        publisher.retire(next: next)
        #expect(writes.last?.defaultAgentName == "Rio")
    }

    @Test func retiringThePublisherClearsTheHomeScreen() async throws {
        var writes: [BighelpWidgetSnapshot] = []
        let agents = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
                                         defaults: isolatedDefaults())
        try await agents.load()
        let catalog = SessionCatalogStore(client: DemoSessionCatalogClient(), records: [])
        let tasks = ScheduledTasksStore(client: ScheduledTasksFixtureClient(), initialAgentID: "finance")
        let publisher = BighelpWidgetSnapshotPublisher(sessions: catalog, scheduledTasks: tasks,
            agents: agents, interval: .milliseconds(1), write: { writes.append($0) })
        publisher.publishNow()
        #expect(writes.last?.defaultAgentID == AgentProfile.financeFixture.id)
        publisher.retire()
        #expect(writes.last == .empty)
    }
}
