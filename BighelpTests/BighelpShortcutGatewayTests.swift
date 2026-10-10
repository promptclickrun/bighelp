import Foundation
import Testing
@testable import Bighelp

/// Shortcuts and widgets set to a gateway run there, whichever one bighelp is
/// using. Home is the gateway in use; Studio another one.
@MainActor
struct BighelpShortcutGatewayTests {
    private static let home = FakeShortcutGateways.home
    private static let studio = FakeShortcutGateways.studio

    private func harness(
        prepareConnection: @escaping @MainActor () async throws -> Void = {}
    ) async throws -> (ShortcutServiceHarness, FakeShortcutGateways, LinkRecorder) {
        let harness = try await ShortcutServiceHarness(prepareConnection: prepareConnection)
        let gateways = FakeShortcutGateways()
        harness.service.gatewayDirectory = gateways
        harness.service.hostServices.hostID = { Self.home }
        harness.service.hostServices.hostName = { "Home" }
        let links = LinkRecorder()
        harness.service.openLink = { links.urls.append($0) }
        return (harness, gateways, links)
    }

    // MARK: Agents

    @Test func agentReferencesKeepTheirGatewayAndOldShortcutsStillResolve() {
        let picked = BighelpShortcutAgentReference(hostID: Self.studio, agentID: "research")
        #expect(BighelpShortcutAgentReference(entityID: picked.entityID) == picked)
        // Made before gateways: the agent on the gateway in use.
        #expect(BighelpShortcutAgentReference(entityID: "finance") == .init(hostID: nil, agentID: "finance"))
        #expect(LoopdyShortcutAgentEntity(.init(id: "finance", name: "Finley", role: "", isDefault: false)).id == "finance")
        for bad in ["", "not-a-uuid\u{1F}finance", Self.studio.uuidString + "\u{1F}", "a\u{1F}b\u{1F}c",
                    String(repeating: "x", count: 97)] {
            #expect(BighelpShortcutAgentReference(entityID: bad) == nil, "\(bad)")
        }
    }

    @Test func agentsOnTheGatewayInUseCarryIt() async throws {
        let (harness, _, _) = try await harness()
        let agents = try await harness.service.availableAgents(on: nil)
        #expect(agents.map(\.id) == ["default", "finance"])
        #expect(agents.allSatisfy { $0.hostID == Self.home && $0.hostName == "Home" })
        let entity = LoopdyShortcutAgentEntity(agents[1])
        #expect(entity.reference == .init(hostID: Self.home, agentID: "finance"))
    }

    @Test func agentsOnAnotherGatewayAreReadWithoutSwitchingToIt() async throws {
        let (harness, gateways, _) = try await harness()
        let agents = try await harness.service.availableAgents(on: Self.studio)
        #expect(agents.map(\.name) == ["Rio"])
        #expect(agents.first?.hostID == Self.studio)
        #expect(gateways.selected.isEmpty)
    }

    /// Resolving saved agents must never wait on a host: the Shortcut starts at once.
    @Test func savedAgentsComeFromThisDeviceWhileTheHostIsDown() async throws {
        let (harness, _, _) = try await harness(prepareConnection: { throw URLError(.notConnectedToInternet) })
        let ids = ["finance", BighelpShortcutAgentReference(hostID: Self.studio, agentID: "research").entityID,
                   BighelpShortcutAgentReference(hostID: Self.studio, agentID: "gone").entityID, "bad\u{1F}id"]
        let saved = harness.service.savedAgents(ids)
        #expect(saved.map(\.name) == ["Finley", "Rio", "gone"])
        #expect(saved.map(\.hostID) == [nil, Self.studio, Self.studio])
    }

    // MARK: Running on a gateway

    @Test func aShortcutSwitchesToItsGatewayFirst() async throws {
        let (harness, gateways, _) = try await harness()
        try harness.service.useGateway(Self.home)
        #expect(gateways.selected.isEmpty, "Already in use")
        try harness.service.useGateway(nil, for: .init(hostID: Self.studio, agentID: "research"))
        #expect(gateways.selected == [Self.studio], "The agent's own gateway")
    }

