import Foundation
import Observation

/// An agent people can see on the board: a Hermes profile with its name and picture.
struct KanbanAgent: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let imageURL: URL?
}

/// One board on screen. Changes show at once and are undone if the host says
/// no; the host's own board (live, or refreshed after each change) always wins.
@MainActor @Observable
final class KanbanBoardModel {
    enum Phase: Equatable {
        case loading
        case ready
        /// The host has no Kanban plugin.
        case unavailable
        case failed(String)
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var isError = true
    }

    enum AgentFilter: Hashable {
        case everyone
        case unassigned
        case agent(String)
    }

    let service: KanbanService
    private(set) var phase: Phase = .loading
    private(set) var boards: [HermesKanbanBoard] = []
    private(set) var snapshot: HermesKanbanBoardSnapshot?
    private(set) var workers: [HermesKanbanActiveWorker] = []
    private(set) var autoPlan: Bool?
    private(set) var isLive = false
    private(set) var busyTaskIDs: Set<String> = []
    private(set) var agents: [KanbanAgent]
    var agentFilter: AgentFilter = .everyone
    var searchText = ""
    var notice: Notice?

    /// Moves shown before the host confirms them.
    private var pendingStatus: [String: HermesKanbanTaskStatus] = [:]
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private var isOnScreen = false
    @ObservationIgnored private var workersCheckedAt: Date?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let publishWidget: (KanbanBoardModel) -> Void

    static let lastBoardKey = "bighelp.kanban.last-board"

    init(service: KanbanService, agents: [KanbanAgent], defaults: UserDefaults = .standard,
         publishWidget: @escaping (KanbanBoardModel) -> Void = { KanbanWidgetPublisher.record($0) }) {
        self.service = service
        self.agents = agents
        self.defaults = defaults
        self.publishWidget = publishWidget
    }

    // MARK: Reading

    var board: HermesKanbanBoard? { snapshot?.board }

    func agent(_ id: String?) -> KanbanAgent? {
        guard let id else { return nil }
        return agents.first { $0.id == id } ?? KanbanAgent(id: id, name: id, imageURL: nil)
    }

    /// Agents who can take work: the host's profiles, plus anyone already on this board.
    var assignableAgents: [KanbanAgent] {
        var seen = Set(agents.map(\.id))
        var result = agents
        for id in (snapshot?.tasks.compactMap(\.assignee) ?? []).sorted() where !seen.contains(id) {
            seen.insert(id)
            result.append(KanbanAgent(id: id, name: id, imageURL: nil))
        }
        return result
    }

    /// The board's cards with pending moves applied, filtered by agent and search.
    func tasks(in lane: KanbanLane) -> [HermesKanbanTask] {
        visibleTasks.filter { $0.lane == lane }
    }

