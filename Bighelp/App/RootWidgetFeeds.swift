import SwiftUI

/// The Usage and Workflows widgets read what the app saves while it's open.
/// Both read only when one of them is on the Home Screen.
extension RootShellView {
    struct UsageWidgetKey: Equatable {
        let usage: UsageReaderKey
        let plans: ProviderUsageKey
        let isActive: Bool
    }

    struct WorkflowsWidgetKey: Equatable {
        let host: String?
        let isAvailable: Bool
        let isActive: Bool
    }

    var usageWidgetKey: UsageWidgetKey {
        UsageWidgetKey(usage: usageReaderKey, plans: providerUsageKey, isActive: scenePhase == .active)
    }

    var workflowsWidgetKey: WorkflowsWidgetKey {
        WorkflowsWidgetKey(host: currentWorkspaceOwner?.cacheScopeID ?? (usesWorkspaceFixtures ? "fixtures" : nil),
                           isAvailable: workflowsAvailability.isAvailable == true, isActive: scenePhase == .active)
    }

    /// The last 30 days and the plans, at most every 15 minutes while bighelp is open.
    func refreshUsageWidget() async {
        guard scenePhase == .active, await UsageWidgetPublisher.isInstalled() else { return }
        let made = usageReader(usageReaderKey)
        let key = providerUsageKey
        let plans: (any ProviderUsageClient)? = if key.fixtures {
            DemoProviderUsageClient()
        } else if key.signIn != nil, let connections = workspaceConnections {
            DirectHermesProviderUsageClient(currentWorkspace: { [weak connections] in connections?.workspace })
        } else {
            nil
        }
        await UsageWidgetPublisher.refresh(reader: made?.reader, plans: plans, agentID: homeAgent?.id ?? "default",
                                           scope: made?.scope)
    }

    /// Running workflows, read while bighelp is open and a run is going.
    func followWorkflowsWidget() async {
        guard scenePhase == .active, workflowsAvailability.isAvailable == true, let client = makeWorkflowsClient(),
              await WorkflowsWidgetPublisher.isInstalled() else { return }
        await WorkflowsWidgetPublisher.follow(client: client)
    }
}
