import Foundation
import Testing
@testable import Bighelp

@MainActor
struct ChatMessageGroupingTests {
    private func message(_ id: String, _ role: TimelineRole, at timestamp: Date? = nil) -> ChatCanvasRow {
        let sender: TimelineSender = role == .human
            ? .user(snapshot: .init(name: "Sam"))
            : .agent(id: "juno", snapshot: .init(name: "Juno"))
        return .transcript(.entry(.message(TimelineItem(
            id: id, role: role, sender: sender, content: .message("text \(id)"),
            metadata: .init(delivery: nil, timestamp: timestamp)
        ))))
    }

    @Test func onlyTheLastBubbleInASameSenderRunKeepsItsTail() {
        let rows = [
            message("u1", .human), message("u2", .human), message("u3", .human),
            message("a1", .assistant), message("a2", .assistant),
            message("u4", .human), .bottom
        ]
        let grouped = ChatView.groupedMessageRowIDs(rows)
        #expect(grouped == Set([rows[0].id, rows[1].id, rows[3].id]))
    }

    /// A scheduled task's report hours after the last answer (a Bot Chat delivery) is its own
    /// message with its own time, not more of the answer above it.
    @Test func messagesFarApartInTimeAreSeparateRuns() {
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            message("u1", .human, at: morning),
            message("a1", .assistant, at: morning.addingTimeInterval(20)),
            message("a2", .assistant, at: morning.addingTimeInterval(80)),
            message("a3", .assistant, at: morning.addingTimeInterval(3.5 * 3_600)),
        ]
        #expect(ChatView.groupedMessageRowIDs(rows) == Set([rows[1].id]))
        #expect(ChatView.continuedMessageRowIDs(rows) == Set([rows[2].id]))
    }

    @Test func nonMessageRowsBreakAGroup() {
        let rows = [message("u1", .human), .divider("Bot Mode started"), message("u2", .human)]
        #expect(ChatView.groupedMessageRowIDs(rows).isEmpty)
    }
}
