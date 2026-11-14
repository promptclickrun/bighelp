import Foundation
import Observation

@MainActor @Observable
final class HermesKanbanStore {
    enum Review: Identifiable, Equatable {
        case create(HermesKanbanTaskCreationReview)
        case edit(HermesKanbanTaskEditReview)
        case removeAttachment(HermesKanbanAttachmentRemovalReview)
        case terminateRun(HermesKanbanRunTerminationReview)
        case dispatch(HermesKanbanDispatchReview)
        case administration(HermesKanbanAdministrationReview)

        var id: String {
            switch self {
            case .create(let value): value.id
            case .edit(let value): value.id
            case .removeAttachment(let value): value.id
            case .terminateRun(let value): value.id
            case .dispatch(let value): value.id
            case .administration(let value): value.id.uuidString
            }
        }

        var title: String {
            switch self {
            case .create: "Create this Kanban task?"
            case .edit: "Apply these task changes?"
            case .removeAttachment: "Remove this attachment?"
            case .terminateRun: "Terminate this worker run?"
            case .dispatch: "Dispatch ready work now?"
            case .administration(let value): value.title
            }
        }

        var actionTitle: String {
            switch self {
            case .create: "Create Task"
            case .edit: "Apply Changes"
            case .removeAttachment: "Remove Attachment"
            case .terminateRun: "Terminate Run"
            case .dispatch: "Dispatch"
            case .administration(let value): value.actionTitle
            }
        }

        var isDestructive: Bool {
            switch self {
            case .removeAttachment, .terminateRun: true
            case .administration(let value): value.isDestructive
            default: false
            }
        }

        var message: String {
            switch self {
            case .create(let value):
                "Create “\(value.draft.title)” on \(value.boardSlug) if the reviewed board revision is still current."
            case .edit(let value):
                "Update “\(value.task.title)” only if its reviewed task revision still matches Hermes."
            case .removeAttachment(let value):
                "Permanently remove \(value.attachment.filename) from task \(value.taskID). The task revision will be checked again first."
            case .terminateRun(let value):
                "Stop run \(value.run.id) for task \(value.run.taskID). Hermes will reclaim the task and Bighelp will verify the ended run."
            case .dispatch(let value):
                "Ask Hermes to dispatch up to \(value.maximum) tasks from the reviewed board. It currently has \(value.readyCount) ready task\(value.readyCount == 1 ? "" : "s")."
            case .administration(let value):
                value.message
            }
        }
    }

    let hostName: String
    private(set) var mount: HermesKanbanMount = .unknown
    private(set) var boards: [HermesKanbanBoard] = []
    private(set) var boardSnapshot: HermesKanbanBoardSnapshot?
    private(set) var taskDetail: HermesKanbanTaskDetail?
    private(set) var isLoading = false
    private(set) var isMutating = false
    private(set) var isLive = false
    private(set) var usesPollingFallback = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    private(set) var liveStatusMessage: String?
    private(set) var configuration: HermesKanbanConfiguration?
    private(set) var assignees: [String] = []
    private(set) var statistics: HermesKanbanStatistics?
    private(set) var diagnostics: [HermesKanbanDiagnostic] = []
    private(set) var projects: [HermesKanbanProject] = []
    private(set) var profiles: [HermesKanbanProfile] = []
    private(set) var orchestration: HermesKanbanOrchestration?
    private(set) var modelProviders: [HermesKanbanModelProvider] = []
    private(set) var activeWorkers: [HermesKanbanActiveWorker] = []
    private(set) var homeChannels: [HermesKanbanHomeChannel] = []
    private(set) var taskLog: HermesKanbanTaskLog?
    private(set) var estimate: HermesKanbanEstimate?
    private(set) var dispatchReceipt: HermesKanbanDispatchReceipt?
    private(set) var exportReceipt: HermesKanbanBoardExportReceipt?
    private(set) var importReceipt: HermesKanbanBoardImportReceipt?
    private(set) var bulkResult: HermesKanbanBulkResult?
    private(set) var operationStatus: HermesKanbanOperationStatus?
    private(set) var isRetired = false
    var review: Review?

