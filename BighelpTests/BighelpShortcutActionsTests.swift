import Foundation
import Testing
@testable import Bighelp

/// The Shortcuts actions beyond sending a chat: they all go through the same
/// live host path, and the ones that open bighelp hand a link to the app.
@MainActor
struct BighelpShortcutActionsTests {
    private func harness(
        tasks: [ScheduledTask] = ScheduledTasksFixtureClient.defaultTasks,
        rooms: BotModeRoomStore? = nil
    ) async throws -> (ShortcutServiceHarness, ScheduledTasksFixtureClient, LinkRecorder) {
        let client = ScheduledTasksFixtureClient(tasks: tasks)
        let store = ScheduledTasksStore(client: client, initialAgentID: nil)
        let harness = try await ShortcutServiceHarness(scheduledTasks: store, rooms: rooms)
        let links = LinkRecorder()
        harness.service.openLink = { links.urls.append($0) }
        return (harness, client, links)
    }

    // MARK: Scheduled tasks

    @Test func scheduledTasksNameTheirAgentAndSchedule() async throws {
        let (harness, _, _) = try await harness()
        let tasks = try await harness.service.availableScheduledTasks()
        #expect(tasks.map(\.name) == ["Morning market brief", "Trip check-in"])
        let brief = try #require(tasks.first)
        #expect(brief.agentName == "Finley")
        #expect(brief.jobID == "task-finance-brief")
        #expect(!brief.isPaused)
        // An agent this host no longer has keeps its ID rather than a blank.
        #expect(tasks.last?.agentName == "travel")
        #expect(tasks.last?.isPaused == true)
    }

    @Test func scheduledTaskListIsBounded() async throws {
        let many = (0..<80).map { index in
            ScheduledTask.fixture(id: "task-\(index)", agentID: "finance", name: "Task \(index)",
                                  instructions: "Check \(index).")
        }
        let (harness, _, _) = try await harness(tasks: many)
        #expect(try await harness.service.availableScheduledTasks().count == BighelpShortcutService.listLimit)
    }

    @Test func runNowRunsThatTaskOnTheHost() async throws {
        let (harness, client, _) = try await harness()
        let tasks = try await harness.service.availableScheduledTasks()
        let ran = try await harness.service.runScheduledTask(id: try #require(tasks.first).id)
        #expect(ran.name == "Morning market brief")
        #expect(client.lastMutation == ScheduledTaskMutation(id: "task-finance-brief", agentID: "finance"))
        let stored = try #require(harness.featureStore.scheduledTasks?.task(id: "task-finance-brief"))
        #expect(stored.lastResult == "Ran just now")
    }

    @Test func runNowForAMissingTaskSaysSoInPlainWords() async throws {
        let (harness, client, _) = try await harness()
        await #expect(throws: BighelpShortcutServiceError.scheduledTaskUnavailable) {
            try await harness.service.runScheduledTask(id: BighelpShortcutScheduledTask.entityID(
                agentID: "finance", jobID: "gone"))
        }
        #expect(client.lastMutation == nil)
        #expect(BighelpShortcutServiceError.scheduledTaskUnavailable.errorDescription?.contains("Hermes") == false)
    }

