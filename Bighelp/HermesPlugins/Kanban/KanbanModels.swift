import Foundation

enum HermesKanbanAPI: String, CaseIterable, Sendable {
    case assignees = "GET /api/plugins/kanban/assignees"
    case deleteAttachment = "DELETE /api/plugins/kanban/attachments/{attachment_id}"
    case downloadAttachment = "GET /api/plugins/kanban/attachments/{attachment_id}"
    case board = "GET /api/plugins/kanban/board"
    case boards = "GET /api/plugins/kanban/boards"
    case createBoard = "POST /api/plugins/kanban/boards"
    case importBoard = "POST /api/plugins/kanban/boards/import"
    case deleteBoard = "DELETE /api/plugins/kanban/boards/{slug}"
    case editBoard = "PATCH /api/plugins/kanban/boards/{slug}"
    case exportBoard = "POST /api/plugins/kanban/boards/{slug}/export"
    case switchBoard = "POST /api/plugins/kanban/boards/{slug}/switch"
    case config = "GET /api/plugins/kanban/config"
    case diagnostics = "GET /api/plugins/kanban/diagnostics"
    case dispatch = "POST /api/plugins/kanban/dispatch"
    case estimate = "POST /api/plugins/kanban/estimate"
    case events = "WS /api/plugins/kanban/events"
    case homeChannels = "GET /api/plugins/kanban/home-channels"
    case deleteLink = "DELETE /api/plugins/kanban/links"
    case createLink = "POST /api/plugins/kanban/links"
    case modelOptions = "GET /api/plugins/kanban/model-options"
    case orchestration = "GET /api/plugins/kanban/orchestration"
    case editOrchestration = "PUT /api/plugins/kanban/orchestration"
    case profiles = "GET /api/plugins/kanban/profiles"
    case editProfile = "PATCH /api/plugins/kanban/profiles/{profile_name}"
    case describeProfile = "POST /api/plugins/kanban/profiles/{profile_name}/describe-auto"
    case projects = "GET /api/plugins/kanban/projects"
    case run = "GET /api/plugins/kanban/runs/{run_id}"
    case inspectRun = "GET /api/plugins/kanban/runs/{run_id}/inspect"
    case terminateRun = "POST /api/plugins/kanban/runs/{run_id}/terminate"
    case stats = "GET /api/plugins/kanban/stats"
    case createTask = "POST /api/plugins/kanban/tasks"
    case editTasks = "POST /api/plugins/kanban/tasks/bulk"
    case deleteTask = "DELETE /api/plugins/kanban/tasks/{task_id}"
    case task = "GET /api/plugins/kanban/tasks/{task_id}"
    case editTask = "PATCH /api/plugins/kanban/tasks/{task_id}"
    case attachments = "GET /api/plugins/kanban/tasks/{task_id}/attachments"
    case uploadAttachment = "POST /api/plugins/kanban/tasks/{task_id}/attachments"
    case comment = "POST /api/plugins/kanban/tasks/{task_id}/comments"
    case decompose = "POST /api/plugins/kanban/tasks/{task_id}/decompose"
    case estimateTask = "POST /api/plugins/kanban/tasks/{task_id}/estimate"
    case unsubscribeHome = "DELETE /api/plugins/kanban/tasks/{task_id}/home-subscribe/{platform}"
    case subscribeHome = "POST /api/plugins/kanban/tasks/{task_id}/home-subscribe/{platform}"
    case taskLog = "GET /api/plugins/kanban/tasks/{task_id}/log"
    case reassign = "POST /api/plugins/kanban/tasks/{task_id}/reassign"
    case reclaim = "POST /api/plugins/kanban/tasks/{task_id}/reclaim"
    case specify = "POST /api/plugins/kanban/tasks/{task_id}/specify"
    case activeWorkers = "GET /api/plugins/kanban/workers/active"
}

enum HermesKanbanMount: Equatable, Sendable {
    case unknown
    case available
    case unavailable
}

enum HermesKanbanError: Error, Equatable, LocalizedError {
    case unavailable
    case staleOwner
    case invalidRequest
    case invalidResponse
    case capacityExceeded
    case reviewChanged
    case mutationNotVerified
    case operationRefused
    case attachmentTransportRequired
    case eventTransportUnavailable
    case pollingLimitReached

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The selected Hermes host does not have the Kanban dashboard plugin mounted."
        case .staleOwner:
            "The selected host or account changed. Reopen Kanban from the current workspace."
        case .invalidRequest:
            "The Kanban request is invalid. Review the selected board and fields."
        case .invalidResponse:
            "Hermes returned an invalid Kanban response. Refresh before trying again."
        case .capacityExceeded:
            "The Kanban response or attachment exceeds Bighelp’s bounded native limit."
        case .reviewChanged:
            "The board, task, or run changed after review. Refresh and review the current state."
        case .mutationNotVerified:
            "Hermes did not provide authoritative readback for this Kanban change. Refresh before retrying."
        case .operationRefused:
            "Hermes completed the request but refused the requested Kanban outcome. Review the current task or profile state."
        case .attachmentTransportRequired:
            "This Kanban attachment action requires the fixed authenticated multipart/binary transport."
        case .eventTransportUnavailable:
            "The separate Kanban event WebSocket is unavailable; Bighelp will use bounded polling."
        case .pollingLimitReached:
            "Live Kanban polling reached its safety limit. Refresh to continue."
        }
    }
}

