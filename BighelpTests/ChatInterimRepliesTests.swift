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

    /// Simple Bot mode: a turn's interim messages go under one "{Agent}'s reasoning" row where the first
    /// was, shown with Show reasoning on and hidden with it off. The message that ends the turn is its
    /// answer and always shows.
    @Test func simpleBotChatsGroupInterimMessagesUnderTheBotsReasoning() {
        func ids(_ rows: [ChatTurnDisplayRow]) -> [String] { rows.map(\.id) }
        let entries = [human("q"), reply("a"), work("w1"), reply("b"), work("w2"), reply("answer")]
        let rows = ChatCompletedTurnProjection.rows(
            from: ChatInterimReplies.marking(entries, isSending: false, isBotMode: false),
            isSending: false, enabled: false, interimReplies: .inline)

        let shown = ChatInterimReplies.groupingForSimpleBots(rows, agentName: "Avery", showsReasoning: true)
        #expect(ids(shown) == ["message:q", "reasoning:a", "activity:w1", "activity:w2", "message:answer"])
        guard case .reasoning(let group)? = shown.first(where: { $0.id == "reasoning:a" }) else {
            Issue.record("No reasoning row")
            return
        }
        #expect(group.agentName == "Avery")
        #expect(group.entries.map(\.id) == ["message:a", "message:b"])

        let hidden = ChatInterimReplies.groupingForSimpleBots(rows, agentName: "Avery", showsReasoning: false)
        #expect(ids(hidden) == ["message:q", "activity:w1", "activity:w2", "message:answer"],
                "The answer shows even with reasoning hidden")

        // While the bot works, its newest message stays a message until more work follows it.
        let working = ChatCompletedTurnProjection.rows(
            from: ChatInterimReplies.marking([human("q"), reply("a"), work("w"), reply("latest")],
                                             isSending: true, isBotMode: false),
            isSending: true, enabled: false, interimReplies: .inline)
        #expect(ids(ChatInterimReplies.groupingForSimpleBots(working, agentName: "Avery", showsReasoning: false))
                == ["message:q", "activity:w", "message:latest"])
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
