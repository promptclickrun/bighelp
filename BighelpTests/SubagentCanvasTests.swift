import Foundation
import Testing
@testable import Bighelp

/// A helper's canvas is built only from what Hermes reported: the parent
/// chat's `subagent.*` events and the child's saved session.
@MainActor
struct SubagentCanvasTests {
    private typealias Payload = [String: BighelpJSONValue]

    private static func event(_ fields: Payload = [:], tools: Int? = nil) -> Payload {
        var payload: Payload = [
            "subagent_id": .string("sa-1"), "child_session_id": .string("child-1"),
            "goal": .string("Compare three ryokans near Kyoto station"), "task_count": .integer(1),
            "task_index": .integer(0),
        ]
        if let tools { payload["tool_count"] = .integer(tools) }
        return payload.merging(fields) { $1 }
    }

    private static func liveLedger() -> SubagentCanvasLedger {
        var ledger = SubagentCanvasLedger()
        ledger.accept(type: "subagent.spawn_requested", payload: event())
        ledger.accept(type: "subagent.start", payload: event(tools: 0))
        ledger.accept(type: "subagent.tool", payload: event([
            "tool_name": .string("read_file"), "tool_preview": .string("notes/ryokans.md"),
            "text": .string("notes/ryokans.md"),
        ], tools: 1))
        ledger.accept(type: "subagent.thinking", payload: event(["text": .string("Two are booked out.")], tools: 1))
        ledger.accept(type: "subagent.tool", payload: event([
            "tool_name": .string("web_search"), "tool_preview": .string("ryokan kyoto station"),
        ], tools: 2))
        return ledger
    }

    // MARK: Live updates

    @Test func liveEventsBecomeStepsInTheOrderTheyHappened() throws {
        var ledger = SubagentCanvasLedger()
        ledger.accept(type: "subagent.spawn_requested", payload: Self.event())
        #expect(ledger["sa-1"]?.phase == .waiting)

        ledger = Self.liveLedger()
        let state = try #require(ledger["sa-1"])
        #expect(state.phase == .working)
        #expect(state.goal == "Compare three ryokans near Kyoto station")
        #expect(state.childSessionID == "child-1")
        #expect(state.toolCount == 2)

        let events = state.transcript().events
        #expect(events.map(\.kind) == [.tool, .reasoning, .tool])
        #expect(events.map(\.toolName) == ["read_file", nil, "web_search"])
        // The first call ended (the stream doesn't say how); the newest is running.
        #expect(events.map(\.lifecycle) == [.recorded, .recorded, .running])
        #expect(events[0].summary == "notes/ryokans.md")
        #expect(events[1].reasoningText == "Two are booked out.")
        // The stream carries no arguments, so the words stay general and true.
        #expect(events[0].arguments == nil)
        #expect(state.currentActivity == ChatToolPhrase.phrase(forTool: "web_search", arguments: nil).live)
        // All steps sit in one folder of the helper's work.
        #expect(Set(events.map(\.turnID)).count == 1)
    }

    @Test func aThinkingStepAfterACallMeansTheCallEnded() throws {
        var ledger = SubagentCanvasLedger()
        ledger.accept(type: "subagent.tool", payload: Self.event(["tool_name": .string("terminal")], tools: 1))
        ledger.accept(type: "subagent.thinking", payload: Self.event(["text": .string("Tests pass.")], tools: 1))
        let state = try #require(ledger["sa-1"])
        #expect(state.transcript().events.map(\.lifecycle) == [.recorded, .recorded])
        #expect(state.currentActivity == BighelpToolActivityCatalog.thinking.label)
    }

    @Test func replayedEventsDoNotRepeatSteps() throws {
        var ledger = Self.liveLedger()
        ledger.accept(type: "subagent.tool", payload: Self.event(["tool_name": .string("web_search")], tools: 2))
        ledger.accept(type: "subagent.thinking", payload: Self.event(["text": .string("Two are booked out.")], tools: 1))
        #expect(ledger["sa-1"]?.liveSteps.count == 3)
    }

    @Test func streamedReplyTextGrowsAsItArrives() throws {
        var ledger = Self.liveLedger()
        ledger.accept(type: "subagent.text", payload: ["subagent_id": .string("sa-1"), "text": .string("Hotel ")])
        ledger.accept(type: "subagent.text", payload: ["subagent_id": .string("sa-1"), "text": .string("Kanra wins")])
        let items = try #require(ledger["sa-1"]).transcript().items
        #expect(items.count == 1)
        guard case .message(let text)? = items.first?.content else { Issue.record("No live reply"); return }
        #expect(text == "Hotel Kanra wins")
    }

