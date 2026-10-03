import Foundation
import Observation

@MainActor @Observable
final class DashboardClarificationDraft {
    /// The card's one answer in your own words; it answers every question
    /// without a picked choice (`ClarificationAnswers`).
    var customResponse = ""
    // Retained for source compatibility with the single-question fixture API.
    // Rendering uses the index-keyed state below so equal labels in different
    // questions never share one selection bucket.
    var selectedChoices: Set<String> = []
    var selectedChoiceIndices: [Int: Set<Int>] = [:]

    func selectedIndices(questionIndex: Int) -> Set<Int> {
        selectedChoiceIndices[questionIndex] ?? []
    }

    func setSelectedIndices(_ value: Set<Int>, questionIndex: Int) {
        selectedChoiceIndices[questionIndex] = value
    }
}

@MainActor
@Observable
final class DashboardModel {
    private struct ClarificationDraftKey: Hashable {
        let itemID: String
        let sessionID: String
        let requestID: String
    }
    @ObservationIgnored private var clarificationDrafts: [ClarificationDraftKey: DashboardClarificationDraft] = [:]

    func clarificationDraft(itemID: String, request: DashboardClarificationRequest) -> DashboardClarificationDraft {
        let key = ClarificationDraftKey(itemID: itemID, sessionID: request.sessionID, requestID: request.requestID)
        if let draft = clarificationDrafts[key] { return draft }
        let draft = DashboardClarificationDraft()
        clarificationDrafts[key] = draft
        return draft
    }

    // Updates are useful as a short activity log; decisions remain visible a
    // little longer so an owner has time to act on them.
    static let agentUpdateRetentionInterval: TimeInterval = 30 * 24 * 60 * 60
    static let decisionRetentionInterval: TimeInterval = 7 * 24 * 60 * 60

    static let updateEventTypes = DashboardEventIntentPolicy.intentionalUserSurfaceTypes
    static let attentionEventTypes = ["approval.required", "attention.required"]

    private let source: any DashboardDataSource
    @ObservationIgnored private let verifiedConnectionGeneration: @MainActor () -> UInt64?
    private let now: () -> Date
    private var accountGeneration: UInt64 = 0
    private var loadGeneration: UInt64 = 0
    private var loadConnectionGeneration: UInt64?
    private var externalRefreshTask: Task<Void, Never>?
    private var externalRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var workSessions: @MainActor () -> [SessionRecord] = { [] }
    @ObservationIgnored private var workPresentation: (@MainActor () -> [SessionRecord])?
    @ObservationIgnored private var workScheduledTasks: @MainActor () -> [ScheduledTask] = { [] }
    private var activeSubagentSessionIDs: Set<String> = []
    private var uncertainClarificationIDs: Set<String> = []
    private var resolvedClarificationIDs: Set<String> = []

    private(set) var state: DashboardLoadingState = .idle
    private(set) var snapshot: DashboardSnapshot? {
        didSet {
            let currentRequests = Set((snapshot?.attentionItems ?? []).compactMap { item -> ClarificationDraftKey? in
                guard case .clarification(let request) = item.interaction else { return nil }
                return ClarificationDraftKey(itemID: item.id, sessionID: request.sessionID, requestID: request.requestID)
            })
            clarificationDrafts = clarificationDrafts.filter { currentRequests.contains($0.key) }
        }
    }
    private(set) var lastUpdatedLabel = "Not updated yet"
    private(set) var mutationErrorMessage: String?
    private(set) var notificationOpenMessage: String?
    private(set) var focusedUpdateID: String?
    private(set) var focusedAttentionID: String?
    private(set) var resolvingAttentionIDs: Set<String> = []
    private(set) var clarificationDeliveryMessages: [String: String] = [:]
    private var requestedFocusUpdateID: String?

    init(
        source: any DashboardDataSource,
        verifiedConnectionGeneration: @escaping @MainActor () -> UInt64? = { 0 },
        now: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.verifiedConnectionGeneration = verifiedConnectionGeneration
        self.now = now
    }

    func configureWorkSessions(_ provider: @escaping @MainActor () -> [SessionRecord]) {
        workSessions = provider
    }

    func configureWorkPresentation(_ provider: @escaping @MainActor () -> [SessionRecord]) {
        workPresentation = provider
    }

