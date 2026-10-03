import Foundation
import Testing
@testable import Bighelp

/// Tool folders in the chat: a live one says what the agent is doing now and
/// lists its calls as they happen; a finished one says what it did; a
/// finished turn folds all of them into "Worked for 2m 14s · 18 steps".
@MainActor
struct ChatToolFolderTests {
    private func tool(_ id: String, _ name: String, _ arguments: String? = nil, lifecycle: ChatActivityLifecycle = .succeeded,
                      turn: String = "turn", order: Int? = nil) -> ChatActivityEvent {
        ChatActivityEvent(eventID: id, sessionID: "session", turnID: turn, kind: .tool, lifecycle: lifecycle,
                          title: name, summary: nil, detail: nil, occurredAt: 1, toolCallID: "call-\(id)",
                          toolName: name, arguments: arguments, sourceOrder: order)
    }

    private func message(_ id: String, human: Bool = false, at time: TimeInterval? = nil, order: Int? = nil,
                         duration: Int? = nil, streaming: Bool = false) -> TimelineItem {
        TimelineItem(id: id, role: human ? .human : .assistant,
                     sender: human ? .user(snapshot: .init(name: "You")) : .agent(id: "a", snapshot: .init(name: "Avery")),
                     content: .message(id),
                     metadata: .init(delivery: streaming ? "Streaming" : nil,
                                     timestamp: time.map { Date(timeIntervalSince1970: $0) },
                                     sourceOrder: order, turnDurationMilliseconds: duration))
    }

    // MARK: Folder headers

