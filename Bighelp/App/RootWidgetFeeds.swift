import SwiftUI

/// The Usage and Workflows widgets read what the app saves. Both read only when
/// one of them is on the Home Screen; Usage also reads from the background.
extension RootShellView {
    /// Each connection (a reconnect when bighelp comes back makes a new one) reads again, once
    /// the agents are known.
    struct UsageWidgetKey: Equatable {
        let owner: WorkspaceOwner?
        let agentsKnown: Bool
        let fixtures: Bool
        let hostID: String
        let isActive: Bool
    }

    struct WorkflowsWidgetKey: Equatable {
        let host: String?
        let isAvailable: Bool
        let isActive: Bool
    }

    var usageWidgetKey: UsageWidgetKey {
        UsageWidgetKey(owner: currentWorkspaceOwner, agentsKnown: agents.knowsProfiles,
                       fixtures: providerUsageKey.fixtures, hostID: usageHostID, isActive: scenePhase == .active)
    }

    var workflowsWidgetKey: WorkflowsWidgetKey {
        WorkflowsWidgetKey(host: currentWorkspaceOwner?.cacheScopeID ?? (usesWorkspaceFixtures ? "fixtures" : nil),
                           isAvailable: workflowsAvailability.isAvailable == true, isActive: scenePhase == .active)
    }

    /// Each Usage widget's gateway, while bighelp is open: now and every 15 minutes.
    func followUsageWidget() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            if let sources = usageWidgetSources { UsageWidgetPublisher.start(sources) }
            try? await Task.sleep(for: UsageWidgetPublisher.interval)
        }
    }

    /// The demo's own numbers, or the gateway in use over this connection and the others over theirs.
    /// Nothing while the connection is down (a read then fails, and the reconnect reads anyway) or
    /// before the agents are known (a read then has only the default agent's).
    private var usageWidgetSources: UsageWidgetPublisher.Sources? {
        if providerUsageKey.fixtures {
            let host = usageReaderKey, agents = self.agents
            let reader = DemoUsageReader(hostID: host.hostID, hostName: host.hostName,
                                         agents: { agents.profiles.map { ($0.id, $0.name) } }, fleet: nil)
            // The demo's sample gateways: its numbers go where the widgets look for the one in use.
            return .init(inUseID: { BighelpWidgetGatewayList.inUseID() }, reader: reader, plans: DemoProviderUsageClient(),
                         agentID: homeAgent?.id ?? "default", others: nil)
        }
        guard currentWorkspaceOwner != nil, agents.knowsProfiles, let connections = workspaceConnections else { return nil }
        return .live(connections: connections, agents: agents, fleet: fleet)
    }

    /// Running workflows, read while bighelp is open and a run is going.
    func followWorkflowsWidget() async {
        guard scenePhase == .active, workflowsAvailability.isAvailable == true, let client = makeWorkflowsClient(),
              await WorkflowsWidgetPublisher.isInstalled() else { return }
        await WorkflowsWidgetPublisher.follow(client: client)
    }
}
