import Foundation

/// Demo mode: three made-up boards worked by the demo agents, held in memory
/// so moves, replies and new tasks behave like the real host.
@MainActor
final class DemoKanbanService: KanbanService {
    private struct Entry {
        var task: HermesKanbanTask
        var comments: [HermesKanbanComment] = []
        var runs: [HermesKanbanRun] = []
        var events: [HermesKanbanEvent] = []
        var parents: [String] = []
        var children: [String] = []
    }

    private var catalog: [HermesKanbanBoard] = []
    private var entries: [String: [String: Entry]] = [:]
    private var autoPlan = false
    private var nextEventID = 100
    private let now = Date.now

    /// One board for the app and Shortcuts, so a card added from a Shortcut shows.
    static let shared = DemoKanbanService()

    init() {
        seed()
    }

    func isAvailable() async throws -> Bool { true }

    func boards() async throws -> [HermesKanbanBoard] { catalog.map(counted) }

    func board(_ slug: String) async throws -> HermesKanbanBoardSnapshot {
        guard let board = catalog.first(where: { $0.slug == slug }) else { throw HermesKanbanError.invalidRequest }
        let tasks = (entries[slug] ?? [:]).values.map(\.task)
            .sorted { ($0.priority, $1.createdAt) > ($1.priority, $0.createdAt) }
        let columns = HermesKanbanTaskStatus.allCases.filter { $0 != .archived }.map { status in
            HermesKanbanColumn(status: status, tasks: tasks.filter { $0.status == status })
        }
        return HermesKanbanBoardSnapshot(board: counted(board), columns: columns, tenants: [],
                                         assignees: Array(Set(tasks.compactMap(\.assignee))).sorted(),
                                         latestEventID: nextEventID, fetchedAt: .now)
    }

    func task(_ id: String, board: String) async throws -> HermesKanbanTaskDetail {
        guard let entry = entries[board]?[id] else { throw HermesKanbanError.invalidRequest }
        return detail(entry)
    }

    func activeWorkers(board: String) async throws -> [HermesKanbanActiveWorker] {
        (entries[board] ?? [:]).values.map(\.task).filter { $0.status == .running }.map {
            HermesKanbanActiveWorker(runID: $0.currentRunID ?? 1, taskID: $0.id, taskTitle: $0.title,
                                     assignee: $0.assignee, profile: $0.assignee, processID: 4242,
                                     startedAt: $0.startedAt ?? now, lastHeartbeatAt: $0.lastHeartbeatAt,
                                     maximumRuntimeSeconds: nil)
        }
    }

    func orchestration() async throws -> HermesKanbanOrchestration {
        HermesKanbanOrchestration(orchestratorProfile: "finance", defaultAssignee: "finance",
                                  automaticallyDecomposes: autoPlan, automaticallyPromotesChildren: true,
                                  resolvedOrchestratorProfile: "finance", resolvedDefaultAssignee: "finance",
                                  activeProfile: "finance")
    }

    func move(_ taskID: String, to status: HermesKanbanTaskStatus, board: String) async throws -> HermesKanbanTaskDetail {
        guard status != .running else { throw HermesKanbanError.operationRefused }
        return try update(taskID, board: board, event: "status") { task in
            task = task.with(status: status, completedAt: status == .done ? .now : nil)
        }
    }

    func edit(_ taskID: String, board: String, patch: HermesKanbanTaskPatch) async throws -> HermesKanbanTaskDetail {
        try update(taskID, board: board, event: "edited") { task in
            if case .set(let value) = patch.title { task = task.with(title: value) }
            if case .set(let value) = patch.body { task = task.with(body: value) }
            if case .set(let value) = patch.priority { task = task.with(priority: value) }
            if case .set(let value) = patch.assignee { task = task.with(assignee: .some(value)) }
            if case .set(let value) = patch.status { task = task.with(status: value) }
        }
    }

    func reassign(_ taskID: String, to profile: String?, board: String) async throws -> HermesKanbanTaskDetail {
        try update(taskID, board: board, event: "reassigned") { task in
            task = task.with(assignee: .some(profile), status: task.status == .running ? .ready : task.status)
        }
    }

    func comment(_ body: String, on taskID: String, board: String) async throws -> HermesKanbanTaskDetail {
        guard var entry = entries[board]?[taskID] else { throw HermesKanbanError.invalidRequest }
        entry.comments.append(HermesKanbanComment(id: entry.comments.count + 1, author: "You", body: body, createdAt: .now))
        entry.task = entry.task.with(commentCount: entry.comments.count)
        entries[board]?[taskID] = entry
        return detail(entry)
    }

