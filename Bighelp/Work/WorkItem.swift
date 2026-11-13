import Foundation

/// What a row on Work is: each kind is read from the store that already holds it.
enum WorkKind: String, CaseIterable, Sendable {
    /// A Code session, a send still starting one, or a batch (`CodeHomeStore`).
    case coding
    /// A chat working right now (`DashboardModel.workInFlightItems`).
    case chat
    /// A bot's background work: subagents, commands and task runs (`BotChatActivity.background`).
    case background
    /// A workflow run (`WorkflowsStore`).
    case workflow
    /// A Kanban card (`KanbanBoardModel`).
    case task
    /// A scheduled task (`ScheduledTasksStore`).
    case schedule
}

/// Which chip a row counts under. `upcoming` shows only under All: a scheduled task that hasn't failed
/// is waiting for its next run, and nothing reports one as working.
enum WorkBucket: String, Sendable {
    case needsYou, working, done, upcoming
}

/// The chips over the list.
enum WorkFilter: String, CaseIterable, Identifiable, Sendable {
    case all, needsYou, working, done

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .needsYou: String(localized: "Needs you")
        case .working: String(localized: "Working")
        case .done: String(localized: "Done")
        }
    }

    func includes(_ bucket: WorkBucket) -> Bool {
        switch self {
        case .all: true
        case .needsYou: bucket == .needsYou
        case .working: bucket == .working
        case .done: bucket == .done
        }
    }
}

/// What a tap on a row opens. The shell maps each to the page that already shows it.
enum WorkTarget: Hashable, Sendable {
    /// A Code session's chat, by its app session ID.
    case codeSession(String)
    /// A Code session's Changes (its long-press menu).
    case codeChanges(String)
    case codeBatch(UUID)
    /// A chat that's working, by its session ID.
    case chat(String)
    /// A bot whose work runs in the background, by profile ID: its Bot Chat.
    case bot(String)
    case workflowRun(String)
    case kanbanTask(String)
    case scheduledTask(ScheduledTaskIdentity)
}

/// The dot and pill color a row takes.
enum WorkTone: Sendable {
    case needsYou, working, done, failed, upcoming
}

/// One line of a batch card: a session or a job still starting, with its live status.
struct WorkBatchLine: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// Its place in the batch, which picks its color (`CodeSessionColor`).
    let index: Int
    let status: CodeSessionStatus
}

/// How a row draws: Code home's own cards for coding work, one shared row for the rest.
enum WorkCard: Equatable, Sendable {
    case session(CodeSessionRecord, CodeSessionStatus, pullRequest: StockGitPullRequest?)
    case launch(CodeLaunch)
    case batch(CodeBatch, lines: [WorkBatchLine], startedCount: Int)
    case row
}

/// One row on Work: only what its store says, never a guess.
struct WorkItem: Identifiable, Equatable, Sendable {
    let kind: WorkKind
    /// Unique across kinds (`kind:storeID`).
    let id: String
    let title: String
    /// The status pill: "Sign off", "Working", "7:00 AM". Nil leaves it out.
    let pill: String?
    /// The second line: where it runs or what it is, and its bot.
    let line: String
    let lineSymbol: String
    /// The bot's name, when the store names one.
    let bot: String?
    /// The last activity; for an upcoming scheduled task, its next run. Nil while it works now and the
    /// store gives no time.
    let time: Date?
    let bucket: WorkBucket
    let tone: WorkTone
    /// The project it belongs to, for Work filtered to a project.
    let projectID: String?
    /// Nil when there's nothing to open (a send that failed before it had a session).
    let target: WorkTarget?
    var card: WorkCard = .row
}
