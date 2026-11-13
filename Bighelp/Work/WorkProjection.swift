import Foundation

/// A Code session as Work shows it: its record, the status its card reads and its pull request.
struct WorkCodeSession: Equatable, Sendable {
    let record: CodeSessionRecord
    let status: CodeSessionStatus
    var pullRequest: StockGitPullRequest?
}

/// A batch with its lines resolved the way Code home's batch card resolves them.
struct WorkCodeBatch: Equatable, Sendable {
    let batch: CodeBatch
    let lines: [WorkBatchLine]
    let startedCount: Int
}

/// What Work reads from each store, at one moment. A store that's nil (never opened, or the computer
/// lacks it) leaves its part empty.
struct WorkSources: Sendable {
    /// Sessions that aren't in a batch.
    var codeSessions: [WorkCodeSession] = []
    /// Sends with no session yet that aren't in a batch.
    var codeLaunches: [CodeLaunch] = []
    var codeBatches: [WorkCodeBatch] = []
    var chatWork: [DashboardWorkItem] = []
    /// Bots with background work, by profile ID.
    var background: [String: BotBackgroundWork] = [:]
    var workflowsWaiting: [WorkflowRunSummary] = []
    var workflowsActive: [WorkflowRunSummary] = []
    var workflowsRecent: [WorkflowRunSummary] = []
    var tasks: [HermesKanbanTask] = []
    var schedules: [ScheduledTask] = []
    /// Bot names by profile ID.
    var botNames: [String: String] = [:]
    var now: Date = .now
}

/// Work's list: every source's rows in one order, newest activity first. Pure, so tests drive it.
enum WorkProjection {
    /// Finished Kanban cards shown at most; the board keeps the rest.
    static let doneTaskLimit = 20

    static func items(_ sources: WorkSources) -> [WorkItem] {
        var items: [WorkItem] = []
        items += sources.codeLaunches.map(launchItem)
        items += sources.codeBatches.map(batchItem)
        items += sources.codeSessions.map(sessionItem)
        // A Code session's chat is also a chat with active work: its card already says so.
        let codeIDs = Set(sources.codeSessions.map(\.record.id))
            .union(sources.codeBatches.flatMap(\.batch.sessionIDs))
        items += sources.chatWork.filter { !codeIDs.contains($0.sessionID) }.map(chatItem)
        items += sources.background.map { backgroundItem(profileID: $0.key, work: $0.value, sources: sources) }
        items += workflowItems(sources)
        items += taskItems(sources)
        items += sources.schedules.map { scheduleItem($0, sources: sources) }
        return ordered(items, now: sources.now)
    }

    /// The rows a chip and, for Work filtered to a project, that project show.
    static func visible(_ items: [WorkItem], filter: WorkFilter, projectID: String?) -> [WorkItem] {
        items.filter { filter.includes($0.bucket) && (projectID == nil || $0.projectID == projectID) }
    }

    /// Each chip's count, under the project filter.
    static func counts(_ items: [WorkItem], projectID: String?) -> [WorkFilter: Int] {
        Dictionary(uniqueKeysWithValues: WorkFilter.allCases.map { filter in
            (filter, visible(items, filter: filter, projectID: projectID).count)
        })
    }

    /// Newest activity first; work running now with no time counts as now. Upcoming scheduled tasks
    /// go last, the next to run first.
    static func ordered(_ items: [WorkItem], now: Date) -> [WorkItem] {
        let (upcoming, rest) = items.reduce(into: ([WorkItem](), [WorkItem]())) { result, item in
            if item.bucket == .upcoming { result.0.append(item) } else { result.1.append(item) }
        }
        let recent = rest.sorted { left, right in
            let l = left.time ?? now, r = right.time ?? now
            return l != r ? l > r : left.id < right.id
        }
        let later = upcoming.sorted { left, right in
            switch (left.time, right.time) {
            case let (l?, r?) where l != r: l < r
            case (.some, nil): true
            case (nil, .some): false
            default: left.id < right.id
            }
        }
        return recent + later
    }

    // MARK: Coding

    static func bucket(for status: CodeSessionStatus) -> WorkBucket {
        switch status {
        case .needsYou: .needsYou
        case .starting, .running: .working
        case .ready, .failed: .done
        }
    }

    static func tone(for status: CodeSessionStatus) -> WorkTone {
        switch status {
        case .needsYou: .needsYou
        case .starting, .running: .working
        case .ready: .done
        case .failed: .failed
        }
    }

    private static func sessionItem(_ session: WorkCodeSession) -> WorkItem {
        let record = session.record
        return WorkItem(kind: .coding, id: "coding:" + record.id, title: record.title, pill: nil,
                        line: record.projectName, lineSymbol: "arrow.triangle.branch", bot: nil,
                        time: record.startedAt, bucket: bucket(for: session.status), tone: tone(for: session.status),
                        projectID: record.projectID, target: .codeSession(record.id),
                        card: .session(record, session.status, pullRequest: session.pullRequest))
    }

