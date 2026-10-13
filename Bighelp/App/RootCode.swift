import SwiftUI

/// Bighelp IDE's sheets over its home.
enum CodeSheet: String, Identifiable {
    case pullRequests, worktrees
    var id: String { rawValue }
}

// Bighelp IDE (Settings › Bighelp IDE): its home, sessions, changes and ☰ entries.
extension RootShellView {
    /// Bighelp IDE needs a host that starts sessions in a chosen folder: native Hermes, or the demo.
    var canUseCodeMode: Bool {
        nativeRuntime != nil || (usesWorkspaceFixtures && workspaceConnections?.isDirectSelected != true)
    }

    /// Shows the home `settings.experience` picks, and returns to it after host and account changes.
    func applyExperience() {
        let home: AppTab = settings.experience == .code ? .code : .sessions
        guard appState.homeTab != home else { return }
        appState.homeTab = home
        appState.select(home)
    }

    @ViewBuilder
    var codeRootTab: some View {
        Group {
            if let store = codeHome, store.scopeID == currentWorkspaceOwner?.cacheScopeID {
                CodeHomeView(context: codeContext(store))
                    .bighelpSheet(item: $codeSheet) { sheet in codeSheetView(sheet, store: store) }
            } else if canUseCodeMode {
                ProgressView("Loading Bighelp IDE")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Bighelp IDE needs your computer", systemImage: "laptopcomputer",
                    description: Text("Connect to a computer running Hermes, then come back to Code."))
            }
        }
        .task(id: currentWorkspaceOwner?.cacheScopeID) { prepareCodeHome() }
    }

    /// One Code home per computer, made on first use and kept through reconnects.
    func prepareCodeHome() {
        guard canUseCodeMode, let scope = currentWorkspaceOwner?.cacheScopeID else { return }
        if let codeHome, codeHome.scopeID == scope { return }
        let source: any CodeProjectSource
        let git: @MainActor () throws -> any StockGitManaging
        if let runtime = nativeRuntime {
            source = LiveCodeProjectSource { [weak runtime] agentID in
                guard let runtime else { throw WorkspaceClientError.transportUnavailable }
                return try runtime.stockGitPresentation(profileID: agentID).projects
            }
            let agentID = workspaceAgentID
            git = { [weak runtime] in
                guard let runtime else { throw WorkspaceClientError.transportUnavailable }
                return try runtime.stockGitPresentation(profileID: agentID).coordinator
            }
        } else {
            source = DemoCodeProjectSource()
            let demo = DemoCodeGit()
            git = { demo }
        }
        let defaults = agentRuntimeDefaults
        codeHome = CodeHomeStore(scopeID: scope, agentID: workspaceAgentID, source: source, git: git,
                                 starter: CodeChatSessionStarter(catalog: sessionCatalog, features: featureStore),
                                 loadModels: { try await defaults.loadModelProviders(agentID: $0) })
    }

    private func codeContext(_ store: CodeHomeStore) -> CodeHomeContext {
        CodeHomeContext(
            store: store,
            status: CodeChatStatusReader(catalog: sessionCatalog, features: featureStore),
            agents: agents.profiles,
            onOpenSession: { openCodeSession($0) },
            onOpenChanges: { appState.open(.codeChanges(sessionID: $0.id)) },
            onPullRequests: { codeSheet = .pullRequests },
            onWorktrees: { codeSheet = .worktrees },
            onRefreshActivity: { await nativeRuntime?.refreshActiveSessions() },
            connectionKey: currentWorkspaceOwner?.connectionGeneration.uuidString
        )
    }

    @ViewBuilder
    private func codeSheetView(_ sheet: CodeSheet, store: CodeHomeStore) -> some View {
        switch sheet {
        case .pullRequests:
            CodePullRequestsSheet(projectName: store.project?.name ?? "This project",
                                  pullRequests: store.git?.pullRequests ?? [])
                .bighelpSheetSize(.standard)
        case .worktrees:
            if let project = store.project, let git = try? store.gitClient() {
                CodeWorktreesSheet(store: StockGitStore(
                    target: StockGitProjectTarget(profileID: store.agentID, projectID: project.id,
                                                  cwd: project.folder, projectName: project.name),
                    client: git, isCurrent: { true }))
                .bighelpSheetSize(.standard)
            } else {
                ContentUnavailableView("Choose a project first", systemImage: "folder")
                    .bighelpSheetSize(.compact)
            }
        }
    }

    /// Opens a Bighelp IDE session's chat over the Code home; Back returns to it.
    func openCodeSession(_ session: CodeSessionRecord) {
        appState.chatOpenedFromList = true
        guard let record = sessionCatalog.session(id: session.id) else {
            actionErrorMessage = "This session isn't on this computer anymore."
            return
        }
        openSession(record.summary)
    }

    @ViewBuilder
    func codeChangesDestination(sessionID: String) -> some View {
        if let store = codeHome, let session = store.sessions.first(where: { $0.id == sessionID }),
           let project = store.projects.first(where: { $0.id == session.projectID }) {
            let starter = CodeChatSessionStarter(catalog: sessionCatalog, features: featureStore)
            CodeChangesView(model: CodeChangesModel(
                session: session, projectFolder: project.folder, git: store.gitClient,
                sendToSession: { try await starter.send($0, toSession: sessionID) }))
        } else {
            ContentUnavailableView("Changes aren't available", systemImage: "plus.forwardslash.minus",
                description: Text("Open Code from the menu, then try again."))
        }
    }

    /// ☰ in Bighelp IDE: New session, Projects, Pull requests and Worktrees, then Kanban and Settings.
    var codeMenu: BighelpMenuDestinations.Code {
        BighelpMenuDestinations.Code(
            onNewSession: { afterClosingHomeSheets { appState.select(.code) } },
            onPullRequests: codeHome?.project == nil ? nil : {
                afterClosingHomeSheets { appState.select(.code); codeSheet = .pullRequests }
            },
            onWorktrees: codeHome?.project == nil ? nil : {
                afterClosingHomeSheets { appState.select(.code); codeSheet = .worktrees }
            }
        )
    }

    /// ☰'s switch between Bighelp Chat and Bighelp IDE, while Bighelp IDE is on in Settings.
    var experienceSwitch: BighelpMenuDestinations.ExperienceSwitch? {
        guard settings.codeModeEnabled else { return nil }
        return BighelpMenuDestinations.ExperienceSwitch(current: settings.experience) { experience in
            afterClosingHomeSheets { settings.experience = experience }
        }
    }
}
