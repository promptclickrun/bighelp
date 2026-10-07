import SwiftUI

// MARK: - Kanban

extension RootShellView {
    /// The agents a board can show: the host's profiles with their pictures.
    var kanbanAgents: [KanbanAgent] {
        agents.profiles.map { KanbanAgent(id: $0.id, name: $0.name, imageURL: agents.avatarURL(for: $0)) }
    }

    /// Hermes' Kanban plugin on the connected host; demo mode has samples.
    func makeKanbanService() -> KanbanService? {
        if usesWorkspaceFixtures, workspaceConnections?.isDirectSelected != true {
            return DemoKanbanService.shared
        }
        guard let owner = currentWorkspaceOwner,
              workspaceConnections?.hosts.selectedWorkspace?.nativeClient != nil else { return nil }
        // Boards are shared by every agent, so only the host has to stay the
        // same; the service follows each reconnect to it.
        let connections = workspaceConnections
        return LiveKanbanService(
            host: owner.authority,
            currentOwner: { currentWorkspaceOwner },
            makeClient: { owner in
                connections?.hosts.selectedWorkspace?.nativeClient?
                    .makeKanbanClient(owner: owner, currentOwner: { currentWorkspaceOwner })
            })
    }

    /// Checks the host for Kanban whenever it (re)connects: the menu shows
    /// Kanban only where it works, and the widget gets that host's boards.
    /// Reconnecting to the same computer keeps the board and the menu row;
    /// only a clear answer from the host changes the row (`KanbanAvailability`).
    func configureKanban(_ key: AgentBoardClientKey) async {
        let isNewHost = kanbanAvailability.use(host: key.owner?.cacheScopeID)
        if isNewHost {
            // Another computer: nothing from the old one stays.
            kanbanModel?.setOnScreen(false)
            kanbanModel = nil
            if !key.fixtures { KanbanWidgetPublisher.clear() }
        }
        guard key.owner != nil, let service = makeKanbanService() else { return }
        // A board that showed before the computer answered gets its data now.
        if kanbanModel == nil, isKanbanPageOpen { kanbanModel = KanbanBoardModel(service: service, agents: kanbanAgents) }
        await kanbanAvailability.check { try await service.isAvailable() }
        guard !Task.isCancelled, !key.fixtures, kanbanAvailability.isAvailable == true else { return }
        await KanbanWidgetPublisher.refreshAll(service: service, agents: kanbanAgents, force: isNewHost)
    }

    var canOpenKanban: Bool { kanbanAvailability.isAvailable == true }

    private var isKanbanPageOpen: Bool {
        appState.selectedTab == .kanban || appState.path.contains { route in
            if case .kanban = route { true } else { false }
        }
    }

    /// Opens the board (or one of its cards). On Vision Pro it gets its own window.
    func openKanban(board: String? = nil, task: String? = nil) {
        let model: KanbanBoardModel
        if let current = kanbanModel {
            model = current
        } else {
            guard let service = makeKanbanService() else {
                actionErrorMessage = "Connect to your computer to use Kanban."
                return
            }
            model = KanbanBoardModel(service: service, agents: kanbanAgents)
            kanbanModel = model
        }
        if let board { Task { await model.select(board: board) } }
        kanbanTaskToOpen = task
        #if os(visionOS)
        if !KanbanWindowCoordinator.opensInMainWindowForTests {
            KanbanWindowCoordinator.shared.show(model, taskID: task)
            openWindow(id: KanbanWindowCoordinator.windowID)
            return
        }
        #endif
        showOneHostPageOnSessions([.kanban])
    }

    @ViewBuilder
    var kanbanDestination: some View {
        if let model = kanbanModel {
            KanbanScreen(model: model, isNerdMode: settings.nerdModeEnabled, initialTaskID: kanbanTaskToOpen)
        } else if currentWorkspaceOwner == nil, workspaceConnections != nil {
            // Back in the app, the connection opens again in a moment.
            ProgressView("Connecting to your computer…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("kanban.connecting")
        } else {
            ContentUnavailableView("Kanban isn't available", systemImage: "rectangle.split.3x1",
                description: Text("Connect to your computer, then open Kanban from the menu."))
        }
    }
}
