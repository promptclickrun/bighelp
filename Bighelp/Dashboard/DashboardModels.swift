import Foundation

enum DashboardEventIntentPolicy {
    static let intentionalUserSurfaceTypes = ["channel.message"]
    static let notificationSurfaceTypes: Set<String> = [
        "channel.message", "attention.required", "approval.required",
    ]
    static let completedLifecycleTypes: Set<String> = [
        "delegation.completed", "job.completed", "session.completed",
    ]
    static let supportedEventTypes: Set<String> = [
        "approval.required", "attention.required", "channel.message",
        "delegation.completed", "delegation.started", "delegation.updated",
        "job.completed", "job.failed", "session.completed", "session.failed",
        "task.updated",
    ]

    static func isIntentionalUserSurface(
        eventType: String,
        message: String?
    ) -> Bool {
        guard intentionalUserSurfaceTypes.contains(eventType) else { return false }
        let message = message?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return !operationalNoisePrefixes.contains(where: message.hasPrefix)
    }

    static func isNotificationSurface(
        eventType: String,
        message: String?
    ) -> Bool {
        guard notificationSurfaceTypes.contains(eventType) else { return false }
        if eventType != "channel.message" { return true }
        return isIntentionalUserSurface(eventType: eventType, message: message)
    }

    static func isCompletedLifecycle(_ eventType: String) -> Bool {
        completedLifecycleTypes.contains(eventType)
    }

    private static let operationalNoisePrefixes = [
        "♻️ Gateway online", "♻ Gateway online",
        "♻️ Gateway restarted", "♻ Gateway restarted",
        "⚠️ Gateway restarting", "⚠ Gateway restarting",
        "⚠️ Gateway shutting down", "⚠ Gateway shutting down",
    ]
}

struct DashboardSnapshot: Equatable, Sendable {
    let inbox: [DashboardInboxItem]
    let attentionItems: [DashboardAttentionItem]
    let completedItems: [DashboardCompletion]
    let agents: [DashboardAgent]
}

struct DashboardInboxItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let agentName: String
    let status: String
    let card: GenerativeUICard?
    let bighelpCard: BighelpCardDocument?
    let sessionID: String?
    let agentID: String?
    let isRead: Bool
    let isPinned: Bool
    let isSessionClosed: Bool
    let createdAt: Date

    init(
        id: String,
        title: String,
        detail: String,
        agentName: String,
        status: String,
        card: GenerativeUICard? = nil,
        bighelpCard: BighelpCardDocument? = nil,
        sessionID: String? = nil,
        agentID: String? = nil,
        isRead: Bool = false,
        isPinned: Bool = false,
        isSessionClosed: Bool = false,
        createdAt: Date = .distantPast
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.agentName = agentName
        self.status = status
        self.card = card
        self.bighelpCard = bighelpCard
        self.sessionID = sessionID
        self.agentID = agentID
        self.isRead = isRead
        self.isPinned = isPinned
        self.isSessionClosed = isSessionClosed
        self.createdAt = createdAt
    }

    var cardEnvelope: BighelpCardEnvelope? {
        if let bighelpCard { return .card(bighelpCard) }
        if let card { return .legacy(card) }
        return nil
    }

    var cardImportance: BighelpCardImportance {
        bighelpCard?.importance ?? .normal
    }

    func withState(isRead: Bool, isPinned: Bool) -> DashboardInboxItem {
        DashboardInboxItem(
            id: id,
            title: title,
            detail: detail,
            agentName: agentName,
            status: status,
            card: card,
            bighelpCard: bighelpCard,
            sessionID: sessionID,
            agentID: agentID,
            isRead: isRead,
            isPinned: isPinned,
            isSessionClosed: isSessionClosed,
            createdAt: createdAt
        )
    }
}

struct DashboardClarificationQuestion: Equatable, Sendable, Identifiable {
    let id: String
    let question: String
    let choices: [String]
    let allowsCustomResponse: Bool
    let isMultiSelect: Bool
    let lockedAnswer: String?

    init(
        id: String,
        question: String,
        choices: [String] = [],
        allowsCustomResponse: Bool = true,
        isMultiSelect: Bool = false,
        lockedAnswer: String? = nil
    ) {
        self.id = id
        self.question = question
        self.choices = choices
        self.allowsCustomResponse = allowsCustomResponse
        self.isMultiSelect = isMultiSelect
        self.lockedAnswer = lockedAnswer
    }
}

struct DashboardClarificationAnswer: Equatable, Sendable {
    let questionID: String
    let value: String
}

struct DashboardClarificationResponse: Equatable, Sendable {
    let answers: [DashboardClarificationAnswer]

    func answer(for questionID: String) -> String? {
        let identity = Data(questionID.utf8)
        let matches = answers.filter { Data($0.questionID.utf8) == identity }
        return matches.count == 1 ? matches[0].value : nil
    }

    var singleAnswer: String? {
        answers.count == 1 ? answers[0].value : nil
    }
}

struct DashboardClarificationRequest: Equatable, Sendable {
    let eventID: String
    let requestID: String
    let sessionID: String
    let questions: [DashboardClarificationQuestion]
    let expiresAt: Date?

