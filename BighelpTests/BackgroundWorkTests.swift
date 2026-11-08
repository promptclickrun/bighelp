import Foundation
import Testing
@testable import Bighelp

/// What an agent runs in the background (#890): the chat's commands from Hermes' `process.list`,
/// each bot's background work from the plugin's `agents/activity`, and the Dashboard's Today list
/// from its `agents/today`.
@MainActor
struct BackgroundWorkTests {
    // MARK: The chat's commands

    /// Rows as Hermes' `tools/process_registry.py::list_sessions` writes them, plus `output_tail`.
    private static let processList: BighelpJSONValue = .object(["processes": .array([
        .object(["session_id": .string("proc_done"), "command": .string("./fetch.sh   kyoto"), "pid": .integer(41),
                 "started_at": .string("2026-11-07T16:30:00"), "uptime_seconds": .integer(900),
                 "status": .string("exited"), "output_preview": .string("Saved"), "exit_code": .integer(0),
                 "exited_at": .number(1_794_091_000.5), "completion_reason": .string("exited")]),
        .object(["session_id": .string("proc_dev"), "command": .string("npm run dev"), "pid": .integer(42),
                 "started_at": .string("2026-11-07T16:41:00"), "uptime_seconds": .integer(360),
                 "status": .string("running"), "output_preview": .string("ready"),
                 "output_tail": .string("VITE ready in 412 ms\nLocal: http://localhost:5173/")]),
        .object(["session_id": .string("proc_failed"), "command": .string("./test.sh"), "uptime_seconds": .integer(1_200),
                 "status": .string("exited"), "exit_code": .integer(1), "completion_reason": .string("exited")]),
        .object(["session_id": .string("proc_stopped"), "command": .string("tail -f log"), "uptime_seconds": .integer(60),
                 "status": .string("exited"), "exit_code": .integer(-15), "completion_reason": .string("killed")]),
        // A subagent's own command is its work, not the chat's. No ID or no command: left out, not the whole list.
        .object(["session_id": .string("proc_helper"), "command": .string("pytest"), "owner_task_id": .string("sa-3f2a"),
                 "uptime_seconds": .integer(30), "status": .string("running")]),
        .object(["command": .string("orphan")]),
        .object(["session_id": .string("proc_blank"), "command": .string("   ")]),
    ])])

    @Test func readsTheChatsCommandsRunningFirstWithTheirStartFromTheirUptime() throws {
        let now = Date(timeIntervalSince1970: 1_794_092_000)
        let commands = try #require(ChatBackgroundCommand.list(Self.processList, now: now))
        #expect(commands.map(\.id) == ["proc_dev", "proc_stopped", "proc_done", "proc_failed"])
        #expect(commands[0].isRunning && commands[0].startedAt == now.addingTimeInterval(-360))
        #expect(commands[0].output == "VITE ready in 412 ms\nLocal: http://localhost:5173/", "The tail, not the preview")
        #expect(commands[2].command == "./fetch.sh kyoto")
        #expect(commands.map(\.outcome) == ["Running", "Stopped", "Finished", "Failed · exit 1"])
        #expect(ChatBackgroundCommand.list(.object(["nope": .null])) == nil)
    }