    func create(_ draft: HermesKanbanTaskDraft, board: String) async throws -> HermesKanbanTaskDetail {
        let id = "t_\(UUID().uuidString.prefix(8).lowercased())"
        // Like Hermes: ready at once unless it starts in planning.
        let status: HermesKanbanTaskStatus = draft.startsInTriage ? .triage : .ready
        let entry = Entry(task: Self.task(id, draft.title, status: status, assignee: draft.assignee,
                                          priority: draft.priority, body: draft.body, createdAt: .now))
        entries[board, default: [:]][id] = entry
        return detail(entry)
    }

    func createBoard(named name: String) async throws -> [HermesKanbanBoard] {
        let slug = LiveKanbanService.slug(for: name, avoiding: Set(catalog.map(\.slug)))
        catalog.append(Self.board(slug, name, summary: ""))
        entries[slug] = [:]
        return try await boards()
    }

    func startReadyWork(board: String) async throws -> HermesKanbanBoardSnapshot {
        for (id, entry) in entries[board] ?? [:] where entry.task.status == .ready && entry.task.assignee != nil {
            entries[board]?[id]?.task = entry.task.with(status: .running, startedAt: .now, heartbeat: .now,
                                                       summary: "Getting started.")
        }
        return try await self.board(board)
    }

    func setAutoPlan(_ isOn: Bool) async throws -> HermesKanbanOrchestration {
        autoPlan = isOn
        return try await orchestration()
    }

    func liveBoards(_ slug: String, since cursor: Int) throws -> AsyncThrowingStream<HermesKanbanBoardSnapshot, any Error> {
        // Demo boards only change when you change them.
        AsyncThrowingStream { _ in }
    }

    // MARK: Helpers

    private func update(_ taskID: String, board: String, event: String,
                        _ change: (inout HermesKanbanTask) -> Void) throws -> HermesKanbanTaskDetail {
        guard var entry = entries[board]?[taskID] else { throw HermesKanbanError.invalidRequest }
        change(&entry.task)
        nextEventID += 1
        entry.events.append(HermesKanbanEvent(id: nextEventID, taskID: taskID, runID: nil, kind: event, createdAt: .now))
        entries[board]?[taskID] = entry
        return detail(entry)
    }

    private func detail(_ entry: Entry) -> HermesKanbanTaskDetail {
        HermesKanbanTaskDetail(task: entry.task, comments: entry.comments, events: entry.events, attachments: [],
                               parentIDs: entry.parents, childIDs: entry.children, runs: entry.runs,
                               revision: Data("\(entry.task.id):\(entry.events.count):\(entry.comments.count)".utf8))
    }

