import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ChatAgentTalkTests {
    // MARK: Reading the calls

    @Test func oneShotHermesChatToAnotherProfileIsAgentTalk() throws {
        let call = try #require(terminalCall(
            "hermes -p nova chat -Q --oneshot --run-budget 180 -q 'Message from Avery (@default): Is Monday free?'"))
        #expect(call.targetID == "nova")
        #expect(call.route == .chat)
        #expect(call.message == "Message from Avery (@default): Is Monday free?")
    }

    @Test func setUpBeforeHermesAndQuotedWordsStillRead() throws {
        let call = try #require(terminalCall(
            #"cd ~ && timeout 180 HERMES_X=1 /opt/bin/hermes --profile=havok chat -c "Bot Chat" --create-if-missing -Q --query "It's \"done\"?" 2>&1"#))
        #expect(call.targetID == "havok")
        #expect(call.message == #"It's "done"?"#)
    }

    @Test func otherHermesCommandsAreOrdinaryTools() {
        #expect(terminalCall("hermes -p nova chat --help") == nil)
        // Without -p the target is whichever agent the shell points at.
        #expect(terminalCall("hermes chat -q 'hi'") == nil)
        #expect(terminalCall("hermes -p nova skills list") == nil)
        #expect(terminalCall("echo 'hermes -p nova chat -q hi'") == nil)
        #expect(terminalCall("hermes -p nova chat -q 'never closed") == nil)
    }

    @Test func queryFileSendsWordsTheCallDoesntShow() throws {
        let call = try #require(terminalCall("hermes -p nova chat -Q --query-file /tmp/ask.txt"))
        #expect(call.targetID == "nova")
        #expect(call.message == nil)
    }

    @Test func peerDirectMessageNamesTheOtherComputersAgent() throws {
        let call = try #require(terminalCall("hermes peer dm spark/researcher 'Any news?'"))
        #expect(call.targetID == "spark/researcher")
        #expect(call.route == .peer)
        #expect(call.message == "Any news?")
        #expect(call.fallbackTargetName == "Researcher")
    }

    @Test func messageAgentToolUsesHermesHandles() throws {
        let call = try #require(AgentTalkCall.parse(
            toolName: "message_agent", arguments: #"{"target":"@hermes","message":"Ping"}"#))
        #expect(call.targetID == "default")
        #expect(call.route == .message)
        #expect(call.message == "Ping")
    }

    // MARK: Reading the answers

    @Test func answerDropsSignatureAndSessionLineWherever() throws {
        let event = tool("t1", command: "hermes -p nova chat -Q -q 'Is Monday free?'",
                         output: "session_id: 20261017_170115_941fc0\nMessage from 🤖 Nova (@nova):\n\nMonday is free after 2 PM.\n")
        let reply = try #require(event.agentTalkReply)
        #expect(reply.outcome == .answered)
        #expect(reply.text == "Monday is free after 2 PM.")
        #expect(reply.sessionID == "20261017_170115_941fc0")
    }

    @Test func failedCommandIsNoAnswer() throws {
        let event = tool("t1", command: "hermes -p nova chat -Q -q 'Hi'", output: "Profile not found", exitCode: 1)
        #expect(event.agentTalkReply?.outcome == .failed)
    }

    @Test func queuedMessageKeepsItsDeliveryProcess() throws {
        let event = ChatActivityEvent(
            eventID: "m1", sessionID: "s", turnID: "turn", kind: .tool, lifecycle: .succeeded,
            title: "message_agent", summary: nil, detail: nil, occurredAt: 1, toolCallID: "call-m1",
            toolName: "message_agent", arguments: #"{"target":"havok","message":"Check Tree's chat"}"#,
            result: #"{"status":"queued","delivery_id":"d1","to":"@havok","process_id":"proc_49755704fc46"}"#)
        let reply = try #require(event.agentTalkReply)
        #expect(reply.outcome == .queued)
        #expect(reply.processID == "proc_49755704fc46")
    }

    @Test func incomingSignatureNamesTheSender() throws {
        let colon = try #require(AgentTalkIncomingMessage.parse("Message from 🤖 Havok (@havok): Not in my chats."))
        #expect(colon.senderID == "havok")
        #expect(colon.senderName == "Havok")
        #expect(colon.body == "Not in my chats.")
        // A comma runs into the message, so the words stay whole.
        let comma = try #require(AgentTalkIncomingMessage.parse("Message from Avery (@hermes), on behalf of Sam."))
        #expect(comma.senderID == "default")
        #expect(comma.body == "Message from Avery (@hermes), on behalf of Sam.")
        #expect(AgentTalkIncomingMessage.parse("Message from me: hello") == nil)
        #expect(AgentTalkIncomingMessage.parse("A Message from 🤖 Havok (@havok): hi") == nil)
    }

    @Test func deliveryNoticeCarriesTheAnswer() throws {
        let delivery = try #require(AgentTalkDelivery.parse(deliveryNotice("proc_abc", reply: "Not my chat.")))
        #expect(delivery.processID == "proc_abc")
        #expect(delivery.targetID == "havok")
        #expect(delivery.succeeded)
        #expect(delivery.reply == "Not my chat.")
        #expect(AgentTalkDelivery.parse("[IMPORTANT: Background process proc_1 exited (exit code 0).\nCommand: npm test\nOutput:\nok]") == nil)
    }

    // MARK: Where the rail goes

    @Test func agentTalkShowsWithToolCallsHidden() {
        let talk = tool("t1", command: "hermes -p nova chat -Q -q 'Hi'", output: "Hello")
        let other = tool("t2", command: "ls", output: "a")
        let hidden = ChatActivityVisibility(showReasoning: false, showToolCalls: false)
        #expect(talk.isVisible(using: hidden))
        #expect(!other.isVisible(using: hidden))
    }

    @Test func finishedTurnFoldsTheWorkButNotTheAgentTalk() throws {
        let user = message("q", human: true, order: 1)
        let answer = message("Monday is free.", order: 6)
        let events = [
            tool("t1", command: "ls", output: "a", order: 2),
            tool("t2", command: "hermes -p nova chat -Q -q 'Is Monday free?'", output: "Yes, after 2 PM.", order: 3),
            tool("t3", command: "hermes -p nova chat -Q -q 'And Tuesday?'", output: "Tuesday is full.", order: 4),
            tool("t4", command: "cat notes.md", output: "x", order: 5),
        ]
        let entries = ChatTranscriptProjection.entries(
            items: [user, answer], activityEvents: events,
            visibility: .init(showReasoning: false, showToolCalls: true), isBotMode: false)
        let display = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        let fold = try #require(display.compactMap { row -> ChatCompletedTurn? in
            if case .completed(let turn) = row { turn } else { nil }
        }.first)
        #expect(fold.stepCount == 2, "Messages to other agents aren't steps")
        let rows = ChatCanvasTranscriptProjection.rows(from: display, disclosures: ChatActivityDisclosureStore())
        let talks = rows.compactMap { row -> ChatAgentTalk? in if case .agentTalk(let talk) = row { talk } else { nil } }
        #expect(talks.count == 1, "Back-to-back messages read as one rail")
        let talk = try #require(talks.first)
        #expect(talk.pieces.count == 2)
        let resolver = TimelineSenderResolver()
        #expect(ChatAgentTalkPresentation.label(for: talk, chatAgentID: "finance", resolver: resolver)
                == "4 messages with Nova")
        #expect(talk.messages(chatAgentID: "finance").map(\.agentID) == ["finance", "nova", "finance", "nova"])
        // The rail sits after the fold, before the answer.
        let kinds = rows.map { row -> String in
            switch row {
            case .transcript(.completed): "fold"
            case .agentTalk: "talk"
            case .transcript(.entry(.message(let item))): item.role == .human ? "human" : "answer"
            default: "other"
            }
        }
        #expect(kinds == ["human", "fold", "talk", "answer"])
    }

    @Test func runningCallIsLiveAndAsks() throws {
        let running = tool("t1", command: "hermes -p nova chat -Q -q 'Is Monday free?'", output: nil, lifecycle: .running)
        let talk = ChatAgentTalk(.call(running, delivery: nil))
        #expect(talk.isLive)
        let resolver = TimelineSenderResolver()
        #expect(ChatAgentTalkPresentation.label(for: talk, chatAgentID: "finance", resolver: resolver) == "Asking Nova…")
        let live = [running.id: AgentTalkLiveActivity(sessionID: "s2", toolName: "web_search", isWorking: true)]
        #expect(ChatAgentTalkPresentation.label(for: talk, chatAgentID: "finance", resolver: resolver, live: live)
                == "Nova is searching the web…")
        #expect(talk.messages(chatAgentID: "finance").last?.state == .working)
    }

    @Test func messageFromAnotherAgentBecomesARailWithTheAnswer() throws {
        let incoming = message("Message from 🤖 Havok (@havok): Can you check the build?", human: true, order: 1)
        let marked = message("Looking now.", order: 2).markedInterim()
        let answer = message("The build passes.", order: 4)
        let entries: [ChatTranscriptEntry] = [.message(incoming), .message(marked), .message(answer)]
        let rows = ChatCanvasTranscriptProjection.rows(from: entries.map(ChatTurnDisplayRow.entry),
                                                       disclosures: ChatActivityDisclosureStore())
        guard case .agentTalk(let talk) = rows.first else {
            Issue.record("The other agent's message shows as a rail, not as the person's bubble")
            return
        }
        let messages = talk.messages(chatAgentID: "finance")
        #expect(messages.map(\.agentID) == ["havok", "finance"])
        #expect(messages.map(\.state) == [.said("Can you check the build?"), .said("The build passes.")])
        // The agent's own answer still shows in the chat.
        #expect(rows.count == 3)
        // A group chat's messages stay as they are.
        let room = ChatCanvasTranscriptProjection.rows(from: entries.map(ChatTurnDisplayRow.entry),
                                                       disclosures: ChatActivityDisclosureStore(),
                                                       readsAgentMessages: false)
        if case .agentTalk = room.first { Issue.record("Rooms don't read agent signatures") }
    }

    @Test func messageAgentAnswerArrivesLaterAndJoinsItsCall() throws {
        let user = message("Ask Havok", human: true, order: 1)
        let call = ChatActivityEvent(
            eventID: "m1", sessionID: "session", turnID: "turn", kind: .tool, lifecycle: .succeeded,
            title: "message_agent", summary: nil, detail: nil, occurredAt: 2, toolCallID: "call-m1",
            toolName: "message_agent", arguments: #"{"target":"havok","message":"Is it yours?"}"#,
            result: #"{"status":"queued","to":"@havok","process_id":"proc_abc"}"#, sourceOrder: 2)
        let sent = message("I asked Havok.", order: 3)
        let notice = message(deliveryNotice("proc_abc", reply: "Not mine."), human: true, order: 4)
        let entries = ChatTranscriptProjection.entries(
            items: [user, sent, notice], activityEvents: [call],
            visibility: .init(showReasoning: false, showToolCalls: false), isBotMode: false)
        let rows = ChatCanvasTranscriptProjection.rows(from: entries.map(ChatTurnDisplayRow.entry),
                                                       disclosures: ChatActivityDisclosureStore())
        let talks = rows.compactMap { row -> ChatAgentTalk? in if case .agentTalk(let talk) = row { talk } else { nil } }
        #expect(talks.count == 2, "The question where it was asked, the answer where it arrived")
        let first = try #require(talks.first)
        #expect(first.messages(chatAgentID: "finance").map(\.state) == [.said("Is it yours?"), .said("Not mine.")])
        let second = try #require(talks.last)
        #expect(second.messages(chatAgentID: "finance").map(\.state) == [.said("Is it yours?"), .said("Not mine.")])
        #expect(!rows.contains { row in
            if case .transcript(.entry(.message(let item))) = row { item.id == notice.id } else { false }
        }, "The raw background notice never shows as the person's bubble")
    }

    @Test func chatListPreviewsReadAsTheOtherAgents() {
        #expect(SessionPreviewText.plain("Message from 🤖 Havok (@havok): **Not** in my chats.")
                == "Havok: Not in my chats.")
        #expect(SessionPreviewText.plain(deliveryNotice("proc_abc", reply: "Not mine.")) == "Havok: Not mine.")
        // A comma signature runs into the words: shown as written, without looping.
        #expect(SessionPreviewText.plain("Message from Avery (@hermes), on behalf of Sam.")
                == "Message from Avery (@hermes), on behalf of Sam.")
    }

    // MARK: The plugin's feed

    @Test func messageHashMatchesThePluginsNormalization() {
        #expect(AgentTalkMessageHash.hash("Message from 🤖 Avery (@hermes): Is Monday free?")
                == AgentTalkMessageHash.hash("  Is Monday free?\n"))
        // The same vector is in the plugin's tests (`test_agent_talk.py`).
        #expect(AgentTalkMessageHash.hash("Is Monday free?")
                == "3f8b2abb9596992352771eb54daf4895b0b8beca852321f474bca45b96e49a87")
        #expect(AgentTalkMessageHash.isHash(AgentTalkMessageHash.hash("x")))
    }

    @Test func liveRunsMatchCallsByAgentAndMessage() {
        let first = tool("t1", command: "hermes -p nova chat -Q -q 'Is Monday free?'", output: "Yes")
        let again = tool("t2", command: "hermes -p nova chat -Q -q 'Is Monday free?'", output: nil, lifecycle: .running)
        let byFile = tool("t3", command: "hermes -p sage chat -Q --query-file /tmp/q", output: nil, lifecycle: .running)
        let peer = tool("t4", command: "hermes peer dm spark/rio 'Is Monday free?'", output: nil, lifecycle: .running)
        #expect(byFile.agentTalkRunQuery == nil, "Words in a file have nothing to match")
        #expect(peer.agentTalkRunQuery == nil, "Another computer's agent isn't in this host's history")
        let live = ChatAgentTalkLive()
        let monday = AgentTalkMessageHash.hash("Is Monday free?")
        live.update(runs: [
            AgentTalkRun(agentID: "sage", sessionID: "s-1", messageHash: monday,
                         startedAt: Date(timeIntervalSince1970: 3), isWorking: true, toolName: "terminal"),
            AgentTalkRun(agentID: "nova", sessionID: "n-2", messageHash: monday,
                         startedAt: Date(timeIntervalSince1970: 2), isWorking: true, toolName: "read_file"),
            AgentTalkRun(agentID: "nova", sessionID: "n-1", messageHash: monday,
                         startedAt: Date(timeIntervalSince1970: 1), isWorking: false, toolName: nil),
        ], calls: [first, again, byFile, peer])
        #expect(live.activities[first.id]?.sessionID == "n-1")
        #expect(live.activities[again.id]?.sessionID == "n-2")
        #expect(live.activities[again.id]?.toolName == "read_file")
        #expect(live.activities[byFile.id] == nil)
        #expect(live.hasWorkingRuns)
    }

    @Test func runsResponseIsReadLeniently() {
        let runs = DirectHermesAgentTalkReader.runs(from: ["runs": .array([
            .object(["agentId": .string("nova"), "sessionId": .string("20261017_170115_941fc0"),
                     "message": .string(AgentTalkMessageHash.hash("Hi")), "startedAt": .number(1_760_000_000),
                     "working": .boolean(true), "tool": .string("web_search"), "extra": .string("ignored")]),
            .object(["agentId": .string("bad id!"), "sessionId": .string("x")]),
            .object(["agentId": .string("sage"), "sessionId": .string("s2"), "tool": .string("rm -rf /")]),
        ])])
        #expect(runs?.map(\.agentID) == ["nova", "sage"])
        #expect(runs?.first?.toolName == "web_search")
        #expect(runs?.last?.toolName == nil, "A tool name that isn't a plain name is dropped")
        #expect(DirectHermesAgentTalkReader.runs(from: [:]) == nil)
    }

    // MARK: Helpers

    private func terminalCall(_ command: String) -> AgentTalkCall? {
        AgentTalkCall.parse(toolName: "terminal", arguments: json(["command": command]))
    }

    private func tool(_ id: String, command: String, output: String?, exitCode: Int = 0, order: Int = 1,
                      lifecycle: ChatActivityLifecycle = .succeeded) -> ChatActivityEvent {
        ChatActivityEvent(
            eventID: id, sessionID: "session", turnID: "turn", kind: .tool, lifecycle: lifecycle,
            title: "terminal", summary: nil, detail: nil, occurredAt: order, toolCallID: "call-\(id)",
            toolName: "terminal", arguments: json(["command": command]),
            result: output.map { json(["output": $0, "exit_code": exitCode, "error": NSNull()]) },
            sourceOrder: order)
    }

    private func message(_ text: String, human: Bool = false, order: Int) -> TimelineItem {
        TimelineItem(
            id: "item-\(order)", role: human ? .human : .assistant,
            sender: human ? .user(snapshot: .init(name: "You")) : .agent(id: "finance", snapshot: .init(name: "Avery")),
            content: .message(text),
            metadata: .init(delivery: "Saved", timestamp: Date(timeIntervalSince1970: TimeInterval(order)),
                            sourceOrder: order))
    }

    private func deliveryNotice(_ process: String, reply: String) -> String {
        "[IMPORTANT: Background process \(process) completed normally (exit code 0).\n"
            + #"Command: /usr/bin/python3 /srv/hermes/tools/bot_mode_dm.py --run-delivery --author '{"id": "bot:default", "is_bot": true}' "#
            + #"query-file /tmp/q hermes -p havok chat --in ~ -c "Bot Chat" --create-if-missing -Q --query-file /tmp/q"#
            + "\nOutput:\n\(reply)]"
    }

    private func json(_ value: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