    init(
        eventID: String,
        requestID: String,
        sessionID: String,
        question: String,
        choices: [String],
        allowsCustomResponse: Bool,
        isMultiSelect: Bool,
        expiresAt: Date?
    ) {
        self.init(
            eventID: eventID,
            requestID: requestID,
            sessionID: sessionID,
            questions: [DashboardClarificationQuestion(
                id: "q0",
                question: question,
                choices: choices,
                allowsCustomResponse: allowsCustomResponse,
                isMultiSelect: isMultiSelect
            )],
            expiresAt: expiresAt
        )
    }

    init(
        eventID: String,
        requestID: String,
        sessionID: String,
        questions: [DashboardClarificationQuestion],
        expiresAt: Date?
    ) {
        self.eventID = eventID
        self.requestID = requestID
        self.sessionID = sessionID
        self.questions = questions
        self.expiresAt = expiresAt
    }

    var question: String { questions.first?.question ?? "" }
    var choices: [String] { questions.first?.choices ?? [] }
    var allowsCustomResponse: Bool { questions.count == 1 && questions[0].allowsCustomResponse }
    var isMultiSelect: Bool { questions.count != 1 || questions[0].isMultiSelect }

    func isExpired(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return date >= expiresAt
    }

    func accepts(_ response: DashboardClarificationResponse) -> Bool {
        guard !questions.isEmpty, response.answers.count == questions.count else { return false }
        var seen = Set<Data>()
        for question in questions {
            let identity = Data(question.id.utf8)
            guard seen.insert(identity).inserted,
                  let answer = response.answer(for: question.id),
                  !answer.isEmpty,
                  answer.utf8.count <= 10_000,
                  !answer.contains("\0") else { return false }
            if let locked = question.lockedAnswer,
               !answer.utf8.elementsEqual(locked.utf8) { return false }
        }
        return response.answers.allSatisfy { answer in
            questions.contains { Data($0.id.utf8) == Data(answer.questionID.utf8) }
        }
    }
}

struct DashboardClarificationReceipt: Equatable, Sendable {
    let eventID: String
    let requestID: String
}

@MainActor
protocol DashboardClarificationClient {
    func respond(
        to request: DashboardClarificationRequest,
        response: String
    ) async throws -> DashboardClarificationReceipt

    func respond(
        to request: DashboardClarificationRequest,
        response: DashboardClarificationResponse
    ) async throws -> DashboardClarificationReceipt
}

extension DashboardClarificationClient {
    func respond(
        to request: DashboardClarificationRequest,
        response: DashboardClarificationResponse
    ) async throws -> DashboardClarificationReceipt {
        guard request.questions.count == 1,
              request.accepts(response),
              let value = response.singleAnswer else {
            throw DashboardMutationError.unsupported
        }
        return try await respond(to: request, response: value)
    }
}

struct DashboardApprovalRequest: Equatable, Sendable {
    let eventID: String
    let approvalID: String
    let allowedDecisions: [ApprovalDecision]
    let expiresAt: Date

    func isExpired(at date: Date) -> Bool {
        date >= expiresAt
    }
}

enum DashboardAttentionInteraction: Equatable, Sendable {
    case none
    case clarification(DashboardClarificationRequest)
    case approval(DashboardApprovalRequest)

    var isStructuredDecision: Bool {
        switch self {
        case .none: false
        case .clarification, .approval: true
        }
    }
}


struct DashboardAttentionItem: Identifiable, Equatable, Sendable {
    enum Urgency: String, Equatable, Sendable {
        case important
        case needsReview

        var title: String {
            switch self {
            case .important: "Important"
            case .needsReview: "Needs review"
            }
        }