    func configureWorkScheduledTasks(_ provider: @escaping @MainActor () -> [ScheduledTask]) {
        workScheduledTasks = provider
    }

    var workInFlightItems: [DashboardWorkItem] {
        DashboardWorkProjection.workInFlightItems(
            sessions: (workPresentation ?? workSessions)(), attentionItems: snapshot?.attentionItems ?? [], now: now(),
            activeSubagentSessionIDs: activeSubagentSessionIDs
        )
    }

    func updateSubagentWork(_ snapshot: SessionSubagentRosterSnapshot) {
        if snapshot.subagents.isEmpty {
            activeSubagentSessionIDs.remove(snapshot.sessionID)
        } else {
            activeSubagentSessionIDs.insert(snapshot.sessionID)
        }
    }

    var presentedCompletedItems: [DashboardCompletion] {
        Array(DashboardWorkProjection.presentedCompletedItems(
            snapshot?.completedItems ?? [], sessions: (workPresentation ?? workSessions)(),
            attentionItems: snapshot?.attentionItems ?? [],
            scheduledTasks: workScheduledTasks(), now: now()
        ).prefix(5))
    }

    func session(for item: DashboardAttentionItem) -> SessionRecord? {
        DashboardWorkProjection.session(
            resolving: item.owningSessionID, agentID: item.agentID, in: workSessions()
        )
    }

    var nextAttentionExpiry: Date? {
        snapshot?.attentionItems.compactMap { item -> Date? in
            switch item.interaction {
            case .clarification(let request): request.expiresAt
            case .approval(let request): request.expiresAt
            case .none: nil
            }
        }.min()
    }

