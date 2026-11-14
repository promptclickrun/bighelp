import Foundation

enum HermesKanbanDiagnosticSeverity: String, CaseIterable, Identifiable, Sendable {
    case warning, error, critical
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct HermesKanbanConfiguration: Equatable, Sendable {
    let defaultTenant: String
    let laneByProfile: Bool
    let includesArchivedByDefault: Bool
    let rendersMarkdown: Bool
}

struct HermesKanbanStatistics: Equatable, Sendable {
    let countsByStatus: [HermesKanbanTaskStatus: Int]
    let countsByAssignee: [String: [HermesKanbanTaskStatus: Int]]
    let oldestReadyAgeSeconds: Int?
    let fetchedAt: Date
}

struct HermesKanbanDiagnostic: Identifiable, Equatable, Sendable {
    let taskID: String
    let taskTitle: String?
    let taskStatus: HermesKanbanTaskStatus?
    let taskAssignee: String?
    let kind: String
    let severity: HermesKanbanDiagnosticSeverity
    let title: String
    let detail: String
    let count: Int
    let firstSeenAt: Date?
    let lastSeenAt: Date?
    let runID: Int?

    var id: String { "\(taskID):\(kind):\(runID ?? 0)" }
}

struct HermesKanbanProject: Identifiable, Equatable, Sendable {
    let id: String
    let slug: String
    let name: String
    let primaryPath: String
    let icon: String?
    let color: String?
}

struct HermesKanbanModelProvider: Identifiable, Equatable, Sendable {
    let slug: String
    let label: String
    let models: [String]
    var id: String { slug }
}

struct HermesKanbanProfile: Identifiable, Equatable, Sendable {
    let name: String
    let isDefault: Bool
    let model: String
    let provider: String
    let summary: String
    let summaryIsAutomatic: Bool
    let skillCount: Int
    var id: String { name }
}

struct HermesKanbanOrchestration: Equatable, Sendable {
    let orchestratorProfile: String
    let defaultAssignee: String
    let automaticallyDecomposes: Bool
    let automaticallyPromotesChildren: Bool
    let resolvedOrchestratorProfile: String
    let resolvedDefaultAssignee: String
    let activeProfile: String
}

struct HermesKanbanOrchestrationPatch: Equatable, Sendable {
    var orchestratorProfile: HermesKanbanFieldUpdate<String> = .unchanged
    var defaultAssignee: HermesKanbanFieldUpdate<String> = .unchanged
    var automaticallyDecomposes: HermesKanbanFieldUpdate<Bool> = .unchanged
    var automaticallyPromotesChildren: HermesKanbanFieldUpdate<Bool> = .unchanged