    @ObservationIgnored private let client: DirectHermesKanbanClient
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    init(hostName: String, client: DirectHermesKanbanClient) {
        self.hostName = hostName
        self.client = client
    }

    var ownsScope: Bool { !isRetired && client.ownsScope }
    var canAct: Bool { ownsScope && mount == .available && !isLoading && !isMutating }
    var supportsAttachmentTransfer: Bool { client.supportsAttachmentTransfer }

    func load() async {
        guard ownsScope, !isMutating else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            mount = try await client.discoverMount()
            guard accepts(token) else { return }
            if mount == .available {
                boards = try await client.boards()
                guard accepts(token) else { return }
            } else {
                boards = []
                boardSnapshot = nil
                taskDetail = nil
            }
        } catch is CancellationError {
        } catch {
            guard accepts(token) else { return }
            errorMessage = Self.message(error)
        }
    }

    func refresh() async {
        if let slug = boardSnapshot?.board.slug {
            await openBoard(slug)
        } else {
            await load()
        }
    }

    func openBoard(
        _ slug: String,
        workflowTemplateID: String? = nil,
        currentStepKey: String? = nil
    ) async {
        guard canLoad else { return }
        stopLiveUpdates()
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            let snapshot = try await client.board(
                slug: slug, workflowTemplateID: workflowTemplateID, currentStepKey: currentStepKey
            )
            guard accepts(token) else { return }
            boardSnapshot = snapshot
            taskDetail = nil
            beginLiveUpdates(snapshot)
        } catch is CancellationError {
        } catch {
            guard accepts(token) else { return }
            errorMessage = Self.message(error)
        }
    }

    func openTask(_ taskID: String, board slug: String) async {
        guard canLoad else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            let detail = try await client.task(id: taskID, board: slug)
            guard accepts(token) else { return }
            taskDetail = detail
        } catch is CancellationError {
        } catch {
            guard accepts(token) else { return }
            errorMessage = Self.message(error)
        }
    }

    func reviewCreation(_ draft: HermesKanbanTaskDraft, board slug: String) async {
        await prepareReview {
            .create(try await client.prepareCreation(draft, board: slug))
        }
    }

    func reviewEdit(taskID: String, board slug: String, patch: HermesKanbanTaskPatch) async {
        await prepareReview {
            .edit(try await client.prepareEdit(taskID: taskID, board: slug, patch: patch))
        }
    }

    func reviewAttachmentRemoval(attachmentID: Int, taskID: String, board slug: String) async {
        await prepareReview {
            .removeAttachment(try await client.prepareAttachmentRemoval(
                attachmentID: attachmentID, taskID: taskID, board: slug
            ))
        }
    }

    func reviewRunTermination(runID: Int, board slug: String, reason: String? = nil) async {
        await prepareReview {
            .terminateRun(try await client.prepareRunTermination(id: runID, board: slug, reason: reason))
        }
    }

    func reviewDispatch(board slug: String, maximum: Int = 8) async {
        await prepareReview {
            .dispatch(try await client.prepareDispatcherNudge(board: slug, maximum: maximum))
        }
    }

    func confirm(_ expected: Review) async {
        guard canAct, review == expected else {
            review = nil
            return
        }
        review = nil
        let token = UUID()
        generation = token
        isMutating = true
        errorMessage = nil
        successMessage = nil
        defer { if generation == token { isMutating = false } }
        do {
            switch expected {
            case .create(let approved):
                taskDetail = try await client.create(approved: approved)
                successMessage = "Hermes created the task and Bighelp verified its detail readback."
            case .edit(let approved):
                taskDetail = try await client.edit(approved: approved)
                successMessage = "Hermes applied the task change and Bighelp verified the new revision."
            case .removeAttachment(let approved):
                try await client.removeAttachment(approved: approved)
                taskDetail = try await client.task(id: approved.taskID, board: approved.boardSlug)
                successMessage = "Hermes removed the attachment and Bighelp verified it is absent."
            case .terminateRun(let approved):
                _ = try await client.terminateRun(approved: approved)
                taskDetail = try await client.task(id: approved.run.taskID, board: approved.boardSlug)
                successMessage = "Hermes ended the run and Bighelp verified the task is no longer running."
            case .dispatch(let approved):
                let result = try await client.nudgeDispatcher(approved: approved)
                boardSnapshot = result.board
                dispatchReceipt = result.receipt
                successMessage = "Hermes processed the dispatch request and returned a typed receipt. Bighelp refreshed the authoritative board."
            case .administration(let approved):
                let statusID = UUID()
                operationStatus = .init(
                    id: statusID, title: approved.actionTitle, target: approved.message,
                    startedAt: Date(), phase: .pending
                )
                let result = try await client.perform(approved: approved)
                guard accepts(token) else { return }
                apply(result)
                operationStatus = .init(
                    id: statusID, title: approved.actionTitle, target: approved.message,
                    startedAt: operationStatus?.startedAt ?? Date(),
                    phase: .completed("Hermes returned a typed result and Bighelp completed authoritative readback.")
                )
                successMessage = "Hermes completed the reviewed Kanban operation and Bighelp verified its readback."
            }
            guard accepts(token) else { return }
            if let slug = boardSnapshot?.board.slug {
                let snapshot = try await client.board(slug: slug)
                guard accepts(token) else { return }
                boardSnapshot = snapshot
            }
        } catch is CancellationError {
            guard accepts(token) else { return }
            if let pending = operationStatus, case .pending = pending.phase {
                operationStatus = .init(
                    id: pending.id, title: pending.title, target: pending.target,
                    startedAt: pending.startedAt, phase: .unverified
                )
            }
            errorMessage = "The operation was interrupted. Refresh Kanban before trying again."
        } catch {
            guard accepts(token) else { return }
            if let pending = operationStatus, case .pending = pending.phase {
                let phase: HermesKanbanOperationStatus.Phase =
                    (error as? HermesKanbanError) == .operationRefused
                    ? .refused(Self.message(error))
                    : .unverified
                operationStatus = .init(
                    id: pending.id, title: pending.title, target: pending.target,
                    startedAt: pending.startedAt, phase: phase
                )
            }
            errorMessage = Self.message(error)
        }
    }

    func reviewComment(_ body: String, taskID: String, board slug: String) async {
        await prepareReview {
            let prepared = try await client.prepareComment(body, taskID: taskID, board: slug)
            return .administration(.init(action: .addComment(
                boardSlug: prepared.boardSlug, task: prepared.task,
                body: prepared.body, revision: prepared.revision
            )))
        }
    }

    func clearTaskSelection() { taskDetail = nil }

    func retire() {
        isRetired = true
        generation = UUID()
        stopLiveUpdates()
        boards = []
        boardSnapshot = nil
        taskDetail = nil
        review = nil
        errorMessage = nil
        successMessage = nil
        configuration = nil
        assignees = []
        statistics = nil
        diagnostics = []
        projects = []
        profiles = []
        orchestration = nil
        modelProviders = []
        activeWorkers = []
        homeChannels = []
        taskLog = nil
        estimate = nil
        dispatchReceipt = nil
        exportReceipt = nil
        importReceipt = nil
        bulkResult = nil
        operationStatus = nil
        isLoading = false
        isMutating = false
    }

    private var canLoad: Bool { ownsScope && mount == .available && !isMutating }

    private func prepareReview(_ operation: () async throws -> Review) async {
        guard canAct else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let prepared = try await operation()
            guard ownsScope else { return }
            review = prepared
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    private func beginLiveUpdates(_ snapshot: HermesKanbanBoardSnapshot) {
        stopLiveUpdates()
        usesPollingFallback = !client.supportsSeparateEventStream
        liveStatusMessage = usesPollingFallback
            ? "Using bounded board polling because the separate Kanban event WebSocket is not connected."
            : "Connected to the Kanban event stream."
        do {
            let stream = try client.liveUpdates(
                board: snapshot.board.slug,
                since: snapshot.latestEventID,
                maximumPolls: 90
            )
            isLive = true
            liveTask = Task { @MainActor [weak self] in
                do {
                    for try await update in stream {
                        guard let self, self.ownsScope,
                              self.boardSnapshot?.board.slug == snapshot.board.slug else { return }
                        switch update {
                        case .snapshot(let value):
                            self.boardSnapshot = value
                        case .events:
                            // Event payloads are notification-only. Re-read the typed
                            // board instead of applying arbitrary event JSON to UI state.
                            self.boardSnapshot = try await self.client.board(slug: snapshot.board.slug)
                        }
                    }
                } catch HermesKanbanError.pollingLimitReached {
                    guard let self, self.ownsScope else { return }
                    self.liveStatusMessage = "Bounded live polling paused. Pull to refresh to start another window."
                } catch is CancellationError {
                } catch {
                    guard let self, self.ownsScope else { return }
                    self.liveStatusMessage = Self.message(error)
                }
                self?.isLive = false
            }
        } catch {
            isLive = false
            liveStatusMessage = Self.message(error)
        }
    }

    private func stopLiveUpdates() {
        liveTask?.cancel()
        liveTask = nil
        isLive = false
    }

    private func accepts(_ token: UUID) -> Bool {
        ownsScope && generation == token && !Task.isCancelled
    }

    private static func message(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let message = localized.errorDescription {
            return message
        }
        return "Hermes could not complete the Kanban request. Refresh the mounted plugin state before trying again."
    }
}

