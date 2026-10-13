import Foundation

/// Where a Bighelp IDE session works.
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

/// A project Bighelp IDE can start sessions in: a Hermes project with one main folder.
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

/// One session Bighelp IDE started, kept on this device per computer so its card
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
}

/// A send that hasn't become a session yet, or couldn't.
struct CodeLaunch: Identifiable, Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case makingWorktree
        case switchingBranch
        case startingSession
        case sending
        case failed(String)
    }

    let id: UUID
    let title: String
    let projectID: String
    let placement: CodePlacement
    let branch: String?
    var step: Step
    /// Set once Hermes has the session, so a failed send still opens it.
    var sessionID: String?
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

/// A session's name from the message that starts it: its first line, trimmed.
enum CodeSessionTitle {
    static func from(_ message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).first.map(String.init) ?? message
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maximumLength else { return trimmed.isEmpty ? "Coding session" : trimmed }
        return String(trimmed.prefix(maximumLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let maximumLength = 80
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