    var isEmpty: Bool {
        orchestratorProfile == .unchanged && defaultAssignee == .unchanged &&
        automaticallyDecomposes == .unchanged && automaticallyPromotesChildren == .unchanged
    }
}

struct HermesKanbanHomeChannel: Identifiable, Equatable, Sendable {
    let platform: String
    let name: String
    let isSubscribed: Bool
    var id: String { platform }
}

struct HermesKanbanActiveWorker: Identifiable, Equatable, Sendable {
    let runID: Int
    let taskID: String
    let taskTitle: String
    let assignee: String?
    let profile: String?
    let processID: Int
    let startedAt: Date
    let lastHeartbeatAt: Date?
    let maximumRuntimeSeconds: Int?
    var id: Int { runID }
}

struct HermesKanbanTaskLog: Equatable, Sendable {
    let taskID: String
    let exists: Bool
    let byteCount: Int
    let isTruncated: Bool
}

enum HermesKanbanEstimateComplexity: String, Sendable {
    case small = "S"
    case medium = "M"
    case large = "L"
}

struct HermesKanbanEstimate: Equatable, Sendable {
    let succeeded: Bool
    let estimatedTokens: Int?
    let complexity: HermesKanbanEstimateComplexity?
    let rationale: String?
    let model: String?
    let reason: String?
}

struct HermesKanbanAuxiliaryOutcome: Equatable, Sendable {
    enum Kind: String, Sendable { case specify, decompose, profileDescription }
    let kind: Kind
    let succeeded: Bool
    let targetID: String
    let reason: String?
    let resultingTitle: String?
    let childIDs: [String]
}

struct HermesKanbanDispatchReceipt: Equatable, Sendable {
    let reclaimed: Int
    let promoted: Int
    let spawnedTaskIDs: [String]
    let skippedUnassignedTaskIDs: [String]
    let automaticallyAssignedTaskIDs: [String]
    let autoBlockedTaskIDs: [String]
    let timedOutTaskIDs: [String]
    let staleTaskIDs: [String]
    let wasLocked: Bool
    let memoryPressure: String?
}

struct HermesKanbanDispatchResult: Equatable, Sendable {
    let receipt: HermesKanbanDispatchReceipt
    let board: HermesKanbanBoardSnapshot
}

struct HermesKanbanBoardDraft: Equatable, Sendable {
    var slug: String
    var name: String = ""
    var summary: String = ""
    var icon: String = ""
    var color: String = ""
    var defaultWorkdir: String = ""
    var projectID: String = ""
    var switchAfterCreation = false
}

struct HermesKanbanBoardPatch: Equatable, Sendable {
    var name: HermesKanbanFieldUpdate<String> = .unchanged
    var summary: HermesKanbanFieldUpdate<String> = .unchanged
    var icon: HermesKanbanFieldUpdate<String> = .unchanged
    var color: HermesKanbanFieldUpdate<String> = .unchanged
    var defaultWorkdir: HermesKanbanFieldUpdate<String> = .unchanged
    var projectID: HermesKanbanFieldUpdate<String> = .unchanged

    var isEmpty: Bool {
        name == .unchanged && summary == .unchanged && icon == .unchanged && color == .unchanged &&
        defaultWorkdir == .unchanged && projectID == .unchanged
    }
}

enum HermesKanbanBoardRemovalMode: String, CaseIterable, Identifiable, Sendable {
    case archive
    case delete
    var id: String { rawValue }
    var label: String { self == .archive ? "Archive" : "Delete Permanently" }
}

struct HermesKanbanBoardExportOptions: Equatable, Sendable {
    var includesAttachments = true
    var includesLogs = false
}

struct HermesKanbanBoardExportReceipt: Equatable, Sendable {
    let boardSlug: String
    let archiveFilename: String
    let byteCount: Int
    let counts: [String: Int]
}

struct HermesKanbanBoardImportRequest: Equatable, Sendable {
    var hostArchivePath: String
    var slugOverride: String = ""
    var switchAfterImport = false
}

struct HermesKanbanBoardImportReceipt: Equatable, Sendable {
    let boardSlug: String
    let requestedSlug: String
    let wasRenamed: Bool
    let name: String
    let counts: [String: Int]
    let restoredAttachmentCount: Int
    let parkedTaskCount: Int
    let warnings: [String]
    let wasActivated: Bool
}

struct HermesKanbanBulkPatch: Equatable, Sendable {
    var status: HermesKanbanTaskStatus?
    var assignee: String?
    var changesAssignee = false
    var priority: Int?
    var archives = false
    var reclaimsFirst = false
    var modelOverride: String?
    var providerOverride: String?
    var clearsModelOverride = false
    var reasoningEffort: String?
    var clearsReasoningEffort = false

    var isEmpty: Bool {
        status == nil && !changesAssignee && priority == nil && !archives &&
        modelOverride == nil && !clearsModelOverride &&
        reasoningEffort == nil && !clearsReasoningEffort
    }
}

struct HermesKanbanBulkResult: Equatable, Sendable {
    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let succeeded: Bool
        let safeError: String?
    }
    let items: [Item]
    let verifiedTasks: [HermesKanbanTask]
}

struct HermesKanbanReviewedTaskRevision: Equatable, Sendable {
    let taskID: String
    let revision: Data
}

