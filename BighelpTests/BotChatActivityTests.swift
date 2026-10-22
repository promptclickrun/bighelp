import Foundation
import Testing
@testable import Bighelp

/// Which bots are working or need you (#504): the plugin's `agents/activity` answer, the stock
/// signals without it, the all-hosts copies of other gateways, and the store that keeps them.
@MainActor
struct BotChatActivityTests {
    // MARK: The plugin's answer

    @Test func readsEachAgentsStateLeniently() {
        let response: [String: BighelpJSONValue] = ["agents": .array([
            .object(["agentId": .string("default"), "state": .string("idle")]),
            .object(["agentId": .string("nova"), "state": .string("working"), "tool": .string("web_search")]),
            .object(["agentId": .string("pip"), "state": .string("waiting")]),
            .object(["agentId": .string("rio"), "state": .string("working"), "tool": .string("rm -rf /")]),
            // Not asked, a state this build doesn't know, a second answer: left out.
            .object(["agentId": .string("ghost"), "state": .string("working")]),
            .object(["agentId": .string("sage"), "state": .string("dreaming")]),
            .object(["agentId": .string("pip"), "state": .string("idle")]),
            .string("not a row"),
        ])]
        let values = DirectHermesBotChatActivityClient.activities(
            from: response, asked: ["default", "nova", "pip", "rio", "sage"])
        #expect(values == ["default": .idle, "nova": .working(tool: "web_search"), "pip": .waiting,
                           "rio": .working(tool: nil)])
        #expect(DirectHermesBotChatActivityClient.activities(from: [:], asked: ["default"]) == nil)
    }

    @Test func asksOnceForAtMost64ValidAgentsAndRetriesAChangedContextOnce() async throws {
        let workspace = try ActivityPerformer()
        let client = DirectHermesBotChatActivityClient(currentWorkspace: { workspace })
        let ids = ["default", "Not An ID", "../etc"] + (0..<80).map { "agent-\($0)" }
        workspace.failures = [WorkspaceClientError.conflict]
        workspace.answer = ["agents": .array([.object(["agentId": .string("default"), "state": .string("waiting")])])]
        let values = await client.activity(agentIDs: ids)
        #expect(values == ["default": .waiting])
        #expect(workspace.payloads.count == 2, "Once, and once more after the context changed")
        let sent = workspace.payloads.last?["agentIds"]?.array?.compactMap(\.string) ?? []
        #expect(sent.count == 64)
        #expect(sent.first == "default")
        #expect(!sent.contains("Not An ID") && !sent.contains("../etc"))

        workspace.failures = [WorkspaceClientError.unavailable(.unsupportedOperation)]
        #expect(await client.activity(agentIDs: ["default"]) == nil, "An older plugin: the host can't say")
    }

    // MARK: Presentation

    @Test func mapsStatesToTheFaceAndTheRowLine() {
        #expect(BotChatActivity.working(tool: "web_search").activityKind == .web)
        #expect(BotChatActivity.working(tool: "web_search").line == "Browsing the web…")
        #expect(BotChatActivity.working(tool: nil).line == "Working…")
        #expect(BotChatActivity.working(tool: nil).liveState == .thinking)
        #expect(BotChatActivity.waiting.line == "Needs you")
        #expect(BotChatActivity.waiting.liveState == .nudge)
        #expect(BotChatActivity.idle.line == nil)
        #expect(BotChatActivity.idle.accessibilityLabel == nil)
        #expect(FleetActivity.waiting.botChatActivity == .waiting)
    }

    @Test func needingYouWinsOverWorkingAndUnknownGivesWay() {
        #expect(BotChatActivity.merged(.working(tool: "terminal"), .waiting) == .waiting)
        #expect(BotChatActivity.merged(.waiting, .working(tool: nil)) == .waiting)
        #expect(BotChatActivity.merged(.idle, .working(tool: "terminal")) == .working(tool: "terminal"))
        #expect(BotChatActivity.merged(nil, .idle) == .idle)
        #expect(BotChatActivity.merged(nil, nil) == nil)
    }

    @Test func theAgentsScreenShowsBotChatsAndAGroupApprovalWins() throws {
        let states = AgentLiveStatePresentation.agentStates(
            rooms: [], pendingApprovals: { _ in [] },
            botChats: ["nova": .working(tool: "web_search"), "pip": .waiting, "rio": .idle])
        #expect(states == ["nova": .thinking, "pip": .nudge], "Idle stays idle: nothing invented")
    }

    // MARK: Signals without the route

    @Test func withoutTheRouteOnlyARunningBotChatCounts() {
        let records = [
            SessionRecord(id: "a", kind: .direct, agentIDs: ["nova"], title: "Bot Chat", isActive: true),
            SessionRecord(id: "b", kind: .direct, agentIDs: ["pip"], title: "Plans", isActive: true),
            SessionRecord(id: "c", kind: .direct, agentIDs: ["rio"], title: "Bot Chat", isActive: false),
        ]
        #expect(BotChatActivitySignals.botChats(records) == ["nova": .working(tool: nil)],
                "Another running chat isn't the Bot Chat")
    }

    @Test func otherGatewaysAreKeyedByGatewayAndShowOnlyWhileFresh() {
        let desk = UUID(), lab = UUID(), old = UUID()
        let now = Date(timeIntervalSince1970: 2_000_000)
        func agent(_ host: UUID, _ id: String, _ botChat: BotChatActivity?, _ activity: FleetActivity? = nil) -> FleetAgent {
            FleetAgent(hostID: host, profileID: id, name: id, role: "", isPinned: false, isDefault: id == "default",
                       activity: activity, botChat: botChat.map(FleetBotChat.init))
        }
        let snapshots: [UUID: FleetSnapshot] = [
            desk: FleetSnapshot(agents: [agent(desk, "default", .working(tool: "terminal"))], refreshedAt: now.addingTimeInterval(-10)),
            lab: FleetSnapshot(agents: [agent(lab, "default", .idle), agent(lab, "nova", nil, .waiting),
                                        agent(lab, "pip", nil)], refreshedAt: now.addingTimeInterval(-30)),
            old: FleetSnapshot(agents: [agent(old, "default", .waiting)], refreshedAt: now.addingTimeInterval(-600)),
        ]
        let values = BotChatActivitySignals.fleet(snapshots, now: now)
        #expect(values[FleetID.make(desk, "default")] == .working(tool: "terminal"))
        #expect(values[FleetID.make(lab, "default")] == .idle, "The same profile on another gateway is its own")
        #expect(values[FleetID.make(lab, "nova")] == .waiting, "An older plugin there: what Hermes said of its chats")
        #expect(values[FleetID.make(lab, "pip")] == .idle)
        #expect(values[FleetID.make(old, "default")] == nil, "An old copy says nothing")
        #expect(values["default"] == nil && values[BotChatActivityStore.liveKey("default")] == nil)
    }

    @Test func fleetCopiesKeepTheBotChatAcrossSaves() throws {
        let agent = FleetAgent(hostID: UUID(), profileID: "nova", name: "Nova", role: "", isPinned: false,
                               isDefault: false, botChat: FleetBotChat(.working(tool: "browser_navigate")))
        let decoded = try JSONDecoder().decode(FleetAgent.self, from: JSONEncoder().encode(agent))
        #expect(decoded.botChat?.activity == .working(tool: "browser_navigate"))
        // A copy saved before this build has no Bot Chat state: the agent's chats say.
        var legacy = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as? [String: Any])
        legacy["botChat"] = nil
        let older = try JSONDecoder().decode(FleetAgent.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(older.botChat == nil)
    }

    // MARK: The store

    @Test func storeReadsTheGatewayInUseAndClearsWhenTheTurnEnds() async throws {
        let reader = ScriptedReader()
        let store = BotChatActivityStore(sleep: { _ in })
        let gateway = Gateway(scope: "desk", reader: reader)
        store.use(gateway.source)
        reader.next = ["nova": .working(tool: "web_search"), "pip": .waiting]
        #expect(await store.tick())
        #expect(store.activity(BotChatActivityStore.liveKey("nova")) == .working(tool: "web_search"))
        #expect(store.activity(BotChatActivityStore.liveKey("pip")) == .waiting)
        #expect(store.activity(BotChatActivityStore.liveKey("rio")) == nil, "Left out by the host: unknown")
        #expect(store.liveActivities() == ["nova": .working(tool: "web_search"), "pip": .waiting])

        reader.next = ["nova": .idle, "pip": .idle, "rio": .idle]
        #expect(await store.tick() == false, "All idle: the slower interval")
        #expect(store.activity(BotChatActivityStore.liveKey("nova")) == .idle)
        #expect(store.liveActivities().isEmpty)

        reader.next = nil
        await store.tick()
        #expect(store.activity(BotChatActivityStore.liveKey("nova")) == nil, "A failed read is unknown, not idle")
    }

    @Test func storeDropsALateAnswerAfterTheGatewayOrSignInChanges() async throws {
        let reader = ScriptedReader()
        let store = BotChatActivityStore(sleep: { _ in })
        let gateway = Gateway(scope: "desk", reader: reader)
        store.use(gateway.source)
        reader.next = ["nova": .working(tool: nil)]
        reader.onRead = { gateway.scope = "lab" }
        await store.tick()
        #expect(store.activity(BotChatActivityStore.liveKey("nova")) == nil, "Desk's answer arrived after Lab came into use")

        reader.onRead = nil
        await store.tick()
        #expect(store.activity(BotChatActivityStore.liveKey("nova")) == .working(tool: nil))
        reader.next = ["nova": .waiting]
        reader.onRead = { gateway.signIn = WorkspaceSignIn(authority: try! .fixture(id: "lab"), authenticationGeneration: UUID()) }
        await store.tick()
        #expect(store.activity(BotChatActivityStore.liveKey("nova")) == .working(tool: nil),
                "Signed in again meanwhile: the old answer is dropped")

        gateway.scope = "studio"
        reader.onRead = nil
        reader.next = [:]
        await store.tick()
        #expect(store.activity(BotChatActivityStore.liveKey("nova")) == nil, "Another gateway's bots start unknown")
    }

    @Test func storeUsesTheStockSignalWithoutTheRouteAndOtherGatewaysByFleetID() async {
        let store = BotChatActivityStore(sleep: { _ in })
        let lab = UUID()
        var refreshes = 0
        store.use(BotChatActivitySource(
            live: { .init(scope: "desk", signIn: nil, agentIDs: ["nova", "pip"], reader: nil,
                          fallback: { ["nova": .working(tool: nil)] }) },
            others: { [FleetID.make(lab, "nova"): .waiting] },
            refreshOthers: { refreshes += 1 }))
        #expect(await store.tick())
        #expect(store.activity(BotChatActivityStore.liveKey("nova")) == .working(tool: nil))
        #expect(store.activity(BotChatActivityStore.liveKey("pip")) == .idle, "The stock signal knows the rest are idle")
        #expect(store.activity(FleetID.make(lab, "nova")) == .waiting, "Lab's Nova isn't the gateway in use's")
        await store.tick()
        #expect(refreshes == 1, "Other gateways' copies are read again at most once a minute")
    }

    @Test func watchingRunsOneLoopForEveryScreenAndClearsWhenTheLastGoes() async throws {
        let reader = ScriptedReader()
        reader.next = ["nova": .working(tool: nil)]
        let store = BotChatActivityStore(sleep: { _ in try await Task.sleep(for: .milliseconds(20)) })
        let source = Gateway(scope: "desk", reader: reader).source
        let home = Task { await store.watch(source) }
        let agents = Task { await store.watch(source) }
        try await waitUntil { store.activity(BotChatActivityStore.liveKey("nova")) != nil }
        let reads = reader.reads
        try await Task.sleep(for: .milliseconds(120))
        #expect(reader.reads - reads <= 8, "One loop, not one a screen")
        home.cancel()
        await home.value
        #expect(store.activity(BotChatActivityStore.liveKey("nova")) == .working(tool: nil), "The Agents screen still shows")
        agents.cancel()
        await agents.value
        #expect(store.activity(BotChatActivityStore.liveKey("nova")) == nil, "Nothing shows it: cleared, it would go stale")
        let stopped = reader.reads
        try await Task.sleep(for: .milliseconds(100))
        #expect(reader.reads == stopped, "No reads once no screen shows it")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}

@MainActor
private final class Gateway {
    var scope: String
    var signIn: WorkspaceSignIn?
    let reader: ScriptedReader

    init(scope: String, reader: ScriptedReader) {
        self.scope = scope
        self.reader = reader
        signIn = WorkspaceSignIn(authority: try! .fixture(id: scope), authenticationGeneration: UUID())
    }

    var source: BotChatActivitySource {
        BotChatActivitySource(live: { [self] in
            .init(scope: scope, signIn: signIn, agentIDs: ["nova", "pip", "rio"], reader: reader, fallback: { [:] })
        })
    }
}

@MainActor
private final class ScriptedReader: BotChatActivityReading {
    var next: [String: BotChatActivity]? = [:]
    var onRead: (() -> Void)?
    private(set) var reads = 0

    func activity(agentIDs: [String]) async -> [String: BotChatActivity]? {
        reads += 1
        await Task.yield()
        onRead?()
        return next
    }
}

@MainActor
private final class ActivityPerformer: WorkspaceOperationPerforming {
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner, values: [:]) }
    var failures: [any Error] = []
    var answer: [String: BighelpJSONValue] = ["agents": .array([])]
    private(set) var payloads: [[String: BighelpJSONValue]] = []

    init() throws {
        owner = WorkspaceOwner(authority: try .fixture(id: UUID().uuidString),
                               authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue],
                 owner: WorkspaceOwner) async throws -> [String: BighelpJSONValue] {
        guard owner == self.owner, operation == .agentsActivity else { throw WorkspaceClientError.ownerChanged }
        payloads.append(payload)
        if !failures.isEmpty { throw failures.removeFirst() }
        return answer
    }
}
