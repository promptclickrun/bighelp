#if DEBUG
import Foundation

/// Credential-free acceptance data for the production Home composition.
@MainActor
final class HomeWorkAcceptanceFixture: DashboardDataSource, DashboardClarificationClient {
    static let activeID = "demo-home-work"
    static let clarifyID = "demo-home-clarify"
    private let expiresAt: Date?
    private var dismissed = false
    private weak var catalog: SessionCatalogStore?
    private var activityTask: Task<Void, Never>?

    init(expires: Bool = false) {
        expiresAt = expires ? Date.now.addingTimeInterval(20) : nil
    }

    static var records: [SessionRecord] {
        [
            SessionRecord(id: activeID, kind: .direct, agentIDs: ["finance"], title: "Improve the Home screen",
                items: [TimelineItem(id: "home-context", role: .human, sender: .user(snapshot: .init(name: "You")),
                    content: .message("Original Home improvement conversation"), metadata: .init(delivery: "Delivered"))],
                activityEvents: [activity(kind: .tool, occurredAt: Int(Date.now.timeIntervalSince1970))], isActive: true,
                createdAt: Date.now.addingTimeInterval(-600), hasAcceptedMessage: true),
            SessionRecord(id: clarifyID, kind: .direct, agentIDs: ["finance"], title: "Choose a release channel",
                items: [TimelineItem(id: "release-context", role: .human, sender: .user(snapshot: .init(name: "You")),
                    content: .message("Original release conversation"), metadata: .init(delivery: "Delivered"))],
                isActive: true, createdAt: Date.now.addingTimeInterval(-500), hasAcceptedMessage: true),
        ]
    }

    func attach(catalog: SessionCatalogStore, featureStore: ShellFeatureStore) {
        self.catalog = catalog
        activityTask = Task { @MainActor [weak featureStore] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            featureStore?.acceptExternalActivity(Self.activity(kind: .subagent, occurredAt: Int(Date.now.timeIntervalSince1970)))
        }
    }

    private static func activity(kind: ChatActivityKind, occurredAt: Int) -> ChatActivityEvent {
        ChatActivityEvent(eventID: "home-fixture-\(kind.rawValue)", sessionID: activeID, turnID: "home-fixture-turn",
            kind: kind, lifecycle: .running, title: "Private implementation detail", summary: nil, detail: nil,
            occurredAt: occurredAt, toolCallID: kind == .tool ? "home-tool" : nil,
            toolName: kind == .tool ? "terminal" : nil, subagentID: kind == .subagent ? "home-worker" : nil)
    }

    func loadDashboard() async throws -> DashboardSnapshot {
        let request = DashboardClarificationRequest(eventID: "home-clarify-card", requestID: "home-clarify-request",
            sessionID: Self.clarifyID, question: "Which release channel should I use?",
            choices: ["TestFlight", "App Store"], allowsCustomResponse: true, isMultiSelect: false, expiresAt: expiresAt)
        let completions = [
            ("user-done", "session.completed", "Plan the next release"),
            ("cron-done", "job.completed", "Morning briefing"),
            ("child-done", "delegation.completed", "Review accessibility"),
        ].enumerated().map { index, entry in
            DashboardCompletionProjection.make(id: entry.0, eventType: entry.1, detail: ["title": entry.2],
                agentName: "Avery", createdAt: Date.now.addingTimeInterval(-Double(index + 1) * 60),
                completedLabel: "Completed recently", fallbackTitle: entry.2, fallbackDetail: "Finished")
        }
        return DashboardSnapshot(inbox: [], attentionItems: dismissed ? [] : [
            DashboardAttentionItem(id: request.eventID, title: "Clarification needed", detail: request.question,
                urgency: .important, sessionID: Self.clarifyID, agentID: "finance",
                interaction: .clarification(request), createdAt: Date.now.addingTimeInterval(-30))
        ], completedItems: completions, agents: [])
    }

    func respond(to request: DashboardClarificationRequest, response: String) async throws -> DashboardClarificationReceipt {
        guard request.requestID == "home-clarify-request", request.sessionID == Self.clarifyID else {
            throw DashboardFixtureError.unavailable
        }
        dismissed = true
        return DashboardClarificationReceipt(eventID: request.eventID, requestID: request.requestID)
    }

    func dismissDashboardEvent(id: String) async throws { if id == "home-clarify-card" { dismissed = true } }
    func dismissDashboardEvents(types: [String], createdBefore: Date) async throws { dismissed = true }
}
#endif