enum HermesKanbanTaskStatus: String, CaseIterable, Identifiable, Hashable, Sendable {
    case triage, todo, scheduled, ready, running, blocked, review, done, archived

    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var isTerminal: Bool { self == .done || self == .archived }
    var canBeSetDirectly: Bool { self != .running }
}

struct HermesKanbanBoard: Identifiable, Equatable, Sendable {
    let slug: String
    let name: String
    let summary: String
    let icon: String?
    let color: String?
    let defaultWorkdir: String?
    let projectID: String?
    let projectName: String?
    let isCurrent: Bool
    let isArchived: Bool
    let total: Int
    let counts: [String: Int]

    var id: String { slug }
}

struct HermesKanbanTask: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let body: String?
    let assignee: String?
    let status: HermesKanbanTaskStatus
    let priority: Int
    let createdBy: String?
    let createdAt: Date
    let startedAt: Date?
    let completedAt: Date?
    let tenant: String?
    let workspaceKind: String
    let workspacePath: String?
    let branchName: String?
    let projectID: String?
    let result: String?
    let idempotencyKey: String?
    let latestSummary: String?
    let currentRunID: Int?
    let workerPID: Int?
    let lastHeartbeatAt: Date?
    let maxRuntimeSeconds: Int?
    let modelOverride: String?
    let providerOverride: String?
    let reasoningEffort: String?
    let workflowTemplateID: String?
    let currentStepKey: String?
    let skills: [String]?
    let maximumRetries: Int?
    let consecutiveFailures: Int
    let goalMode: Bool
    let goalMaximumTurns: Int?
    let completionContract: String?
    let blockKind: String?
    let blockRecurrences: Int
    let childCount: Int
    let parentCount: Int
    let commentCount: Int
}

struct HermesKanbanColumn: Identifiable, Equatable, Sendable {
    let status: HermesKanbanTaskStatus
    let tasks: [HermesKanbanTask]
    var id: String { status.rawValue }
}

struct HermesKanbanBoardSnapshot: Equatable, Sendable {
    let board: HermesKanbanBoard
    let columns: [HermesKanbanColumn]
    let tenants: [String]
    let assignees: [String]
    let latestEventID: Int
    let fetchedAt: Date

    var tasks: [HermesKanbanTask] { columns.flatMap(\.tasks) }
}

struct HermesKanbanComment: Identifiable, Equatable, Sendable {
    let id: Int
    let author: String
    let body: String
    let createdAt: Date
}

struct HermesKanbanEvent: Identifiable, Equatable, Sendable {
    let id: Int
    let taskID: String
    let runID: Int?
    let kind: String
    let createdAt: Date
    /// Why it was blocked, when the agent said.
    var reason: String? = nil
    /// Failed starts in a row, when Hermes gave up.
    var failures: Int? = nil
}

struct HermesKanbanAttachment: Identifiable, Equatable, Sendable {
    let id: Int
    let taskID: String
    let filename: String
    let contentType: String?
    let byteCount: Int
    let uploadedBy: String?
    let createdAt: Date
}

struct HermesKanbanRun: Identifiable, Equatable, Sendable {
    let id: Int
    let taskID: String
    let profile: String?
    let status: String
    let workerPID: Int?
    let startedAt: Date
    let endedAt: Date?
    let outcome: String?
    let summary: String?
    let error: String?
    let lastHeartbeatAt: Date?
    let maxRuntimeSeconds: Int?

    var isActive: Bool { endedAt == nil }
}

struct HermesKanbanRunInspection: Equatable, Sendable {
    let runID: Int
    let isAlive: Bool
    let processID: Int?
    let status: String?
    let CPUPercent: Double?
    let residentBytes: Int?
    let virtualBytes: Int?
    let threadCount: Int?
    let reason: String?
}

struct HermesKanbanTaskDetail: Equatable, Sendable {
    let task: HermesKanbanTask
    let comments: [HermesKanbanComment]
    let events: [HermesKanbanEvent]
    let attachments: [HermesKanbanAttachment]
    let parentIDs: [String]
    let childIDs: [String]
    let runs: [HermesKanbanRun]
    let revision: Data

