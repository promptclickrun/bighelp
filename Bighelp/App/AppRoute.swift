import Foundation

// One home: the old shell's tabs. Nothing selects them any more (`HomeTab` is the bar); they go with
// `FloatingTabBar`, `BighelpAppLayout`, `BighelpMenu` and the boards' old header.
enum AppTab: String, CaseIterable, Identifiable {
    case home, agents, sessions, inbox, profile, scheduledTasks
    case feed, ideas, goals, apps
    /// Pages ☰ opens, as tabs when the person pins them to the bottom bar.
    case projects, kanban, workflows, usage
    /// Code mode's home: coding sessions on the host's projects (Settings › Code mode).
    case code
    /// Every chat, as its own tab (App layout's Sessions). It's the Chat tab's list
    /// (`selectedTab` stays `.sessions`); only the bottom bar tells them apart.
    case sessionList

    /// The standard bottom bar: the agent's chat, then its Feed, Ideas, Goals and Apps.
    /// Settings › Appearance › App layout changes it (`BighelpAppLayout.barTabs`).
    static let allCases: [AppTab] = [.sessions, .feed, .ideas, .goals, .apps]

    /// One computer's pages, opened from ☰ or pinned to the bar.
    var isHostPage: Bool { [.projects, .kanban, .workflows, .usage].contains(self) }

    /// Screens people stay on (Projects, Kanban, Workflows): from ☰ they open as screens of
    /// their own, with ☰ in the corner. Quick ones (Usage, and Feed, Ideas or Goals when the
    /// bottom bar doesn't hold them) slide in over where you are, with Back.
    var isLongStay: Bool { [.projects, .kanban, .workflows, .code].contains(self) }

    /// Tabs drawn as the selected agent's board (no navigation bar).
    var isAgentBoard: Bool { [.feed, .ideas, .goals, .apps].contains(self) }

    var id: Self { self }
}

enum AppRoute: Hashable {
    case chat(conversationID: String)
    /// The computer in use's own Sessions page (projects, imports from other apps), from Chats.
    case sessions
    case scheduledTasks
    case scheduledTask(id: String, agentID: String? = nil)
    case skillsAndTools
    case approval(requestID: String)
    case workspaceSettings
    case workspaceManagement(WorkspaceDestination)
    case workspaceConnections
    /// Projects, like Claude's: related chats and folders together.
    case projects
    case project(id: String)
    /// Kanban: the host's boards, worked by its agents.
    case kanban
    /// Workflows: stages run by agents on the host, with your sign-off (☰ › Workflows).
    case workflows
    case workflow(id: String, startsRun: Bool)
    case workflowRun(id: String)
    case workflowSignoff(runID: String)
    /// All runs; the Mac's three-column monitor, with one selected.
    case workflowRuns(selected: String?)
    /// Plans, limits and what the agents used (☰ › Usage).
    case usage
    /// Today's See all: every bot's Feed, Ideas or Goals, or one bot's (`TodayBoardPage`).
    case board(AgentBoardItem.Kind, agentID: String? = nil)
    /// Work filtered to one project, with its pull requests, worktrees and Dev Factory.
    case work(projectID: String)
    /// A Code mode session's changes, with Ship.
    case codeChanges(sessionID: String)
    /// Orchestration mode's chat for a batch sent with Send all.
    case codeBatch(id: UUID)
    /// Dev Factory (☰ › Dev Factory in Code mode): its home, a recipe, one start's runs, a run's changes.
    case devFactory
    case devFactoryRecipe(id: String)
    case devFactoryGroup(id: String)
    case devFactoryChanges(runID: String)
    /// Bots mode: a bot's profile, from its chat's name or a long press. `opening` is for code that
    /// shows a person one tab and sheet (an agent's drive); nil opens it as a tap does.
    case simpleBotProfile(agentID: String, opening: BotProfileOpening? = nil)
    /// A group chat's Group Settings, from its name, its ⋯ menu or a list of chats.
    /// `conversationID` is its open chat, for what that chat shows (tool calls).
    case groupSettings(roomID: String, conversationID: String? = nil)
    /// A section's page (Bots mode's home or the Agents screen): its bots and group chats.
    case simpleBotsSection(id: String)
}