    @Test func aMismatchedAgentOrARemovedGatewaySaysSo() async throws {
        let (harness, gateways, _) = try await harness()
        #expect(throws: BighelpShortcutServiceError.agentNotOnGateway) {
            try harness.service.useGateway(Self.home, for: .init(hostID: Self.studio, agentID: "research"))
        }
        #expect(throws: BighelpShortcutServiceError.gatewayUnavailable) {
            try harness.service.useGateway(UUID())
        }
        #expect(gateways.selected.isEmpty)
    }

    // MARK: Opening bighelp

    @Test func voiceOnAnotherGatewayNamesItAndLeavesTheSwitchToTheApp() async throws {
        let (harness, gateways, links) = try await harness()
        defer { VoiceLaunchState.shared.finish() }
        try harness.service.startVoiceChat(gatewayID: Self.studio,
                                           agent: .init(hostID: Self.studio, agentID: "research"))
        #expect(BighelpIncomingURLRoute.parse(links.urls[0]) == .voice(agentID: "research", hostID: Self.studio))
        #expect(VoiceLaunchState.shared.agent?.name == "Rio")
        #expect(gateways.selected.isEmpty)
    }

    @Test func newChatAndPlacesOpenOnTheShortcutsGateway() async throws {
        let (harness, _, links) = try await harness()
        try harness.service.startNewChat(gatewayID: Self.studio, agent: nil)
        try harness.service.open(.feed, gatewayID: Self.studio)
        try harness.service.openAgentHome(gatewayID: nil, agent: .init(hostID: Self.studio, agentID: "research"))
        try harness.service.open(.settings, gatewayID: nil)
        #expect(BighelpIncomingURLRoute.parse(links.urls[0]) == .newChat(agentID: nil))
        #expect(BighelpIncomingURLRoute.parse(links.urls[1]) == .agent(tab: "feed"))
        #expect(BighelpIncomingURLRoute.parse(links.urls[2]) == .agent(tab: "chat", agentID: "research"))
        #expect(links.urls.prefix(3).allSatisfy { BighelpIncomingURLRoute.hostID(in: $0) == Self.studio })
        #expect(links.urls[3] == URL(string: "loopdy://settings")!, "No gateway: the one in use")
    }

    // MARK: Tasks, group chats and status on another gateway

    @Test func tasksAndGroupChatsOnAnotherGatewayComeFromIt() async throws {
        let (harness, gateways, _) = try await harness()
        let tasks = try await harness.service.availableScheduledTasks(on: Self.studio)
        #expect(tasks.map(\.name) == ["Weekly digest"])
        #expect(tasks.first?.agentName == "Rio")
        #expect(tasks.first?.isPaused == true)
        let groups = try await harness.service.availableGroupChats(on: Self.studio)
        #expect(groups.map(\.id) == ["hermes-room:room-1"])
        #expect(groups.first?.hostedRoomID == "room-1")
        #expect(gateways.selected.isEmpty)
        // One saved in a Shortcut keeps its ID while its gateway isn't in use.
        let saved = await harness.service.savedScheduledTasks(["rio\u{1F}job-9"], on: Self.studio)
        #expect(saved.map(\.id) == ["rio\u{1F}job-9"])
    }

    @Test func statusOfAnotherGatewayNeverSwitchesToIt() async throws {
        let (harness, gateways, _) = try await harness()
        #expect(await harness.service.hostStatus(gatewayID: Self.studio) == "Connected to Studio.\n1 agent.")
        gateways.reachable = false
        #expect(await harness.service.hostStatus(gatewayID: Self.studio) == "bighelp can't reach Studio right now.")
        #expect(gateways.selected.isEmpty)
    }

    // MARK: Links

    @Test func voiceLinksAreValidatedAndBounded() {
        let host = Self.studio.uuidString
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://voice")!) == .voice(agentID: nil, hostID: nil))
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://voice?agent=juno&host=\(host)")!)
                == .voice(agentID: "juno", hostID: Self.studio))
        for bad in ["loopdy://voice/extra", "loopdy://voice?agent=", "loopdy://voice?agent=a&agent=b",
                    "loopdy://voice?host=nope", "loopdy://voice?agent=a&other=1",
                    "loopdy://voice?agent=" + String(repeating: "x", count: 97)] {
            #expect(BighelpIncomingURLRoute.parse(URL(string: bad)!) == nil, "\(bad)")
        }
        #expect(BighelpIncomingURLRoute.hostID(in: URL(string: "loopdy://chat/abc?host=\(host)")!) == Self.studio)
        #expect(BighelpIncomingURLRoute.hostID(in: URL(string: "loopdy://chat/abc?host=\(host)&host=\(host)")!) == nil)
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://chat/abc?host=\(host)")!) == .chat(sessionID: "abc"))
    }

    // MARK: Widgets

    @Test func widgetLinksOpenOnTheGatewayTheirDataIsFrom() {
        var snapshot = BighelpWidgetSnapshot.preview
        #expect(snapshot.chatURL("a") == BighelpWidgetSnapshot.chatURL("a"), "No gateway: unchanged")
        snapshot.hostID = Self.studio.uuidString
        for url in [snapshot.chatURL("a"), snapshot.newChatURL(agentID: "default"), snapshot.taskURL("t"),
                    snapshot.tasksURL, snapshot.sessionsURL, snapshot.agentURL("feed")] {
            #expect(BighelpIncomingURLRoute.hostID(in: url) == Self.studio, "\(url)")
            #expect(BighelpIncomingURLRoute.parse(url) != nil, "\(url)")
        }
        #expect(BighelpWidgetSnapshot.fileURL(gateway: "not-a-uuid") == nil)
        #expect(BighelpWidgetSnapshot.fileURL(gateway: Self.studio.uuidString)?.lastPathComponent
                == "loopdy-widget-snapshot-v1-\(Self.studio.uuidString).json")
    }

    @Test func aRemovedGatewaysWidgetCopyIsDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "gateway-copies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefix = BighelpWidgetSnapshot.gatewayFilePrefix
        for name in [prefix + Self.home.uuidString + ".json", prefix + Self.studio.uuidString + ".json",
                     BighelpWidgetSnapshot.fileName] {
            try Data("{}".utf8).write(to: directory.appending(path: name))
        }
        BighelpWidgetGatewayPublisher.removeCopies(keeping: [Self.home.uuidString], in: directory)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(left == [BighelpWidgetSnapshot.fileName, prefix + Self.home.uuidString + ".json"].sorted())
    }

    @Test func thePublisherMarksItsGateway() async throws {
        var writes: [BighelpWidgetSnapshot] = []
        let agents = AgentDirectoryStore(client: AgentDirectoryFixtureClient(profiles: [.financeFixture]),
                                         defaults: isolatedDefaults())
        try await agents.load()
        let publisher = BighelpWidgetSnapshotPublisher(
            sessions: SessionCatalogStore(client: DemoSessionCatalogClient(), records: []), scheduledTasks: nil,
            agents: agents, hostID: Self.studio.uuidString, interval: .milliseconds(1), write: { writes.append($0) })
        publisher.publishNow()
        #expect(writes.last?.hostID == Self.studio.uuidString)
        publisher.retire()
        #expect(writes.last?.hostID == nil, "Retiring clears only the gateway in use's file")
    }
}

