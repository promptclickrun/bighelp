import SwiftUI

// MARK: - Workflows

extension RootShellView {
    /// The bighelp plugin's Workflows on the connected host; demo mode has samples.
    func makeWorkflowsClient() -> (any WorkflowsClient)? {
        if usesWorkspaceFixtures, workspaceConnections?.isDirectSelected != true {
            return DemoWorkflowsClient.forHost(demoHosts.selectedHostID)
        }
        guard currentWorkspaceOwner != nil, let connections = workspaceConnections else { return nil }
        // Reads always go through the connection in use; a reconnect keeps the client.
        return DirectHermesWorkflowsClient(currentWorkspace: { [weak connections] in connections?.workspace })
    }

    /// Checks the host for Workflows whenever it (re)connects, so ☰ shows the
    /// row only where it works. The same computer keeps its row and its store;
    /// only a clear answer from the host changes the row (`WorkflowsAvailability`).
    func configureWorkflows(_ key: AgentBoardClientKey) async {
        if workflowsAvailability.use(host: key.owner?.cacheScopeID) {
            // Another computer, or none: nothing from the old one stays.
            workflowsStore?.setOnScreen(false)
            workflowsStore = nil
        }
        guard key.owner != nil, let client = makeWorkflowsClient() else { return }
        await workflowsAvailability.check { try await client.support() }
    }

    /// ☰ shows Workflows for any connected computer. Where the plugin lacks them
    /// or says this computer can't run them, the Workflows page says why and
    /// what to do, so a slow or failed check never hides the feature.
    var canOpenWorkflows: Bool { workflowsAvailability.host != nil || workflowsAvailability.isAvailable == true }

    /// Opens ☰ › Workflows over the chat, so Back returns there.
    func openWorkflows() {
        guard prepareWorkflowsStore() != nil else {
            actionErrorMessage = "Connect to your computer to use Workflows."
            return
        }
        if appState.selectedTab != .sessions { appState.select(.sessions) }
        appState.path = [.workflows]
    }

    /// Opens one run (a widget, a link or a notification later).
    func openWorkflows(run: String) {
        guard prepareWorkflowsStore() != nil else { return }
        if appState.selectedTab != .sessions { appState.select(.sessions) }
        appState.path = [.workflows, BighelpPlatform.isMac ? .workflowRuns(selected: run) : .workflowRun(id: run)]
    }

    /// A tapped workflow alert names its run only as a chat reference (`workflow.run.<id>`,
    /// hashed with the agent); finds that run among the recent ones and opens it.
    func openNotifiedWorkflowRun(profileID: String, reference: String) async -> Bool {
        guard let client = makeWorkflowsClient(),
              let page = try? await client.runs(workflowID: nil, filter: .all, before: nil, limit: 50),
              let run = page.runs.first(where: {
                  ManagedNotificationValidation.sessionReference(profile: profileID,
                                                                 session: Self.workflowAlertPrefix + $0.id) == reference
              }) else { return false }
        openWorkflows(run: run.id)
        return true
    }

    /// The plugin's chat coordinate for a run's alerts (managed_notifications.WORKFLOW_SESSION_PREFIX).
    static let workflowAlertPrefix = "workflow.run."

    @discardableResult
    private func prepareWorkflowsStore() -> WorkflowsStore? {
        if let workflowsStore { return workflowsStore }
        guard let client = makeWorkflowsClient() else { return nil }
        let store = WorkflowsStore(client: client, support: workflowsAvailability.support)
        workflowsStore = store
        return store
    }

    private var workflowsContext: WorkflowsContext? {
        guard let store = workflowsStore else { return nil }
        let roster = agents.profiles.map { WorkflowAgent(id: $0.id, name: $0.name) }
        let navigation = appState
        return WorkflowsContext(store: store, agents: roster, isNerdMode: settings.nerdModeEnabled,
                                hostName: workspaceHostName, open: { navigation.path.append($0) })
    }

    @ViewBuilder
    func workflowsDestination(_ route: AppRoute) -> some View {
        if let context = workflowsContext {
            switch route {
            case .workflow(let id, let startsRun):
                WorkflowScreen(context: context, workflowID: id, startsRun: startsRun)
            case .workflowRun(let id):
                WorkflowRunScreen(context: context, runID: id)
            case .workflowSignoff(let runID):
                WorkflowSignoffScreen(context: context, runID: runID)
            case .workflowRuns(let selected):
                WorkflowRunMonitorView(context: context, selected: selected)
            default:
                WorkflowsHomeView(context: context)
            }
        } else {
            ContentUnavailableView("Workflows aren't available", systemImage: "flowchart",
                description: Text("Connect to your computer, then open Workflows from the menu."))
        }
    }
}
