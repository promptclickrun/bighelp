import Foundation
import Testing
@testable import Bighelp

@MainActor
struct DashboardModelTests {
    @Test func initialLoadWaitsForVerifiedConnectionAndThenLoadsWithoutRetry() async {
        var generation: UInt64?
        let source = ChangingDashboardSource()
        let model = DashboardModel(source: source, verifiedConnectionGeneration: { generation })

        await model.load()
        await model.refreshAfterExternalChange()
        #expect(source.loadCount == 0)
        #expect(model.state == .idle)
        #expect(model.snapshot == nil)

        generation = 1
        await model.load()
        #expect(source.loadCount == 1)
        #expect(model.state == .loaded)
        #expect(model.snapshot?.attentionItems.first?.title == "Update 1")
    }

    @Test func dashboardResponseFromReplacedConnectionCannotPublish() async {
        var generation: UInt64? = 1
        let source = InterleavedDashboardSource()
        let model = DashboardModel(source: source, verifiedConnectionGeneration: { generation })
        let loading = Task { await model.load() }
        await source.waitUntilLoadStarts(count: 1)
        generation = 2
        source.resumeLoad(at: 0, title: "Old host")
        await loading.value
        #expect(model.snapshot == nil)
        #expect(model.state == .idle)
        let replacement = Task { await model.load() }
        await source.waitUntilLoadStarts(count: 2)
        source.resumeLoad(at: 1, title: "Current host")
        await replacement.value
        #expect(model.snapshot?.attentionItems.first?.title == "Current host")
    }

    @Test func disappearingHomeDoesNotPublishCancellationAsDashboardFailure() async {
        let source = InterleavedDashboardSource()
        let model = DashboardModel(source: source)
        let loading = Task { await model.load() }
        await source.waitUntilLoadStarts(count: 1)
        loading.cancel()
        source.failLoad(at: 0, error: CancellationError())
        await loading.value
        #expect(model.state == .idle)
        #expect(model.snapshot == nil)
    }

    @Test func newerSameAccountDashboardLoadOwnsSnapshot() async {
        let source = InterleavedDashboardSource()
        let model = DashboardModel(source: source)

        let olderLoad = Task { await model.load() }
        await source.waitUntilLoadStarts(count: 1)
        let newerLoad = Task { await model.refresh() }
        await source.waitUntilLoadStarts(count: 2)

        source.resumeLoad(at: 1, title: "Newest update")
        await newerLoad.value
        source.resumeLoad(at: 0, title: "Stale update")
        await olderLoad.value

        #expect(model.snapshot?.attentionItems.map(\.title) == ["Newest update"])
    }

    @Test func supersededCleanupCannotRemoveAReplacementSignalFromTheNewerLoad() async {
        let source = InterleavedCleanupDashboardSource()
        let model = DashboardModel(source: source)

        let olderLoad = Task { await model.load() }
        await source.waitUntilCleanupStarts()
        let newerLoad = Task { await model.refresh() }
        await source.waitUntilLoadStarts(count: 2)
        await newerLoad.value

        source.finishCleanup()
        await olderLoad.value

        #expect(model.snapshot?.attentionItems.map(\.title) == ["Replacement update"])
    }

    @Test func resetInvalidatesAnInFlightRemoteLoad() async {
        let source = DeferredDashboardSource()
        let model = DashboardModel(source: source)
        let loading = Task { await model.load() }

        await source.waitUntilLoadStarts()
        model.resetForAccountBoundary()
        source.resumeLoad(with: DashboardSnapshot(
            attentionItems: [DashboardAttentionItem(
                id: "old-account-update",
                title: "Old account",
                detail: "Should not be restored",
                urgency: .important
            )],
            completedItems: [],
            agents: []
        ))
        await loading.value

        #expect(model.snapshot == nil)
        #expect(model.state == .idle)
    }

    @Test func refreshPreservesItemIdentity() async {
        let source = DashboardFixtureSource()
        let model = DashboardModel(source: source)

        await model.load()
        let ids = model.snapshot!.attentionItems.map(\.id)

        await model.refresh()

        #expect(model.snapshot!.attentionItems.map(\.id) == ids)
    }

    @Test func refreshFetchesCurrentHermesDataInsteadOfOnlyChangingTheLabel() async {
        let source = ChangingDashboardSource()
        let model = DashboardModel(source: source)

        await model.load()
        await model.refresh()

        #expect(source.loadCount == 2)
        #expect(model.snapshot?.attentionItems.first?.title == "Update 2")
    }

