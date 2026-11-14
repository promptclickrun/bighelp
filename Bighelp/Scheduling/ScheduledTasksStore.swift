import Foundation
import Observation

enum ScheduledTasksLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

@MainActor
@Observable
final class ScheduledTasksStore {
    private let client: any ScheduledTasksClient
    private(set) var tasks: [ScheduledTask] = []
    private(set) var deliveryTargets: [ScheduledTaskDeliveryTarget] = []
    private(set) var isLoadingDeliveryTargets = false
    private(set) var deliveryTargetsErrorMessage: String?
    private(set) var loadState: ScheduledTasksLoadState = .idle
    private(set) var detailLoadStates: [ScheduledTaskIdentity: ScheduledTasksLoadState] = [:]
    private(set) var runsByTask: [ScheduledTaskIdentity: [ScheduledTaskRun]] = [:]
    private(set) var runsLoadStates: [ScheduledTaskIdentity: ScheduledTasksLoadState] = [:]
    private(set) var blueprints: [ScheduledTaskBlueprint] = []
    private(set) var blueprintsLoadState: ScheduledTasksLoadState = .idle
    private(set) var isInstantiatingBlueprint = false
    private(set) var blueprintErrorMessage: String?
    private(set) var pendingTaskIdentities: Set<ScheduledTaskIdentity> = []
    private(set) var isCreating = false
    private(set) var recoverableDraft: ScheduledTaskDraft?
    private(set) var errorMessage: String?
    var agentFilterID: String?
    var statusFilter: ScheduledTaskFilter = .all
    private var accountGeneration: UInt64 = 0
    private var detailRequests: [ScheduledTaskIdentity: UUID] = [:]
    private var runsRequests: [ScheduledTaskIdentity: UUID] = [:]
    private var blueprintsRequest = UUID()

    init(client: any ScheduledTasksClient, initialAgentID: String?) {
        self.client = client
        agentFilterID = initialAgentID
    }

    var visibleTasks: [ScheduledTask] {
        tasks
            .filter { task in
                guard let agentFilterID else { return true }
                return task.agentID.utf8.elementsEqual(agentFilterID.utf8)
            }
            .filter { statusFilter == .all || $0.status.rawValue == statusFilter.rawValue }
            .sorted(by: sort)
    }

    func task(id: String, agentID: String? = nil) -> ScheduledTask? {
        let matches = matchingTasks(id: id, agentID: agentID)
        return matches.count == 1 ? matches[0] : nil
    }

    func taskLookupMessage(id: String, agentID: String? = nil) -> String {
        matchingTasks(id: id, agentID: agentID).count > 1
            ? ScheduledTasksError.ambiguousTask.localizedDescription
            : ScheduledTasksError.taskNotFound.localizedDescription
    }

    func detailLoadState(for task: ScheduledTask) -> ScheduledTasksLoadState {
        detailLoadStates[task.identity] ?? .idle
    }

    func runs(for task: ScheduledTask) -> [ScheduledTaskRun] {
        runsByTask[task.identity] ?? []
    }

    /// When the task last ran: what Hermes says, else its newest run in the history.
    func lastRun(for task: ScheduledTask) -> Date? {
        task.lastRun ?? runs(for: task).first?.startedAt
    }

    func runsLoadState(for task: ScheduledTask) -> ScheduledTasksLoadState {
        runsLoadStates[task.identity] ?? .idle
    }

    func isPending(_ id: String, agentID: String? = nil) -> Bool {
        if let agentID { return pendingTaskIdentities.contains(.init(profileID: agentID, jobID: id)) }
        if id == "create" { return isCreating }
        return pendingTaskIdentities.contains { $0.jobID.utf8.elementsEqual(id.utf8) }
    }

    func load() async {
        let generation = accountGeneration
        loadState = .loading
        errorMessage = nil
        do {
            let loadedTasks = try await client.list(agentID: nil)
            guard generation == accountGeneration else { return }
            guard Set(loadedTasks.map(\.identity)).count == loadedTasks.count else { throw ScheduledTasksError.invalidCatalog }
            tasks = loadedTasks.sorted(by: sort)
            loadState = .loaded
        } catch {
            guard generation == accountGeneration else { return }
            loadState = .failed(message(for: error))
        }
    }

    func loadDetail(id: String, agentID: String) async {
        guard let task = task(id: id, agentID: agentID) else { return }
        let generation = accountGeneration
        let request = UUID()
        detailRequests[task.identity] = request
        detailLoadStates[task.identity] = .loading
        do {
            let loaded = try await client.detail(id: task.id, agentID: task.agentID)
            guard generation == accountGeneration, detailRequests[task.identity] == request else { return }
            guard loaded.identity == task.identity else { throw WorkspaceClientError.invalidResponse }
            replace(loaded)
            detailLoadStates[task.identity] = .loaded
        } catch {
            guard generation == accountGeneration, detailRequests[task.identity] == request else { return }
            detailLoadStates[task.identity] = .failed(message(for: error))
        }
    }