    @Test func runNowWithoutScheduledTasksOnThisConnectionSaysSo() async throws {
        let harness = try await ShortcutServiceHarness()
        await #expect(throws: BighelpShortcutServiceError.scheduledTaskUnavailable) {
            try await harness.service.availableScheduledTasks()
        }
    }

    // MARK: Group chats

    @Test func groupChatsListHostedRoomsAndOpenThroughTheGroupLink() async throws {
        let rooms = BotModeRoomStore(client: BotModeFixtureClient(), executionEnabled: false,
                                     nativeClient: BotModeCatalogFixtureClient())
        let (harness, _, links) = try await harness(rooms: rooms)
        let groups = try await harness.service.availableGroupChats()
        #expect(Set(groups.map(\.name)) == ["Studio pair", "Research circle"])
        let pair = try #require(groups.first { $0.name == "Studio pair" })
        #expect(pair.hostedRoomID == "studio-pair")

        let opened = try await harness.service.openGroupChat(id: pair.id)
        #expect(opened.name == "Studio pair")
        #expect(links.urls == [URL(string: "loopdy://group/studio-pair")!])
        #expect(BighelpIncomingURLRoute.parse(links.urls[0]) == .group(roomID: "studio-pair"))
    }

    @Test func aGroupChatSavedOnThePhoneOpensAsAChat() async throws {
        let (harness, _, links) = try await harness()
        harness.sessionClient.records = [
            SessionRecord(id: "demo-agent-group", kind: .botMode, agentIDs: ["finance", "default"],
                          title: "Household team", hasAcceptedMessage: true),
            SessionRecord(id: "one-to-one", kind: .direct, agentIDs: ["finance"], title: "Budget",
                          hasAcceptedMessage: true),
        ]
        let groups = try await harness.service.availableGroupChats()
        #expect(groups.map(\.name) == ["Household team"])
        #expect(groups.first?.memberNames == ["Finley", "Avery"])
        _ = try await harness.service.openGroupChat(id: "demo-agent-group")
        #expect(links.urls == [BighelpWidgetSnapshot.chatURL("demo-agent-group")])
    }

    @Test func aGroupChatThatIsGoneSaysSo() async throws {
        let (harness, _, links) = try await harness()
        await #expect(throws: BighelpShortcutServiceError.groupChatUnavailable) {
            try await harness.service.openGroupChat(id: "hermes-room:gone")
        }
        #expect(links.urls.isEmpty)
    }

    // MARK: Chats and agents

    @Test func continueLastChatOpensTheAgentsLatestChat() async throws {
        let (harness, _, links) = try await harness()
        harness.sessionClient.records = [
            SessionRecord(id: "older", kind: .direct, agentIDs: ["finance"], title: "Older",
                          updatedAt: Date(timeIntervalSince1970: 1_000), hasAcceptedMessage: true),
            SessionRecord(id: "latest", kind: .direct, agentIDs: ["finance"], title: "Latest",
                          updatedAt: Date(timeIntervalSince1970: 2_000), hasAcceptedMessage: true),
            SessionRecord(id: "someone-else", kind: .direct, agentIDs: ["default"], title: "Avery's",
                          updatedAt: Date(timeIntervalSince1970: 3_000), hasAcceptedMessage: true),
        ]
        let result = try await harness.service.continueLastChat(agentID: "finance")
        #expect(result == .init(sessionID: "latest", agentName: "Finley", isNew: false))
        #expect(links.urls == [BighelpWidgetSnapshot.chatURL("latest")])
        #expect(harness.catalog.records.count == 3, "No new chat was made")
    }

    @Test func continueLastChatStartsANewChatWhenThereIsNone() async throws {
        let (harness, _, links) = try await harness()
        let result = try await harness.service.continueLastChat(agentID: "finance")
        #expect(result.isNew)
        #expect(result.agentName == "Finley")
        #expect(links.urls.isEmpty)
        #expect(harness.state.path == [.chat(conversationID: result.sessionID)])
    }

    @Test func newChatSaysWhichAgentItIsWith() async throws {
        let (harness, _, _) = try await harness()
        let result = try await harness.service.openNewChat(agentID: "finance")
        #expect(result.agentName == "Finley")
        #expect(harness.state.path == [.chat(conversationID: result.sessionID)])
    }

    @Test func switchAgentMakesItTheHomeAgent() async throws {
        let (harness, _, _) = try await harness()
        #expect(harness.agents.resolvedAgent(explicitID: nil)?.id == "default")
        let agent = try await harness.service.switchAgent(to: "finance")
        #expect(agent.name == "Finley")
        #expect(harness.agents.resolvedAgent(explicitID: nil)?.id == "finance")
        await #expect(throws: BighelpShortcutServiceError.agentUnavailable) {
            try await harness.service.switchAgent(to: "missing")
        }
        #expect(harness.agents.resolvedAgent(explicitID: nil)?.id == "finance")
    }

    @Test func switchAgentWinsOverAnEarlierDefaultAgent() async throws {
        let (harness, _, _) = try await harness()
        _ = harness.agents.setPrimaryAgent("finance")
        _ = try await harness.service.switchAgent(to: "default")
        #expect(harness.agents.resolvedAgent(explicitID: nil)?.id == "default")
    }

    @Test func openAgentOpensThatAgentsHome() async throws {
        let (harness, _, links) = try await harness()
        try harness.service.openAgentHome(gatewayID: nil, agent: .init(hostID: nil, agentID: "finance"))
        #expect(links.urls == [URL(string: "loopdy://agent/chat?agent=finance")!])
        #expect(BighelpIncomingURLRoute.parse(links.urls[0]) == .agent(tab: "chat", agentID: "finance"))
    }

    // MARK: Navigation

    @Test func everySectionOpensThroughALinkTheAppUnderstands() {
        for destination in BighelpShortcutDestination.allCases {
            #expect(BighelpIncomingURLRoute.parse(destination.url) != nil, "\(destination)")
        }
        #expect(BighelpIncomingURLRoute.parse(BighelpShortcutDestination.agents.url) == .agents)
        #expect(BighelpIncomingURLRoute.parse(BighelpShortcutDestination.projects.url) == .projects)
        #expect(BighelpIncomingURLRoute.parse(BighelpShortcutDestination.settings.url) == .settings)
        #expect(BighelpIncomingURLRoute.parse(BighelpShortcutDestination.feed.url) == .agent(tab: "feed"))
        #expect(BighelpIncomingURLRoute.parse(BighelpShortcutDestination.scheduledTasks.url) == .scheduledTasks)
        #expect(BighelpIncomingURLRoute.parse(BighelpShortcutDestination.kanban.url) == .kanban(board: nil, task: nil))
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://group/")!) == nil)
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://group/a/b")!) == nil)
    }

    @Test func linksWaitInTheCenterUntilTheAppTakesThem() {
        let center = BighelpIncomingLinkCenter()
        center.open(BighelpShortcutDestination.settings.url)
        let pending = try? #require(center.pending)
        #expect(pending?.url == BighelpShortcutDestination.settings.url)
        #expect(center.consume(pending!))
        #expect(center.pending == nil)
        #expect(!center.consume(pending!), "A link opens once")
    }

    // MARK: Feed, Ideas and Goals

    @Test func boardItemsComeBackAsShortLines() async throws {
        let (harness, _, _) = try await harness()
        harness.service.hostServices.boards = { DemoAgentBoardClient() }
        let feed = try await harness.service.boardItems(.feed, agentID: "finance")
        #expect(feed.agentName == "Finley")
        #expect(feed.lines.count == 3)
        #expect(feed.lines[0] == "Lisbon fares dropped 18% for October: Round trips for October 9–16 are down to "
            + "$412, the lowest in six weeks. Want me to hold two seats before they climb again?")
        // Markdown marks never reach the text.
        #expect(feed.lines[1] == "Three stories worth your time tonight: Tonight's picks")
        #expect(feed.text.split(separator: "\n").count == 3)

        let goals = try await harness.service.boardItems(.goals, agentID: "finance")
        #expect(goals.lines.first == "Grocery delivery: Out for delivery; arriving between 5 and 6 pm.")
    }

    @Test func boardItemsAreBoundedAndSkipDismissedOnes() {
        let items = (0..<30).map { index in
            AgentBoardItem(id: "idea-\(index)", kind: .idea, title: "Idea \(index)",
                           body: String(repeating: "word ", count: 200), dismissed: index == 0,
                           createdAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let lines = BighelpShortcutBoardResult.lines(items, section: .ideas)
        #expect(lines.count == BighelpShortcutBoardResult.itemLimit)
        #expect(!lines.contains { $0.hasPrefix("Idea 0:") })
        #expect(lines.first?.hasPrefix("Idea 29:") == true)
        #expect(lines.allSatisfy { $0.count <= 240 })
    }

    @Test func anEmptyBoardSaysSo() {
        let result = BighelpShortcutBoardResult(agentName: "Finley", section: .ideas, lines: [])
        #expect(result.text == "Nothing in Finley's Ideas yet.")
    }

    @Test func aBoardWithoutThePluginAsksForAnUpdate() async throws {
        let (harness, _, _) = try await harness()
        await #expect(throws: BighelpShortcutServiceError.boardUnavailable) {
            try await harness.service.boardItems(.feed, agentID: nil)
        }
    }

    // MARK: Workflows

    private func workflowHarness() async throws -> (ShortcutServiceHarness, DemoWorkflowsClient, LinkRecorder, UUID) {
        let (harness, _, links) = try await harness()
        let demo = DemoWorkflowsClient(delays: false)
        let host = UUID()
        harness.service.hostServices.workflows = { demo }
        harness.service.hostServices.hostID = { host }
        return (harness, demo, links, host)
    }

    @Test func pinnedWorkflowsComeFirstAndKnowTheirComputer() async throws {
        let (harness, demo, _, host) = try await workflowHarness()
        _ = try await demo.pin(workflowID: "wf-morning", pinned: true)
        let workflows = try await harness.service.availableWorkflows()
        #expect(workflows.first?.workflowID == "wf-morning" && workflows.first?.isPinned == true,
                "A pinned workflow is a favorite: it comes first")
        #expect(Set(workflows.map(\.workflowID)) == ["wf-research", "wf-triage", "wf-captions", "wf-morning"])
        #expect(workflows.allSatisfy { $0.hostID == host })
        #expect(workflows.first?.id == BighelpShortcutWorkflow.entityID(hostID: host, workflowID: "wf-morning"))
    }

    @Test func openWorkflowOpensItOnItsComputerOrStraightToARun() async throws {
        let (harness, _, links, host) = try await workflowHarness()
        let id = BighelpShortcutWorkflow.entityID(hostID: host, workflowID: "wf-morning")
        try await harness.service.openWorkflow(id: id, startsRun: false)
        try await harness.service.openWorkflow(id: id, startsRun: true)
        #expect(links.urls.map { BighelpIncomingURLRoute.parse($0) } == [
            .workflow(id: "wf-morning", hostID: host, startsRun: false),
            .workflow(id: "wf-morning", hostID: host, startsRun: true),
        ])
    }

    @Test func aWorkflowOnAnotherComputerOpensThereWithoutAskingThisOne() async throws {
        let (harness, _, links, _) = try await workflowHarness()
        let other = UUID()
        try await harness.service.openWorkflow(id: BighelpShortcutWorkflow.entityID(hostID: other, workflowID: "wf_elsewhere"),
                                              startsRun: false)
        #expect(BighelpIncomingURLRoute.parse(try #require(links.urls.first))
                == .workflow(id: "wf_elsewhere", hostID: other, startsRun: false))
    }

    @Test func aWorkflowThatIsGoneOrAComputerWithoutWorkflowsSaysSo() async throws {
        let (harness, _, links, host) = try await workflowHarness()
        await #expect(throws: BighelpShortcutServiceError.workflowUnavailable) {
            try await harness.service.openWorkflow(id: BighelpShortcutWorkflow.entityID(hostID: host, workflowID: "gone"),
                                                  startsRun: false)
        }
        #expect(links.urls.isEmpty)
        harness.service.hostServices.workflows = { nil }
        await #expect(throws: BighelpShortcutServiceError.workflowsUnavailable) {
            try await harness.service.availableWorkflows()
        }
    }

    @Test func workflowLinksAreStrict() {
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://workflows")!) == .workflows)
        #expect(BighelpIncomingURLRoute.parse(BighelpShortcutDestination.workflows.url) == .workflows)
        #expect(BighelpIncomingURLRoute.parse(URL(string: "loopdy://workflows/wf_1")!)
                == .workflow(id: "wf_1", hostID: nil, startsRun: false))
        for bad in ["loopdy://workflows/a/b", "loopdy://workflows/wf_1?host=not-a-uuid",
                    "loopdy://workflows/wf_1?run=1&run=1", "loopdy://workflows/" + String(repeating: "x", count: 200)] {
            #expect(BighelpIncomingURLRoute.parse(URL(string: bad)!) == nil, "\(bad)")
        }
    }

    // MARK: Kanban

    @Test func addKanbanTaskFilesALaterCardOnTheBoard() async throws {
        let (harness, _, _) = try await harness()
        let kanban = DemoKanbanService()
        harness.service.hostServices.kanban = { kanban }
        harness.service.kanbanDefaults = isolatedDefaults()
        let result = try await harness.service.addKanbanTask(title: "  Book the dentist  ",
                                                             notes: "Thursday morning", assigneeID: "finance")
        #expect(result.title == "Book the dentist")
        let boards = try await kanban.boards()
        let board = try await kanban.board(boards.first { $0.isCurrent }?.slug ?? boards[0].slug)
        let card = try #require(board.columns.flatMap(\.tasks).first { $0.title == "Book the dentist" })
        #expect(card.assignee == "finance")
        #expect(card.status == .todo, "Later spends nothing: no agent picks it up")
        #expect(result.boardName == board.board.name)
    }

    @Test func addKanbanTaskNeedsATitleAndAKnownAgent() async throws {
        let (harness, _, _) = try await harness()
        harness.service.hostServices.kanban = { DemoKanbanService() }
        harness.service.kanbanDefaults = isolatedDefaults()
        await #expect(throws: BighelpShortcutServiceError.emptyTitle) {
            try await harness.service.addKanbanTask(title: "   ", notes: "", assigneeID: nil)
        }
        await #expect(throws: BighelpShortcutServiceError.agentUnavailable) {
            try await harness.service.addKanbanTask(title: "Card", notes: "", assigneeID: "missing")
        }
    }

    @Test func addKanbanTaskOnAHostWithoutKanbanSaysSo() async throws {
        let (harness, _, _) = try await harness()
        await #expect(throws: BighelpShortcutServiceError.kanbanUnavailable) {
            try await harness.service.addKanbanTask(title: "Card", notes: "", assigneeID: nil)
        }
        harness.service.hostServices.kanban = { NoKanbanService() }
        harness.service.kanbanDefaults = isolatedDefaults()
        await #expect(throws: BighelpShortcutServiceError.kanbanUnavailable) {
            try await harness.service.addKanbanTask(title: "Card", notes: "", assigneeID: nil)
        }
    }

    // MARK: Host status

    @Test func hostStatusIsAShortPlainSummary() async throws {
        let (harness, _, _) = try await harness()
        harness.service.hostServices.hostName = { "Studio Mac" }
        harness.service.hostServices.hermesVersion = { "0.21.4" }
        harness.sessionClient.records = [
            SessionRecord(id: "busy", kind: .direct, agentIDs: ["finance"], title: "Busy",
                          isActive: true, hasAcceptedMessage: true),
            SessionRecord(id: "quiet", kind: .direct, agentIDs: ["finance"], title: "Quiet",
                          hasAcceptedMessage: true),
        ]
        let status = await harness.service.hostStatus()
        #expect(status == "Connected to Studio Mac.\n2 agents.\n1 chat working right now.\nHermes 0.21.4.")
    }

    @Test func hostStatusLeavesOutAnythingThatIsNotAVersion() async throws {
        let (harness, _, _) = try await harness()
        harness.service.hostServices.hostName = { "Studio Mac" }
        harness.service.hostServices.hermesVersion = { "/Users/someone/.hermes token=abc" }
        let status = await harness.service.hostStatus()
        #expect(status == "Connected to Studio Mac.\n2 agents.\nNothing is working right now.")
    }

    @Test func hostStatusWithoutAComputerOrConnectionSaysSo() async throws {
        let (harness, _, _) = try await harness()
        #expect(await harness.service.hostStatus() == "No computer is set up in bighelp yet.")
        let offline = try await ShortcutServiceHarness(prepareConnection: { throw URLError(.notConnectedToInternet) })
        offline.service.hostServices.hostName = { "Studio Mac" }
        #expect(await offline.service.hostStatus() == "bighelp can't reach Studio Mac right now.")
    }

    // MARK: Shortcut tiles

    @Test func tilesRefreshOnlyWhenNamesChange() {
        let first = BighelpShortcutParameterSignature(agents: [.financeFixture], tasks: [], groups: ["Team"])
        let renamed = BighelpShortcutParameterSignature(
            agents: [AgentProfile(id: "finance", name: "Fin", role: "", summary: "", instructions: "",
                                  avatarFileName: nil, isDefault: false)], tasks: [], groups: ["Team"])
        #expect(first == BighelpShortcutParameterSignature(agents: [.financeFixture], tasks: [], groups: ["Team"]))
        #expect(first != renamed)
        let many = BighelpShortcutParameterSignature(
            agents: [], tasks: [], groups: (0..<200).map { "Group \($0)" })
        #expect(many.values.count == BighelpShortcutService.listLimit)
    }
}

