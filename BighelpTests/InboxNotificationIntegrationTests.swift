import Foundation
import Testing
@testable import Bighelp

@MainActor
struct InboxNotificationIntegrationTests {
    @Test func homeInboxUsesOnlySwipeAndOverflowManagementWithoutAnExposedRemoveButton() {
        #expect(DashboardInboxManagementPresentation.showsBulkRemoveControl == false)
        #expect(DashboardInboxManagementPresentation.menuActionTitles == [
            "Mark read",
            "Pin",
            "Start a chat about this",
            "Delete",
        ])
        #expect(DashboardInboxManagementPresentation.showsDestructiveSwipeLabel == false)
    }

    @Test func notificationFocusWaitsForThePersistedInboxItemToLoad() async {
        let model = DashboardModel(source: NotificationDashboardSource())

        model.requestUpdateFocus(id: "channel.message:cold-launch")
        #expect(model.focusedUpdateID == nil)

        await model.load()
        #expect(model.focusedUpdateID == "channel.message:cold-launch")
    }

    @Test func clarifyNotificationOpensTheMatchingNeedsFromYouCard() async {
        let source = ClarifyNotificationDashboardSource(includesQuestion: true)
        let model = DashboardModel(source: source)

        await model.openNotification(eventID: source.eventID, eventType: "attention.required")

        #expect(model.focusedAttentionID == source.eventID)
        #expect(model.notificationOpenMessage == nil)
    }

    @Test func answeredClarifyNotificationStaysOnHomeAndExplainsThatItWasAnswered() async {
        let source = ClarifyNotificationDashboardSource(includesQuestion: false)
        let model = DashboardModel(source: source)

        await model.openNotification(eventID: source.eventID, eventType: "attention.required")

        #expect(model.focusedAttentionID == nil)
        #expect(model.notificationOpenMessage == "This question has already been answered")
    }

    @Test func unavailableNotificationDestinationFailsClosedWithoutSelectingAStaleCard() async {
        let model = DashboardModel(source: ClarifyNotificationDashboardSource(includesQuestion: false))

        await model.openNotification(
            eventID: "channel.message:missing-session",
            eventType: "channel.message"
        )

        #expect(model.focusedUpdateID == nil)
        #expect(model.focusedAttentionID == nil)
        #expect(model.notificationOpenMessage == "This item is no longer available")
    }

    @Test func aPersistedCardIsPrimaryOnHomeAndInboxInsteadOfDuplicatedFallbackText() throws {
        let card = try GenerativeUICard.decode([
            "schema": "loopdy.generative_ui",
            "version": 1,
            "component": "summary",
            "title": "Morning briefing",
            "body": "Three priorities are ready.",
        ])
        let item = DashboardInboxItem(
            id: "channel.message:card",
            title: "Morning briefing",
            detail: "Morning briefing",
            agentName: "Juno",
            status: "Now",
            card: card
        )

        #expect(InboxUpdateContentPolicy.primaryContent(for: item) == .generativeUICard)
    }

    @Test func scheduledChannelCardBeyondTheFirstFiveSurvivesHomeProjectionAndFocus() async throws {
        let card = try GenerativeUICard.decode([
            "schema": "loopdy.generative_ui",
            "version": 1,
            "component": "summary",
            "title": "Scheduled morning briefing",
            "body": "Three priorities are ready.",
        ])
        let source = NotificationDashboardSource(focusedCard: card)
        let model = DashboardModel(source: source)

        model.requestUpdateFocus(id: "channel.message:scheduled-card")
        await model.load()

        let focusedItem = try #require(model.snapshot?.inbox.last)
        #expect(model.snapshot?.inbox.count == 7)
        #expect(focusedItem.id == "channel.message:scheduled-card")
        #expect(focusedItem.card == card)
        #expect(InboxUpdateContentPolicy.primaryContent(for: focusedItem) == .generativeUICard)
        #expect(model.focusedUpdateID == focusedItem.id)
    }

    @Test func notificationAndForegroundRefreshShareOneFetchAndRevealTheNewCard() async throws {
        let source = SuspendedExternalRefreshDashboardSource()
        let model = DashboardModel(source: source)
        await model.load()

        let notificationRefresh = Task { await model.refreshAfterExternalChange() }
        await source.waitUntilRefreshStarts()
        let foregroundRefresh = Task { await model.refreshAfterExternalChange() }
        await Task.yield()

        #expect(source.loadCount == 2)

        let card = try GenerativeUICard.decode([
            "schema": "loopdy.generative_ui",
            "version": 1,
            "component": "summary",
            "title": "New scheduled briefing",
            "body": "Delivered while bighelp was away.",
        ])
        source.finishRefresh(card: card)
        await notificationRefresh.value
        await foregroundRefresh.value

        #expect(source.loadCount == 2)
        #expect(model.snapshot?.inbox.first?.card == card)
    }
}