    private static func launchItem(_ launch: CodeLaunch) -> WorkItem {
        let status: CodeSessionStatus = launch.step.isFailed ? .failed("") : .starting("")
        return WorkItem(kind: .coding, id: "launch:" + launch.id.uuidString, title: launch.title, pill: nil,
                        line: "", lineSymbol: "arrow.triangle.branch", bot: nil, time: nil,
                        bucket: bucket(for: status), tone: tone(for: status), projectID: launch.projectID,
                        target: launch.sessionID.map(WorkTarget.codeSession), card: .launch(launch))
    }

    /// A batch needs you when any of its sessions does, works while any works, else it's done.
    private static func batchItem(_ batch: WorkCodeBatch) -> WorkItem {
        let lineBuckets = batch.lines.map { Self.bucket(for: $0.status) }
        let result: WorkBucket = lineBuckets.contains(.needsYou) ? .needsYou
            : lineBuckets.contains(.working) || batch.startedCount < batch.batch.jobCount ? .working : .done
        let tone: WorkTone = switch result {
        case .needsYou: .needsYou
        case .working: .working
        case .done, .upcoming: .done
        }
        return WorkItem(kind: .coding, id: "batch:" + batch.batch.id.uuidString, title: batch.batch.title,
                        pill: nil, line: "", lineSymbol: "square.stack.3d.up", bot: nil,
                        time: batch.batch.createdAt, bucket: result, tone: tone, projectID: batch.batch.projectID,
                        target: .codeBatch(batch.batch.id),
                        card: .batch(batch.batch, lines: batch.lines, startedCount: batch.startedCount))
    }

    // MARK: Chats and background work

    private static func chatItem(_ work: DashboardWorkItem) -> WorkItem {
        WorkItem(kind: .chat, id: "chat:" + work.sessionID, title: work.title, pill: String(localized: "Working"),
                 line: work.subtitle, lineSymbol: "bubble.left", bot: nil, time: nil, bucket: .working,
                 tone: .working, projectID: nil, target: .chat(work.sessionID))
    }

    private static func backgroundItem(profileID: String, work: BotBackgroundWork, sources: WorkSources) -> WorkItem {
        let bot = sources.botNames[profileID]
        let count = work.count > 1 ? String(localized: "\(work.count) running") : nil
        let line = joined([String(localized: "In the background"), count, bot])
        return WorkItem(kind: .background, id: "background:" + profileID,
                        title: work.title ?? String(localized: "Background work"), pill: String(localized: "Working"),
                        line: line, lineSymbol: "square.stack.3d.up", bot: bot, time: nil, bucket: .working,
                        tone: .working, projectID: nil, target: .bot(profileID))
    }

    // MARK: Workflows

    private static func workflowItems(_ sources: WorkSources) -> [WorkItem] {
        var seen = Set<String>()
        var items: [WorkItem] = []
        for run in sources.workflowsWaiting where seen.insert(run.id).inserted {
            items.append(workflowItem(run, bucket: .needsYou))
        }
        for run in sources.workflowsActive where seen.insert(run.id).inserted {
            items.append(workflowItem(run, bucket: .working))
        }
        for run in sources.workflowsRecent where run.state.isFinished && seen.insert(run.id).inserted {
            items.append(workflowItem(run, bucket: .done))
        }
        return items
    }

    private static func workflowItem(_ run: WorkflowRunSummary, bucket: WorkBucket) -> WorkItem {
        let pill: String
        var tone: WorkTone = bucket == .needsYou ? .needsYou : bucket == .working ? .working : .done
        switch bucket {
        case .needsYou:
            pill = run.waiting?.kind == "signoff" ? String(localized: "Sign off") : String(localized: "Needs you")
        case .working:
            pill = String(localized: "Working")
        case .done, .upcoming:
            switch run.state {
            case .failed:
                pill = String(localized: "Failed")
                tone = .failed
            case .cancelled: pill = String(localized: "Cancelled")
            default: pill = String(localized: "Done")
            }
        }
        let step = bucket != .done && run.stageCount > 0
            ? String(localized: "step \(min(run.stagesDone + 1, run.stageCount)) of \(run.stageCount)") : nil
        return WorkItem(kind: .workflow, id: "workflow:" + run.id, title: run.workflowName, pill: pill,
                        line: joined([String(localized: "Workflow"), step]), lineSymbol: "point.3.connected.trianglepath.dotted",
                        bot: nil, time: run.endedAt ?? run.updatedAt ?? run.startedAt, bucket: bucket, tone: tone,
                        projectID: nil, target: .workflowRun(run.id))
    }

    // MARK: Kanban

    /// Needs you, Working and Done lanes; cards still waiting to be picked up stay on the board.
    private static func taskItems(_ sources: WorkSources) -> [WorkItem] {
        let done = sources.tasks.filter { $0.lane == .done }
            .sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
            .prefix(doneTaskLimit)
        let open = sources.tasks.filter { $0.lane == .needsYou || $0.lane == .working }
        return (open + done).map { taskItem($0, sources: sources) }
    }

