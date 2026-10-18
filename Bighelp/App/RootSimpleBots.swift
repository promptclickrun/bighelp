import SwiftUI

// Simple Bot mode (Settings › Simple Bot mode): its home in place of the Chat
// tab, its short Settings, bot profiles, and how its chats look.
extension RootShellView {
    /// The all-hosts view keeps its own list.
    var simpleBotsOn: Bool { settings.simpleBotsEnabled && !fleetModeOn }

    /// The home is the tab's root, whatever is pushed over it: no bar, no ☰; the person's circle opens Settings.
    var simpleBotsHomeIsRoot: Bool {
        simpleBotsOn && appState.selectedTab == .sessions
    }

    var simpleBotsHome: some View {
        SimpleBotsHomeView(context: simpleBotsContext)
    }

    private var simpleBotsContext: SimpleBotsContext {
        let owner = currentWorkspaceOwner
        let capabilities = currentWorkspaceCapabilities
        func supports(_ capability: WorkspaceCapability) -> Bool {
            owner.map { capabilities.supports(capability, owner: $0, profileID: nil) } ?? false
        }
        return SimpleBotsContext(
            agents: agents, catalog: sessionCatalog,
            personName: userIdentity.identity.displayName, personImageURL: userIdentity.avatarURL(),
            scope: owner?.cacheScopeID ?? "local",
            canCreateBots: usesWorkspaceFixtures || supports(.profilesCreate),
            canCreateGroups: supports(.groupsCreate) && botModeRooms.canCreateNativeRoom,
            onOpenBot: { openSimpleBotChat($0) },
            onOpenSession: { summary in
                appState.chatOpenedFromList = true
                openSession(summary)
            },
            onOpenSettings: { isUnifiedSettingsPresented = true },
            onOpenProfile: { appState.open(.simpleBotProfile(agentID: $0)) },
            onNewChat: { agentID in
                appState.chatOpenedFromList = true
                startNewChat(explicitAgentID: agentID)
            },
            onCreateGroup: { createGroupChat(with: $0) },
            makeCreator: { makeSimpleBotCreator() },
            onRoutines: { openSimpleBotRoutines($0) }
        )
    }

    /// The edge swipes in Simple Bot mode (`effectiveLeftEdgeSwipeAction`): from the left back to your
    /// bots, from the right this bot's profile (the primary bot's on the home). False for anything else.
    func performSimpleBotsSwipe(_ action: WorkspaceSwipeAction) -> Bool {
        switch action {
        case .agents:
            appState.select(.sessions)
            appState.path.removeAll()
            return true
        case .profile:
            let chatBot: String? = if case .chat(let id)? = appState.path.last {
                featureStore.preparedChatModel(id: id)?.memberIDs.first
            } else { nil }
            guard let botID = chatBot ?? agents.primaryAgentID ?? agents.profiles.first(where: \.isDefault)?.id
            else { return true }
            if case .simpleBotProfile(let shown)? = appState.path.last, shown == botID { return true }
            appState.open(.simpleBotProfile(agentID: botID))
            return true
        default:
            return false
        }
    }

    /// A bot's chat over the home, with Back: its Bot Chat, like everywhere else.
    func openSimpleBotChat(_ agentID: String) {
        openCanonicalAgentChat(agentID, fromList: true)
    }

    /// Its scheduled tasks as a page with Back, not the Tasks tab Simple Bot mode doesn't show.
    func openSimpleBotRoutines(_ agentID: String) {
        guard featureStore.prepareScheduledTasks(filteredTo: agentID) else { return }
        appState.open(.scheduledTasks)
    }

    /// A new bot, made the way New agent makes one: a copy of the default bot's setup where the host can.
    func makeSimpleBotCreator() -> AgentEditorModel? {
        guard let owner = currentWorkspaceOwner else {
            return usesWorkspaceFixtures ? .creating(store: agents, processor: AvatarImageProcessor()) : nil
        }
        let capabilities = currentWorkspaceCapabilities
        guard usesWorkspaceFixtures || capabilities.supports(.profilesCreate, owner: owner, profileID: nil) else {
            return nil
        }
        return .creating(
            store: agents, processor: AvatarImageProcessor(),
            profileCloneSupport: capabilities.supports(.profilesClone, owner: owner, profileID: nil)
                ? .nativeBundleOnly
                : .unavailable("Native profile cloning is not available on this connection."),
            isCurrent: { currentWorkspaceOwner?.signIn == owner.signIn })
    }

    func simpleBotProfileContext(for agentID: String) -> SimpleBotProfileContext {
        let owner = currentWorkspaceOwner
        let canEdit = usesWorkspaceFixtures
            || (owner.map { currentWorkspaceCapabilities.supports(.profilesEdit, owner: $0, profileID: agentID) } ?? false)
        let agent = agents.profiles.first { $0.id == agentID }
        return SimpleBotProfileContext(
            agents: agents, scheduledTasks: featureStore.scheduledTasks,
            screenService: makeBotScreenService(), screenChats: agent.map(botScreenChats(for:)) ?? [],
            canEdit: canEdit,
            onOpenChat: { openSimpleBotChat($0) },
            onOpenRoutine: { openScheduledTask($0) },
            onEditDetails: { profile in
                guard let owner else { return }
                workspaceProfileEditor = .editing(profile, store: agents, processor: AvatarImageProcessor(),
                                                  isCurrent: { currentWorkspaceOwner?.signIn == owner.signIn })
            },
            makeModelDefaults: { id in
                let capabilities = currentWorkspaceCapabilities
                guard usesWorkspaceFixtures || owner.map({
                    capabilities.supports(.modelsRead, owner: $0, profileID: id)
                        && capabilities.supports(.agentDefaultsEdit, owner: $0, profileID: id)
                }) == true else { return nil }
                return AgentRuntimeDefaultsEditorModel(agentID: id, client: agentRuntimeDefaults)
            }
        )
    }

    /// Simple Bot mode's Settings sheet; All Settings leads to everything else.
    func simpleBotsSettings() -> some View {
        let close = { isUnifiedSettingsPresented = false }
        let profile = agents.resolvedAgent(explicitID: nil)?.id ?? "default"
        let agents = agents
        let configuration: (any SimpleBotHostConfiguring)? = usesWorkspaceFixtures
            && workspaceConnections?.isDirectSelected != true
            ? SimpleBotDemoConfiguration.shared
            : currentWorkspaceOwner.map { _ in
                SimpleBotWorkspaceConfiguration(workspace: { [weak workspaceConnections] in workspaceConnections?.workspace })
            }
        return SimpleBotsSettingsView(context: SimpleBotsSettingsContext(
            settings: settings, userIdentity: userIdentity, agents: agents,
            makeHostSettings: {
                configuration.map {
                    SimpleBotHostSettings(client: $0, profile: profile, allProfiles: { agents.profiles.map(\.id) })
                }
            },
            usage: providerUsage,
            makeTeamwork: { teamworkModel() },
            page: { page in AnyView(workspaceSettings().withDone(close).simpleBotsPage(page)) },
            allSettings: {
                let settings = workspaceSettings().withDone(close)
                return AnyView(settings.settingsDone(settings))
            },
            onOpenUsage: { leaveSettings { appState.open(.usage) } },
            onOpenComputer: { id in leaveSettings { appState.open(.simpleBotProfile(agentID: id)) } },
            onDone: close
        ))
    }
}
