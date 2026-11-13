import Foundation

// One home: delete with the old shell, all but `screenKey`, `homeLanding(stored:)` and the mapping to
// `HomeLanding`. The home opens on one of four places (`HomeLanding`, Settings › Chat › Opens on), saved
// under the same key; the old shell still reads the nine screens below until it goes.

/// The screen the old shell opens on. It applies to a cold launch only, and a link, widget or
/// notification that opens the app wins.
enum BighelpLandingScreen: String, CaseIterable, Identifiable, Sendable {
    case agents
    case allAgents = "all-agents"
    case lastChat = "last-chat"
    case sessions
    case feed, ideas, goals, kanban, projects

    var id: Self { self }

    var title: String {
        switch self {
        case .agents: String(localized: "Agents")
        case .allAgents: String(localized: "Agents (multi)")
        case .lastChat: String(localized: "Last chat")
        case .sessions: String(localized: "Sessions")
        case .feed: String(localized: "Feed")
        case .ideas: String(localized: "Ideas")
        case .goals: String(localized: "Goals")
        case .kanban: String(localized: "Kanban")
        case .projects: String(localized: "Projects")
        }
    }

    /// Every choice but every computer's agents starts with one agent.
    var offersStartAgent: Bool { self != .allAgents && self != .sessions }

    /// Where the one home opens for a screen saved before it (PLAN-shell § 4).
    var homeLanding: HomeLanding {
        switch self {
        case .agents, .allAgents: .bots
        case .sessions, .lastChat: .chats
        case .feed, .ideas, .goals: .today
        case .kanban, .projects: .work
        }
    }
}

/// What a cold launch was asked to open on.
enum BighelpLandingChoice: Equatable, Sendable {
    /// Nothing picked: the agent's latest chat, as before. `opensChat` is the
    /// older `loopdy.home.opens-chat` (no Settings row; the UI tests' older
    /// flows pass NO to start on the chat list).
    case standard(opensChat: Bool)
    case chosen(BighelpLandingScreen)
}

/// Where the launch goes once the computer's chats and agents are in.
enum BighelpLandingDestination: Equatable, Sendable {
    case chatList, homeChat, agents, allAgents, board(AppTab), kanban, projects
}

enum BighelpLanding {
    static let screenKey = "loopdy.home.landing"
    static let legacyOpensChatKey = "loopdy.home.opens-chat"
    /// Agent IDs only mean something on their own computer, so Start with is
    /// kept per computer (`cacheScopeID` → agent ID).
    static let startAgentKey = "loopdy.home.start-agent.by-scope"
    /// How long Kanban gets to say whether a computer has it, the first time.
    static let kanbanWait: Duration = .seconds(3)

    /// Opens on as saved: one of the four, or an old screen mapped to its place. Nil when nothing was
    /// picked, or the value is unknown.
    static func homeLanding(stored: String?) -> HomeLanding? {
        guard let stored else { return nil }
        return HomeLanding(rawValue: stored) ?? BighelpLandingScreen(rawValue: stored)?.homeLanding
    }

    static func choice(screen: BighelpLandingScreen?, legacyOpensChat: Bool?) -> BighelpLandingChoice {
        if let screen { return .chosen(screen) }
        return .standard(opensChat: legacyOpensChat ?? true)
    }

    /// Nil: wait for Kanban to answer.
    static func destination(for choice: BighelpLandingChoice, kanbanAvailable: Bool?, kanbanWaitIsOver: Bool,
                            projectsAvailable: Bool) -> BighelpLandingDestination? {
        let screen: BighelpLandingScreen
        switch choice {
        case .standard(let opensChat): return opensChat ? .homeChat : .chatList
        case .chosen(let chosen): screen = chosen
        }
        switch screen {
        case .agents: return .agents
        case .allAgents: return .allAgents
        case .lastChat: return .homeChat
        case .sessions: return .chatList
        case .feed: return .board(.feed)
        case .ideas: return .board(.ideas)
        case .goals: return .board(.goals)
        case .projects: return projectsAvailable ? .projects : .homeChat
        case .kanban:
            switch kanbanAvailable {
            case true?: return .kanban
            case false?: return .homeChat
            case nil: return kanbanWaitIsOver ? .homeChat : nil
            }
        }
    }

    /// The agent to start with, while it's still on that computer; nil is
    /// Automatic (the agent you used last).
    static func startAgent(stored: String?, agentIDs: [String], choice: BighelpLandingChoice) -> String? {
        if case .chosen(let screen) = choice, !screen.offersStartAgent { return nil }
        guard let stored, agentIDs.contains(stored) else { return nil }
        return stored
    }
}