    @Test func aRunningFolderStreamsTheCurrentCallInPlainWords() {
        let events = [tool("a", "web_search"), tool("b", "read_file", #"{"path":"notes.md"}"#, lifecycle: .running)]
        let phase = ChatActivityPresentation.trailPhase(for: events, isLive: true)
        #expect(BighelpActivitySummary.label(for: phase) == "Reading notes.md…")
        #expect(phase.isLive)
        // Each call so far is a line in the same plain words.
        #expect(ChatActivityPresentation.step(for: events[0]).label == "Searched the web")
        #expect(ChatActivityPresentation.step(for: events[1]).label == "Reading notes.md…")
    }

    /// Between calls the agent is still working on this folder: it never
    /// claims to be done.
    @Test func aLiveFolderBetweenCallsIsThinkingNotDone() {
        let events = [tool("a", "web_search"), tool("b", "read_file", #"{"path":"notes.md"}"#)]
        let phase = ChatActivityPresentation.trailPhase(for: events, isLive: true)
        #expect(phase == .thinking)
        #expect(phase.isLive)
        #expect(BighelpActivitySummary.label(for: phase) != "Done")
    }

    @Test func aFinishedFolderSummarizesWhatItDid() {
        let events = [
            tool("a", "web_search"), tool("b", "read_file", #"{"path":"a.md"}"#),
            tool("c", "read_file", #"{"path":"b.md"}"#), tool("d", "terminal", #"{"command":"npm test"}"#),
        ]
        let phase = ChatActivityPresentation.trailPhase(for: events)
        #expect(phase == .finished("Searched the web, read 2 files, ran tests"))
        #expect(!phase.isLive)
        #expect(BighelpActivitySummary.label(for: phase) == "Searched the web, read 2 files, ran tests")
        // How it ended still wins when it ended badly.
        #expect(ChatActivityPresentation.trailPhase(for: [tool("x", "terminal", lifecycle: .failed)]) == .failed)
        #expect(ChatActivityPresentation.trailPhase(for: [tool("x", "terminal", lifecycle: .cancelled)]) == .stopped)
    }

    @Test func aLiveFolderOpensItsCallsUntilItFinishesOrTheReaderChooses() {
        let store = ChatActivityDisclosureStore()
        let trail = ChatActivityTurn(id: "trail", events: [tool("a", "web_search", lifecycle: .running)])
        #expect(store.isExpanded(trail, isLive: true), "Calls are listed while the folder works")
        #expect(!store.isExpanded(trail), "A finished folder starts closed")
        store.setExpanded(false, for: trail)
        #expect(!store.isExpanded(trail, isLive: true), "Closing it holds while it works")
        let grown = ChatActivityTurn(id: "trail", events: trail.events + [tool("b", "read_file", lifecycle: .running)])
        #expect(!store.isExpanded(grown, isLive: true), "…and as more calls arrive")
    }

    // MARK: The live tail

    @Test func onlyTheFolderAtTheTailOfARunningTurnIsLive() {
        let finished = ChatActivityTurn(id: "first", events: [tool("a", "web_search", order: 2)])
        let latest = ChatActivityTurn(id: "second", events: [tool("b", "read_file", order: 4)])
        let rows: [ChatTurnDisplayRow] = [
            .entry(.message(message("q", human: true, order: 1))), .entry(.activity(finished)),
            .entry(.message(message("note", order: 3))), .entry(.activity(latest)),
        ]
        func trails(_ canvas: [ChatCanvasRow]) -> [(String, Bool)] {
            canvas.compactMap { row in
                guard case .workTrailHeader(let turn, let isLive) = row else { return nil }
                return (turn.id, isLive)
            }
        }
        let store = ChatActivityDisclosureStore()
        let live = ChatCanvasTranscriptProjection.rows(from: rows, disclosures: store, isSending: true)
        #expect(trails(live).map(\.0) == ["first", "second"])
        #expect(trails(live).map(\.1) == [false, true])
        // The live folder's calls are listed under it.
        #expect(live.contains { $0.id == "activity-detail:\(latest.events[0].id)" })
        #expect(!live.contains { $0.id == "activity-detail:\(finished.events[0].id)" })

        // Once the agent moves on to text, the folder is finished.
        let moved = rows + [.entry(.message(message("answer", order: 5, streaming: true)))]
        #expect(trails(ChatCanvasTranscriptProjection.rows(from: moved, disclosures: store, isSending: true)).map(\.1)
                == [false, false])
        // And nothing is live once the turn ends.
        #expect(trails(ChatCanvasTranscriptProjection.rows(from: rows, disclosures: store, isSending: false)).map(\.1)
                == [false, false])
    }

    // MARK: The finished turn

    @Test func aFinishedTurnFoldsItsFoldersIntoWorkedForWithTheRealTimeAndSteps() {
        let entries: [ChatTranscriptEntry] = [
            .message(message("q", human: true, at: 1_000, order: 1)),
            .activity(ChatActivityTurn(id: "f1", events: [tool("a", "web_search", order: 2),
                                                          tool("b", "web_extract", order: 3)])),
            .message(message("Found the docs. Next I'm running the tests.", at: 1_050, order: 4).markedInterim()),
            .activity(ChatActivityTurn(id: "f2", events: [tool("c", "terminal", #"{"command":"npm test"}"#, order: 5)])),
            .message(message("All tests pass.", at: 1_134, order: 6)),
        ]
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true, interimReplies: .fold)
        #expect(rows.map(\.id) == ["message:q", "completed-turn:activity:f1", "message:All tests pass."])
        guard case .completed(let fold) = rows[1] else { Issue.record("Missing fold"); return }
        // From the person's message to the final answer.
        #expect(fold.elapsedSeconds == 134)
        #expect(fold.label == "Worked for 2m 14s")
        #expect(fold.stepCount == 3)
        // Inside, the folders and the narration are as they were.
        #expect(fold.expandedEntries.map(\.id) == entries[1...3].map(\.id))
    }

    @Test func aFoldWithoutARecordedTimeSaysWhatTheTurnDidInsteadOfDone() {
        let entries: [ChatTranscriptEntry] = [
            .message(message("q", human: true)),
            .activity(ChatActivityTurn(id: "f1", events: [tool("a", "web_search"),
                                                          tool("b", "read_file", #"{"path":"a.md"}"#)])),
            .message(message("answer")),
        ]
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        guard case .completed(let fold) = rows[1] else { Issue.record("Missing fold"); return }
        #expect(fold.elapsedSeconds == nil)
        #expect(fold.label == "Searched the web, read a.md")
        #expect(fold.label != "Done")
        #expect(BighelpActivitySummary.label(for: fold.phase) == fold.label)
    }

    /// History from Hermes folds the same way: its saved timestamps give the
    /// time, and its tool calls the steps.
    @Test func aTurnLoadedFromHistoryFoldsTheSameWay() throws {
        func request(_ id: Int, callID: String, name: String, arguments: String, at time: Double) -> BighelpJSONValue {
            var value = DirectHermesHistoryProjectionTests.row(id: id, role: "assistant", content: .null,
                                                               timestamp: time).object!
            value["tool_calls"] = .array([.object([
                "id": .string(callID), "type": .string("function"),
                "function": .object(["name": .string(name), "arguments": .string(arguments)]),
            ])])
            return .object(value)
        }
        func result(_ id: Int, callID: String, name: String, at time: Double) -> BighelpJSONValue {
            var value = DirectHermesHistoryProjectionTests.row(id: id, role: "tool", content: .string("ok"),
                                                               timestamp: time).object!
            value["tool_call_id"] = .string(callID)
            value["tool_name"] = .string(name)
            return .object(value)
        }
        let values: [BighelpJSONValue] = [
            DirectHermesHistoryProjectionTests.row(id: 1, role: "user", content: .string("Clone and test it"),
                                                   timestamp: 1_000),
            request(2, callID: "c1", name: "terminal", arguments: #"{"command":"git clone https://example.com/app.git"}"#,
                    at: 1_010),
            result(3, callID: "c1", name: "terminal", at: 1_020),
            request(4, callID: "c2", name: "terminal", arguments: #"{"command":"npm test"}"#, at: 1_030),
            result(5, callID: "c2", name: "terminal", at: 1_100),
            DirectHermesHistoryProjectionTests.row(id: 6, role: "assistant", content: .string("Tests pass."),
                                                   timestamp: 1_134),
        ]
        let rows = try values.map { try DirectHermesHistoryRow($0, sessionID: "tip") }
        let projection = try DirectHermesHistoryProjection(rows: rows, appID: "chat", profileID: "default",
                                                          source: "loopdy", sourceOrderBase: 0)
        let events = projection.activityEvents(sessionID: "chat")
        let entries = ChatTranscriptProjection.entries(items: projection.messages, activityEvents: events,
                                                       visibility: .default, isBotMode: false)
        let display = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true,
                                                       activityEvents: events)
        let folds = display.compactMap { row -> ChatCompletedTurn? in
            guard case .completed(let turn) = row else { return nil }
            return turn
        }
        #expect(folds.count == 1)
        #expect(folds.first?.label == "Worked for 2m 14s")
        #expect(folds.first?.stepCount == 2)
        #expect(display.last?.id == "message:\(projection.messages.last!.id)", "The answer stays outside the fold")
        // Unfolded, its folder says what it did.
        let store = ChatActivityDisclosureStore()
        store.setCompletedTurnExpanded(true, id: folds[0].id)
        let canvas = ChatCanvasTranscriptProjection.rows(from: display, disclosures: store)
        let trail = canvas.compactMap { row -> ChatActivityTurn? in
            guard case .workTrailHeader(let turn, _) = row else { return nil }
            return turn
        }.first
        #expect(trail.map { BighelpActivitySummary.label(for: ChatActivityPresentation.trailPhase(for: $0.events)) }
                == "Cloned app, ran tests")
    }
}