    @Test func refreshFailureKeepsTheLastSuccessfulDashboardVisible() async {
        let source = FlakyDashboardSource()
        let model = DashboardModel(source: source)

        await model.load()
        let snapshot = model.snapshot

        source.shouldFail = true
        await model.refresh()

        #expect(model.state == .loaded)
        #expect(model.snapshot == snapshot)
    }

    @Test func approvalResponseUsesLoadedRequestWithoutReplacingValidatedSummaryScope() async {
        let source = DashboardApprovalResponseSource()
        let model = DashboardModel(
            source: source,
            now: { Date(timeIntervalSince1970: 100) }
        )
        await model.load()

        await model.respondToApproval(itemID: source.itemID, decision: .always)

        #expect(source.loadedIDs.isEmpty)
        #expect(source.submissions.isEmpty)
        #expect(model.mutationErrorMessage == "Hermes did not offer that approval scope.")

        await model.respondToApproval(itemID: source.itemID, decision: .session)

        #expect(source.loadedIDs == [source.loaded.request.id])
        #expect(source.submissions == [DashboardApprovalResponseSource.Submission(
            request: source.loaded.request,
            decision: .session
        )])
        #expect(model.snapshot?.attentionItems.isEmpty == true)
        #expect(model.mutationErrorMessage == nil)
    }

    @Test func removingAnItemTakesItOutOfNeedsYouAndItStaysGoneAfterARefresh() async {
        let source = RemovableDashboardSource()
        let model = DashboardModel(source: source)
        await model.load()
        #expect(model.snapshot?.attentionItems.map(\.id) == ["waiting-1", "waiting-2"])

        await model.dismissAttention(id: "waiting-1")

        #expect(source.dismissedIDs == ["waiting-1"])
        #expect(model.snapshot?.attentionItems.map(\.id) == ["waiting-2"])
        #expect(model.mutationErrorMessage == nil)

        await model.refresh()
        #expect(model.snapshot?.attentionItems.map(\.id) == ["waiting-2"])
    }

    @Test func aRefusedRemovalKeepsTheItemAndSaysWhy() async {
        let source = RemovableDashboardSource()
        source.refusesDismissals = true
        let model = DashboardModel(source: source)
        await model.load()

        await model.dismissAttention(id: "waiting-1")

        #expect(model.snapshot?.attentionItems.map(\.id) == ["waiting-1", "waiting-2"])
        #expect(model.mutationErrorMessage == "That item could not be removed. Please try again.")
    }

    @Test func notificationAndForegroundRefreshShareOneFetchAndRevealTheNewItem() async {
        let source = SuspendedExternalRefreshDashboardSource()
        let model = DashboardModel(source: source)
        await model.load()

        let notificationRefresh = Task { await model.refreshAfterExternalChange() }
        await source.waitUntilRefreshStarts()
        let foregroundRefresh = Task { await model.refreshAfterExternalChange() }
        await Task.yield()

        #expect(source.loadCount == 2)

        source.finishRefresh()
        await notificationRefresh.value
        await foregroundRefresh.value

        #expect(source.loadCount == 2)
        #expect(model.snapshot?.attentionItems.map(\.id) == ["delivered-while-away"])
    }

    @Test func loadAutomaticallyRemovesExpiredDecisionRequests() async {
        let source = RetentionDashboardSource()
        let model = DashboardModel(source: source)

        await model.load()

        #expect(source.dismissedIDs == ["expired-decision"])
        #expect(model.snapshot?.attentionItems.map(\.id) == ["fresh-decision"])
    }

    @Test func loadAutomaticallyRemovesRowsForClosedSessionsEvenWhenTheyAreRecent() async {
        let source = ClosedSessionDashboardSource()
        let model = DashboardModel(source: source)

        await model.load()

        #expect(source.dismissedIDs == ["closed-decision"])
        #expect(model.snapshot?.attentionItems.map(\.id) == ["open-decision"])
    }

    @Test func terminalTurnNotificationDoesNotDismissUnprovenOrNewerSessionRows() async {
        let source = TerminalSessionDashboardSource()
        let model = DashboardModel(source: source)

        await model.load()
        await model.handleTerminalSessionEvent(
            sessionID: "terminal-session",
            eventType: "session.completed"
        )

        #expect(source.dismissedIDs.isEmpty)
        #expect(model.snapshot?.attentionItems.map(\.id) == ["terminal-decision"])
    }

    @Test func clarificationAttentionKeepsHermesQuestionChoicesCustomReplyAndDeadline() async throws {
        let expiresAt = Date(timeIntervalSince1970: 1_000)
        let request = DashboardClarificationRequest(
            eventID: "clarify-event",
            requestID: "clarify-real-id",
            sessionID: "session-clarify",
            question: "Which release channel should I use?",
            choices: ["TestFlight", "App Store"],
            allowsCustomResponse: true,
            isMultiSelect: false,
            expiresAt: expiresAt
        )
        let item = DashboardAttentionItem(
            id: request.eventID,
            title: "Hermes needs guidance",
            detail: request.question,
            urgency: .important,
            sessionID: request.sessionID,
            interaction: .clarification(request)
        )

        guard case .clarification(let projected) = item.interaction else {
            Issue.record("Clarify was flattened into a generic attention item")
            return
        }
        #expect(projected.requestID == "clarify-real-id")
        #expect(projected.question == "Which release channel should I use?")
        #expect(projected.choices == ["TestFlight", "App Store"])
        #expect(projected.allowsCustomResponse)
        #expect(projected.expiresAt == expiresAt)
        #expect(projected.isExpired(at: expiresAt.addingTimeInterval(-1)) == false)
        #expect(projected.isExpired(at: expiresAt))
    }

    @Test func clarificationCanBeResolvedFromHomeAndOnlyThenLeavesNeedsYou() async {
        let source = ClarificationDashboardSource(expiresAt: Date(timeIntervalSince1970: 2_000))
        let model = DashboardModel(
            source: source,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        await model.load()

        await model.respondToClarification(
            itemID: "clarify-event",
            response: "Use TestFlight"
        )

        #expect(source.responses == ["Use TestFlight"])
        #expect(model.snapshot?.attentionItems.isEmpty == true)
        #expect(model.mutationErrorMessage == nil)
    }

    @Test func expiredClarificationLeavesNeedsYouWithoutSubmittingAResponse() async {
        let source = ClarificationDashboardSource(expiresAt: Date(timeIntervalSince1970: 999))
        let model = DashboardModel(
            source: source,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        await model.load()

        #expect(source.responses.isEmpty)
        #expect(model.snapshot?.attentionItems.isEmpty == true)
    }

    @Test func terminalSessionCleanupDoesNotEraseStructuredDecisionCards() async {
        let source = ClarificationDashboardSource(expiresAt: Date(timeIntervalSince1970: 2_000))
        let model = DashboardModel(
            source: source,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        await model.load()

        await model.handleTerminalSessionEvent(
            sessionID: "session-clarify",
            eventType: "session.completed"
        )

        #expect(source.dismissedIDs.isEmpty)
        #expect(model.snapshot?.attentionItems.map(\.id) == ["clarify-event"])
    }
}

@MainActor
private final class ClarificationDashboardSource: DashboardDataSource, DashboardClarificationClient {
    let expiresAt: Date
    private(set) var responses: [String] = []
    private(set) var dismissedIDs: [String] = []

    init(expiresAt: Date) {
        self.expiresAt = expiresAt
    }

    func loadDashboard() async throws -> DashboardSnapshot {
        let request = DashboardClarificationRequest(
            eventID: "clarify-event",
            requestID: "clarify-real-id",
            sessionID: "session-clarify",
            question: "Which release channel should I use?",
            choices: ["TestFlight", "App Store"],
            allowsCustomResponse: true,
            isMultiSelect: false,
            expiresAt: expiresAt
        )
        return DashboardSnapshot(
            attentionItems: [DashboardAttentionItem(
                id: request.eventID,
                title: "Hermes needs guidance",
                detail: request.question,
                urgency: .important,
                sessionID: request.sessionID,
                interaction: .clarification(request),
                createdAt: Date(timeIntervalSince1970: 900)
            )],
            completedItems: [],
            agents: []
        )
    }

    func respond(
        to request: DashboardClarificationRequest,
        response: String
    ) async throws -> DashboardClarificationReceipt {
        responses.append(response)
        return DashboardClarificationReceipt(
            eventID: request.eventID,
            requestID: request.requestID
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        dismissedIDs.append(id)
    }
}

@MainActor
private final class DashboardApprovalResponseSource:
    DashboardDataSource, ApprovalRequestLoading, ApprovalClient {
    struct Submission: Equatable {
        let request: ApprovalRequest
        let decision: ApprovalDecision
    }

    let itemID = "approval.required:approval-1"
    let loaded = LoadedApprovalRequest(
        request: .vendorFixture,
        allowedDecisions: [.once, .session, .always, .deny]
    )
    private(set) var loadedIDs: [String] = []
    private(set) var submissions: [Submission] = []

    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            attentionItems: [DashboardAttentionItem(
                id: itemID,
                title: "Approve session action",
                detail: "Hermes needs authorization",
                urgency: .important,
                approvalID: loaded.request.id,
                interaction: .approval(DashboardApprovalRequest(
                    eventID: itemID,
                    approvalID: loaded.request.id,
                    allowedDecisions: [.session],
                    expiresAt: Date(timeIntervalSince1970: 200)
                )),
                createdAt: Date(timeIntervalSince1970: 90)
            )],
            completedItems: [],
            agents: []
        )
    }

    func loadApproval(id: String) async throws -> LoadedApprovalRequest {
        loadedIDs.append(id)
        return loaded
    }

    func submit(
        request: ApprovalRequest,
        decision: ApprovalDecision
    ) async throws -> ApprovalReceipt {
        submissions.append(Submission(request: request, decision: decision))
        return ApprovalReceipt(requestID: request.id, decision: decision)
    }
}

@MainActor
private final class ChangingDashboardSource: DashboardDataSource {
    private(set) var loadCount = 0

    func loadDashboard() async throws -> DashboardSnapshot {
        loadCount += 1
        return DashboardSnapshot(
            attentionItems: [DashboardAttentionItem(
                id: "update",
                title: "Update \(loadCount)",
                detail: "Current Hermes event data",
                urgency: .important
            )],
            completedItems: [],
            agents: []
        )
    }
}

@MainActor
private final class FlakyDashboardSource: DashboardDataSource {
    var shouldFail = false

    func loadDashboard() async throws -> DashboardSnapshot {
        if shouldFail {
            throw DashboardFixtureError.unavailable
        }
        return DashboardSnapshot(
            attentionItems: [DashboardAttentionItem(
                id: "stable-update",
                title: "Stable update",
                detail: "Keep this visible during a transient refresh failure.",
                urgency: .important,
                createdAt: Date()
            )],
            completedItems: [],
            agents: []
        )
    }
}

@MainActor
private final class RetentionDashboardSource: DashboardDataSource {
    private(set) var dismissedIDs: [String] = []

    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            attentionItems: [
                DashboardAttentionItem(
                    id: "expired-decision",
                    title: "Old decision",
                    detail: "No longer actionable",
                    urgency: .important,
                    createdAt: Date(timeIntervalSince1970: 1)
                ),
                DashboardAttentionItem(
                    id: "fresh-decision",
                    title: "Fresh decision",
                    detail: "Still actionable",
                    urgency: .important,
                    createdAt: Date()
                ),
            ],
            completedItems: [],
            agents: []
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        dismissedIDs.append(id)
    }
}

