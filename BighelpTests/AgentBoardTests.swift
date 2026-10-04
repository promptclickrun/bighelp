import Foundation
import Testing
@testable import Bighelp

@MainActor
struct AgentBoardTests {
    @Test func runningToolPicksTheAvatarReaction() {
        let expected: [String: AgentActivityKind] = [
            "terminal": .coding, "execute_code": .coding, "patch": .coding,
            "web_search": .web, "web_extract": .web, "browser_navigate": .web,
            "image_generate": .images, "vision_analyze": .seeing,
            "memory": .memory, "session_search": .memory, "skill_view": .memory,
            "cronjob": .scheduling, "delegate_task": .delegating,
            "read_file": .files, "write_file": .files, "search_files": .files,
            "send_message": .messaging, "text_to_speech": .messaging,
            "bighelp_board": .publishing, "clarify": .waiting, "todo": .tools,
        ]
        for (tool, kind) in expected {
            #expect(AgentActivityKind(toolName: tool) == kind, "\(tool)")
        }
        #expect(AgentActivityKind(category: "coding") == .coding)
        #expect(AgentActivityKind(category: "something-new") == .tools)
    }

    @Test func everyWorkingStateHasAMoveTheAvatarsKnow() {
        for kind in AgentActivityKind.allCases where kind != .idle {
            let mood = kind.moodID
            #expect(mood.map(BuddyPose.moods.contains) == true, "\(kind) → \(mood ?? "nil")")
            #expect(!kind.label.isEmpty)
        }
        #expect(AgentActivityKind.idle.moodID == nil)
        #expect(!AgentActivityKind.idle.isWorking && !AgentActivityKind.done.isWorking)
        #expect(AgentActivityKind.images.isWorking)
    }

