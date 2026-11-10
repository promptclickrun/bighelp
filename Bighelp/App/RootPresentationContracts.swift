import Foundation

struct ChatHeaderActions {
    let newChat: () -> Void

    func triggerNewChat() {
        newChat()
    }
}

struct ChatAttachmentFlowState: Equatable {
    var composerFocusRequest = 0

    /// Something was added to the message: the message box takes the keyboard again.
    mutating func completeSuccessfulImport() {
        composerFocusRequest &+= 1
    }
}

struct BotModeLoadBannerState: Equatable {
    let message: String
    let actionLabel = "Try again"

    init?(message: String?) {
        guard let message, !message.isEmpty else { return nil }
        self.message = message
    }

    var isVisible: Bool { true }
}

enum SessionRestorePresentationPolicy {
    static let opensCachedSessionBeforeHydration = true

    static func ownsHydration(route: AppRoute, path: [AppRoute]) -> Bool {
        path.last == route
    }

    static func canComplete(
        originTab: AppTab,
        originPath: [AppRoute],
        currentTab: AppTab,
        currentPath: [AppRoute]
    ) -> Bool {
        currentTab == originTab && currentPath == originPath
    }

    static func ownsRestore(
        route: AppRoute,
        originTab: AppTab,
        originPath: [AppRoute],
        currentTab: AppTab,
        currentPath: [AppRoute]
    ) -> Bool {
        canComplete(
            originTab: originTab,
            originPath: originPath,
            currentTab: currentTab,
            currentPath: currentPath
        ) || ownsHydration(route: route, path: currentPath)
    }
}

enum SessionRestoreMetadataReconciler {
    @MainActor
    static func reconcile(
        _ session: SessionRecord,
        workspaces: HermesWorkspaceStore
    ) {
        workspaces.reconcileSessionWorkspace(
            id: session.workspaceID,
            sessionID: session.id
        )
    }
}

enum ProjectChangesTargetResolver {
    static func target(
        agentID: String,
        sessionID: String,
        restoredWorkspaceID: String?,
        restoredWorkspaceName: String?,
        loadedWorkspaceID: String?,
        loadedWorkspaceName: String?
    ) -> ProjectGitTarget? {
        guard let workspaceID = loadedWorkspaceID ?? restoredWorkspaceID else {
            return nil
        }
        let workspaceName = loadedWorkspaceID == nil
            ? restoredWorkspaceName
            : loadedWorkspaceName
        return ProjectGitTarget(
            agentID: agentID,
            sessionID: sessionID,
            workspaceID: workspaceID,
            workspaceName: workspaceName
        )
    }
}

struct SessionRestoreRequest: Equatable {
    let token = UUID()
    let sessionID: String
    let originTab: AppTab
    let originPath: [AppRoute]
}

struct NativeCapabilitiesPresentation {
    let id = UUID()
    let kind: CapabilitiesManagementKind
    let owner: WorkspaceOwner
    let profileID: String
    let dependencies: CapabilitiesManagementDependencies
}
