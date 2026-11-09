import Foundation
import Testing
@testable import Bighelp

/// Hermes 0.23's `message_agent`: the message goes to the other agent's gateway, a background waiter gives up
/// after about half an hour, and the agent asked keeps a receipt (`AgentDelivery`). The rail follows the
/// receipt; a waiter that gave up answers nothing.
@MainActor
struct AgentTalkDeliveryTests {
    static let delivery = String(repeating: "a1", count: 32)

    @Test func messageAgentResultKeepsItsDeliveryID() throws {
        let reply = try #require(call().agentTalkReply)
        #expect(reply.outcome == .queued)
        #expect(reply.deliveryID == Self.delivery)
        #expect(reply.processID == "proc_71d64c3f48e5")
    }

    @Test func aWaiterThatGaveUpIsNoAnswerAndStaysOutOfTheChat() throws {
        let gaveUp = try #require(AgentTalkDelivery.parse(notice(waiter: [
            "outcome": "@ralph never answered within the wait: its turn is still running.",
            "status": "queued", "delivery_id": Self.delivery, "target_state": "working"])))
        #expect(gaveUp.isStillOut)
        #expect(gaveUp.reply == nil, "Hermes' own words about the wait are never the agent's answer")
        #expect(gaveUp.deliveryID == Self.delivery)

        let answered = try #require(AgentTalkDelivery.parse(notice(waiter: [
            "outcome": "@ralph answered.", "reply": "Repo: example/print-autocrop", "status": "settled",
            "delivery_id": Self.delivery])))
        #expect(!answered.isStillOut)
        #expect(answered.succeeded)
        #expect(answered.reply == "Repo: example/print-autocrop")

        let failed = try #require(AgentTalkDelivery.parse(notice(waiter: [
            "reason": "runtime_unavailable", "delivery_id": Self.delivery,
            "error": "The message was NOT sent; it is safe to resend."], exitCode: 1)))
        #expect(!failed.succeeded && !failed.isStillOut && failed.reply == nil)
    }

    @Test func theRailWaitsThroughAGaveUpWaiterAndTakesTheAnswerTheAgentKept() throws {
        let call = call()
        let waiter = message(notice(waiter: ["outcome": "@ralph never answered within the wait.",
                                             "status": "queued", "delivery_id": Self.delivery]), human: true, order: 4)
        let rows = rows(items: [message("Ask Ralph", human: true, order: 1), message("I asked Ralph.", order: 3), waiter],
                        events: [call])
        #expect(!rows.contains { row in
            if case .transcript(.entry(.message(let item))) = row { item.id == waiter.id } else { false }
        }, "The waiter's notice never shows")
        let talk = try #require(rows.compactMap { row -> ChatAgentTalk? in
            if case .agentTalk(let talk) = row { talk } else { nil }
        }.first)
        #expect(talk.messages(chatAgentID: "default").last?.state == .waiting)

        let live = ChatAgentTalkLive()
        live.update(deliveries: [delivery(.working, tool: "terminal")], calls: [call])
        #expect(label(talk, live).hasPrefix("Ralph is "), "Ralph working, on the tool he runs")
        #expect(talk.messages(chatAgentID: "default", live: live.activities).last?.state == .working)

        live.update(deliveries: [delivery(.answered, reply: "Repo: example/print-autocrop")], calls: [call])
        #expect(label(talk, live) == "Ralph answered")
        #expect(talk.messages(chatAgentID: "default", live: live.activities).last?.state
            == .said("Repo: example/print-autocrop"))
        #expect(live.pendingDeliveries(in: [call]).isEmpty, "An answered message isn't read again")
    }

    @Test func eachMessageIsAskedAboutUntilItEndsOrTheHostHasNoReceipt() {
        let call = call()
        let live = ChatAgentTalkLive()
        let query = AgentDeliveryQuery(agentID: "ralph", deliveryID: Self.delivery)
        #expect(live.pendingDeliveries(in: [call]) == [query])
        live.update(deliveries: [delivery(.queued)], calls: [call], asked: [query])
        #expect(live.pendingDeliveries(in: [call]) == [query])
        #expect(label(ChatAgentTalk(.call(call, answer: nil)), live) == "Waiting for Ralph")

        let elsewhere = ChatAgentTalkLive()
        elsewhere.update(deliveries: [], calls: [call], asked: [query])
        #expect(elsewhere.pendingDeliveries(in: [call]).isEmpty, "No receipt here: asking again won't change that")
    }

    @Test func deliveriesAndFramesAreReadLeniently() {
        let read = DirectHermesAgentTalkReader.deliveries(from: ["deliveries": .array([
            .object(["agentId": .string("ralph"), "deliveryId": .string(Self.delivery), "state": .string("working"),
                     "tool": .string("terminal"), "sessionId": .string("local-f679"), "updatedAt": .number(1),
                     "extra": .boolean(true)]),
            .object(["agentId": .string("ralph"), "deliveryId": .string("short"), "state": .string("working")]),
            .object(["agentId": .string("ralph"), "deliveryId": .string(Self.delivery), "state": .string("later")]),
        ])])
        #expect(read == [AgentDelivery(agentID: "ralph", deliveryID: Self.delivery, state: .working,
                                       sessionID: "local-f679", toolName: "terminal", reply: nil)])

        let frames = DirectHermesAgentTalkReader.frames(from: [
            "attached": .boolean(true), "running": .boolean(true), "epoch": .string("e1"), "last": .integer(12),
            "reset": .boolean(false), "events": .array([
                .object(["seq": .integer(11), "type": .string("tool.start"),
                         "payload": .object(["name": .string("terminal")])]),
                .object(["type": .string("no number")]),
            ])])
        #expect(frames?.frames.map(\.sequence) == [11])
        #expect(frames?.isRunning == true && frames?.last == 12 && frames?.epoch == "e1")
        #expect(DirectHermesAgentTalkReader.frames(from: ["events": .array([])]) == nil, "No `attached`: unreadable")
    }

    @Test func theOpenRailFoldsTheAgentsFramesIntoStepsAndSkipsSpinners() {
        let feed = AgentTalkRunFeed()
        feed.fold([
            frame(1, "message.start"),
            frame(2, "tool.start", ["tool_id": .string("t1"), "name": .string("read_file"),
                                    "args": .object(["path": .string("app_mode.py")])]),
            frame(3, "tool.complete", ["tool_id": .string("t1"), "name": .string("read_file")]),
            frame(4, "thinking.delta", ["text": .string("(🔥) setting wing angle...")]),
            frame(5, "reasoning.delta", ["text": .string("The archive needs the hardened runtime")]),
            frame(6, "tool.start", ["tool_id": .string("t2"), "name": .string("terminal")]),
        ])
        #expect(feed.isRunning)
        #expect(feed.steps.map(\.isDone) == [true, false])
        #expect(feed.steps.first?.phrase.past == ChatToolPhrase.phrase(forTool: "read_file",
                                                                       arguments: #"{"path":"app_mode.py"}"#).past)
        #expect(feed.thinking == nil, "A new step starts the thinking line over")
        feed.fold([frame(7, "reasoning.delta", ["text": .string("Signing it next.")]),
                   frame(8, "thinking.delta", ["text": .string("(¬‿¬) musing...")])])
        #expect(feed.thinking == "Signing it next.")
        feed.fold([frame(9, "message.complete", ["text": .string("Done.")])])
        #expect(!feed.isRunning)
    }

    @Test func theWaitForAnotherAgentIsNoBackgroundCommand() throws {
        let waiter = "/opt/hermes/bin/python3 /opt/hermes/tools/bot_mode_dm.py --run-delivery --author "
            + #"'{"id":"bot:default"}' query-file /tmp/dm-x.txt --profile-home /home/sam/.hermes/profiles/ralph "#
            + "/opt/hermes/bin/hermes -p ralph"
        let commands = try #require(ChatBackgroundCommand.list(.object(["processes": .array([
            .object(["session_id": .string("proc_dm"), "command": .string(waiter), "status": .string("running")]),
            .object(["session_id": .string("proc_watch"), "command": .string("./watch.sh"), "status": .string("running")]),
        ])])))
        #expect(commands.map(\.id) == ["proc_watch"], "The rail shows the message to Ralph; the chip doesn't count it")
    }

    @Test func aWaitersNoticeIsTheRailsNeverACommandResult() {
        let waiter = notice(waiter: ["outcome": "@ralph answered.", "reply": "Done.", "status": "settled",
                                     "delivery_id": Self.delivery])
        #expect(ChatBackgroundResult(displayKind: ChatBackgroundResult.commandKind, metadata: nil, text: waiter) == nil)
        #expect(ChatBackgroundResult(
            displayKind: ChatBackgroundResult.commandKind,
            metadata: ["display_text": .string("Background Process Finished: ./watch.sh")],
            text: "[IMPORTANT: Background process proc_1 completed normally (exit code 0).\nCommand: ./watch.sh\nOutput:\nok]")
            != nil, "Any other command still reports as one")
    }

    @Test func activitiesNameAMessageByTheAgentItWentTo() throws {
        let item = try #require(AgentTodayItem(json: .object([
            "id": .string("process:proc_dm"), "kind": .string("command"), "title": .string("Message to Ralph"),
            "state": .string("running"), "agentId": .string("ralph"), "agentName": .string("Ralph"),
            "deliveryId": .string(Self.delivery),
            "delivery": .object(["state": .string("working"), "tool": .string("terminal")]),
        ])))
        #expect(item.message == AgentTodayItem.Message(agentID: "ralph", agentName: "Ralph", state: .working,
                                                       toolName: "terminal"))
        let command = try #require(AgentTodayItem(json: .object([
            "id": .string("process:p"), "kind": .string("command"), "title": .string("make"), "state": .string("done"),
        ])))
        #expect(command.message == nil)
    }

    /// Ralph's Bot Chat while his gateway runs a turn: the chat draws it as its own from now (its saved steps
    /// already show), Stop goes to the gateway, and when the feed says the turn ended the chat is idle again,
    /// though the gateway's own last frames never say `running: false`.
    @Test func aTurnTheGatewayRunsIsDrawnLiveAndEndsWhenItDoes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // The chat's own agent: the chat keeps only its agent's rows.
        let client = try DirectHermesConversationClient(rpc: DirectTestRPC(), hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Bot Chat", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        let reader = FakeLiveReader(batches: [
            .init(isAttached: true, isRunning: true, epoch: "g1", frames: [], last: 40, reset: false),
            .init(isAttached: true, isRunning: true, epoch: "g1", frames: [
                frame(41, "tool.start", ["tool_id": .string("t2"), "name": .string("terminal")]),
            ], last: 41, reset: false),
            .init(isAttached: true, isRunning: false, epoch: "g1", frames: [
                frame(42, "tool.complete", ["tool_id": .string("t2"), "name": .string("terminal")]),
                frame(43, "message.delta", ["text": .string("Both steps finished.")]),
                frame(44, "message.complete", ["text": .string("Both steps finished.")]),
            ], last: 44, reset: false),
        ])
        reader.onFollow = { #expect(model.isSending && model.followsGatewayTurn, "Working, as its own turn would be") }
        await model.followGatewayTurn(reader: reader, sessionID: "stored")
        #expect(reader.asked.first?.latest == true, "From now: the saved steps already show")
        #expect(reader.asked.dropFirst().map(\.after) == [40, 41])
        #expect(!model.isSending && !model.followsGatewayTurn, "The turn ended, so Stop goes")
        #expect(model.items.last?.role == .assistant, "The answer came in as it streamed")
    }

    /// The plugin keeps saying the agent's gateway runs the chat, but its feed can't be followed to the
    /// turn's end: no feed at all, or one that starts and then stops. Stop stays put, and the chat asks
    /// again after its usual wait. Asked again at once, it flipped Stop on and off a few times a second.
    @Test(arguments: [false, true])
    func aGatewayRunWhoseFeedCantBeFollowedKeepsStopSteady(feedStartsThenStops: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = try DirectHermesConversationClient(rpc: DirectTestRPC(), hostIdentity: "host", profile: "default",
            runtimeID: "runtime", storedID: "stored", title: "Bot Chat", epoch: "epoch",
            drafts: DirectHermesDraftStore(root: root))
        let model = ChatModel(conversationID: client.conversationID, client: client, initialItems: [])
        client.model = model
        let reader = UnfollowableRunReader(feedStartsThenStops: feedStartsThenStops)
        reader.model = model
        client.agentTalk = reader

        let follow = Task { await model.followOtherProcess() }
        try await Task.sleep(for: .milliseconds(1_500))
        #expect(reader.reads == 1, "Asked again after the wait, not in a loop")
        #expect(reader.clearedBetweenReads == 0, "Stop never went away while the run went on")
        #expect(model.otherProcessRun != nil && !model.isSending)
        follow.cancel()
        await follow.value
    }

    // MARK: Helpers

    private func call() -> ChatActivityEvent {
        ChatActivityEvent(
            eventID: "m1", sessionID: "session", turnID: "turn", kind: .tool, lifecycle: .succeeded,
            title: "message_agent", summary: nil, detail: nil, occurredAt: 2, toolCallID: "call-m1",
            toolName: "message_agent", arguments: #"{"target":"ralph","message":"Build the Mac app."}"#,
            result: #"{"status":"queued","delivery_id":"\#(Self.delivery)","to":"@ralph","process_id":"proc_71d64c3f48e5","reply_delivery":"notification","target_state":"working"}"#,
            sourceOrder: 2)
    }

    private func delivery(_ state: AgentDelivery.State, tool: String? = nil, reply: String? = nil) -> AgentDelivery {
        AgentDelivery(agentID: "ralph", deliveryID: Self.delivery, state: state, sessionID: "local-f679",
                      toolName: tool, reply: reply)
    }

    private func notice(waiter: [String: Any], exitCode: Int = 0) -> String {
        let output = (try? JSONSerialization.data(withJSONObject: waiter, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "[IMPORTANT: Background process proc_71d64c3f48e5 completed normally (exit code \(exitCode)).\n"
            + #"Command: /opt/hermes/bin/python3 /opt/hermes/tools/bot_mode_dm.py --run-delivery --author '{"id":"bot:default"}' "#
            + "query-file /tmp/dm-x.txt --profile-home /home/sam/.hermes/profiles/ralph /opt/hermes/bin/hermes -p ralph"
            + "\nOutput:\n\(output)\n]"
    }

    private func rows(items: [TimelineItem], events: [ChatActivityEvent]) -> [ChatCanvasRow] {
        let entries = ChatTranscriptProjection.entries(
            items: items, activityEvents: events,
            visibility: .init(showReasoning: false, showToolCalls: false), isBotMode: false)
        return ChatCanvasTranscriptProjection.rows(from: entries.map(ChatTurnDisplayRow.entry),
                                                  disclosures: ChatActivityDisclosureStore())
    }

    private func message(_ text: String, human: Bool = false, order: Int) -> TimelineItem {
        TimelineItem(
            id: "item-\(order)", role: human ? .human : .assistant,
            sender: human ? .user(snapshot: .init(name: "You")) : .agent(id: "default", snapshot: .init(name: "Gordie")),
            content: .message(text),
            metadata: .init(delivery: "Saved", timestamp: Date(timeIntervalSince1970: TimeInterval(order)),
                            sourceOrder: order))
    }

    private func label(_ talk: ChatAgentTalk, _ live: ChatAgentTalkLive) -> String {
        ChatAgentTalkPresentation.label(for: talk, chatAgentID: "default", resolver: TimelineSenderResolver(),
                                        live: live.activities)
    }

    private func frame(_ sequence: Int, _ type: String, _ payload: [String: BighelpJSONValue] = [:])
        -> AgentLiveFrames.Frame {
        AgentLiveFrames.Frame(sequence: sequence, type: type, payload: payload)
    }
}

/// The plugin's `chat/live` for one turn: its answers in order, and what each request asked.
@MainActor
private final class FakeLiveReader: AgentTalkReading {
    private var batches: [AgentLiveFrames]
    private(set) var asked: [(after: Int?, latest: Bool)] = []
    var onFollow: (() -> Void)?

    init(batches: [AgentLiveFrames]) { self.batches = batches }

    func runs(agentID: String, sessionID: String, calls: [AgentTalkRunQuery]) async -> [AgentTalkRun]? { nil }
    func steps(agentID: String, sessionID: String) async -> [String]? { nil }

    func liveFrames(agentID: String, sessionID: String, after: Int?, epoch: String?, wait: Duration,
                    latest: Bool) async -> AgentLiveFrames? {
        asked.append((after, latest))
        if !latest { onFollow?() }
        return batches.isEmpty ? nil : batches.removeFirst()
    }
}

/// The plugin's `chat/activity` saying another process runs the chat, live on its gateway, while
/// `chat/live` can't follow it to the turn's end. After 20 reads it stops answering.
@MainActor
private final class UnfollowableRunReader: AgentTalkReading {
    weak var model: ChatModel?
    private let feedStartsThenStops: Bool
    private(set) var reads = 0
    private(set) var clearedBetweenReads = 0

    init(feedStartsThenStops: Bool) { self.feedStartsThenStops = feedStartsThenStops }

    func runs(agentID: String, sessionID: String, calls: [AgentTalkRunQuery]) async -> [AgentTalkRun]? { nil }
    func steps(agentID: String, sessionID: String) async -> [String]? { nil }

    func otherProcessRun(agentID: String, sessionID: String) async -> ChatOtherProcessReading {
        await Task.yield()
        if reads > 0, model?.otherProcessRun == nil { clearedBetweenReads += 1 }
        reads += 1
        return reads > 20 ? .unavailable : .running(.init(toolName: "terminal", canStop: true, isLive: true))
    }

    func liveFrames(agentID: String, sessionID: String, after: Int?, epoch: String?, wait: Duration,
                    latest: Bool) async -> AgentLiveFrames? {
        await Task.yield()
        guard feedStartsThenStops, latest else {
            return feedStartsThenStops ? nil
                : .init(isAttached: false, isRunning: false, epoch: nil, frames: [], last: nil, reset: false)
        }
        return .init(isAttached: true, isRunning: true, epoch: "g1", frames: [], last: 40, reset: false)
    }
}