    var visibleTasks: [HermesKanbanTask] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (snapshot?.tasks ?? []).map { task in
            pendingStatus[task.id].map { task.with(status: $0) } ?? task
        }.filter { task in
            switch agentFilter {
            case .everyone: break
            case .unassigned: guard task.assignee == nil else { return false }
            case .agent(let id): guard task.assignee == id else { return false }
            }
            guard !query.isEmpty else { return true }
            return task.title.lowercased().contains(query) || (task.body ?? "").lowercased().contains(query)
                || (task.latestSummary ?? "").lowercased().contains(query)
        }.sorted(by: Self.order)
    }

    func count(in lane: KanbanLane) -> Int { tasks(in: lane).count }

    /// One card as shown, whatever the filters say.
    func task(_ id: String) -> HermesKanbanTask? {
        guard let task = snapshot?.tasks.first(where: { $0.id == id }) else { return nil }
        return pendingStatus[id].map { task.with(status: $0) } ?? task
    }

    /// Ready work that no agent has picked up, with nobody working: Hermes'
    /// dispatcher isn't running (it needs the gateway).
    var nobodyIsPickingUpWork: Bool {
        guard isLive || snapshot != nil, workers.isEmpty else { return false }
        let ready = tasks(in: .ready).filter { $0.assignee != nil }
        return ready.contains { Date.now.timeIntervalSince($0.createdAt) > 120 }
    }

    func isBusy(_ task: HermesKanbanTask) -> Bool { busyTaskIDs.contains(task.id) }

    private static func order(_ lhs: HermesKanbanTask, _ rhs: HermesKanbanTask) -> Bool {
        if lhs.status == .done || rhs.status == .done {
            return (lhs.completedAt ?? lhs.createdAt) > (rhs.completedAt ?? rhs.createdAt)
        }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        return lhs.createdAt < rhs.createdAt
    }

    // MARK: Loading

    func start() async {
        phase = .loading
        do {
            guard try await service.isAvailable() else {
                phase = .unavailable
                return
            }
            boards = try await service.boards()
            let remembered = defaults.string(forKey: Self.lastBoardKey)
            let slug = boards.first { $0.slug == remembered }?.slug
                ?? boards.first(where: \.isCurrent)?.slug ?? boards.first?.slug
            if let slug { try await open(slug) }
            phase = .ready
            autoPlan = try? await service.orchestration().automaticallyDecomposes
        } catch {
            phase = .failed(Self.message(error, reading: true))
        }
    }

    func select(board slug: String) async {
        guard slug != snapshot?.board.slug else { return }
        do {
            try await open(slug)
        } catch {
            notice = Notice(text: Self.message(error, reading: true))
        }
    }

    func refresh() async {
        guard let slug = snapshot?.board.slug else { return await start() }
        do {
            boards = try await service.boards()
            apply(try await service.board(slug))
            await refreshWorkers(force: true)
        } catch {
            notice = Notice(text: Self.message(error, reading: true))
        }
    }

    private func open(_ slug: String) async throws {
        stopLive()
        pendingStatus = [:]
        let board = try await service.board(slug)
        apply(board)
        defaults.set(slug, forKey: Self.lastBoardKey)
        await refreshWorkers(force: true)
        if isOnScreen { beginLive() }
    }

    private func apply(_ board: HermesKanbanBoardSnapshot) {
        snapshot = board
        if let index = boards.firstIndex(where: { $0.slug == board.board.slug }) { boards[index] = board.board }
        publishWidget(self)
    }

    private func refreshWorkers(force: Bool = false) async {
        guard let slug = snapshot?.board.slug else { return }
        if !force, let checked = workersCheckedAt, Date.now.timeIntervalSince(checked) < 15 { return }
        workersCheckedAt = .now
        if let value = try? await service.activeWorkers(board: slug) { workers = value }
    }

    // MARK: Live updates

    /// The screen calls this as it appears and disappears; live updates only
    /// run while someone is looking.
    func setOnScreen(_ visible: Bool) {
        isOnScreen = visible
        if visible { beginLive() } else { stopLive() }
    }

    private func beginLive() {
        guard liveTask == nil, let snapshot else { return }
        let slug = snapshot.board.slug
        liveTask = Task { @MainActor [weak self] in
            var cursor = snapshot.latestEventID
            while let self, !Task.isCancelled, self.isOnScreen, self.snapshot?.board.slug == slug {
                do {
                    self.isLive = true
                    for try await board in try self.service.liveBoards(slug, since: cursor) {
                        guard self.snapshot?.board.slug == slug else { return }
                        cursor = board.latestEventID
                        self.apply(board)
                        await self.refreshWorkers()
                    }
                } catch is CancellationError {
                    break
                } catch {
                    // The live window ended or dropped; start another after a pause.
                }
                self.isLive = false
                try? await Task.sleep(for: .seconds(5))
                if let latest = try? await self.service.board(slug), self.snapshot?.board.slug == slug {
                    cursor = latest.latestEventID
                    self.apply(latest)
                }
            }
            self?.isLive = false
        }
    }

    private func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        isLive = false
    }

    // MARK: Changing things

    func move(_ task: HermesKanbanTask, to lane: KanbanLane) async {
        guard let status = lane.dropStatus, lane.accepts(task) else { return }
        await setStatus(task, to: status)
    }

    func approve(_ task: HermesKanbanTask) async { await setStatus(task, to: .done) }

    /// Blocked work goes back to Ready so its agent picks it up again.
    func tryAgain(_ task: HermesKanbanTask) async { await setStatus(task, to: .ready) }

    func archive(_ task: HermesKanbanTask) async { await setStatus(task, to: .archived) }

    /// A reply goes into the task's thread; a question or a review then goes
    /// back to the agent.
    func reply(_ text: String, to task: HermesKanbanTask) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let slug = snapshot?.board.slug else { return false }
        busyTaskIDs.insert(task.id)
        defer { busyTaskIDs.remove(task.id) }
        do {
            _ = try await service.comment(text, on: task.id, board: slug)
            if task.status == .blocked || task.status == .review {
                replace(try await service.move(task.id, to: .ready, board: slug).task)
            } else {
                apply(try await service.board(slug))
            }
            return true
        } catch {
            notice = Notice(text: "Your message didn't send. Try again.")
            return false
        }
    }

    func assign(_ task: HermesKanbanTask, to agentID: String?) async {
        guard task.assignee != agentID, let slug = snapshot?.board.slug else { return }
        await perform(task, failure: "Hermes didn't reassign this card.") {
            try await self.service.reassign(task.id, to: agentID, board: slug)
        }
    }

    func setPriority(_ task: HermesKanbanTask, _ priority: KanbanPriority) async {
        guard task.urgency != priority, let slug = snapshot?.board.slug else { return }
        var patch = HermesKanbanTaskPatch()
        patch.priority = .set(priority.rawValue)
        await perform(task, failure: "Hermes didn't change the priority.") {
            try await self.service.edit(task.id, board: slug, patch: patch)
        }
    }

    func rename(_ task: HermesKanbanTask, title: String, details: String) async {
        guard let slug = snapshot?.board.slug else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var patch = HermesKanbanTaskPatch()
        if !title.isEmpty, title != task.title { patch.title = .set(title) }
        if details != (task.body ?? "") { patch.body = .set(details) }
        guard !patch.isEmpty else { return }
        await perform(task, failure: "Hermes didn't save your changes.") {
            try await self.service.edit(task.id, board: slug, patch: patch)
        }
    }

    /// A new card. Ready is picked up by the chosen agent. Later waits for you:
    /// Hermes would make a new task ready at once, so it starts in planning,
    /// which nothing picks up, and is filed as to-do unless Auto plan is on.
    @discardableResult
    func create(title: String, details: String = "", lane: KanbanLane, assignee: String?,
                priority: KanbanPriority = .normal) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let slug = snapshot?.board.slug else { return false }
        var draft = HermesKanbanTaskDraft(title: title)
        draft.body = details
        draft.assignee = assignee
        draft.priority = priority.rawValue
        draft.startsInTriage = lane != .ready
        do {
            var created = try await service.create(draft, board: slug).task
            if lane != .ready, created.status == .triage, autoPlan != true {
                created = try await service.move(created.id, to: .todo, board: slug).task
            }
            replace(created)
            return true
        } catch {
            notice = Notice(text: "Hermes didn't add the card. Try again.")
            return false
        }
    }

    func startReadyWork() async {
        guard let slug = snapshot?.board.slug else { return }
        do {
            apply(try await service.startReadyWork(board: slug))
            await refreshWorkers(force: true)
            notice = Notice(text: "Asked your bots to start.", isError: false)
        } catch {
            notice = Notice(text: "Hermes couldn't start the work. Check that Hermes is running on your computer.")
        }
    }

    func setAutoPlan(_ isOn: Bool) async {
        let previous = autoPlan
        autoPlan = isOn
        do {
            autoPlan = try await service.setAutoPlan(isOn).automaticallyDecomposes
        } catch {
            autoPlan = previous
            notice = Notice(text: "Hermes didn't change Auto plan.")
        }
    }

    func createBoard(named name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            let before = Set(boards.map(\.slug))
            boards = try await service.createBoard(named: name)
            if let created = boards.first(where: { !before.contains($0.slug) }) {
                try await open(created.slug)
            }
        } catch {
            notice = Notice(text: "Hermes didn't create the board. Try another name.")
        }
    }

    func detail(_ task: HermesKanbanTask) async -> HermesKanbanTaskDetail? {
        guard let slug = snapshot?.board.slug else { return nil }
        guard let detail = try? await service.task(task.id, board: slug) else { return nil }
        replace(detail.task)
        return detail
    }

    func comment(_ text: String, on task: HermesKanbanTask) async -> HermesKanbanTaskDetail? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let slug = snapshot?.board.slug else { return nil }
        do {
            let detail = try await service.comment(text, on: task.id, board: slug)
            replace(detail.task)
            return detail
        } catch {
            notice = Notice(text: "Your message didn't send. Try again.")
            return nil
        }
    }

    private func setStatus(_ task: HermesKanbanTask, to status: HermesKanbanTaskStatus) async {
        guard let slug = snapshot?.board.slug, task.status != status else { return }
        pendingStatus[task.id] = status
        busyTaskIDs.insert(task.id)
        defer {
            pendingStatus[task.id] = nil
            busyTaskIDs.remove(task.id)
        }
        do {
            replace(try await service.move(task.id, to: status, board: slug).task)
        } catch {
            notice = Notice(text: Self.moveFailure(error, to: status))
        }
    }

    private func perform(_ task: HermesKanbanTask, failure: String,
                         _ change: @escaping () async throws -> HermesKanbanTaskDetail) async {
        busyTaskIDs.insert(task.id)
        defer { busyTaskIDs.remove(task.id) }
        do {
            replace(try await change().task)
        } catch {
            notice = Notice(text: failure + " " + Self.retryHint(error))
        }
    }

    /// Puts the host's copy of one task on the board.
    private func replace(_ task: HermesKanbanTask) {
        guard let current = snapshot else { return }
        var tasks = current.tasks.filter { $0.id != task.id }
        if task.status != .archived { tasks.append(task) }
        let columns = HermesKanbanTaskStatus.allCases.filter { $0 != .archived }.map { status in
            HermesKanbanColumn(status: status, tasks: tasks.filter { $0.status == status })
        }
        apply(HermesKanbanBoardSnapshot(board: current.board, columns: columns, tenants: current.tenants,
                                        assignees: current.assignees, latestEventID: current.latestEventID,
                                        fetchedAt: .now))
    }

    // MARK: Words

    private static func moveFailure(_ error: any Error, to status: HermesKanbanTaskStatus) -> String {
        let lane = KanbanLane(status: status)?.title ?? status.label
        if (error as? HermesKanbanError) == .operationRefused {
            return "Hermes kept this card where it was. It may be waiting on another task."
        }
        return "Hermes didn't move this card to \(lane). " + retryHint(error)
    }

    private static func retryHint(_ error: any Error) -> String {
        switch error as? HermesKanbanError {
        case .reviewChanged?: "It changed on your computer. Try again."
        case .unavailable?: "Kanban isn't available on this computer anymore."
        default: "Check your connection and try again."
        }
    }

    static func message(_ error: any Error, reading: Bool) -> String {
        if (error as? HermesKanbanError) == .unavailable {
            return "This computer's Hermes doesn't have Kanban. Update Hermes, then try again."
        }
        if case WorkspaceClientError.authenticationRequired = error {
            return "Sign in to your computer again, then open Kanban."
        }
        return reading ? "The board didn't load. Check that your computer is connected, then try again."
            : "That didn't work. Try again."
    }
}