    private static func taskItem(_ task: HermesKanbanTask, sources: WorkSources) -> WorkItem {
        let bucket: WorkBucket
        let pill: String
        let tone: WorkTone
        switch task.lane {
        case .needsYou?:
            bucket = .needsYou
            pill = task.statusNote ?? String(localized: "Needs you")
            tone = task.gotStuck ? .failed : .needsYou
        case .working?:
            bucket = .working
            pill = String(localized: "Working")
            tone = .working
        default:
            bucket = .done
            pill = String(localized: "Done")
            tone = .done
        }
        let bot = task.assignee.map { sources.botNames[$0] ?? $0 }
        return WorkItem(kind: .task, id: "task:" + task.id, title: task.title, pill: pill,
                        line: joined([String(localized: "Task"), bot]), lineSymbol: "checklist", bot: bot,
                        time: task.completedAt ?? task.lastHeartbeatAt ?? task.startedAt ?? task.createdAt,
                        bucket: bucket, tone: tone, projectID: task.projectID, target: .kanbanTask(task.id))
    }

    // MARK: Scheduled tasks

    /// Needs you only when its last run failed. Otherwise it waits for its next run: never Working,
    /// since nothing reports a run in progress.
    private static func scheduleItem(_ task: ScheduledTask, sources: WorkSources) -> WorkItem {
        let bot = sources.botNames[task.agentID]
        let line = joined([task.scheduleDescription.isEmpty ? nil : task.scheduleDescription, bot])
        let failed = task.lastError != nil || task.status == .failed
        let pill: String?
        if failed {
            pill = String(localized: "Last run failed")
        } else if task.status == .paused {
            pill = String(localized: "Paused")
        } else if task.status == .completed {
            pill = String(localized: "Finished")
        } else {
            pill = task.nextRun.map { nextRunText($0, now: sources.now) }
        }
        return WorkItem(kind: .schedule, id: "schedule:\(task.identity.accessibilitySuffix)", title: task.name,
                        pill: pill, line: line, lineSymbol: "clock", bot: bot,
                        time: failed ? task.lastRun : task.nextRun, bucket: failed ? .needsYou : .upcoming,
                        tone: failed ? .failed : .upcoming, projectID: nil, target: .scheduledTask(task.identity))
    }

    /// "7:00 AM" today, "Tue 7:00 AM" later.
    static func nextRunText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// Short parts of one line ("Workflow · step 3 of 4"): names and values, never sentence fragments.
    private static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

@MainActor
extension WorkSources {
    /// Reads every store in the context now. Called from the view's body, so each store it reads is
    /// observed and the list redraws when one changes.
    init(context: WorkContext, now: Date = .now) {
        self.init(now: now)
        if let code = context.code, let reader = context.codeStatus {
            readCode(code, reader: reader)
        }
        chatWork = context.dashboard?.workInFlightItems ?? []
        for (profileID, activity) in context.activity?.liveActivities() ?? [:] {
            if case .background(let work) = activity { background[profileID] = work }
        }
        if let workflows = context.workflows {
            workflowsWaiting = workflows.waiting
            workflowsActive = workflows.active
            workflowsRecent = workflows.recentRuns
        }
        // The board's own cards, not `tasks(in:)`: that applies the Kanban page's agent filter and search.
        tasks = context.kanban?.snapshot?.tasks ?? []
        schedules = context.schedules?.tasks ?? []
        botNames = Dictionary((context.agents?.profiles ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    private mutating func readCode(_ code: CodeHomeStore, reader: any CodeSessionStatusReading) {
        codeSessions = code.sessions.filter { $0.batchID == nil }.map { record in
            // The store reads git for its selected project only.
            let pullRequest = record.projectID == code.projectID
                ? record.branch.flatMap { branch in code.git?.pullRequests.first { $0.branch == branch } } : nil
            return WorkCodeSession(record: record, status: code.status(of: record, reader: reader),
                                   pullRequest: pullRequest)
        }
        codeLaunches = code.launches.filter { $0.sessionID == nil && $0.batchID == nil }
        // As Code home's batch card: its sessions, then its jobs still starting.
        codeBatches = code.batches.map { batch in
            let members = CodeBatchMember.members(of: batch, sessions: code.sessions)
            let pending = code.pendingLaunches(of: batch).reversed()
            let lines = members.map { member in
                WorkBatchLine(id: member.id, title: member.title, index: member.index,
                              status: code.sessions.first { $0.id == member.id }
                                  .map { code.status(of: $0, reader: reader) } ?? .ready)
            } + pending.enumerated().map { offset, launch in
                WorkBatchLine(id: launch.id.uuidString, title: launch.title, index: members.count + offset,
                              status: launch.step.isFailed ? .failed("Couldn't start") : .starting("Setting up"))
            }
            return WorkCodeBatch(batch: batch, lines: lines, startedCount: members.count)
        }
    }
}