@MainActor
private final class ClosedSessionDashboardSource: DashboardDataSource {
    private(set) var dismissedIDs: [String] = []

    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            attentionItems: [
                DashboardAttentionItem(
                    id: "closed-decision",
                    title: "Closed decision",
                    detail: "Its session has ended",
                    urgency: .important,
                    sessionID: "closed-session",
                    isSessionClosed: true,
                    createdAt: Date()
                ),
                DashboardAttentionItem(
                    id: "open-decision",
                    title: "Open decision",
                    detail: "Its session is still active",
                    urgency: .important,
                    sessionID: "open-session",
                    createdAt: Date()
                ),
            ],
            completedItems: [],
            agents: []
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        dismissedIDs.append(id)
    }
}

@MainActor
private final class TerminalSessionDashboardSource: DashboardDataSource {
    private(set) var dismissedIDs: [String] = []

    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            attentionItems: [DashboardAttentionItem(
                id: "terminal-decision",
                title: "Terminal decision",
                detail: "Its session just completed",
                urgency: .important,
                sessionID: "terminal-session",
                createdAt: Date()
            )],
            completedItems: [],
            agents: []
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        dismissedIDs.append(id)
    }
}

@MainActor
private final class DeferredDashboardSource: DashboardDataSource {
    private var loadContinuation: CheckedContinuation<DashboardSnapshot, Error>?
    private var loadStarted = false