enum HermesKanbanAdministrationAction: Equatable, Sendable {
    case createBoard(HermesKanbanBoardDraft, catalogRevision: Data)
    case editBoard(HermesKanbanBoard, HermesKanbanBoardPatch, catalogRevision: Data)
    case switchBoard(HermesKanbanBoard, catalogRevision: Data)
    case removeBoard(HermesKanbanBoard, HermesKanbanBoardRemovalMode, catalogRevision: Data)
    case exportBoard(HermesKanbanBoard, HermesKanbanBoardExportOptions, catalogRevision: Data)
    case importBoard(HermesKanbanBoardImportRequest, catalogRevision: Data)
    case editOrchestration(HermesKanbanOrchestration, HermesKanbanOrchestrationPatch, revision: Data)
    case editProfile(HermesKanbanProfile, summary: String, revision: Data)
    case autoDescribeProfile(HermesKanbanProfile, overwrite: Bool, revision: Data)
    case bulkTasks(boardSlug: String, taskIDs: [String], patch: HermesKanbanBulkPatch, revisions: [HermesKanbanReviewedTaskRevision])
    case deleteTask(boardSlug: String, task: HermesKanbanTask, revision: Data)
    case linkTasks(boardSlug: String, parent: HermesKanbanTask, child: HermesKanbanTask, remove: Bool, revisions: [HermesKanbanReviewedTaskRevision])
    case reassignTask(boardSlug: String, task: HermesKanbanTask, profile: String?, reclaimFirst: Bool, reason: String?, revision: Data)
    case reclaimTask(boardSlug: String, task: HermesKanbanTask, reason: String?, revision: Data)
    case specifyTask(boardSlug: String, task: HermesKanbanTask, revision: Data)
    case decomposeTask(boardSlug: String, task: HermesKanbanTask, revision: Data)
    case setHomeSubscription(boardSlug: String, task: HermesKanbanTask, channel: HermesKanbanHomeChannel, subscribed: Bool, revision: Data)
    case addComment(boardSlug: String, task: HermesKanbanTask, body: String, revision: Data)
}

struct HermesKanbanAdministrationReview: Identifiable, Equatable, Sendable {
    let id: UUID
    let action: HermesKanbanAdministrationAction
    let preparedAt: Date

    init(action: HermesKanbanAdministrationAction) {
        id = UUID()
        self.action = action
        preparedAt = Date()
    }

    var title: String {
        switch action {
        case .createBoard: "Create this board?"
        case .editBoard: "Apply these board changes?"
        case .switchBoard: "Switch the host-active board?"
        case .removeBoard(_, let mode, _): mode == .archive ? "Archive this board?" : "Delete this board permanently?"
        case .exportBoard: "Prepare this board archive?"
        case .importBoard: "Import this host archive?"
        case .editOrchestration: "Apply this orchestration policy?"
        case .editProfile: "Update this routing profile?"
        case .autoDescribeProfile: "Generate this routing description?"
        case .bulkTasks: "Apply this bulk task change?"
        case .deleteTask: "Delete this task permanently?"
        case .linkTasks(_, _, _, let remove, _): remove ? "Remove this dependency?" : "Add this dependency?"
        case .reassignTask: "Reassign this task?"
        case .reclaimTask: "Reclaim this active task?"
        case .specifyTask: "Run triage specification?"
        case .decomposeTask: "Decompose this task?"
        case .setHomeSubscription(_, _, _, let subscribed, _): subscribed ? "Enable home updates?" : "Disable home updates?"
        case .addComment: "Post this comment?"
        }
    }

    var actionTitle: String {
        switch action {
        case .createBoard: "Create Board"
        case .editBoard: "Apply Changes"
        case .switchBoard: "Switch Board"
        case .removeBoard(_, let mode, _): mode.label
        case .exportBoard: "Prepare Export"
        case .importBoard: "Import Board"
        case .editOrchestration: "Apply Policy"
        case .editProfile: "Update Profile"
        case .autoDescribeProfile: "Generate Description"
        case .bulkTasks: "Apply to Tasks"
        case .deleteTask: "Delete Task"
        case .linkTasks(_, _, _, let remove, _): remove ? "Remove Dependency" : "Add Dependency"
        case .reassignTask: "Reassign"
        case .reclaimTask: "Reclaim"
        case .specifyTask: "Specify"
        case .decomposeTask: "Decompose"
        case .setHomeSubscription(_, _, _, let subscribed, _): subscribed ? "Enable Updates" : "Disable Updates"
        case .addComment: "Post Comment"
        }
    }

