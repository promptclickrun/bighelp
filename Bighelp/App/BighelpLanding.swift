import Foundation

/// A screen the app could open on before the one home, as saved under `BighelpLanding.screenKey`. Only
/// read now: each maps to one of the home's four places (`HomeLanding`, Settings › Chat › Opens on).
enum BighelpLandingScreen: String, CaseIterable, Sendable {
    case agents
    case allAgents = "all-agents"
    case lastChat = "last-chat"
    case sessions
    case feed, ideas, goals, kanban, projects

    /// Where the one home opens for a screen saved before it.
    var homeLanding: HomeLanding {
        switch self {
        case .agents, .allAgents: .bots
        case .sessions, .lastChat: .chats
        case .feed, .ideas, .goals: .today
        case .kanban, .projects: .work
        }
    }
}

enum BighelpLanding {
    static let screenKey = "loopdy.home.landing"
    /// Saved by earlier versions and never read now; `HomeSettingsMigration` takes either as a sign of an
    /// existing install.
    static let legacyOpensChatKey = "loopdy.home.opens-chat"
    static let startAgentKey = "loopdy.home.start-agent.by-scope"

    /// Opens on as saved: one of the four, or an old screen mapped to its place. Nil when nothing was
    /// picked, or the value is unknown.
    static func homeLanding(stored: String?) -> HomeLanding? {
        guard let stored else { return nil }
        return HomeLanding(rawValue: stored) ?? BighelpLandingScreen(rawValue: stored)?.homeLanding
    }
}
