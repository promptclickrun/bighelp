import Foundation

/// Where a coding session works.
enum CodePlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Its own copy of the project on a new branch, so sessions run side by side.
    case newWorktree
    /// The project's own folder on the computer.
    case local

    var id: Self { self }

    var title: String {
        switch self {
        case .newWorktree: "New worktree"
        case .local: "Local checkout"
        }
    }

    var detail: String {
        switch self {
        case .newWorktree: "Its own copy of the project on a new branch. Sessions can run side by side."
        case .local: "Works in the folder already on your computer."
        }
    }

    var systemImage: String {
        switch self {
        case .newWorktree: "square.on.square"
        case .local: "laptopcomputer"
        }
    }
}

/// How a new coding session works (the choices row's mode chip). Each is a
/// Hermes option: Plan sends the first message through `/plan`, which writes a
/// Markdown plan and changes no code; YOLO turns on the session's own YOLO
/// setting (no approval prompts) before the first message.
enum CodeSessionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard = "default"
    case plan
    case yolo

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "Default"
        case .plan: "Plan"
        case .yolo: "YOLO"
        }
    }

    var detail: String {
        switch self {
        case .standard: "Asks before risky commands, as usual."
        case .plan: "Writes a plan first. Changes no code."
        case .yolo: "Runs commands without asking."
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "hand.raised"
        case .plan: "list.bullet.clipboard"
        case .yolo: "bolt"
        }
    }

    /// The first message as Hermes gets it. A message that is already a slash command keeps it.
    func firstMessage(_ message: String) -> String {
        guard self == .plan, !message.hasPrefix("/") else { return message }
        return "/plan " + message
    }
}

/// A project a coding session can start in: a Hermes project with one main folder.
struct CodeProject: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// The project's main folder on the host: the local checkout, and where worktrees branch from.
    let folder: String
    var icon: String?
    var color: String?
}

/// A git folder Hermes found on the computer that isn't a project yet.
struct CodeFoundFolder: Identifiable, Equatable, Sendable {
    let path: String
    let name: String
    var id: String { path }
}

/// One coding session, kept on this device per computer so its card
/// survives a relaunch. Its status always comes from the live chat.
struct CodeSessionRecord: Codable, Identifiable, Equatable, Sendable {
    /// The app's session ID, which opens the chat.
    let id: String
    let agentID: String
    let projectID: String
    let projectName: String
    let title: String
    /// Where it works: a worktree, or the project's main folder.
    let folder: String
    let branch: String?
    let placement: CodePlacement
    let startedAt: Date
    /// Nil on cards saved before the mode button.
    var mode: CodeSessionMode?
    /// The batch it was sent with (Send all), if any.
    var batchID: UUID?
}

/// The exact host folder and branch one launch owns. It is saved before git is changed, so a retry
/// can validate and resume that destination instead of creating another one with a similar name.
struct CodeLaunchDestination: Codable, Equatable, Sendable {
    let folder: String
    let branch: String?
    let placement: CodePlacement
}

/// A send that hasn't become a session yet, or whose create/send outcome is still recoverable.
/// Kept on this device, so a known failure can retry and an uncertain result can be checked without
/// resubmitting. A launch's message is the person's own text, so losing the card means losing it.
struct CodeLaunch: Codable, Identifiable, Equatable, Sendable {
    enum Step: Codable, Equatable, Sendable {
        case makingWorktree
        case switchingBranch
        case startingSession
        case readyToSend
        case sending
        case failed(String)
        case needsRecovery(String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        var needsRecovery: Bool {
            if case .needsRecovery = self { return true }
            return false
        }
    }

    let id: UUID
    let title: String
    let projectID: String
    /// Optional for launches saved by 2.6.95; the selected project supplies these after that.
    var projectName: String? = nil
    var projectFolder: String? = nil
    /// What Send asked for, kept whole so Try again sends exactly the same thing.
    let job: CodeStagedJob
    var step: Step
    /// The launch's exact requested time, when available. Used to bound idempotent create recovery.
    var startedAt: Date? = nil
    /// Persisted before the matching git action; worktree/session retries validate this destination.
    var destination: CodeLaunchDestination? = nil
    /// Set once Hermes has the session, so a failed send still opens it.
    var sessionID: String? = nil
    /// Correlates the local send with the chat's durable submission journal and optimistic row.
    var submissionID: UUID? = nil
    /// The batch it belongs to (Send all), if any.
    var batchID: UUID? = nil

    /// The branch the card shows: Local's, as the checkout had it when Send went.
    var branchLabel: String? = nil

    /// A send that was under way when the app closed can never finish on its own: the step it
    /// waited for was a request in a process that's gone.
    static let interruptedReason = String(localized: "The app closed before this send finished.")

    var placement: CodePlacement { job.placement }
    var branch: String? { destination?.branch ?? branchLabel }
}

/// What a card says about its session, from the live chat (never guessed).
enum CodeSessionStatus: Equatable, Sendable {
    case starting(String)
    /// Working; the tool or step it's on, when Hermes reports one.
    case running(String?)
    /// Waiting on the person: an approval or a question.
    case needsYou(String)
    case ready
    case failed(String)

    var filter: CodeSessionFilter {
        switch self {
        case .starting, .running: .running
        case .needsYou: .needsYou
        case .ready, .failed: .ready
        }
    }
}

/// The chips over the session list.
enum CodeSessionFilter: String, CaseIterable, Identifiable, Sendable {
    case all, running, needsYou, ready

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .running: "Running"
        case .needsYou: "Needs you"
        case .ready: "Ready"
        }
    }
}

/// A session's name from the message that starts it: its first line, trimmed, without
/// a leading slash command ("/plan Add a loading state" is "Add a loading state").
enum CodeSessionTitle {
    static func from(_ message: String) -> String {
        let message = withoutCommand(message)
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumLength else { return trimmed.isEmpty ? "Coding session" : trimmed }
        return String(trimmed.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let maximumLength = 80

    /// The text after a leading `/command`, or the message itself; a bare command stays.
    static func withoutCommand(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), let space = trimmed.firstIndex(where: \.isWhitespace) else { return trimmed }
        let rest = trimmed[space...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? trimmed : rest
    }
}

/// The model, reasoning and fast mode new sessions start with (the message box's
/// model chip). A part left nil keeps the agent's own setting.
struct CodeRuntimeChoice: Codable, Equatable, Sendable {
    var providerID: String?
    var modelID: String?
    /// A Hermes reasoning value ("low", "high", …).
    var reasoning: String?
    var fastMode: Bool?

    var isEmpty: Bool { modelID == nil && reasoning == nil && fastMode == nil }

    /// The levels the chip offers before a session exists; the session confirms its own.
    static let reasoningLevels: [(value: String, label: String)] = [
        ("none", "Off"), ("minimal", "Minimal"), ("low", "Low"), ("medium", "Medium"),
        ("high", "High"), ("xhigh", "X-High"), ("max", "Max"), ("ultra", "Ultra"),
    ]

    static func reasoningLabel(_ value: String) -> String {
        reasoningLevels.first { $0.value == value }?.label ?? value
    }
}
