import Foundation
import Testing
import WidgetKit
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
        #expect(first.target == .stored(hostID: nil, profileID: "default", storedSessionID: "20260923_101500_abc"))
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

    @Test func recentIdleChatsCannotPushWorkingChatsOutOfTheSnapshot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let idle = (0..<20).map { index in
            SessionRecord(id: "idle-\(index)", kind: .direct, agentIDs: ["default"], title: "Finished chat",
                          createdAt: now, updatedAt: now.addingTimeInterval(Double(index)), hasAcceptedMessage: true)
        }
        let working = SessionRecord(id: "working", kind: .direct, agentIDs: ["default"], title: "Long task",
                                    isActive: true, createdAt: now.addingTimeInterval(-600))
        var delegating = SessionRecord(id: "delegating", kind: .direct, agentIDs: ["default"], title: "Team task",
                                       createdAt: now.addingTimeInterval(-900))
        delegating.sessionSubagents = .init(sessionID: delegating.id, subagents: [
            .init(id: "worker", sessionID: "child", parentID: delegating.id, role: "worker", goal: "Task", startedAt: 1)
        ], updatedAt: 10)
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient(), records: idle + [working, delegating],
                                          defaults: isolatedDefaults())
        let agents = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: []), defaults: isolatedDefaults())
        let publisher = BighelpWidgetSnapshotPublisher(sessions: catalog, scheduledTasks: nil, agents: agents,
                                                       extras: BighelpWidgetExtras(), write: { _ in })
        defer { publisher.retire() }
        let snapshot = publisher.makeSnapshot()
        #expect(snapshot.sessions.count == 12)
        #expect(snapshot.runningSessions.map(\.id) == ["working", "delegating"])
        #expect(snapshot.feedSessions.prefix(3).map(\.id) == ["working", "delegating", "idle-19"])
    }

    @Test func chatFreshnessExpiresExactlyAtTheTimelineTransition() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = BighelpWidgetSnapshot.preview
        snapshot.generatedAt = now.addingTimeInterval(100)
        snapshot.sessionsUpdatedAt = now
        let timeline = GatewayWidgetProvider.timeline(snapshot: snapshot, now: now.addingTimeInterval(119))
        #expect(timeline.entries.map(\.date) == [now.addingTimeInterval(119), now.addingTimeInterval(120)])
        #expect(!snapshot.chatsAreStale(at: timeline.entries[0].date))
        #expect(snapshot.chatsAreStale(at: timeline.entries[1].date))
        #expect(timeline.entries[1].snapshot.sessions == snapshot.sessions, "Stale work stays visible.")
        let expired = GatewayWidgetProvider.timeline(snapshot: snapshot, now: now.addingTimeInterval(120))
        #expect(expired.entries.count == 1, "Never schedule a past or duplicate transition.")
        snapshot.sessions = []
        #expect(GatewayWidgetProvider.timeline(snapshot: snapshot, now: now).entries.count == 1)

        let legacy = #"{"sessions":[],"tasks":[],"generatedAt":1800000000}"#
        let decoded = try JSONDecoder.bighelpWidget.decode(BighelpWidgetSnapshot.self, from: Data(legacy.utf8))
        #expect(decoded.sessionsUpdatedAt == nil)
        #expect(decoded.chatsStaleAt == now.addingTimeInterval(120))
    }

    @Test func aLoadedDiskCacheAndUnrelatedUpdatesDoNotMakeChatsFresh() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cached = SessionRecord(id: "cached", kind: .direct, agentIDs: ["finance"], title: "Long task",
                                   isActive: true, createdAt: now.addingTimeInterval(-600))
        let repository = DemoRepository(directory: directory, name: "sessions", seed: [cached])
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient(), repository: repository,
                                          defaults: isolatedDefaults())
        #expect(catalog.hasLoadedState, "A disk cache counts as loaded, but is not a live observation.")
        let agents = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
                                         defaults: isolatedDefaults())
        try await agents.load()
        var saved = BighelpWidgetSnapshot.empty
        saved.generatedAt = now.addingTimeInterval(-300)
        saved.sessionsUpdatedAt = now.addingTimeInterval(-600)
        let extras = BighelpWidgetExtras()
        var writes: [BighelpWidgetSnapshot] = []
        let publisher = BighelpWidgetSnapshotPublisher(sessions: catalog, scheduledTasks: nil, agents: agents,
            extras: extras, saved: saved, now: { now }, write: { writes.append($0) })
        defer { publisher.retire() }
        publisher.publishNow()
        extras.feed = [.init(id: "post", title: "A new idea", icon: "💡", date: now)]
        publisher.publishNow()
        #expect(writes.count == 2)
        #expect(writes.allSatisfy { $0.sessionsUpdatedAt == saved.sessionsUpdatedAt && $0.chatsAreStale(at: now) })
        #expect(writes.last?.runningSessions.map(\.id) == [cached.id])
    }

    @Test func liveHeartbeatRefreshesUnchangedWorkAndStopsWhenDisconnected() async throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        var live = true
        let catalog = SessionCatalogStore(client: SessionCatalogFixtureClient(), records: [
            SessionRecord(id: "work", kind: .direct, agentIDs: ["finance"], title: "Task", isActive: true, createdAt: now)
        ], defaults: isolatedDefaults())
        let agents = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
                                         defaults: isolatedDefaults())
        try await agents.load()
        var writes: [BighelpWidgetSnapshot] = []
        let publisher = BighelpWidgetSnapshotPublisher(sessions: catalog, scheduledTasks: nil, agents: agents,
            extras: BighelpWidgetExtras(), isLive: { live }, sessionsAreLive: { live }, now: { now },
            write: { writes.append($0) })
        defer { publisher.retire() }
        publisher.publishNow()
        now += 59
        publisher.publishNow()
        #expect(writes.count == 1)
        now += 1
        publisher.publishNow()
        #expect(writes.count == 2)
        #expect(writes.last?.sessionsUpdatedAt == now)
        live = false
        now += 120
        publisher.publishNow()
        #expect(writes.count == 2)
        #expect(try #require(writes.last).chatsAreStale(at: now))
        #expect(publisher.makeSnapshot().sessionsUpdatedAt == writes.last?.sessionsUpdatedAt)
        live = true
        catalog.refreshErrorMessage = "Sessions could not be refreshed."
        publisher.publishNow()
        #expect(writes.count == 3)
        #expect(try #require(writes.last).chatsAreStale(at: now), "A connected host with a failed read is not fresh.")
        catalog.refreshErrorMessage = nil
        publisher.publishNow()
        #expect(writes.count == 4, "A fresh observation replaces stale status without waiting another minute.")
        #expect(writes.last?.sessionsUpdatedAt == now)
    }

    @Test func eachChatRowLinkRetainsItsSessionAndGateway() {
        let hosts = ["11111111-0000-4000-8000-000000000001", "11111111-0000-4000-8000-000000000002"]
        for host in hosts {
            var snapshot = BighelpWidgetSnapshot.preview
            snapshot.hostID = host
            let sessions = snapshot.feedSessions
            #expect(Set(sessions.map { snapshot.chatURL($0.id) }).count == sessions.count)
            for session in sessions {
                let url = snapshot.chatURL(session.id)
                #expect(BighelpIncomingURLRoute.parse(url) == .chat(sessionID: session.id))
                #expect(BighelpIncomingURLRoute.hostID(in: url) == UUID(uuidString: host))
                #expect(url != snapshot.sessionsURL)
            }
        }
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