@MainActor
private final class SuspendedExternalRefreshDashboardSource: DashboardDataSource {
    private(set) var loadCount = 0
    private var refreshContinuation: CheckedContinuation<DashboardSnapshot, Never>?

    func loadDashboard() async throws -> DashboardSnapshot {
        loadCount += 1
        guard loadCount > 1 else { return Self.snapshot(card: nil) }
        return await withCheckedContinuation { continuation in
            refreshContinuation = continuation
        }
    }

    func waitUntilRefreshStarts() async {
        while refreshContinuation == nil { await Task.yield() }
    }

    func finishRefresh(card: GenerativeUICard) {
        refreshContinuation?.resume(returning: Self.snapshot(card: card))
        refreshContinuation = nil
    }

    private static func snapshot(card: GenerativeUICard?) -> DashboardSnapshot {
        DashboardSnapshot(
            inbox: card.map { card in
                [DashboardInboxItem(
                    id: "channel.message:new-card",
                    title: "New scheduled briefing",
                    detail: "Delivered while bighelp was away.",
                    agentName: "Juno",
                    status: "Now",
                    card: card
                )]
            } ?? [],
            attentionItems: [],
            completedItems: [],
            agents: []
        )
    }
}

@MainActor
private struct NotificationDashboardSource: DashboardDataSource {
    var focusedCard: GenerativeUICard?

    init(focusedCard: GenerativeUICard? = nil) {
        self.focusedCard = focusedCard
    }

    func loadDashboard() async throws -> DashboardSnapshot {
        let inbox: [DashboardInboxItem]
        if let focusedCard {
            inbox = (0..<6).map { index in
                DashboardInboxItem(
                    id: "channel.message:update-\(index)",
                    title: "Update \(index)",
                    detail: "Scheduled channel update",
                    agentName: "Juno",
                    status: "Now"
                )
            } + [DashboardInboxItem(
                id: "channel.message:scheduled-card",
                title: "Scheduled morning briefing",
                detail: "Scheduled morning briefing",
                agentName: "Juno",
                status: "Now",
                card: focusedCard
            )]
        } else {
            inbox = [DashboardInboxItem(
                id: "channel.message:cold-launch",
                title: "Forecast ready",
                detail: "Open the forecast",
                agentName: "Juno",
                status: "Now"
            )]
        }
        return DashboardSnapshot(
            inbox: inbox,
            attentionItems: [],
            completedItems: [],
            agents: []
        )
    }
}

@MainActor
private struct ClarifyNotificationDashboardSource: DashboardDataSource {
    let includesQuestion: Bool
    let eventID = "attention.required:clarify-notification"

    func loadDashboard() async throws -> DashboardSnapshot {
        let request = DashboardClarificationRequest(
            eventID: eventID,
            requestID: "clarify-notification-request",
            sessionID: "session-clarify-notification",
            question: "Which environment should I use?",
            choices: ["Staging", "Production"],
            allowsCustomResponse: true,
            isMultiSelect: false,
            expiresAt: nil
        )
        return DashboardSnapshot(
            inbox: [],
            attentionItems: includesQuestion ? [DashboardAttentionItem(
                id: eventID,
                title: "Clarification needed",
                detail: request.question,
                urgency: .important,
                sessionID: request.sessionID,
                interaction: .clarification(request)
            )] : [],
            completedItems: [],
            agents: []
        )
    }
}