    var latestEventID: Int { events.map(\.id).max() ?? 0 }
}

enum HermesKanbanFieldUpdate<Value: Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case set(Value)
}

struct HermesKanbanTaskPatch: Equatable, Sendable {
    var title: HermesKanbanFieldUpdate<String> = .unchanged
    var body: HermesKanbanFieldUpdate<String> = .unchanged
    var assignee: HermesKanbanFieldUpdate<String?> = .unchanged
    var status: HermesKanbanFieldUpdate<HermesKanbanTaskStatus> = .unchanged
    var priority: HermesKanbanFieldUpdate<Int> = .unchanged
    var blockReason: HermesKanbanFieldUpdate<String> = .unchanged
    var result: HermesKanbanFieldUpdate<String> = .unchanged
    var summary: HermesKanbanFieldUpdate<String> = .unchanged

    var isEmpty: Bool {
        title == .unchanged && body == .unchanged && assignee == .unchanged &&
        status == .unchanged && priority == .unchanged && blockReason == .unchanged &&
        result == .unchanged && summary == .unchanged
    }
}

struct HermesKanbanTaskDraft: Equatable, Sendable {
    var title: String
    var body: String = ""
    var assignee: String?
    var tenant: String?
    var priority: Int = 0
    var workspaceKind: String?
    var workspacePath: String?
    var parentIDs: [String] = []
    var startsInTriage = false
    var maximumRuntimeSeconds: Int?
    var skills: [String]?
    var goalMode = false
    var goalMaximumTurns: Int?
    var idempotencyKey: String?
    var modelOverride: String?
    var providerOverride: String?
    var reasoningEffort: String?
    var projectID: String?
}

struct HermesKanbanTaskCreationReview: Identifiable, Equatable, Sendable {
    let boardSlug: String
    let boardRevision: Data
    let draft: HermesKanbanTaskDraft

    var id: String { "create:\(boardSlug):\(boardRevision.base64EncodedString())" }
}

struct HermesKanbanTaskEditReview: Identifiable, Equatable, Sendable {
    let boardSlug: String
    let task: HermesKanbanTask
    let patch: HermesKanbanTaskPatch
    let revision: Data
    let preparedAt: Date

    var id: String { "edit:\(boardSlug):\(task.id):\(revision.base64EncodedString())" }
}

struct HermesKanbanDispatchReview: Identifiable, Equatable, Sendable {
    let boardSlug: String
    let maximum: Int
    let boardRevision: Data
    let readyCount: Int

    var id: String { "dispatch:\(boardSlug):\(maximum):\(boardRevision.base64EncodedString())" }
}

struct HermesKanbanCommentReview: Identifiable, Equatable, Sendable {
    let boardSlug: String
    let task: HermesKanbanTask
    let body: String
    let revision: Data

    var id: String { "comment:\(boardSlug):\(task.id):\(revision.base64EncodedString())" }
}

struct HermesKanbanRunTerminationReview: Identifiable, Equatable, Sendable {
    let boardSlug: String
    let run: HermesKanbanRun
    let revision: Data
    let taskRevision: Data
    let reason: String?

    var id: String { "terminate:\(boardSlug):\(run.id):\(revision.base64EncodedString())" }
}

struct HermesKanbanAttachmentRemovalReview: Identifiable, Equatable, Sendable {
    let boardSlug: String
    let taskID: String
    let attachment: HermesKanbanAttachment
    let taskRevision: Data

    var id: String { "attachment:\(boardSlug):\(attachment.id):\(taskRevision.base64EncodedString())" }
}

struct HermesKanbanEventBatch: Equatable, Sendable {
    let events: [HermesKanbanEvent]
    let cursor: Int
}

@MainActor
protocol DirectHermesKanbanEventTransport: AnyObject {
    func eventBatches(board: String, since cursor: Int) -> AsyncThrowingStream<HermesKanbanEventBatch, any Error>
}

struct HermesKanbanAttachmentDownload: Equatable, Sendable {
    let attachment: HermesKanbanAttachment
    let bytes: Data
    let contentType: String
}

@MainActor
protocol DirectHermesKanbanAttachmentTransport: AnyObject {
    func uploadKanbanAttachment(
        board: String,
        taskID: String,
        filename: String,
        contentType: String,
        bytes: Data,
        uploadedBy: String,
        maximumResponseBytes: Int
    ) async throws -> BighelpJSONValue

    func downloadKanbanAttachment(
        board: String,
        attachmentID: Int,
        maximumBytes: Int
    ) async throws -> (statusCode: Int, contentType: String?, bytes: Data)
}

enum HermesKanbanLiveUpdate: Equatable, Sendable {
    case events(HermesKanbanEventBatch)
    case snapshot(HermesKanbanBoardSnapshot)
}
