import Foundation
import SwiftUI
import Testing
import UIKit
import WidgetKit
@testable import Bighelp

/// The Feed, Ideas and Goals widgets: Auto follows the agent picked in the app,
/// or a widget can stay on one agent.
@MainActor
struct BighelpBoardWidgetTests {
    private static let juno = "juno", rex = "rex"

    private static var snapshot: BighelpWidgetSnapshot {
        // A whole second, so saving and loading compare equal.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = BighelpWidgetSnapshot(defaultAgentID: juno, defaultAgentName: "Juno", sessions: [], tasks: [],
                                            generatedAt: now)
        snapshot.feed = [.init(id: "f1", title: "Lisbon fares dropped", icon: "✈️", preview: "Round trips are $412.", date: now)]
        snapshot.ideas = [.init(id: "i1", title: "I can plan Sam's dinner", icon: "🎂", preview: "Three restaurants", date: now)]
        snapshot.goals = [.init(id: "g1", title: "Run a 10K", icon: "🏃", note: "4 of 8 weeks", date: now)]
        snapshot.agents = [.init(id: juno, name: "Juno"), .init(id: rex, name: "Rex"), .init(id: "mira", name: "Mira")]
        snapshot.boards = [.init(agentID: rex, feed: [.init(id: "rf", title: "Rex's market brief", icon: "📈", date: now)],
                                 ideas: [], goals: [.init(id: "rg", title: "Ship the beta", icon: "🚀", date: now)])]
        return snapshot
    }

    @Test func autoFollowsTheAgentPickedInTheApp() throws {
        let feed = try #require(Self.snapshot.board(.feed, agentID: nil))
        #expect(feed.agentID == Self.juno && feed.agentName == "Juno" && feed.isLoaded)
        #expect(feed.items.map(\.id) == ["f1"])
        #expect(Self.snapshot.board(.ideas, agentID: nil)?.items.map(\.id) == ["i1"])
        // Choosing the agent that's picked anyway reads the same board.
        #expect(Self.snapshot.board(.goals, agentID: Self.juno)?.items.map(\.id) == ["g1"])
    }

    @Test func aWidgetCanStayOnOneAgent() throws {
        let rex = try #require(Self.snapshot.board(.feed, agentID: Self.rex))
        #expect(rex.agentName == "Rex" && rex.isLoaded && rex.items.map(\.id) == ["rf"])
        #expect(Self.snapshot.board(.ideas, agentID: Self.rex)?.items.isEmpty == true)
        // An agent whose board the app hasn't loaded yet says so instead of looking empty.
        let mira = try #require(Self.snapshot.board(.goals, agentID: "mira"))
        #expect(mira.agentName == "Mira" && !mira.isLoaded)
        // An agent no longer on this computer shows nothing of anyone else's.
        #expect(Self.snapshot.board(.feed, agentID: "gone") == nil)
    }

    @Test func olderSnapshotsStillLoad() throws {
        let json = #"{"defaultAgentID":"juno","defaultAgentName":"Juno","sessions":[],"tasks":[],"generatedAt":1800000000,"#
            + #""feed":[{"id":"f1","title":"Hi","icon":"👋","isDone":false,"date":1800000000}]}"#
        let decoded = try JSONDecoder.bighelpWidget.decode(BighelpWidgetSnapshot.self, from: Data(json.utf8))
        #expect(decoded.board(.feed, agentID: nil)?.items.first?.title == "Hi")
        #expect(decoded.board(.ideas, agentID: nil)?.items.isEmpty == true)
        let round = try JSONDecoder.bighelpWidget.decode(BighelpWidgetSnapshot.self,
                                                         from: JSONEncoder.bighelpWidget.encode(Self.snapshot))
        #expect(round == Self.snapshot)
    }

    @Test func boardLinksOpenThatAgentsTab() {
        #expect(BighelpIncomingURLRoute.parse(BighelpWidgetSnapshot.agentURL("ideas", agentID: Self.rex))
                == .agent(tab: "ideas", agentID: Self.rex))
        #expect(BighelpIncomingURLRoute.parse(BighelpWidgetSnapshot.agentURL("goals")) == .agent(tab: "goals", agentID: nil))
    }

    /// Only boards a widget shows are read from the host, a few at most; the picked agent's
    /// board already comes from the app's own store.
    @Test func loadsOnlyTheBoardsWidgetsAreSetTo() async throws {
        let client = RecordingBoardClient()
        let extras = BighelpWidgetExtras()
        var picked = [Self.rex, Self.juno, "gone", "a", "b", "c", "d", "e", "f"]
        let loader = BighelpWidgetBoardLoader(extras: extras, pickedAgentIDs: { picked })
        loader.configure(client: client)
        let known = Set([Self.juno, Self.rex, "a", "b", "c", "d", "e", "f"])
        await loader.refresh(homeAgentID: Self.juno, knownAgentIDs: known)
        #expect(client.requested.first == Self.rex)
        #expect(!client.requested.contains(Self.juno) && !client.requested.contains("gone"))
        #expect(client.requested.count == BighelpWidgetBoardLoader.maximumAgents)
        let rex = try #require(extras.agentBoards[Self.rex])
        #expect(rex.feed.map(\.title) == ["Market brief"])
        #expect(rex.ideas.first?.preview == "Compare three plans · Switch", "Previews are plain words, no Markdown")
        #expect(rex.feed.first?.preview == "Stocks up 2%.")
        #expect(rex.goals.isEmpty)

        // A widget set back to Auto stops loading that agent, and its board goes.
        picked = []
        client.requested = []
        await loader.refresh(homeAgentID: Self.juno, knownAgentIDs: known)
        #expect(client.requested.isEmpty)
        #expect(extras.agentBoards.isEmpty)

        // Signing out or switching computers drops every board.
        picked = [Self.rex]
        await loader.refresh(homeAgentID: Self.juno, knownAgentIDs: known)
        loader.configure(client: nil)
        #expect(extras.agentBoards.isEmpty)
    }

    @Test func publisherListsAgentsAndChosenBoards() async throws {
        let agents = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
                                         defaults: isolatedDefaults())
        try await agents.load()
        let extras = BighelpWidgetExtras()
        extras.agentBoards = ["other": .init(agentID: "other", feed: [], ideas: [], goals: [])]
        let publisher = BighelpWidgetSnapshotPublisher(
            sessions: SessionCatalogStore(client: DemoSessionCatalogClient(), records: []),
            scheduledTasks: ScheduledTasksStore(client: ScheduledTasksFixtureClient(), initialAgentID: "finance"),
            agents: agents, extras: extras, interval: .milliseconds(1), write: { _ in })
        let snapshot = publisher.makeSnapshot()
        #expect(snapshot.agents?.map(\.id) == [AgentProfile.financeFixture.id])
        // Boards of agents that aren't on this computer never reach the Home Screen.
        #expect(snapshot.boards?.isEmpty == true)
        publisher.retire()
    }

    /// Each widget at every Home Screen size, in light and dark, saved for review
    /// when BIGHELP_WIDGET_RENDER_DIR is set.
    @Test func boardWidgetsRenderEverySizeInBothModes() throws {
        let out = ProcessInfo.processInfo.environment["BIGHELP_WIDGET_RENDER_DIR"].map(URL.init(fileURLWithPath:))
        var full = BighelpWidgetSnapshot.preview
        full.ideas = BighelpWidgetSnapshot.previewIdeas
        let families: [(String, WidgetFamily, CGSize)] = [("small", .systemSmall, .init(width: 170, height: 170)),
                                                          ("medium", .systemMedium, .init(width: 364, height: 170)),
                                                          ("large", .systemLarge, .init(width: 364, height: 382))]
        for scheme in [ColorScheme.light, .dark] {
            let colors = BighelpWidgetColors(snapshot: full, scheme: scheme, isFullColor: true)
            for section in BighelpWidgetSnapshot.BoardSection.allCases {
                for (name, family, size) in families {
                    for (state, agentID) in [("auto", nil), ("unloaded", "mira")] as [(String, String?)] {
                        var snapshot = full
                        snapshot.agents = [.init(id: "default", name: "Juno"), .init(id: "mira", name: "Mira")]
                        let view = BighelpBoardWidgetView(section: section, snapshot: snapshot, agentID: agentID,
                                                          familyOverride: family)
                            .environment(\.bighelpWidgetColors, colors)
                            .frame(width: size.width, height: size.height)
                            .padding(16)
                            .background(colors.canvas)
                            .environment(\.colorScheme, scheme)
                        let renderer = ImageRenderer(content: view)
                        renderer.scale = 2
                        let image = try #require(renderer.uiImage, "\(section) \(name) did not render")
                        #expect(image.size.width >= size.width && image.size.height >= size.height)
                        if let out, let data = image.pngData() {
                            try data.write(to: out.appendingPathComponent(
                                "board-\(section.rawValue)-\(state)-\(name)-\(scheme == .dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private final class RecordingBoardClient: AgentBoardClient {
    var requested: [String] = []
    var supportsFeedback: Bool { false }

    func items(agentID: String) async throws -> [AgentBoardItem] {
        requested.append(agentID)
        return [
            AgentBoardItem(id: "f", kind: .feed, title: "Market brief", body: "Stocks **up** 2%.", icon: "📈"),
            AgentBoardItem(id: "i", kind: .idea, title: "Cheaper phone plan", body: "1. Compare three plans\n2. Switch",
                           icon: "📱"),
            AgentBoardItem(id: "x", kind: .feed, title: "Deleted", dismissed: true),
        ]
    }

    func update(agentID: String, itemID: String, change: AgentBoardChange) async throws -> AgentBoardItem {
        throw WorkspaceClientError.invalidRequest
    }
    func markRead(agentID: String, itemIDs: [String]) async throws {}
    func promote(agentID: String, itemID: String) async throws -> AgentBoardItem { throw WorkspaceClientError.invalidRequest }
    func picture(agentID: String, itemID: String, index: Int) async throws -> Data { Data() }
    func activity(agentID: String) async throws -> [AgentActivityEntry] { [] }
    func approvals(agentID: String) async throws -> [AgentApprovalEntry] { [] }
    func identity(agentID: String) async throws -> AgentIdentityDocuments { throw WorkspaceClientError.invalidRequest }
}