    var isDestructive: Bool {
        switch action {
        case .removeBoard, .deleteTask, .reclaimTask: true
        case .linkTasks(_, _, _, let remove, _): remove
        default: false
        }
    }

    var message: String {
        switch action {
        case .createBoard(let draft, _):
            "Create board “\(draft.slug)” on the selected host after rechecking the board catalog."
        case .editBoard(let board, _, _):
            "Update board “\(board.name)” (\(board.slug)) only if the reviewed catalog still matches."
        case .switchBoard(let board, _):
            "Make “\(board.name)” (\(board.slug)) the active board for host CLI and slash-command operations."
        case .removeBoard(let board, let mode, _):
            "\(mode == .archive ? "Archive" : "Permanently delete") board “\(board.name)” (\(board.slug)) after rechecking its catalog entry."
        case .exportBoard(let board, _, _):
            "Create a portable archive for “\(board.name)” in the plugin-owned staging directory on the selected host."
        case .importBoard(let request, _):
            "Import \((request.hostArchivePath as NSString).lastPathComponent) from the selected host as a new board."
        case .editOrchestration:
            "Update routing defaults on the selected host only if the reviewed orchestration revision still matches."
        case .editProfile(let profile, _, _), .autoDescribeProfile(let profile, _, _):
            "Update routing metadata for profile “\(profile.name)” on the selected host after rechecking its revision."
        case .bulkTasks(let board, let ids, _, _):
            "Apply one reviewed change to \(ids.count) selected task\(ids.count == 1 ? "" : "s") on board \(board). Each task revision will be checked first."
        case .deleteTask(let board, let task, _):
            "Permanently delete “\(task.title)” (\(task.id)) from board \(board) after rechecking its task revision."
        case .linkTasks(let board, let parent, let child, let remove, _):
            "\(remove ? "Remove" : "Add") dependency \(parent.id) → \(child.id) on board \(board) after rechecking both tasks."
        case .reassignTask(let board, let task, let profile, let reclaim, _, _):
            "Route “\(task.title)” on \(board) to \(profile ?? "Unassigned")\(reclaim ? " and release its active claim first" : "")."
        case .reclaimTask(let board, let task, _, _):
            "Release the active worker claim for “\(task.title)” on \(board). Bighelp will verify the run and task readback."
        case .specifyTask(let board, let task, _):
            "Ask the configured auxiliary model to refine triage task “\(task.title)” on \(board). Keep this operation pending until Hermes returns its outcome."
        case .decomposeTask(let board, let task, _):
            "Ask the configured auxiliary model to create children for “\(task.title)” on \(board). Keep this operation pending until Hermes returns its outcome."
        case .setHomeSubscription(let board, let task, let channel, let subscribed, _):
            "\(subscribed ? "Enable" : "Disable") \(channel.name) updates for task \(task.id) on \(board), then verify the channel readback."
        case .addComment(let board, let task, _, _):
            "Post a comment to “\(task.title)” (\(task.id)) on board \(board) after rechecking its task revision."
        }
    }
}

struct HermesKanbanOperationStatus: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case pending
        case completed(String)
        case refused(String)
        case unverified
    }
    let id: UUID
    let title: String
    let target: String
    let startedAt: Date
    var phase: Phase
}

enum HermesKanbanAdministrationResult: Equatable, Sendable {
    case boards([HermesKanbanBoard])
    case boardExport(HermesKanbanBoardExportReceipt)
    case boardImport(HermesKanbanBoardImportReceipt, [HermesKanbanBoard])
    case orchestration(HermesKanbanOrchestration)
    case profile(HermesKanbanProfile, HermesKanbanAuxiliaryOutcome?)
    case bulk(HermesKanbanBulkResult, HermesKanbanBoardSnapshot)
    case task(HermesKanbanTaskDetail?)
    case auxiliary(HermesKanbanAuxiliaryOutcome, HermesKanbanTaskDetail)
    case homeChannels([HermesKanbanHomeChannel], HermesKanbanTaskDetail)
}