    @Test func boardItemsKeepOnlySafeLinksAndPictures() throws {
        let json: BighelpJSONValue = .object([
            "id": .string("feed-1"), "kind": .string("feed"), "title": .string("Fares dropped"),
            "body": .string("Now $412"), "icon": .string("✈️"), "liked": .boolean(true),
            "createdAt": .integer(1_790_000_000), "updatedAt": .integer(1_790_000_100),
            "links": .array([
                .object(["url": .string("https://example.com/a"), "title": .string("Book")]),
                .object(["url": .string("javascript:alert(1)")]),
                .object(["url": .string("file:///etc/passwd")]),
            ]),
            "images": .array([
                .object(["url": .string("https://example.com/p.jpg")]),
                .object(["url": .string("http://example.com/plain.jpg")]),
                .object(["index": .integer(0)]),
                .object(["index": .integer(9)]),
            ]),
        ])
        let item = try AgentBoardItem(json: json)
        #expect(item.kind == .feed && item.liked && item.title == "Fares dropped")
        #expect(item.links.map(\.url.absoluteString) == ["https://example.com/a"])
        #expect(item.pictures == [.remote(URL(string: "https://example.com/p.jpg")!), .stored(index: 0)])
        #expect(item.createdAt == Date(timeIntervalSince1970: 1_790_000_000))

        #expect(throws: (any Error).self) { try AgentBoardItem(json: .object(["kind": .string("feed"), "title": .string("x")])) }
        #expect(throws: (any Error).self) {
            try AgentBoardItem(json: .object(["id": .string("a"), "kind": .string("poster"), "title": .string("x")]))
        }
    }

    @Test func thumbsShowAtOnceAndRollBackWhenHermesRefuses() async {
        let client = FakeBoardClient(items: [AgentBoardItem(id: "a", kind: .feed, title: "One")])
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        #expect(store.state == .loaded && store.feed.count == 1)

        await store.rate(store.feed[0], .up)
        #expect(store.feed[0].rating == .up && store.feed[0].liked)

        await store.rate(store.feed[0], .down, reason: "Too frequent")
        #expect(store.feed[0].rating == .down && store.feed[0].reason == "Too frequent")
        #expect(client.updates.last?.change == AgentBoardChange(rating: .down, reason: "Too frequent"))

        client.failsUpdates = true
        await store.rate(store.feed[0], .none)
        #expect(store.feed[0].rating == .down, "A refused change must roll back")
    }

    @Test func deleteHidesWithUndoAndReadStateCounts() async {
        let client = FakeBoardClient(items: [
            AgentBoardItem(id: "a", kind: .feed, title: "One", read: false),
            AgentBoardItem(id: "b", kind: .feed, title: "Two", read: false),
            AgentBoardItem(id: "i", kind: .idea, title: "Idea", read: false),
        ])
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        #expect(store.unreadCount(.feed) == 2 && store.unreadCount(.idea) == 1)

        await store.markSeen(store.feed)
        #expect(store.unreadCount(.feed) == 0)
        #expect(client.markedRead == ["a", "b"])
        await store.setRead(store.feed[0], false)
        #expect(store.unreadCount(.feed) == 1)

        await store.hide(store.feed[0])
        #expect(store.feed.map(\.id) == ["b"] && store.recentlyHidden?.id == "a")
        await store.undoHide()
        #expect(store.feed.map(\.id) == ["a", "b"] && store.recentlyHidden == nil)
        #expect(client.updates.suffix(2).map(\.change.dismissed) == [true, false])
    }

    @Test func anIdeaTurnsIntoAGoal() async {
        let client = FakeBoardClient(items: [AgentBoardItem(id: "i", kind: .idea, title: "Sleep by 11", icon: "🌙")])
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        #expect(await store.promote(store.ideas[0]))
        #expect(store.ideas.isEmpty)
        #expect(store.goals.map(\.title) == ["Sleep by 11"])
    }

    /// Let's do it tells the host which idea by its ID, and the chat gets only the readable text.
    @Test func letsDoItNamesTheIdeaByIDAndKeepsTheIDOutOfTheChat() async throws {
        let client = FakeBoardClient(items: [
            AgentBoardItem(id: "idea-7f3a91", kind: .idea, title: "Plan a trip"),
            AgentBoardItem(id: "idea-0c2e44", kind: .idea, title: "Plan a trip"),
        ])
        client.supportsAnswers = true
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        let idea = try #require(store.ideas.first { $0.id == "idea-0c2e44" })
        #expect(await store.accept(idea) == .recorded)
        #expect(client.accepted.map(\.itemID) == ["idea-0c2e44"], "Exactly the tapped idea, not its same-title twin")
        #expect(client.accepted.map(\.agentID) == ["default"])
        #expect(store.ideas.count == 2, "The idea stays on the board")
        let text = idea.letsDoItMessage
        #expect(text == "Yes, go ahead with this idea: “Plan a trip”.")
        #expect(!text.contains(idea.id) && !text.contains("idea-"))
    }

    @Test func letsDoItOnAnOlderPluginJustOpensTheChat() async {
        let client = FakeBoardClient(items: [AgentBoardItem(id: "i", kind: .idea, title: "Plan a trip")])
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        #expect(await store.accept(store.ideas[0]) == .notSupported)
        #expect(client.accepted.isEmpty)

        // A plugin that stops listing the feature after the board loaded: still no error.
        client.supportsAnswers = true
        client.acceptError = WorkspaceClientError.unavailable(.unsupportedOperation)
        #expect(await store.accept(store.ideas[0]) == .notSupported)

        store.configure(client: nil)
        #expect(await store.accept(AgentBoardItem(id: "i", kind: .idea, title: "Plan a trip")) == .notSupported)
    }

    @Test func aFailedLetsDoItCanBeTriedAgain() async {
        let client = FakeBoardClient(items: [AgentBoardItem(id: "i", kind: .idea, title: "Plan a trip")])
        client.supportsAnswers = true
        client.acceptError = WorkspaceClientError.outcomeUnknown
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        #expect(await store.accept(store.ideas[0]) == .failed)
        client.acceptError = nil
        #expect(await store.accept(store.ideas[0]) == .recorded)
        #expect(client.accepted.map(\.itemID) == ["i"])
    }

    @Test func letsDoItIsNotRecordedAcrossAHostOrAgentChange() async {
        let client = FakeBoardClient(items: [AgentBoardItem(id: "i", kind: .idea, title: "Plan a trip")])
        client.supportsAnswers = true
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        let idea = store.ideas[0]
        // The connection changes while the request is out: the answer belongs to the old one.
        client.onAccept = { store.configure(client: FakeBoardClient(items: [])) }
        #expect(await store.accept(idea) == .failed)

        // An idea from another agent's board never goes to this one.
        let other = FakeBoardClient(items: [AgentBoardItem(id: "j", kind: .idea, title: "Other")])
        other.supportsAnswers = true
        store.configure(client: other)
        await store.load(agentID: "work")
        #expect(await store.accept(idea) == .failed)
        #expect(other.accepted.isEmpty)
        // Only ideas.
        #expect(await store.accept(AgentBoardItem(id: "j", kind: .feed, title: "Other")) == .failed)
    }

    @Test func theAcceptRouteSendsOnlyTheAgentAndIdeaIDs() async throws {
        let performer = try BoardPerformer()
        let old = DirectHermesAgentBoardClient(workspace: performer, owner: performer.owner!, supportsFeedback: true)
        #expect(!old.supportsAnswers)
        await #expect(throws: WorkspaceClientError.unavailable(.unsupportedOperation)) {
            try await old.accept(agentID: "default", itemID: "i")
        }
        #expect(performer.calls.isEmpty)
        let current = DirectHermesAgentBoardClient(workspace: performer, owner: performer.owner!, supportsFeedback: true,
                                                   supportsAnswers: true)
        try await current.accept(agentID: "default", itemID: "idea-7f3a91")
        #expect(performer.calls.map(\.operation) == [.boardAccept])
        #expect(performer.calls.last?.payload == ["agentId": .string("default"), "itemId": .string("idea-7f3a91")])
        #expect(DirectHermesNativePluginClient.supports(.boardAccept))
        #expect(DemoAgentBoardClient().supportsAnswers)
    }

    @Test func olderPluginsKeepTheHeartAndHideNewFeedback() async throws {
        let performer = try BoardPerformer()
        let old = DirectHermesAgentBoardClient(workspace: performer, owner: performer.owner!, supportsFeedback: false)
        _ = try await old.update(agentID: "default", itemID: "a", change: .init(rating: .up, reason: "x", read: true))
        #expect(performer.calls.last?.payload["liked"] == .boolean(true))
        #expect(performer.calls.last?.payload["rating"] == nil && performer.calls.last?.payload["read"] == nil)
        await #expect(throws: (any Error).self) {
            _ = try await old.update(agentID: "default", itemID: "a", change: .init(rating: .down))
        }
        try await old.markRead(agentID: "default", itemIDs: ["a"])
        #expect(performer.calls.count == 1, "No read route on an older plugin")

        let current = DirectHermesAgentBoardClient(workspace: performer, owner: performer.owner!, supportsFeedback: true)
        _ = try await current.update(agentID: "default", itemID: "a", change: .init(rating: .down, reason: "Not relevant"))
        #expect(performer.calls.last?.payload["rating"] == .string("down"))
        #expect(performer.calls.last?.payload["reason"] == .string("Not relevant"))
        try await current.markRead(agentID: "default", itemIDs: ["a", "b"])
        #expect(performer.calls.last?.operation == .boardRead)

        // Items from an older plugin: the heart is thumbs up and nothing is "new".
        let legacy = try AgentBoardItem(json: .object(["id": .string("x"), "kind": .string("feed"),
                                                        "title": .string("t"), "liked": .boolean(true)]))
        #expect(legacy.rating == .up && legacy.read)
        let rated = try AgentBoardItem(json: .object(["id": .string("y"), "kind": .string("feed"), "title": .string("t"),
                                                       "rating": .string("down"), "reason": .string("Wrong timing"),
                                                       "read": .boolean(false)]))
        #expect(rated.rating == .down && rated.reason == "Wrong timing" && !rated.read)
    }

    @Test func goalsToggleDoneAndANewConnectionClearsTheBoard() async {
        let client = FakeBoardClient(items: [
            AgentBoardItem(id: "g", kind: .goal, title: "Sleep", section: "goal", status: "active"),
            AgentBoardItem(id: "t", kind: .goal, title: "Groceries", section: "tracking", status: "active"),
            AgentBoardItem(id: "i", kind: .idea, title: "Cheaper plan"),
        ])
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.load(agentID: "default")
        #expect(store.goals.count == 2 && store.ideas.count == 1)
        #expect(store.goals.filter(\.isTracking).map(\.id) == ["t"])

        await store.setDone(store.goals.first { $0.id == "g" }!, true)
        #expect(store.goals.first { $0.id == "g" }?.isDone == true)
        #expect(client.updates.last?.change.status == "done")

        store.configure(client: nil)
        #expect(store.items.isEmpty && store.state == .unavailable && !store.isAvailable)
        await store.load(agentID: "default")
        #expect(store.state == .unavailable)
    }

    /// Coming back to the app reconnects: for a moment there's no connection, then one whose
    /// plugin features aren't known yet. Feed, Ideas and Goals keep what they show (never "update
    /// the plugin") and reload by themselves once the new connection is ready.
    @Test func comingBackKeepsTheBoardAndReloadsIt() async {
        let first = FakeBoardClient(items: [AgentBoardItem(id: "a", kind: .feed, title: "Before")])
        let store = AgentBoardStore()
        await store.connect(client: first, scope: "studio")
        await store.load(agentID: "default")
        #expect(store.feed.map(\.title) == ["Before"])

        store.waitForConnection()
        #expect(store.state == .loaded && store.feed.map(\.title) == ["Before"])
        #expect(store.state != .unavailable)

        let second = FakeBoardClient(items: [AgentBoardItem(id: "b", kind: .feed, title: "After")])
        await store.connect(client: second, scope: "studio")
        #expect(store.state == .loaded && store.feed.map(\.title) == ["After"], "Reloaded without leaving the screen")
    }

    @Test func aFirstConnectionWaitsInsteadOfAskingForAPluginUpdate() async {
        let store = AgentBoardStore()
        store.waitForConnection()
        #expect(store.state == .loading)
        await store.load(agentID: "default")
        #expect(store.state == .loading, "No client yet: still waiting, not unavailable")
        await store.connect(client: FakeBoardClient(items: [AgentBoardItem(id: "i", kind: .idea, title: "Plan")]),
                            scope: "studio")
        #expect(store.state == .loaded && store.ideas.count == 1, "The page asked for an agent; it loads now")
    }

    @Test func anotherComputerStartsFresh() async {
        let store = AgentBoardStore()
        await store.connect(client: FakeBoardClient(items: [AgentBoardItem(id: "a", kind: .feed, title: "Studio")]),
                            scope: "studio")
        await store.load(agentID: "default")
        await store.connect(client: FakeBoardClient(items: [AgentBoardItem(id: "b", kind: .feed, title: "Lab")]),
                            scope: "lab")
        #expect(store.items.isEmpty && store.state == .idle, "Nothing from the other computer stays")
        // A host whose plugin really lacks the board still says so.
        store.configure(client: nil)
        #expect(store.state == .unavailable && !store.isDisconnected)
    }

    /// Only a host that answered without the board asks for a plugin update. Reconnecting, and the
    /// moment after when the features still belong to the old connection, just wait.
    @Test func onlyAMissingBoardAsksForAPluginUpdate() {
        typealias Step = AgentBoardConnectionStep
        #expect(Step.decide(isConnected: true, board: .available, reconnects: true) == .connect)
        #expect(Step.decide(isConnected: true, board: .unknown, reconnects: true) == .wait)
        #expect(Step.decide(isConnected: true, board: .unavailable(.notConnected), reconnects: true) == .wait)
        #expect(Step.decide(isConnected: false, board: .unknown, reconnects: true) == .wait)
        #expect(Step.decide(isConnected: true, board: .unavailable(.pluginRequired), reconnects: true) == .pluginMissing)
        #expect(Step.decide(isConnected: false, board: .unknown, reconnects: false) == .disconnected)
    }

    @Test func profileHistoryLoadsEvenWithoutIdentityFiles() async {
        let client = FakeBoardClient(items: [])
        client.failsIdentity = true
        let store = AgentBoardStore()
        store.configure(client: client)
        await store.loadLogs(agentID: "default")
        #expect(store.logState == .loaded)
        #expect(store.activity.map(\.title) == ["Checked the porch"])
        #expect(store.identity == nil)
    }

    @Test func feedGroupsByPartOfDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        func at(_ day: Int, _ hour: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
        }
        let now = at(25, 21)
        #expect(BoardTimeBucket.title(for: at(25, 19), now: now, calendar: calendar) == "This evening")
        #expect(BoardTimeBucket.title(for: at(25, 8), now: now, calendar: calendar) == "This morning")
        #expect(BoardTimeBucket.title(for: at(25, 2), now: now, calendar: calendar) == "Tonight")
        #expect(BoardTimeBucket.title(for: at(24, 14), now: now, calendar: calendar) == "Yesterday afternoon")
    }

    @Test func islandAndAvatarShareOneActivityVocabulary() {
        for kind in AgentActivityKind.allCases {
            #expect(kind.pose.rawValue == kind.rawValue)
            #expect(kind.pose.symbolName == kind.systemImage)
            #expect(kind.pose.label == kind.label)
        }
        #expect(BighelpActivityPose(phase: .usingTool, tool: "coding") == .coding)
        #expect(BighelpActivityPose(phase: .usingTool, tool: "browser_navigate") == .web)
        #expect(BighelpActivityPose(phase: .usingTool, tool: nil) == .tools)
        #expect(BighelpActivityPose(phase: .responding, tool: "terminal") == .replying)
    }

    @Test func boardTextWaitsForTheNextNewChatOnly() {
        let state = AppState()
        state.pendingComposerText = "About my goal"
        #expect(state.consumeComposerText() == "About my goal")
        #expect(state.consumeComposerText() == nil)
        state.pendingComposerText = "Left over"
        state.resetForHostBoundary()
        #expect(state.pendingComposerText == nil)
    }
}

