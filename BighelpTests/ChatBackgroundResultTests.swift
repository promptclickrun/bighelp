import Foundation
import Testing
@testable import Bighelp

/// Helpers and background commands report back as a user row written for the model. The chat
/// shows a small card that still starts the agent's turn, so the work trail stays under it.
@MainActor
struct ChatBackgroundResultTests {
    static let batch = """
    [ASYNC DELEGATION BATCH COMPLETE — deleg_test-1]
    A background fan-out unit you dispatched earlier — 3 subagent(s) — has finished; its consolidated results are below.

    Dispatched: 2026-11-03 17:44:23 (12m2s ago)
    Role: leaf   Model: test-model   Total duration: 722.4s

    --- ✓ TASK 1/3: Draw the robots pack (with 15 characters)  (status=completed, api_calls=22, 553.45s) ---
    {"verified":"15 characters"}
    Full live transcript (complete tool/assistant trace): /tmp/task-0.log

    --- ⚠ TASK 2/3: Draw the birds pack  (status=completed, api_calls=90, 640.2s, TRUNCATED: hit max_iterations — work may be incomplete) ---
    Partial birds.

    --- ✗ TASK 3/3: Draw the plants pack  (status=failed, 12.5s) ---
    (failed: could not read plants.json)
    """

    static let single = """
    [ASYNC DELEGATION COMPLETE — deleg_one]
    A background subagent you dispatched earlier has finished.

    Dispatched: 2026-11-03 17:44:23 (1m ago)
    Original goal: Fix the failing tests
    Role: leaf   Model: test-model
    Status: completed   API calls: 5   Duration: 12.3s
    --- RESULT ---
    All 12 tests pass now.
    """

    static let earlyWarning = """
    [ASYNC DELEGATION TASK FAILED — deleg_x, task 2/3]
    One subagent in a background fan-out you dispatched has failed while its siblings are still running.
    Task: Draw the birds pack
    Status: failed   Duration: 41.0s
    Error: the model refused
    """

    static let batchMetadata: [String: BighelpJSONValue] = [
        "display_text": .string("Subagent Tasks Finished with Issues: Draw packs (3 tasks)"),
        "task_count": .integer(3), "duration_seconds": .number(722.4),
    ]

