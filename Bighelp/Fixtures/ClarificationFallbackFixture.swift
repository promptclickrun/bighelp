#if DEBUG
import Foundation

/// Offline failure injection for the real Home/chat clarification surfaces.
@MainActor
final class ClarificationFallbackFixture: DashboardDataSource, DashboardClarificationClient, QueuedConversationClient {
    private let expiresAt: Date?
    private var failNextSend: Bool
    private var dismissed = false

    init(expired: Bool, failNextSend: Bool) {
        self.expiresAt = expired ? .now.addingTimeInterval(-60) : nil
        self.failNextSend = failNextSend
    }

    func loadDashboard() async throws -> DashboardSnapshot {
        let request = DashboardClarificationRequest(
            eventID: "clarification-fallback-fixture",
            requestID: "clarification-fallback-request",
            sessionID: "demo-finance",
            question: "Which release channel should I use?",
            choices: ["TestFlight", "App Store"],
            allowsCustomResponse: true,
            isMultiSelect: false,
            expiresAt: expiresAt
        )
        return DashboardSnapshot(inbox: [], attentionItems: dismissed ? [] : [
            DashboardAttentionItem(id: request.eventID, title: "Clarification needed", detail: request.question,
                                   urgency: .important, sessionID: request.sessionID,
                                   interaction: .clarification(request), createdAt: .now)
        ], completedItems: [], agents: [])
    }

    func respond(to request: DashboardClarificationRequest, response: String) async throws -> DashboardClarificationReceipt {
        throw BighelpLinkWorkspaceClientError.remote(
            status: .conflict, code: "workspace_conflict",
            message: "The workspace changed. Refresh and try again."
        )
    }

    func dismissDashboardEvent(id: String) async throws { dismissed = true }

    func submit(message: String, attachments: [ChatAttachment], conversationID: String) async throws {
        guard conversationID == "demo-finance" else { throw DashboardFixtureError.unavailable }
        if failNextSend {
            failNextSend = false
            throw DashboardFixtureError.unavailable
        }
    }

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        try await submit(message: message, attachments: [], conversationID: conversationID)
        return ConversationResponse(items: [])
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        throw DashboardFixtureError.unavailable
    }
}
#endif
