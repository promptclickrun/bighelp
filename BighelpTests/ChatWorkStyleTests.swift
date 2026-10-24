import Foundation
import Testing
@testable import Bighelp

/// Settings › Chat › Agent's work (`ChatWorkStyle`): how a one-to-one chat shows what its agent did.
@MainActor
struct ChatWorkStyleTests {
    private let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery"))

    private func human(_ id: String, time: TimeInterval? = nil) -> ChatTranscriptEntry {
        .message(TimelineItem(id: id, role: .human, sender: .user(snapshot: .init(name: "You")),
                              content: .message("Question"),
                              metadata: .init(timestamp: time.map { Date(timeIntervalSince1970: $0) })))
    }

    private func reply(_ id: String, _ text: String = "Reply") -> ChatTranscriptEntry {
        .message(TimelineItem(id: id, role: .assistant, sender: agent, content: .message(text), metadata: .init()))
    }

    private func toolEvent(_ id: String, running: Bool = false) -> ChatActivityEvent {
        ChatActivityEvent(eventID: id, sessionID: "s", turnID: "t", kind: .tool,
                          lifecycle: running ? .running : .succeeded, title: "Read file", summary: nil,
                          detail: nil, occurredAt: 1, toolCallID: "call-\(id)", toolName: "read_file")
    }

    private func thoughtEvent(_ id: String, _ text: String, running: Bool = false) -> ChatActivityEvent {
        ChatActivityEvent(eventID: id, sessionID: "s", turnID: "t", kind: .reasoning,
                          lifecycle: running ? .running : .succeeded, title: "Reasoning", summary: nil,
                          detail: text, occurredAt: 1)
    }

    private func tool(_ id: String, running: Bool = false) -> ChatTranscriptEntry {
        .activity(ChatActivityTurn(id: id, events: [toolEvent(id, running: running)]))
    }

    private func rows(_ entries: [ChatTranscriptEntry], isSending: Bool, style: ChatWorkStyle?,
                      folds: Bool = true, showsReasoning: Bool = true) -> [ChatTurnDisplayRow] {
        ChatCompletedTurnProjection.rows(
            from: ChatInterimReplies.marking(entries, isSending: isSending, isBotMode: false),
            isSending: isSending, enabled: folds,
            interimReplies: .following(.init(showReasoning: showsReasoning, showToolCalls: true)), style: style)
    }

    private var working: [ChatTranscriptEntry] {
        [human("q"), reply("a", "Let me check your calendar first."), tool("w1"),
         reply("b", "Thursday at 10 is free."), tool("w2", running: true)]
    }

    private var finished: [ChatTranscriptEntry] {
        [human("q"), reply("a"), tool("w1"), reply("answer")]
    }

