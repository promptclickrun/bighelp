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

    @Test func roomRepliesAreEachAgentsAnswer() {
        let entries = [human("q"), reply("a"), work("w"), reply("b")]
        #expect(interimIDs(ChatInterimReplies.marking(entries, isSending: false, isBotMode: true)).isEmpty)
    }

    /// Simple Bot mode reads like texting: a message the agent kept working after is still a
    /// text. It never turns grey while the turn runs, and it stays when the turn ends (with
    /// Show reasoning off, the default, the full chat hides such notes).
    @Test func simpleBotChatsKeepEveryMessageAsAText() {
        func shownMessages(_ rows: [ChatTurnDisplayRow]) -> [String] {
            rows.compactMap { row in
                guard case .entry(.message(let item)) = row else { return nil }
                return item.id
            }
        }
        let entries = [human("q"), reply("a"), work("w1"), reply("b"), work("w2")]
        let full = ChatInterimReplies.marking(entries, isSending: false, isBotMode: false)
        #expect(shownMessages(ChatCompletedTurnProjection.rows(
            from: full, isSending: false, enabled: true, interimReplies: .hidden)) == ["q", "b"])

        let texts = ChatInterimReplies.marking(entries, isSending: false, isBotMode: false, isSimpleBots: true)
        #expect(interimIDs(texts).isEmpty)
        #expect(shownMessages(ChatCompletedTurnProjection.rows(
            from: texts, isSending: false, enabled: true, interimReplies: .hidden)) == ["q", "a", "b"])
        let running = [human("q"), reply("a"), work("w")]
        #expect(interimIDs(ChatInterimReplies.marking(
            running, isSending: true, isBotMode: false, isSimpleBots: true)).isEmpty)
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

    @Test func theInterimMarkIsNeverSaved() throws {
        guard case .message(let item) = reply("a") else { return }
        let data = try JSONEncoder().encode(item.markedInterim())
        let decoded = try JSONDecoder().decode(TimelineItem.self, from: data)
        #expect(!decoded.metadata.isInterimReply)
        #expect(decoded == item)
    }
}
