import Foundation
import Testing
@testable import Bighelp

/// A coding session on Work reads "Needs you" from the dashboard's list too, as Today's Needs you
/// does, so a session whose chat isn't open is never shown as Done or Working while it waits.
@MainActor
struct CodeSessionStatusReaderTests {
    private func approval(session: String?) -> DashboardAttentionItem {
        DashboardAttentionItem(
            id: "event-1", title: "Approve session action", detail: "Hermes needs authorization", urgency: .important,
            approvalID: "approval-1", sessionID: session, agentID: "coder",
            interaction: .approval(DashboardApprovalRequest(
                eventID: "event-1", approvalID: "approval-1", allowedDecisions: [.session],
                expiresAt: Date(timeIntervalSince1970: 2_000_000_000))))
    }

    private func question(session: String) -> DashboardAttentionItem {
        DashboardAttentionItem(
            id: "event-2", title: "Hermes needs guidance", detail: "Which branch?", urgency: .needsReview,
            sessionID: session, agentID: "coder",
            interaction: .clarification(DashboardClarificationRequest(
                eventID: "event-2", requestID: "request-2", sessionID: session, question: "Which branch?",
                choices: ["main", "next"], allowsCustomResponse: false, isMultiSelect: false, expiresAt: nil)))
    }

    @Test func aSessionWithAWaitingApprovalOrQuestionNeedsYou() {
        let items = [approval(session: "s-1"), question(session: "s-2")]
        #expect(CodeChatStatusReader.waitingAsk(for: "s-1", in: items) == "Approve a command")
        #expect(CodeChatStatusReader.waitingAsk(for: "s-2", in: items) == "Answer a question")
    }

    @Test func otherSessionsAndPlainNoticesDoNotWait() {
        let notice = DashboardAttentionItem(id: "n", title: "Review", detail: "", urgency: .needsReview,
                                            sessionID: "s-3", agentID: "coder")
        let items = [approval(session: "s-1"), approval(session: nil), notice]
        #expect(CodeChatStatusReader.waitingAsk(for: "s-3", in: items) == nil)
        #expect(CodeChatStatusReader.waitingAsk(for: "s-9", in: items) == nil)
        #expect(CodeChatStatusReader.waitingAsk(for: "s-1", in: []) == nil)
    }
}