extension HermesKanbanStore {
    func loadAdministration(board slug: String) async {
        guard canLoad else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        assignees = []
        statistics = nil
        diagnostics = []
        activeWorkers = []
        defer { if generation == token { isLoading = false } }
        var loadedFamilies = 0
        if let value = try? await client.configuration() {
            configuration = value
            loadedFamilies += 1
        }
        guard accepts(token) else { return }
        if let value = try? await client.assignees(board: slug) { assignees = value; loadedFamilies += 1 }
        if let value = try? await client.statistics(board: slug) { statistics = value; loadedFamilies += 1 }
        if let value = try? await client.diagnostics(board: slug) { diagnostics = value; loadedFamilies += 1 }
        if let value = try? await client.projects() { projects = value; loadedFamilies += 1 }
        if let value = try? await client.profiles() { profiles = value; loadedFamilies += 1 }
        if let value = try? await client.orchestration() { orchestration = value; loadedFamilies += 1 }
        if let value = try? await client.modelOptions() { modelProviders = value; loadedFamilies += 1 }
        if let value = try? await client.activeWorkers(board: slug) { activeWorkers = value; loadedFamilies += 1 }
        guard accepts(token) else { return }
        if loadedFamilies == 0 {
            errorMessage = "Kanban administration routes are unavailable on the selected host. Ordinary boards and tasks remain available."
        }
    }