    /// The Home view owns the sleeping task; leaving Home cancels it. Expiry
    /// changes presentation only and never submits an answer or stops Hermes.
    func expireAttentionWhenDue() async {
        guard let expiry = nextAttentionExpiry else { return }
        let generation = accountGeneration
        do {
            try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSince(now()))))
        } catch { return }
        guard generation == accountGeneration, !Task.isCancelled else { return }
        expireAttention()
    }

    func expireAttention() {
        guard let current = snapshot else { return }
        let attention = current.attentionItems.filter {
            DashboardWorkProjection.isActionable($0, at: now())
        }
        guard attention != current.attentionItems else { return }
        snapshot = DashboardSnapshot( inbox: current.inbox, attentionItems: attention,
            completedItems: current.completedItems, agents: current.agents
        )
    }

    func load() async {
        // Cached workspace admission can reveal Home before Link verifies its
        // socket. The verified refresh pipeline will load once it is ready.
        guard !Task.isCancelled, let connectionGeneration = verifiedConnectionGeneration() else { return }
        loadGeneration &+= 1
        let accountGeneration = self.accountGeneration
        let loadGeneration = self.loadGeneration
        loadConnectionGeneration = connectionGeneration
        state = .loading
        defer {
            // Cancellation and a replaced connection are lifecycle changes,
            // not a failed dashboard. Do not disturb a newer load's state.
            if accountGeneration == self.accountGeneration,
               loadGeneration == self.loadGeneration, state == .loading {
                state = snapshot == nil ? .idle : .loaded
            }
        }

        do {
            let loadedSnapshot = try await source.loadDashboard()
            guard ownsLoad(
                accountGeneration: accountGeneration,
                loadGeneration: loadGeneration
            ) else { return }
            let resolvedSnapshot = rankedSnapshot(loadedSnapshot)
            snapshot = resolvedSnapshot
            let dismissedIDs = await autoDismissStaleItems(
                from: resolvedSnapshot,
                accountGeneration: accountGeneration,
                loadGeneration: loadGeneration
            )
            guard ownsLoad(
                accountGeneration: accountGeneration,
                loadGeneration: loadGeneration
            ) else { return }
            if !dismissedIDs.isEmpty, let current = snapshot {
                snapshot = DashboardSnapshot(
                    inbox: current.inbox.filter { !dismissedIDs.contains($0.id) },
                    attentionItems: current.attentionItems.filter { !dismissedIDs.contains($0.id) },
                    completedItems: current.completedItems,
                    agents: current.agents
                )
            }
            resolveRequestedUpdateFocus()
            lastUpdatedLabel = "Updated just now"
            state = .loaded
        } catch {
            guard !(error is CancellationError) else { return }
            guard ownsLoad(
                accountGeneration: accountGeneration,
                loadGeneration: loadGeneration
            ) else { return }
            if let current = snapshot {
                // Keep the last known-good dashboard visible when a refresh
                // briefly loses the relay. A transient transport failure
                // must not erase useful inbox and attention content.
                snapshot = DashboardSnapshot(
                    inbox: current.inbox,
                    attentionItems: current.attentionItems,
                    completedItems: current.completedItems,
                    agents: current.agents
                )
                lastUpdatedLabel = "Could not refresh"
                state = .loaded
            } else {
                state = .failure(message: "Dashboard data is unavailable. Please try again.")
            }
        }
    }

    func refresh() async {
        await load()
    }

    func refreshAfterExternalChange() async {
        if let externalRefreshTask {
            await externalRefreshTask.value
            return
        }

        externalRefreshGeneration &+= 1
        let generation = externalRefreshGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            await self.load()
        }
        externalRefreshTask = task
        await task.value
        if generation == externalRefreshGeneration {
            externalRefreshTask = nil
        }
    }

    /// A completed turn does not close its reusable conversation. The fresh
    /// dashboard's profile-scoped timestamps decide which old rows are stale;
    /// an uncoordinated notification must never erase a newer attention card.
    func handleTerminalSessionEvent(sessionID: String?, eventType: String) async {
        guard Self.terminalSessionEventTypes.contains(eventType), sessionID != nil else { return }
        // Both notification receipt paths refresh immediately after this call.
        // Keep local expiry current without issuing a duplicate network load.
        expireAttention()
    }

    func resetForAccountBoundary() {
        externalRefreshTask?.cancel()
        externalRefreshTask = nil
        externalRefreshGeneration &+= 1
        accountGeneration &+= 1
        loadGeneration &+= 1
        state = .idle
        snapshot = nil
        lastUpdatedLabel = "Not updated yet"
        mutationErrorMessage = nil
        notificationOpenMessage = nil
        focusedUpdateID = nil
        focusedAttentionID = nil
        resolvingAttentionIDs = []
        activeSubagentSessionIDs = []
        uncertainClarificationIDs = []
        resolvedClarificationIDs = []
        clarificationDeliveryMessages = [:]
        requestedFocusUpdateID = nil
    }

    func focusUpdate(id: String) {
        guard snapshot?.inbox.contains(where: { $0.id == id }) == true else { return }
        focusedUpdateID = id
    }

    func requestUpdateFocus(id: String) {
        guard
            !id.isEmpty,
            id.count <= 220,
            id.allSatisfy({ $0.isASCII && !$0.isWhitespace })
        else { return }
        requestedFocusUpdateID = id
        resolveRequestedUpdateFocus()
    }

    func openNotification(eventID: String, eventType: String?) async {
        requestedFocusUpdateID = nil
        focusedUpdateID = nil
        focusedAttentionID = nil
        notificationOpenMessage = nil

        await refreshAfterExternalChange()

        guard let snapshot else {
            notificationOpenMessage = "This item is no longer available"
            return
        }
        if snapshot.inbox.contains(where: { $0.id == eventID }) {
            focusedUpdateID = eventID
            return
        }
        if snapshot.attentionItems.contains(where: { $0.id == eventID }) {
            focusedAttentionID = eventID
            return
        }
        notificationOpenMessage = eventType == "attention.required"
            ? "This question has already been answered"
            : "This item is no longer available"
    }

    func clearNotificationOpenMessage() {
        notificationOpenMessage = nil
    }

    func consumeFocusedUpdate(id: String) {
        guard focusedUpdateID == id else { return }
        focusedUpdateID = nil
    }

    func consumeFocusedAttention(id: String) {
        guard focusedAttentionID == id else { return }
        focusedAttentionID = nil
    }

    func dismissUpdate(id: String) async {
        guard snapshot?.inbox.contains(where: { $0.id == id }) == true else { return }
        let generation = accountGeneration
        do {
            try await source.dismissDashboardEvent(id: id)
            guard generation == accountGeneration else { return }
            invalidateInFlightLoad()
            guard let snapshot else { return }
            self.snapshot = DashboardSnapshot(
                inbox: snapshot.inbox.filter { $0.id != id },
                attentionItems: snapshot.attentionItems,
                completedItems: snapshot.completedItems,
                agents: snapshot.agents
            )
            mutationErrorMessage = nil
        } catch {
            guard generation == accountGeneration else { return }
            invalidateInFlightLoad()
            let reconciliationLoadGeneration = loadGeneration
            do {
                let refreshed = try await source.loadDashboard()
                guard ownsLoad(
                    accountGeneration: generation,
                    loadGeneration: reconciliationLoadGeneration
                ) else { return }
                let resolved = rankedSnapshot(refreshed)
                snapshot = resolved
                if !resolved.inbox.contains(where: { $0.id == id }) {
                    mutationErrorMessage = nil
                    return
                }
            } catch {
                guard ownsLoad(
                    accountGeneration: generation,
                    loadGeneration: reconciliationLoadGeneration
                ) else { return }
            }
            mutationErrorMessage = "That item could not be removed. Please try again."
        }
    }

    func setUpdateRead(id: String, isRead: Bool) async {
        guard let item = snapshot?.inbox.first(where: { $0.id == id }) else { return }
        await setUpdateState(item, isRead: isRead, isPinned: item.isPinned)
    }

    func setUpdatePinned(id: String, isPinned: Bool) async {
        guard let item = snapshot?.inbox.first(where: { $0.id == id }) else { return }
        await setUpdateState(item, isRead: item.isRead, isPinned: isPinned)
    }

    func setAttentionRead(id: String, isRead: Bool) async {
        guard let item = snapshot?.attentionItems.first(where: { $0.id == id }) else { return }
        await setAttentionState(item, isRead: isRead, isPinned: item.isPinned)
    }

    func setAttentionPinned(id: String, isPinned: Bool) async {
        guard let item = snapshot?.attentionItems.first(where: { $0.id == id }) else { return }
        await setAttentionState(item, isRead: item.isRead, isPinned: isPinned)
    }

    func dismissAttention(id: String) async {
        guard snapshot?.attentionItems.contains(where: { $0.id == id }) == true else { return }
        let generation = accountGeneration
        do {
            try await source.dismissDashboardEvent(id: id)
            guard generation == accountGeneration else { return }
            invalidateInFlightLoad()
            guard let snapshot else { return }
            self.snapshot = DashboardSnapshot(
                inbox: snapshot.inbox,
                attentionItems: snapshot.attentionItems.filter { $0.id != id },
                completedItems: snapshot.completedItems,
                agents: snapshot.agents
            )
            mutationErrorMessage = nil
        } catch {
            guard generation == accountGeneration else { return }
            mutationErrorMessage = "That item could not be removed. Please try again."
        }
    }

    func respondToClarification(itemID: String, response: String) async {
        guard let item = snapshot?.attentionItems.first(where: { $0.id == itemID }),
              case .clarification(let request) = item.interaction,
              let question = request.questions.first,
              request.questions.count == 1 else { return }
        await respondToClarification(
            itemID: itemID,
            response: DashboardClarificationResponse(answers: [
                DashboardClarificationAnswer(questionID: question.id, value: response),
            ])
        )
    }

    func respondToClarification(
        itemID: String,
        response: DashboardClarificationResponse
    ) async {
        guard
            !resolvingAttentionIDs.contains(itemID),
            let item = snapshot?.attentionItems.first(where: { $0.id == itemID }),
            case .clarification(let request) = item.interaction
        else { return }

        let generation = accountGeneration
        guard request.accepts(response) else {
            mutationErrorMessage = "Complete every question before sending."
            return
        }

        resolvingAttentionIDs.insert(itemID)
        clarificationDeliveryMessages[itemID] = nil
        defer {
            if generation == accountGeneration {
                resolvingAttentionIDs.remove(itemID)
            }
        }

        if uncertainClarificationIDs.contains(itemID) {
            await reconcileClarification(request, accountGeneration: generation)
            return
        }

        guard !request.isExpired(at: now()) else {
            expireAttention()
            mutationErrorMessage = "This clarification has expired. No chat message was sent."
            return
        }
        guard let client = source as? any DashboardClarificationClient else {
            mutationErrorMessage = "This source cannot answer the original clarification request. No chat message was sent."
            return
        }

        do {
            let receipt = try await client.respond(to: request, response: response)
            guard generation == accountGeneration else { return }
            guard !Task.isCancelled else {
                uncertainClarificationIDs.insert(itemID)
                return
            }
            if receipt.eventID == request.eventID,
               receipt.requestID == request.requestID {
                resolvedClarificationIDs.insert(itemID)
                invalidateInFlightLoad()
                removeAttentionFromSnapshot(id: itemID)
                clarificationDeliveryMessages[itemID] = nil
                mutationErrorMessage = nil
                return
            }
            // A mismatched receipt is not a rejection. The original request may
            // have consumed the answer, so a second tap only performs readback.
            uncertainClarificationIDs.insert(itemID)
            await reconcileClarification(request, accountGeneration: generation)
        } catch is CancellationError {
            if generation == accountGeneration { uncertainClarificationIDs.insert(itemID) }
        } catch {
            guard generation == accountGeneration else { return }
            guard !Task.isCancelled else {
                uncertainClarificationIDs.insert(itemID)
                return
            }
            if case BighelpLinkWorkspaceClientError.remote(.conflict, "workspace_conflict", _) = error {
                await reconcileClarification(request, accountGeneration: generation)
                if snapshot?.attentionItems.contains(where: { $0.id == itemID }) == true {
                    mutationErrorMessage = "Hermes did not accept that answer. It remains in this card; no chat message was sent."
                }
            } else {
                uncertainClarificationIDs.insert(itemID)
                await reconcileClarification(request, accountGeneration: generation)
            }
        }
    }

    /// Authoritative absence can settle a lost receipt. Presence or failed
    /// readback never authorizes resending an answer or converting it to chat.
    private func reconcileClarification(
        _ request: DashboardClarificationRequest,
        accountGeneration generation: UInt64
    ) async {
        do {
            let fresh = try await source.loadDashboard()
            guard generation == accountGeneration, !Task.isCancelled,
                  let current = snapshot?.attentionItems.first(where: { $0.id == request.eventID }),
                  case .clarification(let currentRequest) = current.interaction,
                  currentRequest == request
            else { return }
            if !fresh.attentionItems.contains(where: { $0.id == request.eventID }) {
                uncertainClarificationIDs.remove(request.eventID)
                resolvedClarificationIDs.insert(request.eventID)
                removeAttentionFromSnapshot(id: request.eventID)
                clarificationDeliveryMessages[request.eventID] = nil
                mutationErrorMessage = nil
                return
            }
        } catch is CancellationError {
            return
        } catch {
            // Failed readback is not evidence that the original send failed.
        }
        guard generation == accountGeneration, !Task.isCancelled else { return }
        let message = "Delivery could not be confirmed. Your answer is still here. Try again to check its status without sending it twice."
        clarificationDeliveryMessages[request.eventID] = message
        mutationErrorMessage = message
    }

    func respondToApproval(itemID: String, decision: ApprovalDecision) async {
        guard
            !resolvingAttentionIDs.contains(itemID),
            let item = snapshot?.attentionItems.first(where: { $0.id == itemID }),
            case .approval(let summary) = item.interaction
        else { return }
        guard !summary.isExpired(at: now()) else {
            mutationErrorMessage = "This approval has expired."
            return
        }
        guard summary.allowedDecisions.contains(decision) else {
            mutationErrorMessage = "Hermes did not offer that approval scope."
            return
        }
        guard
            let loader = source as? any ApprovalRequestLoading,
            let client = source as? any ApprovalClient
        else {
            mutationErrorMessage = "That approval could not be sent. Please try again."
            return
        }

        let generation = accountGeneration
        resolvingAttentionIDs.insert(itemID)
        defer {
            if generation == accountGeneration {
                resolvingAttentionIDs.remove(itemID)
            }
        }
        do {
            let loaded = try await loader.loadApproval(id: summary.approvalID)
            guard generation == accountGeneration else { return }
            let receipt = try await client.submit(
                request: loaded.request,
                decision: decision
            )
            guard generation == accountGeneration else { return }
            guard
                receipt.requestID == summary.approvalID,
                receipt.decision == decision
            else {
                mutationErrorMessage = "That approval could not be confirmed. Please try again."
                return
            }
            removeAttentionFromSnapshot(id: itemID)
            mutationErrorMessage = nil
        } catch {
            guard generation == accountGeneration else { return }
            mutationErrorMessage = summary.isExpired(at: now())
                ? "This approval has expired."
                : "That approval could not be sent. Please try again."
        }
    }

    func clearUpdates() async {
        guard
            let snapshot,
            let cutoff = snapshot.inbox.map(\.createdAt).max()
        else { return }
        let generation = accountGeneration
        do {
            try await source.dismissDashboardEvents(
                types: Self.updateEventTypes,
                createdBefore: cutoff
            )
            guard generation == accountGeneration else { return }
            guard let current = self.snapshot else { return }
            self.snapshot = DashboardSnapshot(
                inbox: current.inbox.filter { $0.createdAt > cutoff },
                attentionItems: current.attentionItems,
                completedItems: current.completedItems,
                agents: current.agents
            )
            mutationErrorMessage = nil
        } catch {
            guard generation == accountGeneration else { return }
            mutationErrorMessage = "Agent updates could not be cleared. Please try again."
        }
    }

    func clearAttention() async {
        guard
            let snapshot,
            let cutoff = snapshot.attentionItems.map(\.createdAt).max()
        else { return }
        let generation = accountGeneration
        do {
            try await source.dismissDashboardEvents(
                types: Self.attentionEventTypes,
                createdBefore: cutoff
            )
            guard generation == accountGeneration else { return }
            invalidateInFlightLoad()
            guard let current = self.snapshot else { return }
            self.snapshot = DashboardSnapshot(
                inbox: current.inbox,
                attentionItems: current.attentionItems.filter { $0.createdAt > cutoff },
                completedItems: current.completedItems,
                agents: current.agents
            )
            mutationErrorMessage = nil
        } catch {
            guard generation == accountGeneration else { return }
            mutationErrorMessage = "Decision requests could not be cleared. Please try again."
        }
    }

    func clearMutationError() {
        mutationErrorMessage = nil
    }

    private func autoDismissStaleItems(
        from snapshot: DashboardSnapshot,
        accountGeneration: UInt64,
        loadGeneration: UInt64
    ) async -> Set<String> {
        let referenceDate = now()
        let staleUpdates = snapshot.inbox.filter { item in
            guard !item.isPinned else { return false }
            return item.isSessionClosed || isExpired(
                item.createdAt,
                before: referenceDate.addingTimeInterval(-Self.agentUpdateRetentionInterval)
            )
        }
        let staleDecisions = snapshot.attentionItems.filter { item in
            guard !item.isPinned else { return false }
            return (item.isSessionClosed && !item.interaction.isStructuredDecision) || isExpired(
                item.createdAt,
                before: referenceDate.addingTimeInterval(-Self.decisionRetentionInterval)
            )
        }

        var dismissedIDs = Set<String>()
        for itemID in staleUpdates.map(\.id) + staleDecisions.map(\.id) {
            guard ownsLoad(
                accountGeneration: accountGeneration,
                loadGeneration: loadGeneration
            ) else { return dismissedIDs }
            do {
                try await source.dismissDashboardEvent(id: itemID)
                guard ownsLoad(
                    accountGeneration: accountGeneration,
                    loadGeneration: loadGeneration
                ) else { return dismissedIDs }
                dismissedIDs.insert(itemID)
            } catch {
                // Automatic cleanup is best effort. A failed cleanup must not
                // hide an item that the server still considers present.
            }
        }
        return dismissedIDs
    }

    private static let terminalSessionEventTypes: Set<String> = [
        "session.completed",
        "session.failed",
    ]

    private func isExpired(_ date: Date, before cutoff: Date) -> Bool {
        date != .distantPast && date <= cutoff
    }

    private func removeAttentionFromSnapshot(id: String) {
        invalidateInFlightLoad()
        guard let snapshot else { return }
        self.snapshot = DashboardSnapshot(
            inbox: snapshot.inbox,
            attentionItems: snapshot.attentionItems.filter { $0.id != id },
            completedItems: snapshot.completedItems,
            agents: snapshot.agents
        )
    }

    private func rankedSnapshot(
        _ snapshot: DashboardSnapshot
    ) -> DashboardSnapshot {
        let referenceDate = now()
        let rankedInbox = snapshot.inbox.enumerated()
            .filter { _, item in
                if item.isPinned { return true }
                guard let validUntil = item.bighelpCard?.validUntil else { return true }
                return validUntil > referenceDate
            }
            .sorted { left, right in
                if left.element.isPinned != right.element.isPinned {
                    return left.element.isPinned
                }
                if left.element.cardImportance != right.element.cardImportance {
                    return left.element.cardImportance > right.element.cardImportance
                }
                return left.offset < right.offset
            }
            .map(\.element)
        return DashboardSnapshot(
            inbox: rankedInbox,
            attentionItems: snapshot.attentionItems.filter {
                !resolvedClarificationIDs.contains($0.id)
                    && DashboardWorkProjection.isActionable($0, at: referenceDate)
            },
            completedItems: snapshot.completedItems,
            agents: snapshot.agents
        )
    }

    private func ownsLoad(
        accountGeneration: UInt64,
        loadGeneration: UInt64
    ) -> Bool {
        accountGeneration == self.accountGeneration
            && loadGeneration == self.loadGeneration
            && !Task.isCancelled
            && loadConnectionGeneration == verifiedConnectionGeneration()
    }

    private func invalidateInFlightLoad() {
        loadGeneration &+= 1
        if snapshot != nil {
            state = .loaded
        }
    }

    private func resolveRequestedUpdateFocus() {
        guard let requestedFocusUpdateID, let snapshot else { return }
        if snapshot.inbox.contains(where: { $0.id == requestedFocusUpdateID }) {
            self.requestedFocusUpdateID = nil
            focusedUpdateID = requestedFocusUpdateID
            return
        }
        guard snapshot.attentionItems.contains(where: { $0.id == requestedFocusUpdateID }) else {
            return
        }
        self.requestedFocusUpdateID = nil
        focusedAttentionID = requestedFocusUpdateID
    }

    private func setUpdateState(
        _ item: DashboardInboxItem,
        isRead: Bool,
        isPinned: Bool
    ) async {
        let generation = accountGeneration
        do {
            try await source.setDashboardEventState(
                id: item.id,
                isRead: isRead,
                isPinned: isPinned
            )
            guard generation == accountGeneration else { return }
            guard let snapshot else { return }
            let replaced = snapshot.inbox.map { candidate in
                candidate.id == item.id
                    ? candidate.withState(isRead: isRead, isPinned: isPinned)
                    : candidate
            }
            let ordered = replaced.filter(\.isPinned).sorted { left, right in
                left.createdAt > right.createdAt
            } + replaced.filter { !$0.isPinned }
            self.snapshot = DashboardSnapshot(
                inbox: ordered,
                attentionItems: snapshot.attentionItems,
                completedItems: snapshot.completedItems,
                agents: snapshot.agents
            )
            mutationErrorMessage = nil
        } catch {
            guard generation == accountGeneration else { return }
            mutationErrorMessage = "That item could not be updated. Please try again."
        }
    }

    private func setAttentionState(
        _ item: DashboardAttentionItem,
        isRead: Bool,
        isPinned: Bool
    ) async {
        let generation = accountGeneration
        do {
            try await source.setDashboardEventState(
                id: item.id,
                isRead: isRead,
                isPinned: isPinned
            )
            guard generation == accountGeneration else { return }
            guard let snapshot else { return }
            let replaced = snapshot.attentionItems.map { candidate in
                candidate.id == item.id
                    ? candidate.withState(isRead: isRead, isPinned: isPinned)
                    : candidate
            }
            let ordered = replaced.filter(\.isPinned).sorted { left, right in
                left.createdAt > right.createdAt
            } + replaced.filter { !$0.isPinned }
            self.snapshot = DashboardSnapshot(
                inbox: snapshot.inbox,
                attentionItems: ordered,
                completedItems: snapshot.completedItems,
                agents: snapshot.agents
            )
            mutationErrorMessage = nil
        } catch {
            guard generation == accountGeneration else { return }
            mutationErrorMessage = "That item could not be updated. Please try again."
        }
    }
}