    @Test func theChipCountsRunningCommandsBesideSubagents() {
        #expect(SessionStatusRailPresentation.items(goal: nil, subagents: [], runningCommands: 1, tasks: nil)
            .map(\.kind) == [.background])
        #expect(SessionStatusRailPresentation.items(goal: nil, subagents: [], runningCommands: 0, tasks: nil).isEmpty)
        #expect(ChatBackgroundSummary(subagents: 2, commands: 1).detail == "2 subagents · 1 command")
        #expect(ChatBackgroundSummary(subagents: 0, commands: 3).detail == "3 commands")
        #expect(ChatBackgroundSummary(subagents: 1, commands: 0).detail == "1 subagent")
    }

    @Test(.timeLimit(.minutes(1)))
    func aChatReadsAndStopsItsCommandsAndStopsAskingAHermesWithoutThem() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = ProcessRPC()
        let client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "host", profile: "default", runtimeID: "runtime", storedID: "stored",
            title: "Chat", epoch: "epoch", drafts: DirectHermesDraftStore(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model

        #expect(await model.refreshBackgroundCommands())
        #expect(model.backgroundCommands.map(\.id) == ["proc_dev", "proc_stopped", "proc_done", "proc_failed"])
        #expect(model.runningBackgroundCommands == 1)
        #expect(rpc.requests.last?.params["session_id"]?.string == "runtime", "Asked for this chat's live session")

        #expect(await model.stopBackgroundCommand("proc_dev"))
        #expect(rpc.requests.contains { $0.method == "process.kill" && $0.params["process_id"]?.string == "proc_dev" })
        #expect(model.runningBackgroundCommands == 0, "Read again after Stop")
        #expect(await model.stopBackgroundCommand("proc_dev") == false, "Already ended")

        rpc.supportsProcesses = false
        #expect(await model.refreshBackgroundCommands() == false)
        #expect(model.backgroundCommands.isEmpty)
        let asked = rpc.requests.count
        #expect(await model.refreshBackgroundCommands() == false)
        #expect(rpc.requests.count == asked, "Not asked again on this connection")
    }

    // MARK: Each bot's background work

    @Test func anIdleBotWithBackgroundWorkShowsItAndATurnWins() {
        let response: [String: BighelpJSONValue] = ["agents": .array([
            .object(["agentId": .string("nova"), "state": .string("idle"),
                     "background": .object(["count": .integer(3), "title": .string("Find a  battery\nback plate")])]),
            .object(["agentId": .string("pip"), "state": .string("working"), "tool": .string("web_search"),
                     "background": .object(["count": .integer(1)])]),
            .object(["agentId": .string("rio"), "state": .string("idle"), "background": .object(["count": .integer(0)])]),
            .object(["agentId": .string("sage"), "state": .string("idle"), "background": .string("lots")]),
        ])]
        let values = DirectHermesBotChatActivityClient.activities(from: response, asked: ["nova", "pip", "rio", "sage"])
        let work = BotBackgroundWork(count: 3, title: "Find a battery back plate")
        #expect(values == ["nova": .background(work), "pip": .working(tool: "web_search"), "rio": .idle, "sage": .idle])

        let one = BotChatActivity.background(BotBackgroundWork(count: 1, title: "npm run dev"))
        #expect(one.line == "In the background: npm run dev")
        #expect(BotChatActivity.background(work).line == "In the background: Find a battery back plate +2")
        #expect(BotChatActivity.background(BotBackgroundWork(count: 2)).line == "In the background · 2")
        #expect(one.isBusy && !one.isOnTurn, "Shown, but not read again as often as a turn")
        #expect(one.activityKind == .idle && one.liveState == .idle, "The face stays calm")
        #expect(SimpleBotFace.showsBadge(for: one, faceMoves: true), "Its stack shows even on a face that moves")
        #expect(BotChatActivity.merged(one, .working(tool: nil)) == .working(tool: nil))
        #expect(BotChatActivity.merged(.idle, one) == one)
        #expect(BotChatActivity.merged(one, .waiting) == .waiting)
    }

    @Test func otherGatewaysCopiesKeepBackgroundWork() throws {
        let work = BotChatActivity.background(BotBackgroundWork(count: 2, title: "Reconcile statements"))
        let decoded = try JSONDecoder().decode(FleetBotChat.self, from: JSONEncoder().encode(FleetBotChat(work)))
        #expect(decoded.activity == work)
        // A copy saved before this build: idle, nothing more.
        let older = try JSONDecoder().decode(FleetBotChat.self, from: Data(#"{"state":"idle"}"#.utf8))
        #expect(older.activity == .idle)
    }

    // MARK: Today on the Dashboard

    @Test func readsTodaysWorkRunningFirstThenNewestLeniently() {
        let rows: [BighelpJSONValue] = [
            .object(["id": .string("cron:brief"), "kind": .string("scheduled"), "title": .string("Morning brief"),
                     "state": .string("done"), "startedAt": .number(1_794_038_400), "endedAt": .number(1_794_038_460)]),
            .object(["id": .string("delegation:a"), "kind": .string("subagent"),
                     "title": .string("Find a battery back plate\nthat fits the puck"), "state": .string("running"),
                     "startedAt": .number(1_794_091_440.2), "sessionId": .string("20261107_164100_ab12cd")]),
            .object(["id": .string("message:9"), "kind": .string("command"), "title": .string("./test.sh"),
                     "state": .string("failed"), "endedAt": .integer(1_794_082_200), "detail": .string("Exit 1")]),
            .object(["id": .string("delegation:b"), "kind": .string("subagent"), "title": .string("Old plan"),
                     "state": .string("vanished"), "startedAt": .number(-5)]),
            // A kind this build doesn't know, no title, and the same ID twice: left out.
            .object(["id": .string("x"), "kind": .string("meeting"), "title": .string("Standup"), "state": .string("done")]),
            .object(["id": .string("y"), "kind": .string("command"), "state": .string("done")]),
            .object(["id": .string("message:9"), "kind": .string("command"), "title": .string("dup"), "state": .string("done")]),
        ]
        let items = AgentTodayItem.list(rows)
        #expect(items.map(\.id) == ["delegation:a", "message:9", "cron:brief", "delegation:b"])
        #expect(items[0].title == "Find a battery back plate", "One line")
        #expect(items[1].detail == "Exit 1" && items[1].state == .failed)
        #expect(items[3].state == .unknown && items[3].startedAt == nil, "Unknown is never done; a bad time shows none")
        #expect(AgentTodayItem.list([.object(["id": .string("long"), "kind": .string("command"), "state": .string("done"),
                                              "title": .string(String(repeating: "a", count: 300))])])
            .first?.title.count == AgentTodayItem.maximumTitleLength)
    }

    @Test(.timeLimit(.minutes(1)))
    func todayAsksFromTheStartOfThePhonesDayAndKeepsWhatItShowedThroughAFailure() async {
        let client = TodayClient()
        let today = AgentTodayModel()
        #expect(AgentTodayModel.summary(today.phase) == "Loading…")
        #expect(!today.isExpanded, "Closed until the person opens it")
        today.use(client, scope: "home-mac")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let now = Date(timeIntervalSince1970: 1_794_092_000)
        await today.refresh(agentID: "nova", now: now, calendar: calendar)
        #expect(client.asked == [calendar.startOfDay(for: now)])
        #expect(today.items.map(\.id) == ["delegation:a", "cron:brief"])
        #expect(today.hasRunning)
        #expect(AgentTodayModel.summary(today.phase) == "1 running · 1 finished")

        client.fails = true
        await today.refresh(agentID: "nova", now: now, calendar: calendar)
        #expect(today.items.count == 2, "A passing failure keeps the list")

        let older = TodayClient()
        older.supportsToday = false
        let other = AgentTodayModel()
        other.use(older, scope: "home-mac")
        #expect(other.phase == .unsupported)
        #expect(AgentTodayModel.summary(other.phase) == "Update the plugin to see it")
        #expect(AgentTodayModel.summary(.loaded([])) == "Nothing in the background yet")
    }
}