    func loadDashboard() async throws -> DashboardSnapshot {
        loadStarted = true
        return try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
        }
    }

    func waitUntilLoadStarts() async {
        while !loadStarted { await Task.yield() }
    }

    func resumeLoad(with snapshot: DashboardSnapshot) {
        loadContinuation?.resume(returning: snapshot)
        loadContinuation = nil
    }
}

@MainActor
private final class InterleavedDashboardSource: DashboardDataSource {
    private var continuations: [CheckedContinuation<DashboardSnapshot, any Error>] = []

    func loadDashboard() async throws -> DashboardSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilLoadStarts(count: Int) async {
        while continuations.count < count { await Task.yield() }
    }

    func resumeLoad(at index: Int, title: String) {
        continuations[index].resume(returning: Self.snapshot(title: title))
    }

    func failLoad(at index: Int, error: any Error) {
        continuations[index].resume(throwing: error)
    }

    private static func snapshot(title: String) -> DashboardSnapshot {
        DashboardSnapshot(
            attentionItems: [DashboardAttentionItem(
                id: "shared-update",
                title: title,
                detail: title,
                urgency: .important
            )],
            completedItems: [],
            agents: []
        )
    }
}

@MainActor
private final class InterleavedCleanupDashboardSource: DashboardDataSource {
    private var loadCount = 0
    private var cleanupContinuation: CheckedContinuation<Void, Never>?
    private var cleanupStarted = false