/// Home is in use; Studio answers with one agent, Rio, one paused task and one group chat.
@MainActor
final class FakeShortcutGateways: BighelpShortcutGatewayDirectory {
    static let home = UUID(uuidString: "0D0D0D0D-0000-4000-8000-0000000000A1")!
    static let studio = UUID(uuidString: "0D0D0D0D-0000-4000-8000-0000000000A2")!
    var selected: [UUID] = []
    var reachable = true

    var gateways: [BighelpShortcutGateway] {
        [.init(id: Self.home, name: "Home", isInUse: true), .init(id: Self.studio, name: "Studio", isInUse: false)]
    }

    /// Empty, like a cold start: the app's own agents stand in.
    var agentsInUse: [BighelpShortcutAgent] { [] }

    func select(_ id: UUID) { selected.append(id) }

    func agents(on id: UUID, reachOnly: Bool) async throws -> [BighelpShortcutAgent] {
        guard reachable else { throw BighelpShortcutServiceError.gatewayUnreachable }
        return savedAgents(on: id)
    }

    func modelProviders(on id: UUID, agentID: String) async throws -> [BighelpLinkModelProvider] { [] }

    func snapshot(of id: UUID) async throws -> FleetSnapshot {
        guard reachable else { throw BighelpShortcutServiceError.gatewayUnreachable }
        return FleetSnapshot(
            agents: [FleetAgent(hostID: id, profileID: "rio", name: "Rio", role: "Research", avatarFile: nil,
                                isPinned: false, isDefault: true, activity: nil)],
            tasks: [FleetTask(hostID: id, jobID: "job-1", profileID: "rio", name: "Weekly digest",
                              schedule: "Every Monday", nextRun: nil, status: .paused)],
            groups: [FleetGroup(hostID: id, roomID: "room-1", name: "Launch", memberNames: ["Rio"], updatedAt: .now,
                                isWorking: false, canRename: true, canDelete: true)],
            refreshedAt: .now)
    }

    func savedSnapshot(of id: UUID) -> FleetSnapshot? { nil }

    func savedAgents(on id: UUID) -> [BighelpShortcutAgent] {
        [.init(id: "research", name: "Rio", role: "Research", isDefault: true, hostID: id, hostName: "Studio")]
    }
}
