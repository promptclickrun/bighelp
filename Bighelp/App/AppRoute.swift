enum AppTab: String, CaseIterable, Identifiable {
    case home, agents, sessions, inbox, profile, scheduledTasks, workspace
    case feed, ideas, goals, apps

    /// The bottom bar: the agent's chat, then its Feed, Ideas, Goals and Apps.
    /// Agents, Tasks and Settings live in the ☰ drawer and the iPad sidebar.
    static let allCases: [AppTab] = [.sessions, .feed, .ideas, .goals, .apps]

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
    /// The all-hosts view's chat list: every host's chats.
    case allHostsChats
}
