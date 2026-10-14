import SwiftUI

// MARK: - Bot Screen

extension RootShellView {
    /// The agents' screens on the connected host; demo mode has a made-up one.
    func makeBotScreenService() -> (any BotScreenService)? {
        if usesWorkspaceFixtures, workspaceConnections?.isDirectSelected != true {
            return DemoBotScreenService.shared
        }
        guard let connections = workspaceConnections, let owner = currentWorkspaceOwner,
              let hostID = connections.hosts.selectedHostID else { return nil }
        return LiveBotScreenService(signIn: owner.signIn, hostID: hostID) {
            guard connections.hosts.selectedHostID == hostID, let owner = connections.owner,
                  let workspace = connections.workspace,
                  let client = connections.hosts.selectedWorkspace?.nativeClient else { return nil }
            return .init(owner: owner, workspace: workspace,
                         streams: client.makeBotScreenStreams(owner: owner, currentOwner: { connections.owner }))
        }
    }

    /// The agent's one-to-one chats open in the app: what it's doing on its screen, and Stop task.
    func botScreenChats(for agent: AgentProfile) -> [ChatModel] {
        sessionCatalog.recentSummaries(includeCronSessions: false)
            .filter { $0.kind == .direct && $0.agentIDs.first == agent.id }
            .compactMap { featureStore.preparedChatModel(id: $0.id) }
    }
}