@MainActor
private final class FakeBoardClient: AgentBoardClient {
    var items: [AgentBoardItem]
    var failsUpdates = false
    var failsIdentity = false
    let supportsFeedback = true
    var supportsAnswers = false
    var acceptError: (any Error)?
    var onAccept: (() -> Void)?
    private(set) var accepted: [(agentID: String, itemID: String)] = []
    private(set) var updates: [(id: String, change: AgentBoardChange)] = []
    private(set) var markedRead: [String] = []

    init(items: [AgentBoardItem]) { self.items = items }

    func items(agentID: String) async throws -> [AgentBoardItem] { items }

    func update(agentID: String, itemID: String, change: AgentBoardChange) async throws -> AgentBoardItem {
        if failsUpdates { throw WorkspaceClientError.invalidRequest }
        updates.append((itemID, change))
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw WorkspaceClientError.invalidRequest }
        if let rating = change.rating { items[index].rating = rating; items[index].reason = change.reason ?? "" }
        if let read = change.read { items[index].read = read }
        if let dismissed = change.dismissed { items[index].dismissed = dismissed }
        if let status = change.status { items[index].status = status }
        return items[index]
    }

    func markRead(agentID: String, itemIDs: [String]) async throws { markedRead += itemIDs }

    func promote(agentID: String, itemID: String) async throws -> AgentBoardItem {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { throw WorkspaceClientError.invalidRequest }
        items[index].dismissed = true
        let goal = AgentBoardItem(id: "goal-" + itemID, kind: .goal, title: items[index].title, section: "goal",
                                  status: "active")
        items.append(goal)
        return goal
    }

    func accept(agentID: String, itemID: String) async throws {
        onAccept?()
        if let acceptError { throw acceptError }
        accepted.append((agentID, itemID))
    }

    func picture(agentID: String, itemID: String, index: Int) async throws -> Data { Data() }

    func activity(agentID: String) async throws -> [AgentActivityEntry] {
        [AgentActivityEntry(id: 1, sessionID: "s", title: "Checked the porch", request: "", summary: "",
                            kind: .seeing, outcome: "done", createdAt: .now)]
    }

    func approvals(agentID: String) async throws -> [AgentApprovalEntry] { [] }

    func identity(agentID: String) async throws -> AgentIdentityDocuments {
        if failsIdentity { throw WorkspaceClientError.unavailable(.unsupportedOperation) }
        return AgentIdentityDocuments(soul: .init(), memory: .init(), user: .init())
    }
}

@MainActor
private final class BoardPerformer: WorkspaceOperationPerforming {
    struct Call { let operation: WorkspaceOperation; let payload: [String: BighelpJSONValue] }
    var owner: WorkspaceOwner?
    var capabilities: WorkspaceCapabilities { .init(owner: owner) }
    var calls: [Call] = []

    init() throws {
        owner = .init(authority: try .fixture(id: "board-test"), authenticationGeneration: UUID(), connectionGeneration: UUID())
    }

    func perform(_ operation: WorkspaceOperation, payload: [String: BighelpJSONValue], owner: WorkspaceOwner) async throws
        -> [String: BighelpJSONValue] {
        calls.append(.init(operation: operation, payload: payload))
        if operation == .boardRead { return ["updated": .integer(1)] }
        return ["item": .object(["id": payload["itemId"] ?? .string("a"), "kind": .string("feed"), "title": .string("t")])]
    }
}