        var systemImage: String {
            switch self {
            case .important: "exclamationmark.triangle.fill"
            case .needsReview: "eye.fill"
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let urgency: Urgency
    let approvalID: String?
    let sessionID: String?
    let agentID: String?
    let isRead: Bool
    let isPinned: Bool
    let isSessionClosed: Bool
    let interaction: DashboardAttentionInteraction
    let createdAt: Date

    init(
        id: String,
        title: String,
        detail: String,
        urgency: Urgency,
        approvalID: String? = nil,
        sessionID: String? = nil,
        agentID: String? = nil,
        isRead: Bool = false,
        isPinned: Bool = false,
        isSessionClosed: Bool = false,
        interaction: DashboardAttentionInteraction = .none,
        createdAt: Date = .distantPast
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.urgency = urgency
        self.approvalID = approvalID
        self.sessionID = sessionID
        self.agentID = agentID
        self.isRead = isRead
        self.isPinned = isPinned
        self.isSessionClosed = isSessionClosed
        self.interaction = interaction
        self.createdAt = createdAt
    }

    var owningSessionID: String? {
        if case .clarification(let request) = interaction {
            guard sessionID == nil || sessionID == request.sessionID else { return nil }
            return request.sessionID
        }
        return sessionID
    }

    func withState(isRead: Bool, isPinned: Bool) -> DashboardAttentionItem {
        DashboardAttentionItem(
            id: id,
            title: title,
            detail: detail,
            urgency: urgency,
            approvalID: approvalID,
            sessionID: sessionID,
            agentID: agentID,
            isRead: isRead,
            isPinned: isPinned,
            isSessionClosed: isSessionClosed,
            interaction: interaction,
            createdAt: createdAt
        )
    }
}

struct DashboardCompletion: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let taskID: String?
    let jobID: String?
    let agentName: String?
    let status: String
    let completedAt: Date
    let completedLabel: String
    let sessionID: String?
    let agentID: String?
    let childSessionID: String?
    let parentSessionID: String?
    let delegationID: String?
    let turnID: String?

    init(
        id: String,
        title: String,
        detail: String,
        taskID: String? = nil,
        jobID: String? = nil,
        agentName: String? = nil,
        status: String = "completed",
        completedAt: Date = .distantPast,
        completedLabel: String,
        sessionID: String? = nil,
        agentID: String? = nil,
        childSessionID: String? = nil,
        parentSessionID: String? = nil,
        delegationID: String? = nil,
        turnID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.taskID = taskID
        self.jobID = jobID
        self.agentName = agentName
        self.status = status
        self.completedAt = completedAt
        self.completedLabel = completedLabel
        self.sessionID = sessionID
        self.agentID = agentID
        self.childSessionID = childSessionID
        self.parentSessionID = parentSessionID
        self.delegationID = delegationID
        self.turnID = turnID
    }

    func presented(title: String, sessionID: String?) -> DashboardCompletion {
        DashboardCompletion(
            id: id, title: title, detail: detail, taskID: taskID, jobID: jobID,
            agentName: agentName, status: status, completedAt: completedAt,
            completedLabel: completedLabel, sessionID: sessionID, agentID: agentID,
            childSessionID: childSessionID, parentSessionID: parentSessionID,
            delegationID: delegationID, turnID: turnID
        )
    }
}

enum DashboardCompletionProjection {
    static func make(
        id: String,
        eventType: String,
        detail: [String: String],
        agentName: String,
        createdAt: Date,
        completedLabel: String,
        fallbackTitle: String,
        fallbackDetail: String,
        sessionID: String? = nil,
        agentID: String? = nil
    ) -> DashboardCompletion {
        let copy = eventType == "job.completed"
            ? jobCopy(detail: detail)
            : (
                DashboardWorkProjection.meaningfulTitle(detail["title"])
                    ?? (eventType == "delegation.completed" ? "Subagent task" : "Conversation"),
                fallbackDetail
            )
        return DashboardCompletion(
            id: id,
            title: copy.0,
            detail: copy.1,
            taskID: normalized(detail["task_id"], maximum: 180),
            jobID: normalized(detail["job_id"], maximum: 180),
            agentName: agentName,
            status: eventType,
            completedAt: createdAt,
            completedLabel: completedLabel,
            sessionID: sessionID,
            agentID: agentID,
            childSessionID: coordinate(detail["child_session_id"]),
            parentSessionID: coordinate(detail["parent_session_id"]),
            delegationID: coordinate(detail["delegation_id"]),
            turnID: coordinate(detail["turn_id"])
        )
    }

    private static func coordinate(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 180,
              !value.contains("\0"), !value.contains(where: \.isWhitespace)
        else { return nil }
        return value
    }

    private static func jobCopy(detail: [String: String]) -> (String, String) {
        let title = ["task_name", "task_title", "job_title"]
            .compactMap { normalized(detail[$0], maximum: 160) }
            .first
            ?? distinctJobTitle(detail["title"])
            ?? "Scheduled task"
        let result = ["summary", "message", "result", "detail", "description"]
            .compactMap { normalized(detail[$0], maximum: 240) }
            .first { $0 != title }
            ?? "No result details were provided."
        return (title, result)
    }

    private static func distinctJobTitle(_ value: String?) -> String? {
        guard let value = normalized(value, maximum: 160) else { return nil }
        return ["Scheduled task completed", "Job completed"].contains(value) ? nil : value
    }

    private static func normalized(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let normalized = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? nil : String(normalized.prefix(maximum))
    }
}

struct DashboardAgent: Identifiable, Equatable, Sendable {
    let id: String
    let initials: String
    let name: String
    let role: String
    let availability: String
}

@MainActor
protocol DashboardDataSource {
    func loadDashboard() async throws -> DashboardSnapshot
    func setDashboardEventState(id: String, isRead: Bool, isPinned: Bool) async throws
    func dismissDashboardEvent(id: String) async throws
    func dismissDashboardEvents(types: [String], createdBefore: Date) async throws
}

enum DashboardMutationError: Error {
    case unsupported
}

extension DashboardDataSource {
    func setDashboardEventState(id: String, isRead: Bool, isPinned: Bool) async throws {
        throw DashboardMutationError.unsupported
    }

    func dismissDashboardEvent(id: String) async throws {
        throw DashboardMutationError.unsupported
    }

    func dismissDashboardEvents(types: [String], createdBefore: Date) async throws {
        throw DashboardMutationError.unsupported
    }
}

enum DashboardLoadingState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failure(message: String)
}