    func loadRuns(id: String, agentID: String, limit: Int = 20) async {
        guard let task = task(id: id, agentID: agentID) else { return }
        let generation = accountGeneration
        let request = UUID()
        runsRequests[task.identity] = request
        runsLoadStates[task.identity] = .loading
        do {
            let loaded = try await client.runs(id: task.id, agentID: task.agentID, limit: limit)
            guard generation == accountGeneration, runsRequests[task.identity] == request else { return }
            guard loaded.allSatisfy({ $0.agentID.utf8.elementsEqual(task.agentID.utf8) }),
                  Set(loaded.map(\.id)).count == loaded.count else {
                throw WorkspaceClientError.invalidResponse
            }
            runsByTask[task.identity] = loaded.sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                return $0.id > $1.id
            }
            runsLoadStates[task.identity] = .loaded
        } catch {
            guard generation == accountGeneration, runsRequests[task.identity] == request else { return }
            runsLoadStates[task.identity] = .failed(message(for: error))
        }
    }

    func loadBlueprints() async {
        let generation = accountGeneration
        let request = UUID()
        blueprintsRequest = request
        blueprintsLoadState = .loading
        blueprintErrorMessage = nil
        do {
            let loaded = try await client.blueprints()
            guard generation == accountGeneration, blueprintsRequest == request else { return }
            guard Set(loaded.map(\.key)).count == loaded.count else { throw ScheduledTasksError.invalidCatalog }
            blueprints = loaded.sorted {
                if $0.category != $1.category {
                    return $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            blueprintsLoadState = .loaded
        } catch {
            guard generation == accountGeneration, blueprintsRequest == request else { return }
            blueprintsLoadState = .failed(message(for: error))
        }
    }

    func instantiate(
        _ blueprint: ScheduledTaskBlueprint,
        values: [String: String],
        agentID: String
    ) async throws -> ScheduledTask {
        guard !agentID.isEmpty else { throw ScheduledTasksError.agentRequired }
        guard !isInstantiatingBlueprint else { throw ScheduledTasksError.requestInProgress }
        let generation = accountGeneration
        isInstantiatingBlueprint = true
        blueprintErrorMessage = nil
        defer {
            if generation == accountGeneration { isInstantiatingBlueprint = false }
        }
        do {
            let created = try await client.instantiate(blueprint, values: values, agentID: agentID)
            guard generation == accountGeneration else { throw CancellationError() }
            guard created.agentID.utf8.elementsEqual(agentID.utf8) else {
                throw WorkspaceClientError.outcomeUnknown
            }
            tasks.removeAll { $0.identity == created.identity }
            tasks.append(created)
            tasks.sort(by: sort)
            return created
        } catch {
            guard generation == accountGeneration else { throw CancellationError() }
            blueprintErrorMessage = message(for: error)
            throw error
        }
    }

    func clearBlueprintError() {
        blueprintErrorMessage = nil
    }

    func loadDeliveryTargets() async {
        let generation = accountGeneration
        isLoadingDeliveryTargets = true
        deliveryTargetsErrorMessage = nil
        defer {
            if generation == accountGeneration {
                isLoadingDeliveryTargets = false
            }
        }
        do {
            let targets = try await client.deliveryTargets()
            guard generation == accountGeneration else { return }
            deliveryTargets = targets
        } catch {
            guard generation == accountGeneration else { return }
            deliveryTargetsErrorMessage = message(for: error)
        }
    }

    func resetForAccountBoundary() {
        accountGeneration &+= 1
        tasks.removeAll()
        deliveryTargets.removeAll()
        isLoadingDeliveryTargets = false
        deliveryTargetsErrorMessage = nil
        loadState = .idle
        detailLoadStates.removeAll()
        runsByTask.removeAll()
        runsLoadStates.removeAll()
        blueprints.removeAll()
        blueprintsLoadState = .idle
        isInstantiatingBlueprint = false
        blueprintErrorMessage = nil
        detailRequests.removeAll()
        runsRequests.removeAll()
        blueprintsRequest = UUID()
        pendingTaskIdentities.removeAll()
        isCreating = false
        recoverableDraft = nil
        errorMessage = nil
        agentFilterID = nil
        statusFilter = .all
    }

    func create(_ draft: ScheduledTaskDraft) async throws -> ScheduledTask {
        guard !draft.agentID.isEmpty else { throw ScheduledTasksError.agentRequired }
        let generation = accountGeneration
        guard !isCreating else { throw ScheduledTasksError.requestInProgress }
        isCreating = true
        defer {
            if generation == accountGeneration {
                isCreating = false
            }
        }
        errorMessage = nil
        do {
            let created = try await client.create(draft)
            guard generation == accountGeneration else { throw CancellationError() }
            guard created.agentID.utf8.elementsEqual(draft.agentID.utf8) else { throw ScheduledTasksError.taskNotFound }
            tasks.removeAll { $0.identity == created.identity }
            tasks.append(created)
            tasks.sort(by: sort)
            recoverableDraft = nil
            return created
        } catch {
            guard generation == accountGeneration else { throw CancellationError() }
            recoverableDraft = draft
            errorMessage = message(for: error)
            throw error
        }
    }

    func update(
        id: String,
        name: String,
        instructions: String,
        schedule: ScheduleInput,
        deliveryTarget: String? = nil,
        agentID: String? = nil
    ) async throws {
        let task = try requireTask(id: id, agentID: agentID)
        let resolvedDeliveryTarget = deliveryTarget ?? task.deliveryTarget
        let changes = ScheduledTaskChanges(
            name: name,
            instructions: instructions,
            schedule: schedule,
            deliveryTarget: resolvedDeliveryTarget
        )
        try await mutate(task, operation: {
            self.errorMessage = nil
            return try await self.client.update(id: id, agentID: task.agentID, changes: changes)
        }, commit: { updated in
            try self.accept(updated, for: task)
            self.recoverableDraft = nil
        }, recover: {
            self.recoverableDraft = ScheduledTaskDraft(
                agentID: task.agentID,
                name: name,
                instructions: instructions,
                schedule: schedule,
                deliveryTarget: resolvedDeliveryTarget
            )
        })
    }

    func setPaused(_ paused: Bool, id: String, agentID: String? = nil) async throws {
        let task = try requireTask(id: id, agentID: agentID)
        try await mutate(task, operation: {
            try await self.client.setPaused(paused, id: id, agentID: task.agentID)
        }, commit: { updated in
            try self.accept(updated, for: task)
        })
    }

    func runNow(id: String, agentID: String? = nil) async throws {
        let task = try requireTask(id: id, agentID: agentID)
        try await mutate(task, operation: {
            try await self.client.runNow(id: id, agentID: task.agentID)
        }, commit: { updated in
            try self.accept(updated, for: task)
            await self.loadRuns(id: updated.id, agentID: updated.agentID)
        })
    }

    func delete(id: String, agentID: String? = nil) async throws {
        let task = try requireTask(id: id, agentID: agentID)
        try await mutate(task, operation: {
            try await self.client.delete(id: id, agentID: task.agentID)
        }, commit: { _ in
            self.tasks.removeAll { $0.identity == task.identity }
            self.detailLoadStates[task.identity] = nil
            self.runsByTask[task.identity] = nil
            self.runsLoadStates[task.identity] = nil
            self.detailRequests[task.identity] = nil
            self.runsRequests[task.identity] = nil
        })
    }

    /// Admission, completion and failure all belong to the captured account.
    /// Keep the claim through commit (including run-history refresh).
    private func mutate<Result: Sendable>(
        _ task: ScheduledTask,
        operation: @MainActor () async throws -> Result,
        commit: @MainActor (Result) async throws -> Void,
        recover: @MainActor () -> Void = {}
    ) async throws {
        let generation = accountGeneration
        guard pendingTaskIdentities.insert(task.identity).inserted else {
            throw ScheduledTasksError.requestInProgress
        }
        defer {
            if generation == accountGeneration {
                pendingTaskIdentities.remove(task.identity)
            }
        }
        do {
            let result = try await operation()
            guard generation == accountGeneration else { throw CancellationError() }
            try await commit(result)
        } catch {
            guard generation == accountGeneration else { throw CancellationError() }
            recover()
            errorMessage = message(for: error)
            throw error
        }
    }

    private func accept(_ updated: ScheduledTask, for task: ScheduledTask) throws {
        guard updated.identity == task.identity else { throw ScheduledTasksError.taskNotFound }
        replace(updated)
    }

    private func matchingTasks(id: String, agentID: String?) -> [ScheduledTask] {
        tasks.filter { task in
            guard task.id.utf8.elementsEqual(id.utf8) else { return false }
            guard let agentID else { return true }
            return task.agentID.utf8.elementsEqual(agentID.utf8)
        }
    }

    private func requireTask(id: String, agentID: String?) throws -> ScheduledTask {
        let matches = matchingTasks(id: id, agentID: agentID)
        guard matches.count <= 1 else { throw ScheduledTasksError.ambiguousTask }
        guard let task = matches.first else { throw ScheduledTasksError.taskNotFound }
        return task
    }

    private func replace(_ updated: ScheduledTask) {
        guard let index = tasks.firstIndex(where: { $0.identity == updated.identity }) else { return }
        tasks[index] = updated
        tasks.sort(by: sort)
    }

    private func sort(_ lhs: ScheduledTask, _ rhs: ScheduledTask) -> Bool {
        if lhs.status != rhs.status { return lhs.status == .active }
        switch (lhs.nextRun, rhs.nextRun) {
        case let (left?, right?): return left < right
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func message(for error: Error) -> String {
        if error is CancellationError {
            return "This request was cancelled. Refresh before trying again if the computer may have received it."
        }
        return (error as? LocalizedError)?.errorDescription ?? "Unable to update this task. Try again."
    }
}