    func loadTaskAdministration(taskID: String, board slug: String) async {
        guard canLoad else { return }
        let token = UUID()
        generation = token
        isLoading = true
        errorMessage = nil
        defer { if generation == token { isLoading = false } }
        if let channels = try? await client.homeChannels(taskID: taskID, board: slug) {
            homeChannels = channels
        }
        taskLog = try? await client.taskLogMetadata(taskID: taskID, board: slug)
        guard accepts(token) else { return }
    }

    func estimateDraft(title: String, body: String?) async {
        await readOperation { estimate = try await client.estimate(title: title, body: body) }
    }

    func estimateTask(taskID: String, board slug: String) async {
        await readOperation { estimate = try await client.estimate(taskID: taskID, board: slug) }
    }

    func reviewBoardCreation(_ draft: HermesKanbanBoardDraft) async {
        await prepareReview { .administration(try await client.prepareBoardCreation(draft)) }
    }

    func reviewBoardEdit(slug: String, patch: HermesKanbanBoardPatch) async {
        await prepareReview { .administration(try await client.prepareBoardEdit(slug: slug, patch: patch)) }
    }

    func reviewBoardSwitch(slug: String) async {
        await prepareReview { .administration(try await client.prepareBoardSwitch(slug: slug)) }
    }

    func reviewBoardRemoval(slug: String, mode: HermesKanbanBoardRemovalMode) async {
        await prepareReview { .administration(try await client.prepareBoardRemoval(slug: slug, mode: mode)) }
    }