    @Test func cardAndMinimalGatherTheRunningTurnIntoOneBlock() throws {
        for style in [ChatWorkStyle.card, .minimal] {
            let shown = rows(working, isSending: true, style: style)
            #expect(shown.map(\.id) == ["message:q", "live-work:message:q"])
            guard case .liveWork(let work)? = shown.last else {
                Issue.record("No live block for \(style)")
                continue
            }
            #expect(work.style == style)
            #expect(work.entries.map(\.id) == ["message:a", "activity:w1", "message:b", "activity:w2"],
                    "The work stays in the order it happened")
            #expect(work.stepCount == 2)
        }
        // The answer streams under the block, as itself, and the block says what the agent did.
        let answering = rows(Array(working.dropLast() + [tool("w2"), reply("answer")]), isSending: true, style: .card)
        #expect(answering.map(\.id) == ["message:q", "live-work:message:q", "message:answer"])
        guard case .liveWork(let work)? = answering.dropLast().last else {
            Issue.record("No live block while answering")
            return
        }
        #expect(work.isAnswering)
        #expect(!ChatLiveWorkPresentation(entries: work.entries).phase(waiting: nil, isAnswering: true).isLive)
        let canvas = ChatCanvasTranscriptProjection.rows(from: answering, disclosures: ChatActivityDisclosureStore(),
                                                          isSending: true)
        #expect(ChatCanvasTranscriptProjection.activeLoaderID(in: canvas, isSending: true) == nil,
                "Nothing plays once the work is done")
    }

    @Test func fullAndGroupChatsKeepTheRunningTurnInPlace() {
        for style in [ChatWorkStyle.full, nil] {
            #expect(rows(working, isSending: true, style: style).map(\.id)
                    == ["message:q", "message:a", "activity:w1", "message:b", "activity:w2"])
        }
    }

    @Test func aFinishedTurnFoldsWhereItsStyleSays() throws {
        for style in [ChatWorkStyle.card, .full] {
            let shown = rows(finished, isSending: false, style: style)
            #expect(shown.map(\.id) == ["message:q", "completed-turn:message:a", "message:answer"])
            guard case .completed(let turn)? = shown.first(where: { $0.id.hasPrefix("completed-turn") }) else {
                Issue.record("No fold for \(style)")
                continue
            }
            #expect(turn.style == style)
        }
        // Minimal: a receipt under the answer.
        #expect(rows(finished, isSending: false, style: .minimal).map(\.id)
                == ["message:q", "message:answer", "completed-turn:message:a"])
    }

    @Test func withFoldingOffFinishedWorkStaysOpenAndTheRunningTurnStillGathers() {
        #expect(rows(finished, isSending: false, style: .card, folds: false).map(\.id)
                == ["message:q", "message:a", "activity:w1", "message:answer"])
        #expect(rows(working, isSending: true, style: .minimal, folds: false).map(\.id)
                == ["message:q", "live-work:message:q"])
    }

    @Test func hiddenReasoningLeavesTheNotesOutOfTheBlock() throws {
        let shown = rows(working, isSending: true, style: .card, showsReasoning: false)
        guard case .liveWork(let work)? = shown.last else {
            Issue.record("No live block")
            return
        }
        #expect(work.entries.map(\.id) == ["activity:w1", "activity:w2"])
    }

    @Test func aLiveBlockOpensItsStepsBelowItWithOneLoader() {
        let store = ChatActivityDisclosureStore()
        store.configure(style: .card)
        let shown = rows(working, isSending: true, style: .card)
        func describe(_ rows: [ChatCanvasRow]) -> [String] {
            rows.compactMap { row in
                switch row {
                case .activityDetail(let event): "step:\(event.eventID)"
                case .workTrailEnd: nil
                default: row.id
                }
            }
        }
        let closed = ChatCanvasTranscriptProjection.rows(from: shown, disclosures: store, isSending: true)
        #expect(describe(closed) == ["message:q", "live-work:message:q"])
        #expect(ChatCanvasTranscriptProjection.hasLiveWork(in: closed))
        #expect(ChatCanvasTranscriptProjection.activeLoaderID(in: closed, isSending: true) == "live-work:message:q")

        store.setWorkExpanded(true, id: "live-work:message:q")
        let open = ChatCanvasTranscriptProjection.rows(from: shown, disclosures: store, isSending: true)
        #expect(describe(open) == ["message:q", "live-work:message:q", "message:a", "step:w1", "message:b", "step:w2"])

        let done = ChatCanvasTranscriptProjection.rows(from: rows(finished, isSending: false, style: .card),
                                                        disclosures: store)
        #expect(!ChatCanvasTranscriptProjection.hasLiveWork(in: done))
    }

    @Test func fullOpensEveryFolderAndThoughtAndATapStillWins() {
        let store = ChatActivityDisclosureStore()
        let trail = ChatActivityTurn(id: "w", events: [toolEvent("w")])
        let thinking = [thoughtEvent("r", "Compare the two options.")]
        #expect(!store.isExpanded(trail, isLive: false))
        #expect(!store.isExpanded(reasoning: thinking))

        store.configure(style: .full)
        #expect(store.isExpanded(trail, isLive: false))
        #expect(store.isExpanded(reasoning: thinking))
        store.setExpanded(false, for: trail)
        #expect(!store.isExpanded(trail, isLive: false), "A tap still wins")

        store.configure(style: .card)
        #expect(!store.isExpanded(reasoning: thinking))
        #expect(store.isExpanded(ChatActivityTurn(id: "live", events: [toolEvent("live", running: true)]),
                                 isLive: true), "A group chat's live folder still opens")
    }

    @Test func theLiveBlockSaysWhatTheAgentIsDoingNow() {
        let running = ChatLiveWorkPresentation(entries: [
            reply("a", "Let me check your calendar first."), tool("w1"),
            .activity(ChatActivityTurn(id: "r", events: [
                thoughtEvent("r1", "**Finding a free slot**\nTuesday is full."),
                thoughtEvent("r2", "Thursday works."),
            ])),
            reply("b", "Thursday at 10 is free."), tool("w2", running: true),
        ])
        #expect(running.lines.map(\.kind) == [.note, .step, .thought, .note, .step],
                "Back-to-back thinking is one line")
        #expect(running.latestNote == "Thursday at 10 is free.")
        guard case .working = running.phase(waiting: nil) else {
            Issue.record("A running tool is the current step")
            return
        }
        #expect(running.phase(waiting: .approval) == .waitingForApproval(label: ChatActivityWaiting.approval.label))

        let thinking = ChatLiveWorkPresentation(entries: [
            .activity(ChatActivityTurn(id: "r", events: [thoughtEvent("r1", "**Finding a free slot**", running: true)])),
        ])
        #expect(thinking.phase(waiting: nil) == .thinking)
        #expect(ChatLiveWorkPresentation.preview("### Step 1\n\nChecking **the source** and `ids`.\n> Quoted")
                == "Step 1\nChecking **the source** and ids.\nQuoted", "Markdown marks stay out of the preview")
        #expect(thinking.title == "Finding a free slot")
        #expect(ChatLiveWorkPresentation(entries: [tool("w1")]).phase(waiting: nil) == .thinking,
                "Between steps the agent is thinking")
    }
}