/// Answers `process.list` and `process.kill` the way Hermes' gateway does, or, for an older
/// Hermes, says it has no such method.
@MainActor
private final class ProcessRPC: DirectHermesRPC {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var supportsProcesses = true
    private var stopped: Set<String> = []
    private(set) var requests: [(method: String, params: [String: BighelpJSONValue])] = []

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        requests.append((method, params))
        switch method {
        case "session.control.read":
            return .object(["control": .object(["goal": .null, "loop": .null, "heartbeat": .null,
                                                "revision": .string("r"), "updated_at": .integer(0)])])
        case "process.list", "process.kill":
            guard supportsProcesses else { throw DirectHermesError.rpcRejected(code: -32601) }
            guard params["session_id"]?.string == "runtime" else { throw DirectHermesError.rpcRejected(code: 4001) }
            if method == "process.kill" {
                let id = params["process_id"]?.string ?? ""
                guard id == "proc_dev" else { return .object(["status": .string("not_found")]) }
                return .object(["status": .string(stopped.insert(id).inserted ? "killed" : "already_exited")])
            }
            guard var rows = BackgroundWorkTestsRows.processList.object?["processes"]?.array else { return .null }
            if stopped.contains("proc_dev"), let index = rows.firstIndex(where: { $0.object?["session_id"]?.string == "proc_dev" }),
               var row = rows[index].object {
                row["status"] = .string("exited")
                row["completion_reason"] = .string("killed")
                rows[index] = .object(row)
            }
            return .object(["processes": .array(rows)])
        default:
            throw DirectHermesError.notConnected
        }
    }

    func disconnect() async {}
}