    func loadDashboard() async throws -> DashboardSnapshot {
        loadCount += 1
        if loadCount == 1 {
            return DashboardSnapshot(
                attentionItems: [DashboardAttentionItem(
                    id: "shared-update",
                    title: "Closed update",
                    detail: "The old load will try to clean this up.",
                    urgency: .important,
                    isSessionClosed: true,
                    createdAt: Date()
                )],
                completedItems: [],
                agents: []
            )
        }
        return DashboardSnapshot(
            attentionItems: [DashboardAttentionItem(
                id: "shared-update",
                title: "Replacement update",
                detail: "This newer signal remains actionable.",
                urgency: .important,
                createdAt: Date()
            )],
            completedItems: [],
            agents: []
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        cleanupStarted = true
        await withCheckedContinuation { continuation in
            cleanupContinuation = continuation
        }
    }

    func waitUntilLoadStarts(count: Int) async {
        while loadCount < count { await Task.yield() }
    }

    func waitUntilCleanupStarts() async {
        while !cleanupStarted { await Task.yield() }
    }

    func finishCleanup() {
        cleanupContinuation?.resume()
        cleanupContinuation = nil
    }
}

/// Like the real source: a dismissal is remembered, so later loads leave the item out.
@MainActor
private final class RemovableDashboardSource: DashboardDataSource {
    var refusesDismissals = false
    private(set) var dismissedIDs: [String] = []

    func loadDashboard() async throws -> DashboardSnapshot {
        DashboardSnapshot(
            attentionItems: ["waiting-1", "waiting-2"]
                .filter { !dismissedIDs.contains($0) }
                .map {
                    DashboardAttentionItem(
                        id: $0, title: "Waiting", detail: "Its chat was deleted.",
                        urgency: .important, createdAt: Date()
                    )
                },
            completedItems: [],
            agents: []
        )
    }

    func dismissDashboardEvent(id: String) async throws {
        if refusesDismissals { throw DashboardFixtureError.unavailable }
        dismissedIDs.append(id)
    }
}

@MainActor
private final class SuspendedExternalRefreshDashboardSource: DashboardDataSource {
    private(set) var loadCount = 0
    private var refreshContinuation: CheckedContinuation<DashboardSnapshot, Never>?

    func loadDashboard() async throws -> DashboardSnapshot {
        loadCount += 1
        guard loadCount > 1 else { return Self.snapshot(waiting: false) }
        return await withCheckedContinuation { continuation in
            refreshContinuation = continuation
        }
    }

    func waitUntilRefreshStarts() async {
        while refreshContinuation == nil { await Task.yield() }
    }

    func finishRefresh() {
        refreshContinuation?.resume(returning: Self.snapshot(waiting: true))
        refreshContinuation = nil
    }

    private static func snapshot(waiting: Bool) -> DashboardSnapshot {
        DashboardSnapshot(
            attentionItems: waiting ? [DashboardAttentionItem(
                id: "delivered-while-away",
                title: "Delivered while Bighelp was away",
                detail: "A question arrived in the background.",
                urgency: .important,
                createdAt: Date()
            )] : [],
            completedItems: [],
            agents: []
        )
    }
}