    // MARK: Completion and failure

    @Test func completionKeepsTheFinalStateAndResult() throws {
        var ledger = Self.liveLedger()
        ledger.accept(type: "subagent.complete", payload: Self.event([
            "status": .string("completed"), "summary": .string("Hotel Kanra is the best fit."),
            "duration_seconds": .number(72.4), "files_written": .array([.string("notes/pick.md")]),
        ], tools: 2))
        let state = try #require(ledger["sa-1"])
        #expect(state.phase == .done)
        #expect(state.lifecycle == .succeeded)
        #expect(state.durationSeconds == 72.4)
        #expect(state.filesWritten == ["notes/pick.md"])
        #expect(state.resultText == "Hotel Kanra is the best fit.")
        #expect(state.currentActivity == nil)
        // Nothing runs once Hermes says it finished.
        #expect(!state.transcript().events.contains { $0.lifecycle == .running })

        // A late step after the end never reopens it.
        ledger.accept(type: "subagent.tool", payload: Self.event(["tool_name": .string("terminal")], tools: 3))
        #expect(ledger["sa-1"]?.phase == .done)
        #expect(ledger["sa-1"]?.liveSteps.count == 3)
    }

    @Test func failuresAndStopsAreReportedAsHermesSaidThem() throws {
        func finished(_ status: BighelpJSONValue?) -> SubagentCanvasState? {
            var ledger = SubagentCanvasLedger()
            var payload = Self.event(["summary": .string("Gave up after the timeout")])
            payload["status"] = status
            if status == .string("timeout") { payload["failure_reason"] = .string("Took too long") }
            ledger.accept(type: "subagent.complete", payload: payload)
            return ledger["sa-1"]
        }
        #expect(finished(.string("timeout"))?.phase == .failed)
        #expect(finished(.string("timeout"))?.failureReason == "Took too long")
        #expect(finished(.string("error"))?.phase == .failed)
        #expect(finished(.string("interrupted"))?.phase == .stopped)
        // No reported outcome is not a success.
        #expect(finished(nil)?.phase == .finished)
        #expect(finished(.string("something-new"))?.phase == .finished)
    }

    // MARK: Unknown and malformed input

    @Test func unknownEventsAndFieldsOnlyRefreshTheHelpersIdentity() throws {
        var ledger = SubagentCanvasLedger()
        ledger.accept(type: "subagent.heartbeat", payload: Self.event([
            "model": .string("fast-model"), "brand_new_field": .object(["x": .integer(1)]),
            "tool_count": .string("not a number"),
        ]))
        let state = try #require(ledger["sa-1"])
        #expect(state.liveSteps.isEmpty)
        #expect(state.model == "fast-model")
        #expect(state.phase == .waiting)

        // Reasoning hidden on the host: the frame comes without its text.
        ledger.accept(type: "subagent.thinking", payload: Self.event())
        #expect(ledger["sa-1"]?.liveSteps.isEmpty == true)

        // An event naming no helper is dropped, never given a made-up identity.
        var empty = SubagentCanvasLedger()
        empty.accept(type: "subagent.tool", payload: ["tool_name": .string("terminal")])
        empty.accept(type: "tool.start", payload: Self.event())
        #expect(empty.isEmpty)
    }

    @Test func olderHostsAreKnownByTheirChildSession() {
        var ledger = SubagentCanvasLedger()
        ledger.accept(type: "subagent.start", payload: ["child_session_id": .string("child-9"),
                                                        "goal": .string("Read the logs")])
        #expect(ledger["child-9"]?.goal == "Read the logs")
        #expect(ledger["child-9"]?.childSessionID == "child-9")
    }

    @Test func theLedgerStaysBoundedAndKeepsRunningHelpers() {
        var ledger = SubagentCanvasLedger()
        ledger.accept(type: "subagent.start", payload: ["subagent_id": .string("running")])
        for index in 0..<(SubagentCanvasLedger.capacity + 5) {
            ledger.accept(type: "subagent.complete", payload: ["subagent_id": .string("done-\(index)"),
                                                               "status": .string("completed")])
        }
        #expect(ledger.ordered.count == SubagentCanvasLedger.capacity)
        #expect(ledger["running"] != nil)
        #expect(ledger["done-0"] == nil)
        #expect(ledger.ordered.last?.id == "done-\(SubagentCanvasLedger.capacity + 4)")
    }

    // MARK: Saved record