    private func counted(_ board: HermesKanbanBoard) -> HermesKanbanBoard {
        let tasks = (entries[board.slug] ?? [:]).values.map(\.task)
        var counts: [String: Int] = [:]
        for task in tasks { counts[task.status.rawValue, default: 0] += 1 }
        return HermesKanbanBoard(slug: board.slug, name: board.name, summary: board.summary, icon: board.icon,
                                 color: board.color, defaultWorkdir: nil, projectID: nil, projectName: nil,
                                 isCurrent: board.isCurrent, isArchived: false, total: tasks.count, counts: counts)
    }

    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    private func seed() {
        catalog = [
            Self.board("launch", "bighelp launch", summary: "Everything for launch week", color: "#7B52E0", current: true),
            Self.board("home", "Home", summary: "House and family", color: "#2FA58B"),
            Self.board("japan", "Japan trip", summary: "Spring, two weeks", color: "#E5624F"),
        ]
        var launch: [String: Entry] = [:]
        func add(_ entry: Entry) { launch[entry.task.id] = entry }
        add(Entry(task: Self.task("t_store", "Draft the App Store description", status: .triage, assignee: nil,
                                  priority: 0, createdAt: ago(300))))
        add(Entry(task: Self.task("t_survey", "Plan the beta feedback survey", status: .todo, assignee: "travel",
                                  priority: 0, createdAt: ago(280))))
        add(Entry(task: Self.task("t_recap", "Weekly metrics recap", status: .scheduled, assignee: "finance",
                                  priority: 0, createdAt: ago(900))))
        add(Entry(task: Self.task("t_quotes", "Pick three testimonials for the site", status: .ready, assignee: "home",
                                  priority: 1, createdAt: ago(120))))
        add(Entry(task: Self.task("t_dinner", "Book a table for the launch dinner", status: .ready, assignee: "travel",
                                  priority: 0, createdAt: ago(110))))
        add(Entry(task: Self.task("t_hosting", "Compare hosting costs for the website", status: .running, assignee: "finance",
                                  priority: 1, createdAt: ago(95), startedAt: ago(14), heartbeat: now.addingTimeInterval(-20),
                                  summary: "Pulled prices from three hosts. Checking bandwidth limits next.", runID: 12),
                  runs: [Self.run(12, "t_hosting", "finance", started: ago(14), heartbeat: now.addingTimeInterval(-20))]))
        add(Entry(task: Self.task("t_press", "Collect screenshots for the press kit", status: .running, assignee: "home",
                                  priority: 0, createdAt: ago(80), startedAt: ago(6), heartbeat: now.addingTimeInterval(-45),
                                  summary: "Captured the chat and Feed screens in light mode.", runID: 13),
                  runs: [Self.run(13, "t_press", "home", started: ago(6), heartbeat: now.addingTimeInterval(-45))]))
        add(Entry(task: Self.task("t_budget", "Approve the launch budget", status: .review, assignee: "finance",
                                  priority: 2, createdAt: ago(200), summary: "Budget comes to $2,400: ads $1,500, dinner $600, swag $300.",
                                  commentCount: 1),
                  comments: [HermesKanbanComment(id: 1, author: "finance", body: "Ready for your review. I kept ads under $1,500 like last time.",
                                                 createdAt: ago(25))],
                  runs: [Self.run(9, "t_budget", "finance", started: ago(60), ended: ago(26), outcome: "review")]))
        add(Entry(task: Self.task("t_date", "Pick a date for the launch party", status: .blocked, assignee: "travel",
                                  priority: 1, createdAt: ago(150), blockKind: "needs_input",
                                  summary: "Friday the 17th or Saturday the 18th?", commentCount: 1),
                  comments: [HermesKanbanComment(id: 1, author: "travel", body: "Both venues are free on Friday the 17th and Saturday the 18th. Which do you prefer?",
                                                 createdAt: ago(40))]))
        // Stuck the way a broken worker install looks: it never got to start.
        let startFailure = #"pid 5120 exited with code 1 Worker's last output: "/Users/you/.hermes/tools/python3: Error while finding module specification for 'hermes_cli.main' (ModuleNotFoundError: No module named 'hermes_cli')""#
        var domain = Self.task("t_domain", "Renew the domain for another year", status: .blocked, assignee: "home",
                               priority: 0, createdAt: ago(400), blockKind: "gave_up")
        domain = domain.with(consecutiveFailures: 2)
        add(Entry(task: domain,
                  runs: [Self.run(21, "t_domain", "home", started: ago(380), ended: ago(379.8), outcome: "crashed", error: startFailure),
                         Self.run(22, "t_domain", "home", started: ago(379.5), ended: ago(379.3), outcome: "crashed", error: startFailure)],
                  events: [HermesKanbanEvent(id: 70, taskID: "t_domain", runID: nil, kind: "gave_up", createdAt: ago(379.3),
                                             failures: 2)]))
        add(Entry(task: Self.task("t_signup", "Set up the beta sign-up form", status: .done, assignee: "home",
                                  priority: 0, createdAt: ago(2_000), completedAt: ago(600), summary: "Form is live and sends replies to the shared inbox.")))
        add(Entry(task: Self.task("t_faq", "Write the FAQ", status: .done, assignee: "finance",
                                  priority: 0, createdAt: ago(3_000), completedAt: ago(1_400))))
        entries["launch"] = launch
        entries["home"] = [
            "h_filter": Entry(task: Self.task("h_filter", "Order new furnace filters", status: .ready, assignee: "home",
                                              priority: 0, createdAt: ago(60))),
            "h_dentist": Entry(task: Self.task("h_dentist", "Find a dentist near the new office", status: .todo, assignee: nil,
                                               priority: 0, createdAt: ago(500))),
            "h_gutter": Entry(task: Self.task("h_gutter", "Get quotes for gutter cleaning", status: .running, assignee: "home",
                                              priority: 0, createdAt: ago(70), startedAt: ago(3), heartbeat: now.addingTimeInterval(-12),
                                              summary: "Two quotes in so far.", runID: 3)),
        ]
        entries["japan"] = [
            "j_rail": Entry(task: Self.task("j_rail", "Compare rail passes", status: .review, assignee: "travel",
                                            priority: 1, createdAt: ago(90), summary: "A 14-day pass saves about $120.")),
            "j_hotel": Entry(task: Self.task("j_hotel", "Shortlist hotels in Kyoto", status: .todo, assignee: "travel",
                                             priority: 0, createdAt: ago(300))),
        ]
    }