@MainActor
final class LinkRecorder {
    var urls: [URL] = []
}

/// A host whose Hermes has no Kanban plugin.
@MainActor
private final class NoKanbanService: KanbanService {
    func isAvailable() async throws -> Bool { false }
    func boards() async throws -> [HermesKanbanBoard] { throw HermesKanbanError.unavailable }
    func board(_ slug: String) async throws -> HermesKanbanBoardSnapshot { throw HermesKanbanError.unavailable }
    func task(_ id: String, board: String) async throws -> HermesKanbanTaskDetail { throw HermesKanbanError.unavailable }
    func activeWorkers(board: String) async throws -> [HermesKanbanActiveWorker] { [] }
    func orchestration() async throws -> HermesKanbanOrchestration { throw HermesKanbanError.unavailable }
    func move(_ taskID: String, to status: HermesKanbanTaskStatus, board: String) async throws -> HermesKanbanTaskDetail {
        throw HermesKanbanError.unavailable
    }
    func edit(_ taskID: String, board: String, patch: HermesKanbanTaskPatch) async throws -> HermesKanbanTaskDetail {
        throw HermesKanbanError.unavailable
    }
    func reassign(_ taskID: String, to profile: String?, board: String) async throws -> HermesKanbanTaskDetail {
        throw HermesKanbanError.unavailable
    }
    func comment(_ body: String, on taskID: String, board: String) async throws -> HermesKanbanTaskDetail {
        throw HermesKanbanError.unavailable
    }
    func create(_ draft: HermesKanbanTaskDraft, board: String) async throws -> HermesKanbanTaskDetail {
        Issue.record("A host without Kanban must not be asked to create a card")
        throw HermesKanbanError.unavailable
    }
    func createBoard(named name: String) async throws -> [HermesKanbanBoard] { throw HermesKanbanError.unavailable }
    func startReadyWork(board: String) async throws -> HermesKanbanBoardSnapshot { throw HermesKanbanError.unavailable }
    func setAutoPlan(_ isOn: Bool) async throws -> HermesKanbanOrchestration { throw HermesKanbanError.unavailable }
    func liveBoards(_ slug: String, since cursor: Int) throws -> AsyncThrowingStream<HermesKanbanBoardSnapshot, any Error> {
        throw HermesKanbanError.unavailable
    }
}
