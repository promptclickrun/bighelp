import CryptoKit
import Foundation

/// A native approval is already owned by a verified Hermes client. The
/// dashboard only presents it; the responder is supplied by that owner (for
/// example, a direct session client or BotModeRoomStore).
struct DirectHermesDashboardApproval: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let sessionID: String?
    let agentID: String?
    let agentName: String?
    let allowedDecisions: Set<ApprovalDecision>
    let expiresAt: Date?
    let createdAt: Date

    init(
        id: String,
        title: String,
        detail: String,
        sessionID: String? = nil,
        agentID: String? = nil,
        agentName: String? = nil,
        allowedDecisions: Set<ApprovalDecision>,
        expiresAt: Date? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.sessionID = sessionID
        self.agentID = agentID
        self.agentName = agentName
        self.allowedDecisions = allowedDecisions
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    /// `groups.state` has no expiry field. A distant date represents that
    /// exact contract without inventing a client timeout.
    var dashboardExpiration: Date { expiresAt ?? .distantFuture }

    static func hostedRoom(
        _ pending: HermesBotModePendingApproval,
        roomName: String,
        agentName: String? = nil,
        createdAt: Date = .now
    ) -> Self {
        Self(
            id: pending.id,
            title: pending.command ?? "\(roomName) approval",
            detail: pending.description ?? "Review this \(roomName) action before allowing it.",
            sessionID: "hermes-room:\(pending.roomID)",
            agentID: nil,
            agentName: agentName,
            allowedDecisions: Set(pending.choices.map { $0 == .once ? .once : .deny }),
            createdAt: createdAt
        )
    }

    var approvalRequest: ApprovalRequest {
        ApprovalRequest(
            id: id,
            action: title,
            requester: agentName ?? "Hermes",
            vendor: "Hermes",
            amount: "One action",
            dueDate: expiresAt.map {
                $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "No expiry",
            category: "Native Hermes",
            sourceInvoice: "Direct Hermes approval",
            consequence: detail
        )
    }
}

/// A structured clarification retained by a current direct session. The
/// source accepts a value projection so it never reaches into a live
/// conversation client or invents a second RPC endpoint.
struct DirectHermesDashboardClarification: Equatable, Sendable, Identifiable {
    let id: String
    let sessionID: String
    let questions: [DashboardClarificationQuestion]
    let expiresAt: Date?
    let agentID: String?
    let createdAt: Date

    init(
        id: String,
        sessionID: String,
        questions: [DashboardClarificationQuestion],
        expiresAt: Date? = nil,
        agentID: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.questions = questions
        self.expiresAt = expiresAt
        self.agentID = agentID
        self.createdAt = createdAt
    }

    init(
        id: String,
        sessionID: String,
        question: String,
        choices: [String] = [],
        allowsCustomResponse: Bool = true,
        isMultiSelect: Bool = false,
        expiresAt: Date? = nil,
        agentID: String? = nil,
        createdAt: Date = .now
    ) {
        self.init(
            id: id,
            sessionID: sessionID,
            questions: [DashboardClarificationQuestion(
                id: "$single",
                question: question,
                choices: choices,
                allowsCustomResponse: allowsCustomResponse,
                isMultiSelect: isMultiSelect
            )],
            expiresAt: expiresAt,
            agentID: agentID,
            createdAt: createdAt
        )
    }

    var question: String { questions.first?.question ?? "" }

    var request: DashboardClarificationRequest {
        DashboardClarificationRequest(
            eventID: "native.clarification.\(id)",
            requestID: id,
            sessionID: sessionID,
            questions: questions,
            expiresAt: expiresAt
        )
    }
}

/// Dashboard projection for a selected direct Hermes host.
///
/// Hermes 0.21.2 does not provide the bighelp dashboard event API. This source
/// therefore reads the already authenticated native session/profile catalogs
/// and optional native prompt projections. It never calls Link, the notification relay, or
/// a made-up dashboard endpoint.
@MainActor
final class DirectHermesDashboardDataSource: DashboardDataSource,
    DashboardClarificationClient, ApprovalRequestLoading, ApprovalClient {
    typealias SessionProvider = @MainActor () -> [SessionRecord]
    typealias AgentProvider = @MainActor () -> [AgentProfile]
    typealias ApprovalProvider = @MainActor () -> [DirectHermesDashboardApproval]
    typealias ClarificationProvider = @MainActor () -> [DirectHermesDashboardClarification]
    typealias ApprovalResponder = @MainActor (
        DirectHermesDashboardApproval, ApprovalDecision
    ) async throws -> Void
    typealias ClarificationResponder = @MainActor (
        DirectHermesDashboardClarification, String
    ) async throws -> Void
    typealias StructuredClarificationResponder = @MainActor (
        DirectHermesDashboardClarification, DashboardClarificationResponse
    ) async throws -> Void

    private struct PresentationState: Codable {
        var readIDs: Set<String> = []
        var pinnedIDs: Set<String> = []
        var dismissedIDs: Set<String> = []
    }

    private let authority: WorkspaceAuthority
    private let sessions: SessionProvider
    private let agents: AgentProvider
    private let approvals: ApprovalProvider
    private let clarifications: ClarificationProvider
    private let approvalResponder: ApprovalResponder?
    private let clarificationResponder: ClarificationResponder?
    private let structuredClarificationResponder: StructuredClarificationResponder?
    private let defaults: UserDefaults
    private let now: () -> Date
    private let isCurrentOwner: @MainActor () -> Bool
    private var presentation: PresentationState

    init(
        authority: WorkspaceAuthority,
        sessions: @escaping SessionProvider,
        agents: @escaping AgentProvider,
        approvals: @escaping ApprovalProvider = { [] },
        clarifications: @escaping ClarificationProvider = { [] },
        approvalResponder: ApprovalResponder? = nil,
        clarificationResponder: ClarificationResponder? = nil,
        structuredClarificationResponder: StructuredClarificationResponder? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        isCurrentOwner: @escaping @MainActor () -> Bool = { true }
    ) {
        self.authority = authority
        self.sessions = sessions
        self.agents = agents
        self.approvals = approvals
        self.clarifications = clarifications
        self.approvalResponder = approvalResponder
        self.clarificationResponder = clarificationResponder
        self.structuredClarificationResponder = structuredClarificationResponder
        self.defaults = defaults
        self.now = now
        self.isCurrentOwner = isCurrentOwner
        presentation = Self.loadPresentation(defaults: defaults, key: Self.key(for: authority))
    }

    convenience init(
        authority: WorkspaceAuthority,
        sessions: SessionCatalogStore,
        agents: AgentDirectoryStore,
        approvals: @escaping ApprovalProvider = { [] },
        clarifications: @escaping ClarificationProvider = { [] },
        approvalResponder: ApprovalResponder? = nil,
        clarificationResponder: ClarificationResponder? = nil,
        structuredClarificationResponder: StructuredClarificationResponder? = nil,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        isCurrentOwner: @escaping @MainActor () -> Bool = { true }
    ) {
        self.init(
            authority: authority,
            sessions: { sessions.records },
            agents: { agents.profiles },
            approvals: approvals,
            clarifications: clarifications,
            approvalResponder: approvalResponder,
            clarificationResponder: clarificationResponder,
            structuredClarificationResponder: structuredClarificationResponder,
            defaults: defaults,
            now: now,
            isCurrentOwner: isCurrentOwner
        )
    }

    func loadDashboard() async throws -> DashboardSnapshot {
        try checkOwner()
        try Task.checkCancellation()

        let currentSessions = sessions()
        let currentApprovals = uniqueApprovals(approvals())
        let currentClarifications = uniqueClarifications(clarifications())
        let attention = currentAttention(
            approvals: currentApprovals,
            clarifications: currentClarifications
        )
        let activeIDs = Set(DashboardWorkProjection.workInFlightItems(
            sessions: currentSessions,
            attentionItems: attention,
            now: now()
        ).map(\.sessionID))
        let inbox = currentSessions
            .filter { !activeIDs.contains($0.id) }
            .compactMap(sessionUpdate)
            .filter { !presentation.dismissedIDs.contains($0.id) }
            .map(applyPresentation(to:))
            .sorted(by: sortInbox)

        return DashboardSnapshot(
            inbox: inbox,
            attentionItems: attention
                .filter { !presentation.dismissedIDs.contains($0.id) }
                .map(applyPresentation(to:))
                .sorted(by: sortAttention),
            completedItems: [],
            agents: Array(agents().prefix(8).map { agent in
                DashboardAgent(
                    id: agent.id,
                    initials: Self.initials(agent.name),
                    name: agent.name,
                    role: agent.role,
                    availability: "Available"
                )
            })
        )
    }

    func setDashboardEventState(id: String, isRead: Bool, isPinned: Bool) async throws {
        try checkOwner()
        try validateID(id)
        presentation.readIDs = isRead
            ? presentation.readIDs.union([id])
            : presentation.readIDs.subtracting([id])
        presentation.pinnedIDs = isPinned
            ? presentation.pinnedIDs.union([id])
            : presentation.pinnedIDs.subtracting([id])
        savePresentation()
    }

    func dismissDashboardEvent(id: String) async throws {
        try checkOwner()
        try validateID(id)
        presentation.dismissedIDs.insert(id)
        savePresentation()
    }

    func dismissDashboardEvents(types: [String], createdBefore: Date) async throws {
        try checkOwner()
        let normalized = Set(types)
        let allowed = Set(["channel.message", "attention.required", "approval.required"])
        guard !normalized.isEmpty, normalized.isSubset(of: allowed) else {
            throw WorkspaceClientError.invalidResponse
        }
        let snapshot = try await loadDashboard()
        let dismissIDs = snapshot.inbox.compactMap { item -> String? in
            guard normalized.contains("channel.message"), item.createdAt <= createdBefore else { return nil }
            return item.id
        } + snapshot.attentionItems.compactMap { item -> String? in
            guard item.createdAt <= createdBefore else { return nil }
            let type = item.interaction.isStructuredDecision
                ? (item.approvalID == nil ? "attention.required" : "approval.required")
                : "attention.required"
            return normalized.contains(type) ? item.id : nil
        }
        presentation.dismissedIDs.formUnion(dismissIDs)
        savePresentation()
    }

    func respond(
        to request: DashboardClarificationRequest,
        response: String
    ) async throws -> DashboardClarificationReceipt {
        guard let question = request.questions.first, request.questions.count == 1 else {
            throw DashboardMutationError.unsupported
        }
        return try await respond(
            to: request,
            response: DashboardClarificationResponse(answers: [
                DashboardClarificationAnswer(questionID: question.id, value: response),
            ])
        )
    }

    func respond(
        to request: DashboardClarificationRequest,
        response: DashboardClarificationResponse
    ) async throws -> DashboardClarificationReceipt {
        try checkOwner()
        guard let clarification = clarifications().first(where: {
            "native.clarification.\($0.id)" == request.eventID
                && $0.id == request.requestID
                && $0.sessionID == request.sessionID
        }), clarification.request == request,
              request.accepts(response),
              clarification.expiresAt.map({ now() < $0 }) ?? true else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        if let structuredClarificationResponder {
            try await structuredClarificationResponder(clarification, response)
        } else if let value = response.singleAnswer, let clarificationResponder {
            try await clarificationResponder(clarification, value)
        } else {
            throw DashboardMutationError.unsupported
        }
        try checkOwner()
        return DashboardClarificationReceipt(eventID: request.eventID, requestID: request.requestID)
    }

    func loadApproval(id: String) async throws -> LoadedApprovalRequest {
        try checkOwner()
        guard let approval = approvals().first(where: { $0.id == id }),
              !approval.allowedDecisions.isEmpty,
              approval.expiresAt.map({ now() < $0 }) ?? true else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        return LoadedApprovalRequest(
            request: approval.approvalRequest,
            allowedDecisions: approval.allowedDecisions
        )
    }

    func submit(request: ApprovalRequest, decision: ApprovalDecision) async throws -> ApprovalReceipt {
        try checkOwner()
        guard let approval = approvals().first(where: { $0.id == request.id }),
              approval.allowedDecisions.contains(decision),
              approval.expiresAt.map({ now() < $0 }) ?? true else {
            throw DirectHermesWorkspaceError.expiredPrompt
        }
        guard let approvalResponder else { throw DashboardMutationError.unsupported }
        try await approvalResponder(approval, decision)
        return ApprovalReceipt(requestID: request.id, decision: decision)
    }

    private func checkOwner() throws {
        guard authority.kind == .direct, isCurrentOwner() else {
            throw WorkspaceClientError.ownerChanged
        }
    }

    private func currentAttention(
        approvals: [DirectHermesDashboardApproval],
        clarifications: [DirectHermesDashboardClarification]
    ) -> [DashboardAttentionItem] {
        let approvalItems = approvals.map { approval in
            DashboardAttentionItem(
                id: "native.approval.\(approval.id)",
                title: approval.title,
                detail: approval.detail,
                urgency: .needsReview,
                approvalID: approval.id,
                sessionID: approval.sessionID,
                agentID: approval.agentID,
                interaction: .approval(DashboardApprovalRequest(
                    eventID: "native.approval.\(approval.id)",
                    approvalID: approval.id,
                    allowedDecisions: approval.allowedDecisions.sorted {
                        $0.rawValue < $1.rawValue
                    },
                    expiresAt: approval.dashboardExpiration
                )),
                createdAt: approval.createdAt
            )
        }
        let clarificationItems = clarifications.map { clarification in
            let request = clarification.request
            return DashboardAttentionItem(
                id: request.eventID,
                title: "Hermes has a question",
                detail: clarification.question,
                urgency: .important,
                sessionID: clarification.sessionID,
                agentID: clarification.agentID,
                interaction: .clarification(request),
                createdAt: clarification.createdAt
            )
        }
        return approvalItems + clarificationItems
    }

    private func sessionUpdate(_ session: SessionRecord) -> DashboardInboxItem? {
        guard let item = session.items.last,
              item.role == .assistant,
              item.metadata.delivery != "Streaming" else { return nil }
        let projection = projectContent(item.content)
        guard projection.detail != nil || projection.card != nil || projection.bighelpCard != nil else {
            return nil
        }
        let agent = session.agentIDs.first.flatMap { id in agents().first { $0.id == id } }
        let timestamp = item.metadata.timestamp ?? session.updatedAt
        return DashboardInboxItem(
            id: Self.sessionUpdateID(sessionID: session.id, itemID: item.id),
            title: DashboardWorkProjection.meaningfulTitle(session.title)
                ?? (session.kind == .botMode ? "Group chat" : "Conversation"),
            detail: projection.detail ?? "Hermes shared an update.",
            agentName: agent?.name ?? item.sender.snapshot.name,
            status: freshness(for: timestamp),
            card: projection.card,
            bighelpCard: projection.bighelpCard,
            sessionID: session.id,
            agentID: session.agentIDs.first,
            isSessionClosed: false,
            createdAt: timestamp
        )
    }

    private func projectContent(_ content: TimelineContent) -> (
        detail: String?, card: GenerativeUICard?, bighelpCard: BighelpCardDocument?
    ) {
        switch content {
        case .message(let text):
            let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return (normalized.isEmpty ? nil : String(normalized.prefix(240)), nil, nil)
        case .generativeUI(let card):
            return ("Hermes shared an interactive card.", card, nil)
        case .bighelpCard(let card):
            return ("Hermes shared a card.", nil, card)
        case .budgetSummary, .weatherAndTasks, .approvalRequest:
            return ("Hermes shared an update.", nil, nil)
        }
    }

    private func applyPresentation(to item: DashboardInboxItem) -> DashboardInboxItem {
        item.withState(
            isRead: presentation.readIDs.contains(item.id),
            isPinned: presentation.pinnedIDs.contains(item.id)
        )
    }

    private func applyPresentation(to item: DashboardAttentionItem) -> DashboardAttentionItem {
        item.withState(
            isRead: presentation.readIDs.contains(item.id),
            isPinned: presentation.pinnedIDs.contains(item.id)
        )
    }

    private func uniqueApprovals(_ values: [DirectHermesDashboardApproval]) -> [DirectHermesDashboardApproval] {
        var seen = Set<String>()
        return values.filter {
            !$0.id.isEmpty && !$0.allowedDecisions.isEmpty && seen.insert($0.id).inserted
        }
    }

    private func uniqueClarifications(_ values: [DirectHermesDashboardClarification]) -> [DirectHermesDashboardClarification] {
        var seen = Set<String>()
        return values.filter {
            !$0.id.isEmpty && !$0.sessionID.isEmpty && !$0.question.isEmpty
                && seen.insert($0.id).inserted
        }
    }

    private func freshness(for date: Date) -> String {
        let seconds = max(0, Int(now().timeIntervalSince(date)))
        if seconds < 60 { return "Just now" }
        if seconds < 3_600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func sortInbox(_ lhs: DashboardInboxItem, _ rhs: DashboardInboxItem) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }

    private func sortAttention(_ lhs: DashboardAttentionItem, _ rhs: DashboardAttentionItem) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }

    private func validateID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 220,
              !id.contains("\0"), id == id.trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw WorkspaceClientError.invalidResponse }
    }

    private static func sessionUpdateID(sessionID: String, itemID: String) -> String {
        let prefix = "native.session."
        let direct = prefix + sessionID + "." + itemID
        guard direct.utf8.count > 220 else { return direct }
        let digestInput = Data((sessionID + "\0" + itemID).utf8)
        return prefix + BighelpLinkBase64URL.encode(Data(SHA256.hash(data: digestInput)))
    }

    private static func key(for authority: WorkspaceAuthority) -> String {
        "direct-hermes-dashboard.presentation.v1.\(authority.cacheScopeID)"
    }

    private static func loadPresentation(defaults: UserDefaults, key: String) -> PresentationState {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(PresentationState.self, from: data) else {
            return PresentationState()
        }
        return value
    }

    private func savePresentation() {
        let limit = 4_096
        if presentation.readIDs.count > limit {
            presentation.readIDs = Set(presentation.readIDs.sorted().suffix(limit))
        }
        if presentation.pinnedIDs.count > limit {
            presentation.pinnedIDs = Set(presentation.pinnedIDs.sorted().suffix(limit))
        }
        if presentation.dismissedIDs.count > limit {
            presentation.dismissedIDs = Set(presentation.dismissedIDs.sorted().suffix(limit))
        }
        guard let data = try? JSONEncoder().encode(presentation) else { return }
        defaults.set(data, forKey: Self.key(for: authority))
    }

    private static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: \.isWhitespace)
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "H" : String(letters).uppercased()
    }
}