    func reviewBoardExport(slug: String, options: HermesKanbanBoardExportOptions) async {
        await prepareReview { .administration(try await client.prepareBoardExport(slug: slug, options: options)) }
    }

    func reviewBoardImport(_ request: HermesKanbanBoardImportRequest) async {
        await prepareReview { .administration(try await client.prepareBoardImport(request)) }
    }

    func reviewOrchestration(_ patch: HermesKanbanOrchestrationPatch) async {
        await prepareReview { .administration(try await client.prepareOrchestrationEdit(patch)) }
    }

    func reviewProfile(name: String, summary: String) async {
        await prepareReview { .administration(try await client.prepareProfileEdit(name: name, summary: summary)) }
    }

    func reviewAutomaticProfileDescription(name: String, overwrite: Bool) async {
        await prepareReview {
            .administration(try await client.prepareAutomaticProfileDescription(name: name, overwrite: overwrite))
        }
    }

    func reviewBulk(ids: [String], board slug: String, patch: HermesKanbanBulkPatch) async {
        await prepareReview {
            .administration(try await client.prepareBulkTasks(ids: ids, board: slug, patch: patch))
        }
    }

    func reviewTaskDeletion(taskID: String, board slug: String) async {
        await prepareReview { .administration(try await client.prepareTaskDeletion(taskID: taskID, board: slug)) }
    }

    func reviewTaskLink(parentID: String, childID: String, board slug: String, remove: Bool) async {
        await prepareReview {
            .administration(try await client.prepareTaskLink(
                parentID: parentID, childID: childID, board: slug, remove: remove
            ))
        }
    }

    func reviewReassignment(
        taskID: String, board slug: String, profile: String?, reclaimFirst: Bool, reason: String?
    ) async {
        await prepareReview {
            .administration(try await client.prepareReassignment(
                taskID: taskID, board: slug, profile: profile, reclaimFirst: reclaimFirst, reason: reason
            ))
        }
    }

    func reviewReclaim(taskID: String, board slug: String, reason: String?) async {
        await prepareReview {
            .administration(try await client.prepareReclaim(taskID: taskID, board: slug, reason: reason))
        }
    }

    func reviewSpecify(taskID: String, board slug: String) async {
        await prepareReview { .administration(try await client.prepareSpecify(taskID: taskID, board: slug)) }
    }

    func reviewDecompose(taskID: String, board slug: String) async {
        await prepareReview { .administration(try await client.prepareDecompose(taskID: taskID, board: slug)) }
    }

    func reviewHomeSubscription(taskID: String, board slug: String, platform: String, subscribed: Bool) async {
        await prepareReview {
            .administration(try await client.prepareHomeSubscription(
                taskID: taskID, board: slug, platform: platform, subscribed: subscribed
            ))
        }
    }

    private func readOperation(_ operation: () async throws -> Void) async {
        guard canAct else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await operation()
        } catch is CancellationError {
        } catch {
            guard ownsScope else { return }
            errorMessage = Self.message(error)
        }
    }

    private func apply(_ result: HermesKanbanAdministrationResult) {
        switch result {
        case .boards(let value):
            boards = value
            if let currentSlug = boardSnapshot?.board.slug,
               !value.contains(where: { $0.slug == currentSlug }) {
                boardSnapshot = nil
                taskDetail = nil
                stopLiveUpdates()
            }
        case .boardExport(let value):
            exportReceipt = value
        case .boardImport(let receipt, let value):
            importReceipt = receipt
            boards = value
        case .orchestration(let value):
            orchestration = value
        case .profile(let value, _):
            if let index = profiles.firstIndex(where: { $0.id == value.id }) {
                profiles[index] = value
            } else {
                profiles.append(value)
            }
        case .bulk(let value, let board):
            bulkResult = value
            boardSnapshot = board
            taskDetail = nil
        case .task(let value):
            taskDetail = value
        case .auxiliary(_, let detail):
            taskDetail = detail
        case .homeChannels(let channels, let detail):
            homeChannels = channels
            taskDetail = detail
        }
    }
}
