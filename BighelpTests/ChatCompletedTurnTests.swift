import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ChatCompletedTurnTests {
    @Test func emptyReasoningLifecycleAfterFinalDoesNotCreateContinuationFold() {
        let user = message("user", time: 100, human: true, order: 1)
        let final = message("final", time: 104, order: 3)
        let tool = ChatActivityEvent(
            eventID: "tool-real", sessionID: "session", turnID: "turn-real",
            kind: .tool, lifecycle: .succeeded, title: "Read file", summary: "Read file",
            detail: "The file was read.", occurredAt: 102, toolCallID: "call-real", sourceOrder: 2
        )
        // This is a terminal lifecycle marker with no reasoning content. It can
        // remain in the incremental transcript after a visible reasoning row
        // is settled, even though a full projection would omit it.
        let emptyReasoning = ChatActivityEvent(
            eventID: "reasoning-empty", sessionID: "session", turnID: "turn-empty",
            kind: .reasoning, lifecycle: .succeeded, title: "Reasoning",
            summary: "Response ready", detail: nil, occurredAt: 105, sourceOrder: 4
        )
        let entries = ChatTranscriptProjection.entries(
            items: [user, final],
            activityEvents: [tool, emptyReasoning],
            visibility: .init(showReasoning: true, showToolCalls: true),
            isBotMode: false
        )

        // Feed the rows projection the stale entry explicitly to reproduce the
        // incremental-update path without involving ChatModel internals.
        let staleEntries = entries + [.activity(ChatActivityTurn(
            id: "turn-empty:reasoning-empty", events: [emptyReasoning]
        ))]
        let rows = ChatCompletedTurnProjection.rows(from: staleEntries, isSending: false, enabled: true)
        let folds = rows.compactMap { row -> ChatCompletedTurn? in
            guard case .completed(let turn) = row else { return nil }
            return turn
        }
        #expect(folds.count == 1)
        #expect(folds.first?.entries.map(\.id) == [entries[1].id])
        #expect(visibleIDs(rows) == [user.id, final.id])
        #expect(expandedIDs(rows) == entries.map(\.id))
    }

    @Test func transcriptProjectionDropsReasoningLifecycleLabelWithoutReorderingRealContent() {
        let user = message("user", time: 100, human: true, order: 1)
        let final = message("final", time: 104, order: 3)
        let realReasoning = ChatActivityEvent(
            eventID: "reasoning-real", sessionID: "session", turnID: "turn-real",
            kind: .reasoning, lifecycle: .succeeded, title: "Reasoning",
            summary: nil, detail: "Compare the two verified options.", occurredAt: 102, sourceOrder: 2
        )
        let emptyReasoning = ChatActivityEvent(
            eventID: "reasoning-label", sessionID: "session", turnID: "turn-label",
            kind: .reasoning, lifecycle: .succeeded, title: "Reasoning",
            summary: "Reasoning completed", detail: nil, occurredAt: 105, sourceOrder: 4
        )

        let entries = ChatTranscriptProjection.entries(
            items: [user, final],
            activityEvents: [realReasoning, emptyReasoning],
            visibility: .init(showReasoning: true, showToolCalls: true),
            isBotMode: false
        )

        #expect(entries.map(\.id) == [
            "message:\(user.id)",
            "activity:\(realReasoning.turnID):\(realReasoning.eventID)",
            "message:\(final.id)",
        ])
        guard case .activity(let turn) = entries[1] else {
            Issue.record("Missing real reasoning activity")
            return
        }
        #expect(turn.events == [realReasoning])
    }

    @Test func reasoningLifecyclePlaceholderDetailDoesNotHideRealSummary() {
        let event = ChatActivityEvent(
            eventID: "reasoning-summary", sessionID: "session", turnID: "turn-summary",
            kind: .reasoning, lifecycle: .succeeded, title: "Reasoning",
            summary: "Compared the verified options.", detail: "Reasoning completed",
            occurredAt: 102, sourceOrder: 2
        )

        let entries = ChatTranscriptProjection.entries(
            items: [message("question", time: 100, human: true, order: 1)],
            activityEvents: [event],
            visibility: .init(showReasoning: true, showToolCalls: true),
            isBotMode: false
        )

        guard case .activity(let turn)? = entries.last else {
            Issue.record("Real reasoning summary was hidden by its lifecycle detail")
            return
        }
        #expect(turn.events == [event])
    }

    @Test func clarificationContextRemainsVisibleBeforeFollowupQuestion() {
        let entries: [ChatTranscriptEntry] = [
            .message(message("user", time: 100, human: true)),
            .message(message("The migration replaces your local settings. Keep a backup before proceeding.", time: 101)),
            .activity(ChatActivityTurn(id: "clarify-work", events: [ChatActivityEvent(
                eventID: "clarify-call", sessionID: "session", turnID: "turn",
                kind: .tool, lifecycle: .succeeded, title: "Clarify", summary: nil, detail: nil,
                occurredAt: 102, toolCallID: "clarify-1"
            )])),
            .message(message("Proceed with the migration?", time: 103)),
        ]
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        let visible = rows.compactMap { row -> String? in
            guard case .entry(.message(let item)) = row else { return nil }
            return item.id
        }
        #expect(visible == ["user", "The migration replaces your local settings. Keep a backup before proceeding.", "Proceed with the migration?"])
        let expanded = rows.flatMap { row -> [String] in
            switch row {
            case .entry(let entry): [entry.id]
            case .completed(let turn): turn.entries.map(\.id)
            }
        }
        #expect(expanded == entries.map(\.id))
    }

    /// With tool calls hidden, the agent's notes are the visible thought
    /// process, so a finished turn folds them; the answer stays out.
    @Test func hiddenToolCallsFoldTheNotesIntoTheFinishedTurn() {
        let entries: [ChatTranscriptEntry] = [
            .message(message("user", time: 100, human: true, order: 1)),
            .message(message("note-1", time: 101, order: 2).markedInterim()),
            .message(message("note-2", time: 102, order: 4).markedInterim()),
            .message(message("answer", time: 110, duration: 9_000, order: 6)),
        ]
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true,
                                                    interimReplies: .fold)
        #expect(rows.map(\.id) == ["message:user", "completed-turn:message:note-1", "message:answer"])
        guard case .completed(let turn) = rows[1] else { Issue.record("Missing fold"); return }
        #expect(turn.label == "Worked for 9s")
        #expect(turn.expandedEntries.map(\.id) == ["message:note-1", "message:note-2"])
        // Tool calls shown: the notes stay in the chat, as before.
        let shown = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        #expect(shown.map(\.id) == ["message:user", "message:note-1", "message:note-2", "message:answer"])
        // Never while the turn is still running.
        let live = ChatCompletedTurnProjection.rows(from: entries, isSending: true, enabled: true,
                                                    interimReplies: .fold)
        #expect(live.map(\.id) == ["message:user", "message:note-1", "message:note-2", "message:answer"])
    }

    /// Claude's notes between steps are its reasoning: they follow Show
    /// reasoning, not Show tool calls. Both on put them in the fold with the
    /// work (they sat outside it); reasoning off hides them (a fold of notes
    /// still showed with everything hidden, and hiding reasoning did nothing).
    @Test func notesFollowShowReasoning() {
        let withWork: [ChatTranscriptEntry] = [
            .message(message("user", time: 100, human: true, order: 1)),
            .message(message("note-1", time: 101, order: 2).markedInterim()),
            activity("work-1", time: 102),
            .message(message("note-2", time: 103, order: 4).markedInterim()),
            activity("work-2", time: 104),
            .message(message("answer", time: 110, duration: 9_000, order: 6)),
        ]
        let bothOn = ChatCompletedTurnProjection.rows(
            from: withWork, isSending: false, enabled: true,
            interimReplies: .following(.init(showReasoning: true, showToolCalls: true)))
        #expect(bothOn.map(\.id) == ["message:user", "completed-turn:message:note-1", "message:answer"])
        guard case .completed(let turn) = bothOn[1] else { Issue.record("Missing fold"); return }
        #expect(turn.entries.map(\.id) == withWork[1...4].map(\.id), "Notes and work together, in order")

        let reasoningOff = ChatCompletedTurnProjection.rows(
            from: withWork, isSending: false, enabled: true,
            interimReplies: .following(.init(showReasoning: false, showToolCalls: true)))
        #expect(reasoningOff.map(\.id) == ["message:user", "completed-turn:activity:work-1", "message:answer"])
        guard case .completed(let tools) = reasoningOff[1] else { Issue.record("Missing fold"); return }
        #expect(tools.entries.allSatisfy { if case .activity = $0 { true } else { false } }, "Only the tool calls")

        // Tool calls hidden too: the transcript has no work, and nothing is left to fold.
        let notesOnly = withWork.filter { if case .activity = $0 { false } else { true } }
        let bothOff = ChatCompletedTurnProjection.rows(
            from: notesOnly, isSending: false, enabled: true,
            interimReplies: .following(.init(showReasoning: false, showToolCalls: false)))
        #expect(bothOff.map(\.id) == ["message:user", "message:answer"])

        // A running turn keeps its notes where they are.
        let live = ChatCompletedTurnProjection.rows(from: notesOnly, isSending: true, enabled: true,
                                                    interimReplies: .hidden)
        #expect(live.map(\.id) == notesOnly.map(\.id))
    }

    @Test func persistedDurationWinsOverArrivalTimesAndSurvivesCodable() throws {
        let final = message("final", time: 90_000, duration: 20_125)
        let restored = try JSONDecoder().decode(TimelineItem.self, from: JSONEncoder().encode(final))
        #expect(restored.ordered(9).metadata.turnDurationMilliseconds == 20_125)
        let zero = message("zero", time: nil, duration: 0).ordered(10)
        let decodedZero = try JSONDecoder().decode(TimelineItem.self, from: JSONEncoder().encode(zero))
        #expect(decodedZero.metadata.turnDurationMilliseconds == 0)
        let entries: [ChatTranscriptEntry] = [
            .message(message("user", time: 100, human: true)),
            activity("work", time: 110), .message(restored),
        ]
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        guard case .completed(let turn) = rows[1] else { Issue.record("Missing fold"); return }
        #expect(turn.elapsedSeconds == 20.125)
        #expect(turn.label == "Worked for 20s")
        #expect(ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: false).count == 3)
        #expect(ChatCompletedTurnProjection.rows(from: entries, isSending: true, enabled: true).count == 3)
    }

    @Test func hiddenTerminalActivitySuppliesDurationAcrossFoldToggle() {
        let entries: [ChatTranscriptEntry] = [
            .message(message("user", time: 100, human: true, order: 1)),
            activity("work", time: 101),
            .message(message("final", time: 90_000, order: 4)),
        ]
        let terminal = ChatActivityEvent(
            eventID: "reason-terminal-0001", sessionID: "session", turnID: "turn-0001",
            kind: .reasoning, lifecycle: .succeeded, title: "Reasoning",
            summary: "Response ready", detail: nil, occurredAt: 120,
            durationMilliseconds: 20_125, sourceOrder: 2
        )
        var ledger = ChatActivityLedger(sessionID: "session", events: [terminal])
        _ = ledger.receive(terminal)
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true,
                                                    activityEvents: ledger.allEvents)
        guard case .completed(let turn) = rows[1] else { Issue.record("Missing fold"); return }
        #expect(turn.elapsedSeconds == 20.125)
        #expect(!terminal.isPresentable)
        #expect(ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: false,
                                                 activityEvents: ledger.allEvents).count == 3)
    }

    @Test func missingTimestampsDoNotBecomeZeroOrSyntheticActivityDuration() {
        let entries: [ChatTranscriptEntry] = [
            .message(message("user", time: nil, human: true)),
            .activity(ChatActivityTurn(id: "history-group", events: [ChatActivityEvent(
                eventID: "history-tool", sessionID: "session", turnID: "history-turn",
                kind: .tool, lifecycle: .succeeded, title: "Tool", summary: nil, detail: nil,
                occurredAt: 42, toolCallID: "call-1"
            )])),
            .message(message("interim", time: nil)), .message(message("final", time: nil)),
        ]
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        guard case .completed(let turn) = rows[1] else { Issue.record("Missing fold"); return }
        #expect(turn.elapsedSeconds == nil)
        // No real time: it says what the turn did, never a bare "Done".
        #expect(turn.label == "Called a tool")
        #expect(ChatCompletedTurn(id: "zero", entries: [], elapsedSeconds: 0).label == "Worked for less than a second")
    }

    @Test func legacyPersistedTimestampsExcludeIdleBetweenTurns() {
        let entries: [ChatTranscriptEntry] = [
            .message(message("user1", time: 100, human: true)),
            activity("work1", time: 110), .message(message("final1", time: 120.25)),
            .message(message("user2", time: 90_000, human: true)),
            activity("work2", time: 90_001), .message(message("final2", time: 90_002)),
        ]
        let durations = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true).compactMap { row -> TimeInterval? in
            guard case .completed(let turn) = row else { return nil }
            return turn.elapsedSeconds
        }
        #expect(durations == [20.25, 2])
    }

    @Test func verifierFollowupKeepsEveryMessageVisibleWithOneFold() {
        let entries: [ChatTranscriptEntry] = [
            .message(message("user", time: 100, human: true)),
            .message(message("I will check the configuration.", time: 101)),
            activity("inspection"), activity("inspection-second"),
            .message(message("Use the staged rollout. The existing clients need the compatibility flag.", time: 105)),
            activity("verifier", time: 106),
            .message(message("Verification confirmed that recommendation.", time: 110, duration: 10_000)),
        ]
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        #expect(visibleIDs(rows) == entries.compactMap { entry in
            guard case .message(let item) = entry else { return nil as String? }
            return item.id
        })
        // One fold holds all of the turn's work, in order, where the work began;
        // the middle answer and the final reply stay outside it.
        #expect(expandedIDs(rows) == ["message:user", "message:I will check the configuration.",
                                      "activity:inspection", "activity:inspection-second", "activity:verifier",
                                      entries[4].id, entries[6].id])
        let folds = rows.compactMap { row -> ChatCompletedTurn? in
            guard case .completed(let turn) = row else { return nil }
            return turn
        }
        #expect(folds.count == 1)
        #expect(folds.first?.entries.count == 3)
        #expect(folds.map(\.label) == ["Worked for 10s"])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }

    @Test func workOnBothSidesOfInterimMessagesFoldsOnceInOrder() {
        let entries: [ChatTranscriptEntry] = [
            .message(message("user", time: 100, human: true)),
            activity("first"),
            .message(message("interim one", time: 102)),
            activity("second"),
            .message(message("interim two", time: 104)),
            activity("third"),
            .message(message("final", time: 108, duration: 8_000)),
        ]
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        #expect(rows.map(\.id) == ["message:user", "completed-turn:activity:first",
                                    "message:interim one", "message:interim two", "message:final"])
        guard case .completed(let fold)? = rows.first(where: { if case .completed = $0 { true } else { false } }) else {
            Issue.record("Expected one fold")
            return
        }
        #expect(fold.label == "Worked for 8s")
        // Unfolded, each folder is as it was during the turn, in order.
        #expect(fold.expandedEntries.map(\.id) == ["activity:first", "activity:second", "activity:third"])
    }

    @Test func backToBackReasoningSharesOneThinkingRow() {
        func event(_ id: String, _ kind: ChatActivityKind, running: Bool = false, ms: Int? = 2_000) -> ChatActivityEvent {
            ChatActivityEvent(eventID: id, sessionID: "session", turnID: "turn", kind: kind,
                              lifecycle: running ? .running : .succeeded, title: id, summary: nil,
                              detail: kind == .reasoning ? "Thought \(id)" : nil, occurredAt: 0,
                              durationMilliseconds: kind == .reasoning ? ms : nil,
                              toolCallID: kind == .tool ? "call-\(id)" : nil)
        }
        let turn = ChatActivityTurn(id: "turn", events: [
            event("r1", .reasoning), event("r2", .reasoning), event("t1", .tool),
            event("r3", .reasoning), event("r4", .reasoning, running: true),
        ])
        let segments = ChatActivityTurnPresentation(turn: turn).segments
        #expect(segments.count == 3)
        guard segments.count == 3, case .thinking(let first) = segments[0], case .workTrail = segments[1],
              case .thinking(let last) = segments[2] else {
            Issue.record("Expected thinking groups")
            return
        }
        #expect(first.map(\.eventID) == ["r1", "r2"])
        #expect(ChatActivityPresentation.thinkingPhase(for: first) == .thought(elapsed: 4))
        #expect(BighelpActivitySummary.label(for: ChatActivityPresentation.thinkingPhase(for: first)) == "Thought for 4s")
        #expect(ChatActivityPresentation.thinkingPhase(for: last) == .thinking)
        #expect(BighelpActivitySummary.label(for: ChatActivityPresentation.thinkingPhase(for: [
            event("a", .reasoning), event("b", .reasoning, ms: nil),
        ])) == "Thought process")
        #expect(ChatActivityPresentation.thinkingNote(for: first) == "Thought r1\n\nThought r2")

        // The timeline draws each group as one row.
        let rows = ChatCanvasTranscriptProjection.rows(from: [.entry(.activity(turn))],
                                                       disclosures: ChatActivityDisclosureStore())
        let thinkingRows = rows.filter { $0.id.contains("card:") }
        #expect(thinkingRows.count == 2)
    }

    @Test func aThinkingGroupRemembersItsOpenStateAsItGrows() {
        func reasoning(_ id: String, running: Bool) -> ChatActivityEvent {
            ChatActivityEvent(eventID: id, sessionID: "session", turnID: "turn", kind: .reasoning,
                              lifecycle: running ? .running : .succeeded, title: id, summary: nil,
                              detail: id, occurredAt: 0)
        }
        let store = ChatActivityDisclosureStore()
        let one = [reasoning("a", running: true)]
        #expect(store.isExpanded(reasoning: one), "Open while thinking")
        store.setExpanded(false, reasoning: one)
        let two = one + [reasoning("b", running: true)]
        #expect(!store.isExpanded(reasoning: two), "Closing it holds as more thinking arrives")
        #expect(!store.isExpanded(reasoning: [reasoning("x", running: false)]), "Finished thinking starts closed")
    }

    @Test func expandedFoldKeepsReasoningGroupsAsTheyWere() {
        func reasoning(_ id: String) -> ChatTranscriptEntry {
            .activity(ChatActivityTurn(id: id, events: [ChatActivityEvent(
                eventID: id, sessionID: "session", turnID: "turn", kind: .reasoning, lifecycle: .succeeded,
                title: id, summary: nil, detail: "Thought \(id)", occurredAt: 0, durationMilliseconds: 1_000)]))
        }
        let entries: [ChatTranscriptEntry] = [
            .message(message("user", time: 100, human: true)), reasoning("r1"),
            .message(message("interim", time: 101)), reasoning("r2"),
            .message(message("final", time: 103, duration: 3_000)),
        ]
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        let store = ChatActivityDisclosureStore()
        store.setCompletedTurnExpanded(true, id: "completed-turn:activity:r1")
        let canvas = ChatCanvasTranscriptProjection.rows(from: rows, disclosures: store)
        // As they were in the turn: the message outside the fold had split them.
        #expect(canvas.filter { $0.id.contains("card:") }.count == 2)
    }

    @Test func streamingMessagePreventsPrematureFoldingDuringIdleGap() {
        let entries: [ChatTranscriptEntry] = [
            activity("work"),
            .message(TimelineItem(id: "streaming", role: .assistant,
                                 sender: .agent(id: "default", snapshot: .init(name: "Agent")),
                                 content: .message("Still answering"), metadata: .init(delivery: "Streaming"))),
        ]
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        #expect(rows.allSatisfy { if case .entry = $0 { true } else { false } })
        #expect(rows.map(\.id) == entries.map(\.id))
    }

    @Test func runningActivityDoesNotBecomeCompletedWork() {
        let entries: [ChatTranscriptEntry] = [activity("running", running: true), .message(message("context", time: 101))]
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        #expect(rows.allSatisfy { if case .entry = $0 { true } else { false } })
    }

    @Test func textOnlyTurnsHaveNothingToFold() {
        let entries: [ChatTranscriptEntry] = [.message(message("context", time: 100)), .message(message("answer", time: 101))]
        let rows = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        #expect(visibleIDs(rows) == ["context", "answer"])
    }

    @Test func restoredProjectionAndTogglePreserveMessagesCardsAttachmentsAndAgents() throws {
        var record = ConversationFixtures.completedTurnContextPreview
        let otherAgent = TimelineSender.agent(id: "reviewer", snapshot: .init(name: "Reviewer"))
        let attachment = try ChatAttachment(id: "fold-file-attachment-0001", fileName: "result.txt",
                                            mimeType: "text/plain", data: Data("Result".utf8))
        record.items.append(TimelineItem(id: "reviewer-card", role: .assistant, sender: otherAgent,
                                         content: .approvalRequest(.vendorFixture), metadata: .init(sourceOrder: 9)))
        record.items.append(TimelineItem(id: "reviewer-file", role: .assistant, sender: otherAgent,
                                         content: .message("Attached result"), metadata: .init(sourceOrder: 10), attachments: [attachment]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(record)
        let restored = try JSONDecoder().decode(SessionRecord.self, from: before)
        func project(_ session: SessionRecord) -> [ChatTranscriptEntry] {
            ChatTranscriptProjection.entries(items: session.items, activityEvents: session.activityEvents,
                                             visibility: session.activityVisibility, isBotMode: false)
        }
        let entries = project(record)
        let original = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true)
        let reopened = ChatCompletedTurnProjection.rows(from: project(restored), isSending: false, enabled: true)
        #expect(original.map(\.id) == reopened.map(\.id))
        #expect(visibleIDs(reopened) == record.items.map(\.id))
        // The turn's work sits in one fold where it began; every message keeps its order.
        func isActivity(_ entry: ChatTranscriptEntry) -> Bool { if case .activity = entry { true } else { false } }
        var expected = entries.filter { !isActivity($0) }.map(\.id)
        if let firstWork = entries.firstIndex(where: isActivity) {
            expected.insert(contentsOf: entries.filter(isActivity).map(\.id), at: firstWork)
        }
        #expect(expandedIDs(reopened) == expected)
        let unfolded = ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: false)
        #expect(unfolded.map(\.id) == entries.map(\.id))
        #expect(ChatCompletedTurnProjection.rows(from: entries, isSending: false, enabled: true).map(\.id) == original.map(\.id))
        #expect(try encoder.encode(record) == before)
        #expect(restored.items.last?.attachments == [attachment])
    }

    @Test func onlyEarlierTurnFoldsWhileLatestTurnIsActive() {
        let first: [ChatTranscriptEntry] = [.message(message("first-user", time: 100, human: true)),
                                            activity("first-work"), .message(message("first-answer", time: 104))]
        let latest: [ChatTranscriptEntry] = [.message(message("second-user", time: 200, human: true)),
                                             activity("second-work"), .message(message("second-context", time: 202))]
        let rows = ChatCompletedTurnProjection.rows(from: first + latest, isSending: true, enabled: true)
        #expect(rows.filter { if case .completed = $0 { true } else { false } }.count == 1)
        #expect(Array(rows.suffix(latest.count)).map(\.id) == latest.map(\.id))
        #expect(expandedIDs(rows) == (first + latest).map(\.id))
    }

    private func visibleIDs(_ rows: [ChatTurnDisplayRow]) -> [String] {
        rows.compactMap { row in
            guard case .entry(.message(let item)) = row else { return nil }
            return item.id
        }
    }

    private func expandedIDs(_ rows: [ChatTurnDisplayRow]) -> [String] {
        rows.flatMap { row in
            switch row {
            case .entry(let entry): [entry.id]
            case .completed(let turn): turn.entries.map(\.id)
            }
        }
    }

    @Test func finalActionsUseCompactUniformGlyphsWithoutShrinkingHitTargets() {
        #expect(ChatMessageActionMetrics.symbolSize == 16)
        #expect(ChatMessageActionMetrics.spacing == 0)
        #expect(ChatMessageActionMetrics.hitTarget >= 44)
    }

    private func activity(_ id: String, time: Int = 102, running: Bool = false) -> ChatTranscriptEntry {
        .activity(ChatActivityTurn(id: id, events: [ChatActivityEvent(
            eventID: id, sessionID: "session", turnID: "turn-\(id)",
            kind: .tool, lifecycle: running ? .running : .succeeded,
            title: "Tool", summary: nil, detail: nil,
            occurredAt: time, toolCallID: "call-\(id)"
        )]))
    }

    private func message(_ id: String, time: TimeInterval?, human: Bool = false, duration: Int? = nil, order: Int? = nil) -> TimelineItem {
        TimelineItem(
            id: id, role: human ? .human : .assistant,
            sender: human ? .user(snapshot: .init(name: "You")) : .agent(id: "default", snapshot: .init(name: "Agent")),
            content: .message(id),
            metadata: .init(timestamp: time.map { Date(timeIntervalSince1970: $0) }, sourceOrder: order, turnDurationMilliseconds: duration)
        )
    }
}
