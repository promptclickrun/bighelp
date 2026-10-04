import SwiftUI
import UIKit

// Same RootShellView owner; no new model, lifecycle or navigation state.
extension RootShellView {
    @ViewBuilder
    func nativeCapabilitiesDestination(_ kind: CapabilitiesManagementKind, destination: WorkspaceDestination) -> some View {
        let presentation = capabilitiesPresentations[destination]
        switch presentation.map({ availability(of: $0.owner, profileID: $0.profileID, current: currentWorkspaceOwner,
                                               signIn: workspaceSignIn) }) ?? .unavailable {
        case .current:
            if let presentation {
                CapabilitiesManagementView(kind: kind, hostName: workspaceHostName,
                    profileName: workspaceProfileName, dependencies: presentation.dependencies)
                    .id(presentation.id)
                    .toolbar {
                        if kind == .skills {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Edit Skills") { appState.open(.skillsAndTools) }
                            }
                        }
                    }
            }
        case .reconnecting:
            WorkspaceReconnectingView(destination: destination, hostName: workspaceHostName)
        case .unavailable:
            WorkspaceUnavailableView(destination: destination, hostName: workspaceHostName,
                reason: "Open this feature again after connecting to the selected host and profile.")
        }
    }

    /// Default model, Provider Keys and the other host pages. Leaving the app
    /// reconnects; the page waits for the connection instead of asking to be
    /// opened again (`WorkspaceScreenAvailability`).
    @ViewBuilder
    func hostAdministrationDestination(_ destination: WorkspaceDestination) -> some View {
        let presentation = administrationPresentations[destination]
        switch presentation.map({ availability(of: $0.owner, profileID: $0.profileID, current: administrationOwner,
                                               signIn: administrationSignIn) }) ?? .unavailable {
        case .current:
            if let presentation {
                NativeAdministrationDestination(presentation: presentation,
                    permissionCenter: permissionCenter, agents: modelAdministrationAgents,
                    reasoningDefaults: agentRuntimeDefaults,
                    onOpenProviderAccounts: { openWorkspaceDestination(.keys) },
                    onOpenAgentDefaults: { openWorkspaceDestination(.profiles) })
            }
        case .reconnecting:
            WorkspaceReconnectingView(destination: destination, hostName: workspaceHostName)
        case .unavailable:
            WorkspaceUnavailableView(destination: destination, hostName: workspaceHostName,
                reason: "Reopen this feature after connecting to the selected host and profile.")
        }
    }

    /// A page opened for another agent is not this one's.
    private func availability(of owner: WorkspaceOwner, profileID: String, current: WorkspaceOwner?,
                              signIn: WorkspaceSignIn?) -> WorkspaceScreenAvailability {
        guard Data(profileID.utf8) == Data(workspaceAgentID.utf8) else { return .unavailable }
        return .of(openedFor: owner, current: current, signIn: signIn)
    }

    /// The workspace pages in the navigation stack, bottom first.
    var openWorkspaceDestinations: [WorkspaceDestination] {
        appState.path.compactMap { route in
            if case .workspaceManagement(let destination) = route { return destination }
            return nil
        }
    }

    /// Pages that left the stack let go of their connection; the ones still
    /// in it (under Provider Keys, say) keep theirs.
    func retireClosedWorkspacePresentations() {
        let open = Set(openWorkspaceDestinations)
        for page in administrationPresentations.keep(only: open) { page.retire() }
        _ = capabilitiesPresentations.keep(only: open)
        if open.isDisjoint(with: [.sessionMaintenance, .profileLifecycle]), lifecycleCoordinator != nil {
            lifecycleCoordinator = nil
            lifecycleProfileID = nil
            lifecyclePresentationID = nil
        }
    }

    func openWorkspaceDestination(_ destination: WorkspaceDestination) {
        _ = presentWorkspaceDestination(destination, reattaching: false)
    }

    /// After a reconnect to the same computer, every host page in the stack gets
    /// the new connection in place, not just the one on top (Default model under
    /// Provider Keys), instead of asking to be opened again.
    /// False: the host isn't all the way back yet, so try again later.
    func reattachWorkspacePresentations() -> Bool {
        let open = openWorkspaceDestinations
        guard !open.isEmpty else { return true }
        var reattached = true
        for destination in Set(open) where opensHostAdministration(destination)
            || (CapabilitiesManagementKind(destination: destination) != nil && !usesWorkspaceFixtures) {
            let owner = administrationPresentations[destination]?.owner ?? capabilitiesPresentations[destination]?.owner
            if let owner, owner == administrationOwner || owner == currentWorkspaceOwner { continue }
            reattached = presentWorkspaceDestination(destination, reattaching: true) && reattached
        }
        if lifecycleCoordinator != nil,
           let destination = open.last(where: { $0 == .sessionMaintenance || $0 == .profileLifecycle }) {
            reattached = openLifecycleDestination(destination, reattaching: true) && reattached
        }
        // Of the rest, only the management list keeps a connection of its own.
        if managementStore != nil {
            if let store = makeWorkspaceManagementStore() {
                managementStore?.retire()
                managementStore = store
            } else {
                reattached = false
            }
        }
        return reattached
    }

    /// Opens a workspace screen, or (`reattaching`) gives the one already open
    /// a new connection, quietly and without navigating.
    private func presentWorkspaceDestination(_ destination: WorkspaceDestination, reattaching: Bool) -> Bool {
        if destination == .sessionMaintenance || destination == .profileLifecycle {
            return openLifecycleDestination(destination, reattaching: reattaching)
        }
        if opensHostAdministration(destination) {
            var presentation: NativeAdministrationPresentation?
            if usesWorkspaceFixtures {
                presentation = makeDemoAdministrationPresentation(destination)
                if presentation == nil, reattaching { return false }
            } else if let owner = currentWorkspaceOwner,
               let connections = workspaceConnections,
               let direct = connections.hosts.selectedWorkspace?.nativeClient,
               let invalidationSource = connections.nativeInvalidationSource(authority: owner.authority) {
                let profileID = workspaceAgentID
                let servingProfileID = connections.workspace?.nativeContext?.servingProfileID
                guard invalidationSource.owner == owner,
                      Data(invalidationSource.profileID.utf8) == Data(profileID.utf8),
                      invalidationSource.servingProfileID.map({ Data($0.utf8) })
                        == servingProfileID.map({ Data($0.utf8) }) else {
                    if !reattaching {
                        actionErrorMessage = "Management updates could not be connected. Reopen this feature after refreshing the selected host."
                    }
                    return false
                }
                let stockGit: NativeStockGitProjectPresentation?
                if destination == .projects, let runtime = nativeRuntime {
                    do { stockGit = try runtime.stockGitPresentation(profileID: profileID) }
                    catch {
                        if !reattaching {
                            actionErrorMessage = "Project changes could not be connected. Reopen Projects after refreshing this host."
                        }
                        return false
                    }
                } else {
                    stockGit = nil
                }
                presentation = NativeAdministrationPresentation(
                    destination: destination, hostName: workspaceHostName, profileID: profileID,
                    servingProfileID: servingProfileID,
                    rpc: direct, http: direct, owner: owner, currentOwner: {
                        guard Data(workspaceAgentID.utf8) == Data(profileID.utf8) else { return nil }
                        return currentWorkspaceOwner
                    }, connections: connections, invalidationSource: invalidationSource, stockGit: stockGit)
            } else if reattaching {
                return false
            }
            // Opening one page leaves the ones under it alone.
            if let presentation { administrationPresentations.open(presentation, for: destination)?.retire() }
            if !reattaching { appState.open(.workspaceManagement(destination)) }
            return true
        }
        if let kind = CapabilitiesManagementKind(destination: destination), !usesWorkspaceFixtures {
            var presentation: NativeCapabilitiesPresentation?
            if let owner = currentWorkspaceOwner,
               let direct = workspaceConnections?.hosts.selectedWorkspace?.nativeClient {
                let profileID = workspaceAgentID
                let current: @MainActor () -> WorkspaceOwner? = {
                    guard workspaceAgentID == profileID else { return nil }
                    return currentWorkspaceOwner
                }
                let actionStatusClient = DirectHermesHostOperationsClient(rpc: direct, http: direct,
                    owner: owner, currentOwner: current)
                presentation = NativeCapabilitiesPresentation(
                    kind: kind, owner: owner, profileID: profileID,
                    dependencies: CapabilitiesManagementDependencies(
                        skills: DirectHermesSkillsHubClient(http: direct, owner: owner, profileID: profileID, currentOwner: current, actionStatusClient: actionStatusClient),
                        mcp: DirectHermesMCPClient(http: direct, rpc: direct, owner: owner, profileID: profileID, currentOwner: current, actionStatusClient: actionStatusClient),
                        plugins: DirectHermesPluginLifecycleClient(http: direct, owner: owner, currentOwner: current),
                        toolsets: DirectHermesToolsetClient(http: direct, owner: owner, profileID: profileID, currentOwner: current, actionStatusClient: actionStatusClient)
                    )
                )
            } else if reattaching {
                return false
            }
            if let presentation { capabilitiesPresentations.open(presentation, for: destination) }
            if !reattaching { appState.open(.workspaceManagement(destination)) }
            return true
        }
        if reattaching { return true }
        switch destination {
        case .activity:
            appState.open(.workspaceActivity)
        case .scheduledTasks:
            openScheduledTasks(filteredTo: nil)
        case .tasks, .artifacts:
            appState.open(.workspaceManagement(destination))
        case .logs:
            managementStore?.retire()
            managementStore = nil
            appState.open(.workspaceManagement(.logs))
        case .wiki:
            managementStore?.retire()
            managementStore = nil
            appState.open(.workspaceManagement(.wiki))
        case .skills:
            appState.open(.skillsAndTools)
        case .profiles:
            guard let owner = currentWorkspaceOwner,
                  let profile = agents.resolvedAgent(explicitID: nil),
                  currentWorkspaceCapabilities.supports(.profilesEdit, owner: owner, profileID: profile.id) else {
                actionErrorMessage = "Connect to this host before editing its agent profile."
                return false
            }
            // A reconnect to the same computer keeps the editor usable.
            workspaceProfileEditor = .editing(profile, store: agents, processor: AvatarImageProcessor(),
                                               isCurrent: { currentWorkspaceOwner?.signIn == owner.signIn })
        case .instances:
            appState.open(.workspaceConnections)
        case .security, .appearance, .tabBar, .caching, .contact, .watch:
            appState.open(.workspaceManagement(destination))
        case .voice, .permissions, .documentation:
            managementStore?.retire()
            managementStore = nil
            appState.open(.workspaceManagement(destination))
        default:
            managementStore?.retire()
            managementStore = makeWorkspaceManagementStore()
            appState.open(.workspaceManagement(destination))
        }
        return true
    }

    /// Demo runs: the same host page on made-up data (`DemoModels`).
    private func makeDemoAdministrationPresentation(_ destination: WorkspaceDestination) -> NativeAdministrationPresentation? {
        #if DEBUG
        guard let owner = administrationOwner else { return nil }
        let profileID = workspaceAgentID
        let transport = DemoModels.transport
        return NativeAdministrationPresentation(
            destination: destination, hostName: workspaceHostName, profileID: profileID,
            servingProfileID: profileID, rpc: transport, http: transport, owner: owner, currentOwner: {
                guard Data(workspaceAgentID.utf8) == Data(profileID.utf8) else { return nil }
                return administrationOwner
            }, connections: nil, invalidationSource: nil)
        #else
        return nil
        #endif
    }

    private func makeWorkspaceManagementStore() -> WorkspaceManagementStore? {
        let profileID = workspaceAgentID
        if usesWorkspaceFixtures, let owner = currentWorkspaceOwner {
            return WorkspaceManagementStore(
                hostName: workspaceHostName, profileName: workspaceProfileName,
                client: FixtureWorkspaceManagementClient(),
                isCurrent: { currentWorkspaceOwner == owner && workspaceAgentID == profileID }
            )
        } else if let owner = currentWorkspaceOwner, let performer = workspaceConnections?.workspace {
            return WorkspaceManagementStore(
                hostName: workspaceHostName, profileName: workspaceProfileName,
                client: NativeWorkspaceManagementClient(
                    owner: owner, profileID: profileID, performer: performer,
                    isCurrent: { currentWorkspaceOwner == owner && workspaceAgentID == profileID }
                ),
                isCurrent: { currentWorkspaceOwner == owner && workspaceAgentID == profileID }
            )
        }
        return nil
    }

    /// Deleting from the Agents screen or the agent editor. Same lifecycle path
    /// as Profiles, with no navigation beyond leaving a chat that was retired.
    /// Lets other screens (the Chats rail) offer the Agents list's hold menu.
    var agentActionsConfig: AgentActionsConfig {
        AgentActionsConfig(
            store: agents, runtimeDefaultsClient: agentRuntimeDefaults, owner: currentWorkspaceOwner,
            capabilities: currentWorkspaceCapabilities, cloneClient: workspaceConnections?.cloneClient,
            shortcutsAvailable: usesWorkspaceFixtures || (nativeRuntime != nil && currentWorkspaceOwner != nil),
            onAction: handleAgentWorkspaceAction, agentDeletion: agentDeletionAction
        )
    }

    var agentDeletionAction: AgentDeletionAction? {
        guard nativeRuntime != nil, workspaceConnections != nil, currentWorkspaceOwner != nil else { return nil }
        return AgentDeletionAction { profileID in try await deleteAgentProfile(profileID) }
    }

    func deleteAgentProfile(_ profileID: String) async throws {
        guard let connections = workspaceConnections, let owner = currentWorkspaceOwner,
              connections.owner == owner, let runtime = nativeRuntime else {
            throw WorkspaceClientError.unavailable(.notConnected)
        }
        let coordinator = try NativeWorkspaceLifecycleCoordinator(
            owner: owner, connections: connections, catalog: sessionCatalog, agents: agents, bridge: runtime.bridge,
            adoptedSession: { _ in throw CancellationError() },
            retiredProfile: { _, retiredSessionIDs in
                guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                if let active = appState.activeConversationID, retiredSessionIDs.contains(active) {
                    sessionRestoreTask?.cancel()
                    sessionRestoreTask = nil
                    sessionRestoreRequest = nil
                    appState.resetForHostBoundary()
                }
            },
            reconciledProfile: { _ in
                guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                guard await runtime.refreshLocalCache() else { throw NativeWorkspaceLifecycleError.sharedStateMismatch }
            },
            reconciledClosedRuntime: { visibleID, _ in
                guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                if appState.activeConversationID == visibleID {
                    sessionRestoreTask?.cancel()
                    sessionRestoreTask = nil
                    sessionRestoreRequest = nil
                    appState.openSessions()
                }
            })
        try await coordinator.deleteAgent(profileID: profileID)
    }

    func openLifecycleDestination(_ destination: WorkspaceDestination, reattaching: Bool) -> Bool {
        guard let connections = workspaceConnections, let owner = currentWorkspaceOwner,
              connections.owner == owner, let runtime = nativeRuntime else {
            if !reattaching {
                actionErrorMessage = "Connect to a native Hermes host before managing sessions or profiles."
            }
            return false
        }
        let presentationID = UUID()
        do {
            let coordinator = try NativeWorkspaceLifecycleCoordinator(
                owner: owner, connections: connections, catalog: sessionCatalog, agents: agents, bridge: runtime.bridge,
                adoptedSession: { summary in
                    guard currentWorkspaceOwner == owner, lifecyclePresentationID == presentationID else {
                        throw CancellationError()
                    }
                    openSession(summary)
                },
                retiredProfile: { _, retiredSessionIDs in
                    guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                    if let active = appState.activeConversationID, retiredSessionIDs.contains(active) {
                        sessionRestoreTask?.cancel()
                        sessionRestoreTask = nil
                        sessionRestoreRequest = nil
                        appState.resetForHostBoundary()
                    }
                },
                reconciledProfile: { result in
                    guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                    guard await runtime.refreshLocalCache() else { throw NativeWorkspaceLifecycleError.sharedStateMismatch }
                    guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                    if lifecyclePresentationID == presentationID {
                        switch result.change {
                        case .renamed, .deleted: appState.openSessions()
                        default: break
                        }
                    }
                },
                reconciledClosedRuntime: { visibleID, _ in
                    guard currentWorkspaceOwner == owner, lifecyclePresentationID == presentationID else {
                        throw WorkspaceClientError.ownerChanged
                    }
                    if appState.activeConversationID == visibleID {
                        sessionRestoreTask?.cancel()
                        sessionRestoreTask = nil
                        sessionRestoreRequest = nil
                        appState.openSessions()
                    }
                })
            lifecycleCoordinator = coordinator
            lifecycleProfileID = workspaceAgentID
            lifecyclePresentationID = presentationID
            if !reattaching { appState.open(.workspaceManagement(destination)) }
            return true
        } catch {
            if !reattaching {
                actionErrorMessage = "The session and profile controls could not connect to this host."
            }
            return false
        }
    }

    func handleAgentWorkspaceAction(_ request: AgentWorkspaceActionRequest) {
        guard currentWorkspaceOwner == request.owner else {
            actionErrorMessage = WorkspaceClientError.ownerChanged.localizedDescription
            return
        }
        switch request.action {
        case .openAgentSessions(let id):
            openSessions(filteredTo: id)
        case .openAgentGroups(let id):
            agentGroupFilterRequest = id
            appState.select(.agents)
        case .openAgentScheduledTasks(let id):
            openScheduledTasks(filteredTo: id)
        case .openHostStatus:
            isHostStatusPresented = true
        case .openAgentChat(let id):
            openAgentChat(id)
        case .openGroup(let id):
            openHostedGroup(id, owner: request.owner, settings: false)
        case .openGroupSettings(let id):
            openHostedGroup(id, owner: request.owner, settings: true)
        case .renameGroup(let id, let name):
            Task { @MainActor in
                guard currentWorkspaceOwner == request.owner else { return }
                do {
                    _ = try await botModeRooms.openNativeRoom(roomID: id)
                    guard currentWorkspaceOwner == request.owner else { return }
                    try await botModeRooms.renameNativeRoom(roomID: id, name: name)
                } catch {
                    guard currentWorkspaceOwner == request.owner else { return }
                    actionErrorMessage = "The group could not be renamed. Check the host and try again."
                }
            }
        case .deleteGroup(let id):
            Task { @MainActor in
                guard currentWorkspaceOwner == request.owner else { return }
                do {
                    try await botModeRooms.deleteNativeRoom(roomID: id)
                    guard currentWorkspaceOwner == request.owner else { return }
                    sessionCatalog.removeConfirmedHostedGroup(roomID: id)
                }
                catch {
                    guard currentWorkspaceOwner == request.owner else { return }
                    actionErrorMessage = "The group deletion was not confirmed. Refresh before trying again."
                }
            }
        case .createGroup(let seed):
            guard botModeRooms.canCreateNativeRoom else {
                actionErrorMessage = WorkspaceUnavailableReason.driverUnavailable.message
                return
            }
            groupCreationSeed = seed
            groupCreationOwner = request.owner
            isGroupCreationPresented = true
        }
    }

    func openHostedGroup(_ id: String, owner: WorkspaceOwner, settings: Bool) {
        Task { @MainActor in
            guard currentWorkspaceOwner == owner else { return }
            do {
                let room = try await botModeRooms.openNativeRoom(roomID: id)
                guard currentWorkspaceOwner == owner else { throw WorkspaceClientError.ownerChanged }
                let record = try sessionCatalog.installWorkspaceRecord(
                    SessionRecord(id: "hermes-room:\(room.id)", kind: .botMode, agentIDs: room.profileIDs,
                                  title: room.title, remoteSource: "hermes-room", botModeRoomID: room.id),
                    ownerIsCurrent: { currentWorkspaceOwner == owner }
                )
                let route = AppRoute.chat(conversationID: record.id)
                guard featureStore.prepare(route),
                      case .chat(let model)? = featureStore.preparedModel(for: route) else {
                    throw WorkspaceClientError.unavailable(.unsupportedOperation)
                }
                if settings { groupSettingsModel = model }
                else { appState.activateConversation(id: record.id, source: .sessions) }
            } catch {
                guard currentWorkspaceOwner == owner else { return }
                actionErrorMessage = "Hermes could not open this group. Check the host and try again."
            }
        }
    }

}
