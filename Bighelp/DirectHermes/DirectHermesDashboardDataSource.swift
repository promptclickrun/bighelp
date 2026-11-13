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
/// therefore reads the already authenticated native profile catalog and the native prompt
/// projections (what waits on the person). It never calls Link, the notification relay, or
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

    /// What the person removed from Needs you, kept per computer. Older saves also hold read and
    /// pinned IDs of the Activity screen; they are ignored.
    private struct PresentationState: Codable {
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

        let currentApprovals = uniqueApprovals(approvals())
        let currentClarifications = uniqueClarifications(clarifications())
        let attention = currentAttention(
            approvals: currentApprovals,
            clarifications: currentClarifications
        )

        return DashboardSnapshot(
            attentionItems: attention
                .filter { !presentation.dismissedIDs.contains($0.id) }
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

    func dismissDashboardEvent(id: String) async throws {
        try checkOwner()
        try validateID(id)
        presentation.dismissedIDs.insert(id)
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

    private func sortAttention(_ lhs: DashboardAttentionItem, _ rhs: DashboardAttentionItem) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }

    private func validateID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 220,
              !id.contains("\0"), id == id.trimmingCharacters(in: .whitespacesAndNewlines)
        else { throw WorkspaceClientError.invalidResponse }
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
