enum AppTab: String, CaseIterable, Identifiable {
    case home, agents, sessions, inbox, profile, scheduledTasks, workspace
    case feed, ideas, goals, apps
    /// Pages ☰ opens, as tabs when the person pins them to the bottom bar.
    case projects, kanban, workflows, usage

    /// The standard bottom bar: the agent's chat, then its Feed, Ideas, Goals and Apps.
    /// Settings › Appearance › App layout changes it (`BighelpAppLayout.barTabs`).
    static let allCases: [AppTab] = [.sessions, .feed, .ideas, .goals, .apps]

    /// One computer's pages, opened from ☰ or pinned to the bar.
    var isHostPage: Bool { [.projects, .kanban, .workflows, .usage].contains(self) }

    /// Screens people stay on (Projects, Kanban, Workflows): from ☰ they open as screens of
    /// their own, with ☰ in the corner. Quick ones (Usage, and Feed, Ideas or Goals when the
    /// bottom bar doesn't hold them) slide in over where you are, with Back.
    var isLongStay: Bool { [.projects, .kanban, .workflows].contains(self) }

    /// Tabs drawn as the selected agent's board (no navigation bar).
    var isAgentBoard: Bool { [.feed, .ideas, .goals, .apps].contains(self) }

    var id: Self { self }
}

enum AppRoute: Hashable {
    case chat(conversationID: String)
    case sessions
    case scheduledTasks
    case scheduledTask(id: String, agentID: String? = nil)
    case skillsAndTools
    case approval(requestID: String)
    case workspaceActivity
    case workspaceSettings
    case workspaceManagement(WorkspaceDestination)
    case workspaceConnections
    case workspaceHub
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
    /// The all-hosts view's chat list: every host's chats.
    case allHostsChats
    /// Feed, Ideas, Goals or Files as a quick screen with Back, when the bottom bar doesn't hold it.
    case board(AppTab)

    /// Screens about every computer, which stay put when the working computer changes.
    var isAllHosts: Bool { self == .allHostsChats }
}
