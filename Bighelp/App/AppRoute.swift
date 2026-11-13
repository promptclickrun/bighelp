import Foundation

/// A page pushed over one of the home's three places (`HomeTab`).
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
    /// Workflows: stages run by agents on the host, with your sign-off (Work › Workflows).
    case workflows
    case workflow(id: String, startsRun: Bool)
    case workflowRun(id: String)
    case workflowSignoff(runID: String)
    /// All runs; the Mac's three-column monitor, with one selected.
    case workflowRuns(selected: String?)
    /// Plans, limits and what the agents used (Settings › Usage, and a chat's ⋯).
    case usage
    /// Today's See all: every bot's Feed, Ideas or Goals, or one bot's (`TodayBoardPage`).
    case board(AgentBoardItem.Kind, agentID: String? = nil)
    /// Work filtered to one project, with its pull requests, worktrees and Dev Factory.
    case work(projectID: String)
    /// A coding session's changes, with Ship.
    case codeChanges(sessionID: String)
    /// The chat for a batch sent with Send all.
    case codeBatch(id: UUID)
    /// Dev Factory (the ⋯ of Work filtered to a project): its home, a recipe, one start's runs, a run's changes.
    case devFactory
    case devFactoryRecipe(id: String)
    case devFactoryGroup(id: String)
    case devFactoryChanges(runID: String)
    /// A bot's page, from its chat's name or a long press. `opening` is for code that
    /// shows a person one tab and sheet (an agent's drive); nil opens it as a tap does.
    case simpleBotProfile(agentID: String, opening: BotProfileOpening? = nil)
    /// A group chat's Group Settings, from its name, its ⋯ menu or a list of chats.
    /// `conversationID` is its open chat, for what that chat shows (tool calls).
    case groupSettings(roomID: String, conversationID: String? = nil)
    /// A section's page, from the Bots view: its bots and group chats.
    case simpleBotsSection(id: String)
}