    @Test func batchReportReadsEachTask() throws {
        let result = try #require(ChatBackgroundResult(displayKind: ChatBackgroundResult.helpersKind,
                                                       metadata: Self.batchMetadata, text: Self.batch))
        #expect(result.kind == .helpers)
        #expect(result.tasks.map(\.goal) == ["Draw the robots pack (with 15 characters)", "Draw the birds pack",
                                            "Draw the plants pack"])
        #expect(result.tasks.map(\.outcome) == [.finished, .stoppedEarly, .failed])
        #expect(result.tasks.map(\.seconds) == [553.45, 640.2, 12.5])
        #expect(result.seconds == 722.4)
        #expect(result.headline == "1 of 3 helpers finished")
        let sections = result.reportSections
        #expect(sections.map(\.heading) == ["Task 1 of 3", "Task 2 of 3", "Task 3 of 3"])
        #expect(sections[0].body.hasPrefix(#"{"verified":"15 characters"}"#))
        #expect(sections[2].body == "(failed: could not read plants.json)")
    }

    /// Hermes before `display_kind` saved the report untyped; it reads the same.
    @Test func oneHelperReadsItsGoalAndStatus() throws {
        let result = try #require(ChatBackgroundResult(displayKind: nil, metadata: nil, text: Self.single))
        #expect(result.tasks == [.init(goal: "Fix the failing tests", outcome: .finished, seconds: 12.3)])
        #expect(result.seconds == 12.3)
        #expect(result.headline == "Helper finished")
        #expect(result.reportSections.map(\.body) == ["All 12 tests pass now."])
    }

    @Test func earlyWarningSaysOneHelperFailed() throws {
        let result = try #require(ChatBackgroundResult(displayKind: ChatBackgroundResult.helpersKind,
                                                       metadata: nil, text: Self.earlyWarning))
        #expect(result.isEarlyWarning)
        #expect(result.headline == "A helper failed")
        #expect(result.tasks == [.init(goal: "Draw the birds pack", outcome: .failed, seconds: 41)])
    }

    @Test func commandTitleGivesTheCommandAndHowItEnded() throws {
        func result(_ title: String) throws -> ChatBackgroundResult {
            try #require(ChatBackgroundResult(displayKind: ChatBackgroundResult.commandKind,
                                              metadata: ["display_text": .string(title)], text: "[IMPORTANT: …]"))
        }
        let failed = try result("Background Process Failed (exit 1): npm run build")
        #expect(failed.headline == "Command failed")
        #expect(failed.tasks.first?.goal == "npm run build")
        #expect(try result("Background Process Finished: npm test").headline == "Command finished")
        #expect(try result("Background Process Terminated: sleep 600").headline == "Command stopped")
    }

    @Test func aPersonsMessageIsNotAResult() {
        #expect(ChatBackgroundResult(displayKind: nil, metadata: nil, text: "Did [ASYNC DELEGATION ] finish?") == nil)
        #expect(ChatBackgroundResult(displayKind: "steer", metadata: nil, text: Self.single) == nil)
    }

    @Test func durationsReadShort() {
        #expect(ChatBackgroundResult.duration(0.4) == "1s")
        #expect(ChatBackgroundResult.duration(41) == "41s")
        #expect(ChatBackgroundResult.duration(555.01) == "9m")
        #expect(ChatBackgroundResult.duration(3_900) == "1h 5m")
        #expect(ChatBackgroundResult.duration(nil) == nil)
    }

    /// The saved row becomes the card, and it still opens the turn the agent answers it in.
    @Test func savedRowBecomesACardThatStillStartsItsTurn() throws {
        let rows = try [
            DirectHermesHistoryProjectionTests.row(id: 1, role: "user", content: .string("Draw three packs in the background")),
            DirectHermesHistoryProjectionTests.row(id: 2, role: "assistant", content: .string("On it.")),
            DirectHermesHistoryProjectionTests.row(id: 3, role: "user", content: .string(Self.batch),
                                                   displayKind: ChatBackgroundResult.helpersKind,
                                                   displayMetadata: .object(Self.batchMetadata)),
            DirectHermesHistoryProjectionTests.row(id: 4, role: "assistant", content: .string("Robots are ready.")),
        ].map { try DirectHermesHistoryRow($0, sessionID: "tip") }
        let projection = try DirectHermesHistoryProjection(rows: rows, appID: "chat", profileID: "default",
                                                           source: nil, sourceOrderBase: 0)
        let card = projection.messages[2]
        guard case .backgroundResult(let result) = card.content else {
            Issue.record("Expected a result card, got \(card.content)")
            return
        }
        #expect(result.headline == "1 of 3 helpers finished")
        #expect(card.role == .human)
        #expect(card.sender.kind == .system)
        let turns = ChatTranscriptTurn.split(projection.messages.map(ChatTranscriptEntry.message))
        #expect(turns.map(\.range) == [0..<2, 2..<4])
    }

    /// The socket's history (a reconnect's replay) reads the same rows the same way.
    @Test func replayedRowBecomesACard() {
        var projection = DirectHermesProjection(conversationID: "chat", profile: "default", storedID: "s", epoch: "")
        projection.seedHistory([
            .object(["role": .string("user"), "row_id": .integer(7), "text": .string(Self.single),
                     "display_kind": .string(ChatBackgroundResult.helpersKind)]),
            .object(["role": .string("assistant"), "row_id": .integer(8), "text": .string("Tests pass.")]),
        ])
        guard case .backgroundResult(let result)? = projection.items.first?.content else {
            Issue.record("Expected a result card, got \(String(describing: projection.items.first?.content))")
            return
        }
        #expect(result.headline == "Helper finished")
        #expect(projection.items.first?.role == .human)
    }

    /// Coming back while the agent answers the report: Hermes' in-flight turn holds it.
    @Test func inFlightReportBecomesACard() {
        var projection = DirectHermesProjection(conversationID: "chat", profile: "default", storedID: "s", epoch: "")
        let seeded = projection.seedLiveReplayHistory([
            "messages": .array([]), "turn_started_at": .number(100),
            "inflight": .object(["user": .string(Self.batch), "display_kind": .string(ChatBackgroundResult.helpersKind),
                                 "display_metadata": .object(Self.batchMetadata)]),
        ], epoch: "e")
        #expect(seeded)
        guard case .backgroundResult(let result)? = projection.items.first?.content else {
            Issue.record("Expected a result card, got \(String(describing: projection.items.first?.content))")
            return
        }
        #expect(result.tasks.count == 3)
    }

    /// A chat list preview may cut the report short, so it names the result without counting.
    @Test func listPreviewNamesTheResult() {
        #expect(SessionPreviewText.plain(Self.batch) == "Helpers reported back")
        #expect(SessionPreviewText.plain(Self.earlyWarning) == "A helper failed")
    }

    /// The card is a row of its own: it stays in the transcript cache through a chat's coding,
    /// and a reply quoting it names the result, not the report.
    @Test func cardSurvivesSavingAndQuotesByItsHeadline() throws {
        let result = try #require(ChatBackgroundResult(displayKind: nil, metadata: nil, text: Self.single))
        let item = TimelineItem.backgroundResult(result, id: "chat:row:3", metadata: .init(sourceOrder: 3))
        let decoded = try JSONDecoder().decode(TimelineItem.self, from: JSONEncoder().encode(item))
        #expect(decoded == item)
        #expect(ChatReplyQuote.quotedText(of: item) == "Helper finished")
    }
}
