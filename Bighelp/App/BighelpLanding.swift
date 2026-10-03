import Foundation

/// The screen bighelp opens on (Settings › Chat › Open on). It applies to a
/// cold launch only, and a link, widget or notification that opens the app wins.
enum BighelpLandingScreen: String, CaseIterable, Identifiable, Sendable {
    case agents
    case allAgents = "all-agents"
    case lastChat = "last-chat"
    case feed, ideas, goals, kanban, projects

    var id: Self { self }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .allAgents: "Agents (multi)"
        case .lastChat: "Last chat"
        case .feed: "Feed"
        case .ideas: "Ideas"
        case .goals: "Goals"
        case .kanban: "Kanban"
        case .projects: "Projects"
        }
    }

    var detail: String {
        switch self {
        case .agents: "This computer's agents."
        case .allAgents: "Every agent on every computer."
        case .lastChat: "Your latest chat with the agent."
        case .feed: "The agent's Feed."
        case .ideas: "The agent's Ideas."
        case .goals: "The agent's Goals."
        case .kanban: "The board, where this computer has Kanban."
        case .projects: "This computer's projects."
        }
    }

    /// Every choice but every computer's agents starts with one agent.
    var offersStartAgent: Bool { self != .allAgents }
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

    /// A picked screen decides the all-hosts view at launch; nothing picked
    /// leaves the switch as it was.
    static func allHostsMode(for choice: BighelpLandingChoice) -> Bool? {
        guard case .chosen(let screen) = choice else { return nil }
        return screen == .allAgents
    }

    /// The agent to start with, while it's still on that computer; nil is
    /// Automatic (the agent you used last).
    static func startAgent(stored: String?, agentIDs: [String], choice: BighelpLandingChoice) -> String? {
        if case .chosen(let screen) = choice, !screen.offersStartAgent { return nil }
        guard let stored, agentIDs.contains(stored) else { return nil }
        return stored
    }
}