    private static func savedRows(finished: Bool, secondResult: Bool = true) throws -> [DirectHermesHistoryRow] {
        func row(_ id: Int, _ role: String, _ content: BighelpJSONValue, extra: Payload = [:]) -> BighelpJSONValue {
            var value: Payload = [
                "id": .integer(id), "session_id": .string("child-1"), "role": .string(role), "content": content,
                "timestamp": .number(Double(1_000 + id)), "tool_calls": .null, "tool_call_id": .null,
                "tool_name": .null,
            ]
            value.merge(extra) { $1 }
            return .object(value)
        }
        func call(_ id: String, _ name: String, _ arguments: String) -> BighelpJSONValue {
            .array([.object(["id": .string(id), "type": .string("function"),
                             "function": .object(["name": .string(name), "arguments": .string(arguments)])])])
        }
        var values = [
            row(1, "user", .string("Compare three ryokans near Kyoto station. Context: two adults, May.")),
            row(2, "assistant", .string("Reading the notes first."),
                extra: ["tool_calls": call("c1", "read_file", #"{"path":"notes/ryokans.md"}"#)]),
            row(3, "tool", .string("Kanra, Sakura, Yuzuya"),
                extra: ["tool_call_id": .string("c1"), "tool_name": .string("read_file")]),
            row(4, "assistant", .null, extra: ["tool_calls": call("c2", "web_search", #"{"query":"ryokan kyoto"}"#)]),
        ]
        if secondResult {
            values.append(row(5, "tool", .string("3 results"),
                              extra: ["tool_call_id": .string("c2"), "tool_name": .string("web_search")]))
        }
        if finished { values.append(row(6, "assistant", .string("Hotel Kanra is the best fit."))) }
        return try values.map { try DirectHermesHistoryRow($0, sessionID: "child-1") }
    }

    @Test func theSavedRecordFillsInAndNewerLiveStepsFollowIt() throws {
        var ledger = Self.liveLedger()
        ledger.accept(type: "subagent.tool", payload: Self.event(["tool_name": .string("terminal")], tools: 3))
        let history = try SubagentCanvasHistory(childSessionID: "child-1", subagentID: "sa-1", profile: "kai",
                                                rows: Self.savedRows(finished: false))
        #expect(history.toolCallCount == 2)
        #expect(history.task?.hasPrefix("Compare three ryokans") == true)
        let adopted1 = ledger.adoptHistory(history, for: "sa-1", readAfterFinish: false)
        #expect(adopted1)

        let state = try #require(ledger["sa-1"])
        let (items, events) = state.transcript()
        // The task is the header, not a bubble; the helper's own words stay.
        #expect(items.map(\.role) == [.assistant])
        let tools = events.filter { $0.kind == .tool }
        #expect(tools.map(\.toolName) == ["read_file", "web_search", "terminal"])
        // Saved calls carry their real arguments and results, so they read in plain words.
        #expect(tools[0].arguments == #"{"path":"notes/ryokans.md"}"#)
        #expect(tools[0].result == "Kanra, Sakura, Yuzuya")
        #expect(tools[0].toolPhrase.past == "Read ryokans.md")
        // Only the live call newer than the record is added, and it is the one running.
        #expect(tools.map(\.lifecycle) == [.recorded, .recorded, .running])
        // The older live thinking is already in the record's time; it isn't repeated.
        #expect(!events.contains { $0.reasoningText == "Two are booked out." })
    }

    @Test func theHelpersWordsComeBeforeTheCallsTheyMade() throws {
        let history = try SubagentCanvasHistory(childSessionID: "child-1", subagentID: "sa-1", profile: "kai",
                                                rows: Self.savedRows(finished: false))
        let entries = ChatTranscriptProjection.entries(
            items: history.items, activityEvents: history.events,
            visibility: .init(showReasoning: true, showToolCalls: true), isBotMode: false)
        // "Reading the notes first." was said, then read_file was called.
        guard case .message(let first)? = entries.first, case .activity(let work)? = entries.dropFirst().first else {
            Issue.record("Expected the helper's words before its first call: \(entries.map(\.id))"); return
        }
        #expect(first.role == .assistant)
        #expect(work.events.first?.toolName == "read_file")
    }

    @Test func aSavedCallWithoutItsResultIsTheOneRunning() throws {
        var ledger = Self.liveLedger()
        let history = try SubagentCanvasHistory(childSessionID: "child-1", subagentID: "sa-1", profile: "kai",
                                                rows: Self.savedRows(finished: false, secondResult: false))
        ledger.adoptHistory(history, for: "sa-1", readAfterFinish: false)
        let tools = try #require(ledger["sa-1"]).transcript().events.filter { $0.kind == .tool }
        #expect(tools.map(\.lifecycle) == [.recorded, .running])
        #expect(tools.last?.arguments == #"{"query":"ryokan kyoto"}"#)
    }

    @Test func aRecordReadAfterTheEndIsTheWholeStory() throws {
        var ledger = Self.liveLedger()
        ledger.accept(type: "subagent.complete", payload: Self.event([
            "status": .string("completed"), "summary": .string("Hotel Kanra is the best fit."),
        ], tools: 2))
        let history = try SubagentCanvasHistory(childSessionID: "child-1", subagentID: "sa-1", profile: "kai",
                                                rows: Self.savedRows(finished: true))
        let adopted2 = ledger.adoptHistory(history, for: "sa-1", readAfterFinish: true)
        #expect(adopted2)
        let state = try #require(ledger["sa-1"])
        #expect(state.historyIsFinal)
        let (items, events) = state.transcript()
        #expect(events.filter { $0.kind == .tool }.count == 2)
        #expect(!events.contains { $0.eventID.contains(":live:") })
        // The record ends with the reply, so the result isn't shown twice.
        guard case .message(let last)? = items.last?.content else { Issue.record("No reply"); return }
        #expect(last == "Hotel Kanra is the best fit.")
        #expect(state.resultText == nil)
        #expect(state.stepSummary != nil)
    }

    @Test func anOlderOrForeignRecordNeverReplacesTheCurrentOne() throws {
        var ledger = Self.liveLedger()
        let full = try SubagentCanvasHistory(childSessionID: "child-1", subagentID: "sa-1", profile: "kai",
                                             rows: Self.savedRows(finished: false))
        let older = try SubagentCanvasHistory(childSessionID: "child-1", subagentID: "sa-1", profile: "kai",
                                              rows: Array(Self.savedRows(finished: false).prefix(2)))
        let adopted3 = ledger.adoptHistory(full, for: "sa-1", readAfterFinish: false)
        #expect(adopted3)
        let adopted4 = ledger.adoptHistory(older, for: "sa-1", readAfterFinish: false)
        #expect(!adopted4)
        #expect(ledger["sa-1"]?.history?.toolCallCount == 2)

        let foreign = SubagentCanvasHistory(childSessionID: "someone-else", items: [], events: [], toolCallCount: 9,
                                            task: nil)
        let adopted5 = ledger.adoptHistory(foreign, for: "sa-1", readAfterFinish: false)
        #expect(!adopted5)
        let adopted6 = ledger.adoptHistory(full, for: "unknown", readAfterFinish: false)
        #expect(!adopted6)
    }

    // MARK: Through the chat

    private func nativeChat(rpc: SubagentCanvasRPC, root: URL) throws
        -> (DirectHermesConversationClient, ChatModel) {
        let client = try DirectHermesConversationClient(
            rpc: rpc, hostIdentity: "host-a", profile: "kai", runtimeID: "runtime", storedID: "stored",
            title: "Trip", epoch: "epoch", drafts: DirectHermesDraftStore(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        return (client, model)
    }

    @Test func theChatKeepsAFinishedHelpersCanvasAfterTheRailLetsGo() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (client, model) = try nativeChat(rpc: SubagentCanvasRPC(), root: root)
        client.receive(.init(type: "subagent.start", sessionID: "runtime", payload: Self.event(), sequence: 1))
        client.receive(.init(type: "subagent.tool", sessionID: "runtime",
                             payload: Self.event(["tool_name": .string("read_file")], tools: 1), sequence: 2))
        #expect(model.nativeSubagents.map(\.id) == ["sa-1"])
        #expect(model.subagentCanvases["sa-1"]?.liveSteps.count == 1)

        client.receive(.init(type: "subagent.complete", sessionID: "runtime",
                             payload: Self.event(["status": .string("completed")], tools: 1), sequence: 3))
        #expect(model.nativeSubagents.isEmpty)
        #expect(model.subagentCanvases["sa-1"]?.phase == .done)

        // Another session's events never reach this chat's canvases.
        client.receive(.init(type: "subagent.start", sessionID: "other-runtime",
                             payload: ["subagent_id": .string("sa-other")], sequence: 4))
        #expect(model.subagentCanvases["sa-other"] == nil)
    }

    @Test func aGroupChatKeepsItsMembersWorkPrivate() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try DirectHermesConversationClient(
            rpc: SubagentCanvasRPC(), hostIdentity: "host-a", profile: "kai", runtimeID: "runtime",
            storedID: "stored", title: "Group", epoch: "epoch", drafts: DirectHermesDraftStore(root: root))
        let room = BotModeRoom.fixture(id: "room", memberIDs: ["kai", "ren"])
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [],
                              botModeRoomStore: BotModeRoomStore(client: BotModeFixtureClient(), rooms: [room]),
                              botModeRoomID: room.id)
        client.model = model
        #expect(model.isBotMode)
        client.receive(.init(type: "subagent.start", sessionID: "runtime", payload: Self.event(), sequence: 1))
        #expect(model.subagentCanvases.isEmpty)
        #expect(await model.refreshSubagentHistory(id: "sa-1") == .skipped)
    }

    @Test func theSavedRecordIsReadFromThisChatsOwnHost() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = SubagentCanvasRPC()
        rpc.messages = try Self.savedRowValues()
        let (client, model) = try nativeChat(rpc: rpc, root: root)
        client.receive(.init(type: "subagent.start", sessionID: "runtime", payload: Self.event(), sequence: 1))

        #expect(await model.refreshSubagentHistory(id: "sa-1") == .adopted)
        let request = try #require(rpc.httpRequests.last)
        #expect(request.path == "/api/sessions/child-1/messages")
        #expect(request.method == .get)
        #expect(request.query.contains(.init(name: "profile", value: "kai")))
        #expect(request.query.contains(.init(name: "order", value: "latest")))
        #expect(model.subagentCanvases["sa-1"]?.history?.toolCallCount == 2)

        // A helper with no child session yet has nothing to read.
        client.receive(.init(type: "subagent.spawn_requested", sessionID: "runtime",
                             payload: ["subagent_id": .string("sa-2"), "goal": .string("Later")], sequence: 2))
        #expect(await model.refreshSubagentHistory(id: "sa-2") == .skipped)
    }

    @Test func aRecordThatArrivesAfterTheConnectionChangedIsDropped() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = SubagentCanvasRPC()
        rpc.messages = try Self.savedRowValues()
        let (client, model) = try nativeChat(rpc: rpc, root: root)
        client.receive(.init(type: "subagent.start", sessionID: "runtime", payload: Self.event(), sequence: 1))
        // The chat reconnects (or switches hosts) while the read is in flight.
        rpc.beforeAnswer = { client.generation = UUID() }
        #expect(await model.refreshSubagentHistory(id: "sa-1") == .unavailable)
        #expect(model.subagentCanvases["sa-1"]?.history == nil)
    }

    @Test func aChildThatHasntSavedYetKeepsItsLiveSteps() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let rpc = SubagentCanvasRPC()
        let (client, model) = try nativeChat(rpc: rpc, root: root)
        client.receive(.init(type: "subagent.tool", sessionID: "runtime",
                             payload: Self.event(["tool_name": .string("read_file")], tools: 1), sequence: 1))
        #expect(await model.refreshSubagentHistory(id: "sa-1") == .unavailable)
        #expect(model.subagentCanvases["sa-1"]?.liveSteps.count == 1)
    }

    private static func savedRowValues() throws -> [BighelpJSONValue] {
        try savedRows(finished: false).map { .object($0.raw) }
    }
}

@MainActor
private final class SubagentCanvasRPC: DirectHermesRPC, DirectHermesAuthenticatedHTTP {
    var onEvent: ((DirectHermesEvent) -> Void)?
    var messages: [BighelpJSONValue]?
    var httpRequests: [DirectHermesHTTPRequest] = []
    var beforeAnswer: (@MainActor () -> Void)?

    func request(_ method: String, params: [String: BighelpJSONValue]) async throws -> BighelpJSONValue {
        if method == "session.control.read" {
            return .object(["control": .object(["goal": .null, "loop": .null, "heartbeat": .null,
                                                "revision": .string("fixture"), "updated_at": .integer(0)])])
        }
        if method == "subagent.list" { return .object(["subagents": .array([])]) }
        throw DirectHermesError.notConnected
    }

    func request(_ request: DirectHermesHTTPRequest) async throws -> BighelpJSONValue {
        httpRequests.append(request)
        beforeAnswer?()
        // Hermes answers 404 until the child saves its first step.
        guard let messages else { throw DirectHermesError.invalidResponse }
        return .object(["session_id": .string("child-1"), "profile": .string("kai"), "messages": .array(messages),
                        "pagination": .object(["limit": .integer(100), "offset": .integer(0),
                                               "order": .string("latest"), "returned": .integer(messages.count)])])
    }

    func disconnect() async {}
}
