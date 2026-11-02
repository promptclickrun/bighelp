import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ChatInterimRepliesTests {
    private let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery"))

    private func human(_ id: String) -> ChatTranscriptEntry {
        .message(TimelineItem(id: id, role: .human, sender: .user(snapshot: .init(name: "You")),
                              content: .message("Question"), metadata: .init()))
    }

    private func reply(_ id: String, _ text: String = "Reply") -> ChatTranscriptEntry {
        .message(TimelineItem(id: id, role: .assistant, sender: agent, content: .message(text), metadata: .init()))
    }

    private func work(_ id: String) -> ChatTranscriptEntry {
        .activity(ChatActivityTurn(id: id, events: [ChatActivityEvent(
            eventID: id, sessionID: "s", turnID: "t", kind: .tool, lifecycle: .succeeded,
            title: "Tool", summary: nil, detail: nil, occurredAt: 1)]))
    }

    private func interimIDs(_ entries: [ChatTranscriptEntry]) -> [String] {
        entries.compactMap { entry in
            guard case .message(let item) = entry, item.metadata.isInterimReply else { return nil }
            return item.id
        }
    }

    @Test func inAFinishedTurnOnlyTheLastReplyIsTheAnswer() {
        let entries = [human("q"), reply("a"), work("w1"), reply("b"), work("w2"), reply("answer"), work("w3")]
        let marked = ChatInterimReplies.marking(entries, isSending: false, isBotMode: false)
        #expect(interimIDs(marked) == ["a", "b"])
    }

    @Test func whileReplyingAMessageTurnsInterimOnceMoreWorkFollows() {
        let streaming = [human("q1"), reply("done"), human("q2"), reply("a"), work("w"), reply("latest")]
        #expect(interimIDs(ChatInterimReplies.marking(streaming, isSending: true, isBotMode: false)) == ["a"])
        let working = [human("q"), reply("a"), work("w")]
        #expect(interimIDs(ChatInterimReplies.marking(working, isSending: true, isBotMode: false)) == ["a"])
    }

    @Test func earlierTurnsAndOtherContentKeepTheirLook() {
        let entries = [human("q1"), reply("first answer"), human("q2"), reply("empty", "  "), work("w"), reply("second answer")]
        #expect(interimIDs(ChatInterimReplies.marking(entries, isSending: false, isBotMode: false)).isEmpty)
    }

    @Test func plainMessagesInARowAreAllAnswers() {
        let entries = [human("q"), reply("a"), reply("b"), work("w"), reply("c"), reply("d")]
        // Only a message the agent kept working after is interim.
        #expect(interimIDs(ChatInterimReplies.marking(entries, isSending: false, isBotMode: false)) == ["a", "b"])
        #expect(interimIDs(ChatInterimReplies.marking([human("q"), reply("a"), reply("b")], isSending: true, isBotMode: false)).isEmpty)
    }

    /// Hermes' own answer (`message.complete`) stays the answer when work lands after it, while the
    /// turn finishes or in a turn Hermes runs with no message from the person. Notes keep their look.
    @Test func theAnswerHermesEndedATurnWithIsNeverANote() {
        func answer(_ id: String) -> ChatTranscriptEntry {
            guard case .message(let item) = reply(id) else { return reply(id) }
            return .message(item.endingTurn())
        }
        let finishing = [human("q"), reply("note"), work("w1"), answer("answer"), work("memory")]
        #expect(interimIDs(ChatInterimReplies.marking(finishing, isSending: true, isBotMode: false)) == ["note"])
        let ownTurn = [human("q"), answer("answer"), work("w2"), answer("follow-up")]
        #expect(interimIDs(ChatInterimReplies.marking(ownTurn, isSending: false, isBotMode: false)).isEmpty)
        let rows = ChatCompletedTurnProjection.rows(
            from: ChatInterimReplies.marking(ownTurn, isSending: false, isBotMode: false),
            isSending: false, enabled: true, interimReplies: .hidden, style: .card)
        #expect(rows.map(\.id) == ["message:q", "message:answer", "completed-turn:activity:w2", "message:follow-up"],
                "Both answers show, even with reasoning hidden")
    }

    @Test func roomRepliesAreEachAgentsAnswer() {
        let entries = [human("q"), reply("a"), work("w"), reply("b")]
        #expect(interimIDs(ChatInterimReplies.marking(entries, isSending: false, isBotMode: true)).isEmpty)
    }

    /// With tool calls hidden the transcript shows no work, but the agent kept
    /// working after its notes (Claude's thinking arrives blank, so the notes
    /// are the only thinking people see). Hidden work still makes them interim.
    @Test func hiddenWorkStillMarksTheNotesBeforeIt() {
        func ordered(_ id: String, _ order: Int, human: Bool = false) -> ChatTranscriptEntry {
            .message(TimelineItem(id: id, role: human ? .human : .assistant,
                                  sender: human ? .user(snapshot: .init(name: "You")) : agent,
                                  content: .message(id), metadata: .init(sourceOrder: order)))
        }
        func hiddenTool(_ id: String, _ order: Int) -> ChatActivityEvent {
            ChatActivityEvent(eventID: id, sessionID: "s", turnID: "t", kind: .tool, lifecycle: .succeeded,
                              title: "Tool", summary: nil, detail: nil, occurredAt: order, sourceOrder: order)
        }
        let finished = [ordered("q1", 1, human: true), ordered("note", 2), ordered("answer", 5),
                        ordered("q2", 6, human: true), ordered("plain", 7)]
        let hidden = [hiddenTool("t1", 3), hiddenTool("t2", 4)]
        #expect(interimIDs(ChatInterimReplies.marking(finished, isSending: false, isBotMode: false,
                                                      activityEvents: hidden)) == ["note"])
        // Live: the note turns quiet as soon as a hidden tool starts after it.
        let live = [ordered("q", 1, human: true), ordered("note", 2)]
        #expect(interimIDs(ChatInterimReplies.marking(live, isSending: true, isBotMode: false,
                                                      activityEvents: [hiddenTool("t", 3)])) == ["note"])
        // Work from another turn never reaches back into this one.
        #expect(interimIDs(ChatInterimReplies.marking(finished, isSending: false, isBotMode: false,
                                                      activityEvents: [hiddenTool("later", 8)])).isEmpty)
    }

    @Test func savedAnswerStaysVisibleAfterValidationFollowup() throws {
        guard case .message(let item) = reply("answer") else { return }
        let restored = try JSONDecoder().decode(TimelineItem.self,
            from: JSONEncoder().encode(item.endingTurn()))
        let entries = [human("q"), .message(restored), work("validation"), reply("follow-up")]
        for sending in [false, true] {
            let marked = ChatInterimReplies.marking(entries, isSending: sending, isBotMode: false)
            #expect(interimIDs(marked).isEmpty)
            for placement in [ChatInterimReplyPlacement.fold, .hidden] {
                let rows = ChatCompletedTurnProjection.rows(from: marked, isSending: sending,
                    enabled: true, interimReplies: placement, style: .card)
                #expect(rows.contains { $0.id == "message:answer" })
                #expect(rows.contains { $0.id == "message:follow-up" })
            }
        }
    }

    @Test func legacyMetadataWithoutAnswerMarkerStillDecodes() throws {
        let metadata = try JSONDecoder().decode(TimelineMetadata.self, from: Data("{}".utf8))
        #expect(!metadata.endsTurn)
    }

    @Test func invalidRecordedDurationsDoNotProtectInterimNotes() {
        for duration in [-1, 86_400_001] {
            let item = TimelineItem(id: "note", role: .assistant, sender: agent,
                content: .message("Checking"), metadata: .init(turnDurationMilliseconds: duration))
            let entries = [human("q"), .message(item), work("validation"), reply("answer")]
            #expect(interimIDs(ChatInterimReplies.marking(entries,
                isSending: false, isBotMode: false)) == ["note"])
        }
    }

    @Test func theInterimMarkIsNeverSaved() throws {
        guard case .message(let item) = reply("a") else { return }
        let data = try JSONEncoder().encode(item.markedInterim())
        let decoded = try JSONDecoder().decode(TimelineItem.self, from: data)
        #expect(!decoded.metadata.isInterimReply)
        #expect(decoded == item)
    }
}