/// The same rows the parsing test reads, for the fake host.
private enum BackgroundWorkTestsRows {
    static let processList: BighelpJSONValue = .object(["processes": .array([
        .object(["session_id": .string("proc_done"), "command": .string("./fetch.sh kyoto"), "uptime_seconds": .integer(900),
                 "status": .string("exited"), "exit_code": .integer(0), "completion_reason": .string("exited")]),
        .object(["session_id": .string("proc_dev"), "command": .string("npm run dev"), "uptime_seconds": .integer(360),
                 "status": .string("running")]),
        .object(["session_id": .string("proc_failed"), "command": .string("./test.sh"), "uptime_seconds": .integer(1_200),
                 "status": .string("exited"), "exit_code": .integer(1), "completion_reason": .string("exited")]),
        .object(["session_id": .string("proc_stopped"), "command": .string("tail -f log"), "uptime_seconds": .integer(60),
                 "status": .string("exited"), "exit_code": .integer(-15), "completion_reason": .string("killed")]),
    ])])
}

/// A board client that only answers Today.
@MainActor
private final class TodayClient: AgentBoardClient {
    let supportsFeedback = false
    var supportsToday = true
    var fails = false
    private(set) var asked: [Date] = []

    func today(agentID: String, since: Date) async throws -> [AgentTodayItem] {
        asked.append(since)
        if fails { throw WorkspaceClientError.transportUnavailable }
        return AgentTodayItem.list([
            .object(["id": .string("cron:brief"), "kind": .string("scheduled"), "title": .string("Morning brief"),
                     "state": .string("done"), "endedAt": .number(1_794_038_460)]),
            .object(["id": .string("delegation:a"), "kind": .string("subagent"), "title": .string("Find a back plate"),
                     "state": .string("running"), "startedAt": .number(1_794_091_440)]),
        ])
    }

    func items(agentID: String) async throws -> [AgentBoardItem] { [] }
    func update(agentID: String, itemID: String, change: AgentBoardChange) async throws -> AgentBoardItem {
        throw WorkspaceClientError.invalidRequest
    }
    func markRead(agentID: String, itemIDs: [String]) async throws {}
    func promote(agentID: String, itemID: String) async throws -> AgentBoardItem { throw WorkspaceClientError.invalidRequest }
    func picture(agentID: String, itemID: String, index: Int) async throws -> Data { Data() }
    func activity(agentID: String) async throws -> [AgentActivityEntry] { [] }
    func approvals(agentID: String) async throws -> [AgentApprovalEntry] { [] }
    func identity(agentID: String) async throws -> AgentIdentityDocuments {
        AgentIdentityDocuments(soul: .init(json: nil), memory: .init(json: nil), user: .init(json: nil))
    }
}