    private static func board(_ slug: String, _ name: String, summary: String, color: String? = nil,
                              current: Bool = false) -> HermesKanbanBoard {
        HermesKanbanBoard(slug: slug, name: name, summary: summary, icon: nil, color: color, defaultWorkdir: nil,
                          projectID: nil, projectName: nil, isCurrent: current, isArchived: false, total: 0, counts: [:])
    }

    private static func run(_ id: Int, _ taskID: String, _ profile: String, started: Date, ended: Date? = nil,
                            heartbeat: Date? = nil, outcome: String? = nil, error: String? = nil) -> HermesKanbanRun {
        HermesKanbanRun(id: id, taskID: taskID, profile: profile,
                        status: ended == nil ? "running" : error == nil ? "done" : outcome ?? "failed",
                        workerPID: ended == nil ? 4242 : nil, startedAt: started, endedAt: ended, outcome: outcome,
                        summary: nil, error: error, lastHeartbeatAt: heartbeat ?? ended, maxRuntimeSeconds: nil)
    }

    static func task(_ id: String, _ title: String, status: HermesKanbanTaskStatus, assignee: String?,
                     priority: Int, body: String? = nil, createdAt: Date, startedAt: Date? = nil,
                     completedAt: Date? = nil, heartbeat: Date? = nil, blockKind: String? = nil,
                     summary: String? = nil, runID: Int? = nil, commentCount: Int = 0) -> HermesKanbanTask {
        HermesKanbanTask(
            id: id, title: title, body: body, assignee: assignee, status: status, priority: priority,
            createdBy: "you", createdAt: createdAt, startedAt: startedAt, completedAt: completedAt, tenant: nil,
            workspaceKind: "scratch", workspacePath: nil, branchName: nil, projectID: nil, result: nil,
            idempotencyKey: nil, latestSummary: summary, currentRunID: runID, workerPID: runID == nil ? nil : 4242,
            lastHeartbeatAt: heartbeat, maxRuntimeSeconds: nil, modelOverride: nil, providerOverride: nil,
            reasoningEffort: nil, workflowTemplateID: nil, currentStepKey: nil, skills: nil, maximumRetries: nil,
            consecutiveFailures: 0, goalMode: false, goalMaximumTurns: nil, completionContract: nil,
            blockKind: blockKind, blockRecurrences: 0, childCount: 0, parentCount: 0, commentCount: commentCount
        )
    }
}

extension HermesKanbanTask {
    /// A copy with some fields changed; used for instant, optimistic board updates.
    func with(title: String? = nil, body: String? = nil, assignee: String?? = nil,
              status: HermesKanbanTaskStatus? = nil, priority: Int? = nil, startedAt: Date? = nil,
              completedAt: Date? = nil, heartbeat: Date? = nil, summary: String? = nil,
              commentCount: Int? = nil, consecutiveFailures: Int? = nil) -> HermesKanbanTask {
        HermesKanbanTask(
            id: id, title: title ?? self.title, body: body ?? self.body, assignee: assignee ?? self.assignee,
            status: status ?? self.status, priority: priority ?? self.priority, createdBy: createdBy,
            createdAt: createdAt, startedAt: startedAt ?? self.startedAt, completedAt: completedAt ?? self.completedAt,
            tenant: tenant, workspaceKind: workspaceKind, workspacePath: workspacePath, branchName: branchName,
            projectID: projectID, result: result, idempotencyKey: idempotencyKey,
            latestSummary: summary ?? latestSummary, currentRunID: currentRunID, workerPID: workerPID,
            lastHeartbeatAt: heartbeat ?? lastHeartbeatAt, maxRuntimeSeconds: maxRuntimeSeconds,
            modelOverride: modelOverride, providerOverride: providerOverride, reasoningEffort: reasoningEffort,
            workflowTemplateID: workflowTemplateID, currentStepKey: currentStepKey, skills: skills,
            maximumRetries: maximumRetries, consecutiveFailures: consecutiveFailures ?? self.consecutiveFailures,
            goalMode: goalMode,
            goalMaximumTurns: goalMaximumTurns, completionContract: completionContract,
            blockKind: (status ?? self.status) == .blocked ? blockKind : nil, blockRecurrences: blockRecurrences,
            childCount: childCount, parentCount: parentCount, commentCount: commentCount ?? self.commentCount
        )
    }
}
