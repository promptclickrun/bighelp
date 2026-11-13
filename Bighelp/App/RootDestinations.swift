import SwiftUI
import UIKit

// Same RootShellView owner; no new model, lifecycle or navigation state.
extension RootShellView {
    @ViewBuilder
    func routeDestination(_ route: AppRoute) -> some View {
        if nativeWorkspaceStore != nil, nativeRuntime == nil {
            ContentUnavailableView("Not available on this host", systemImage: "server.rack",
                description: Text("This capability is not connected through the selected native host."))
        } else {
        switch (route, featureStore.preparedModel(for: route)) {
        case (.workspaceSettings, _):
            routeWithWorkspaceMenu { workspaceSettings() }
        case (.projects, _):
            if let context = projectsContext {
                ProjectsHomeView(context: context)
            } else {
                ContentUnavailableView("Projects aren't available", systemImage: "folder",
                    description: Text("Connect to your computer, then open Projects from Work."))
            }
        case (.sessions, let prepared):
            sessionsDestination({ if case .sessions(let model)? = prepared { model } else { nil } }())
        case (.work(let projectID), _):
            workProjectPage(projectID)
        case (.kanban, _):
            kanbanDestination
        case (.workflows, _), (.workflow, _), (.workflowRun, _), (.workflowSignoff, _), (.workflowRuns, _):
            workflowsDestination(route)
        case (.usage, _):
            usageDestination
        case (.codeChanges(let sessionID), _):
            codeChangesDestination(sessionID: sessionID)
        case (.codeBatch(let id), _):
            codeBatchDestination(id: id)
        case (.devFactory, _), (.devFactoryRecipe, _), (.devFactoryGroup, _), (.devFactoryChanges, _):
            devFactoryDestination(route)
        case (.simpleBotProfile(let agentID, let opening), _):
            SimpleBotProfileView(agentID: agentID, context: simpleBotProfileContext(for: agentID), opening: opening)
        case (.groupSettings(let roomID, let conversationID), _):
            GroupSettingsView(roomID: roomID, rooms: botModeRooms, agents: agents,
                              chat: conversationID.flatMap(featureStore.preparedChatModel(id:)))
        case (.simpleBotsSection(let id), _):
            SimpleBotsHomeView(context: simpleBotsContext, sectionID: id)
        case (.board(let kind, let agentID), _):
            todayBoardPage(kind, agentID: agentID)
        case (.project(let id), _):
            if let context = projectsContext {
                ProjectDetailView(projectID: id, context: context)
            } else {
                ContentUnavailableView("Projects aren't available", systemImage: "folder",
                    description: Text("Connect to your computer, then open Projects from Work."))
            }
        case (.workspaceConnections, _):
            routeWithWorkspaceMenu {
                if let hostRegistry {
                    BighelpHostsPage(registry: hostRegistry)
                        .accessibilityIdentifier("workspace.connections")
                } else {
                    WorkspaceUnavailableView(destination: .instances, hostName: workspaceHostName,
                                             reason: "Host selection is unavailable in this presentation.")
                }
            }
        case (.workspaceManagement(let destination), _):
            routeWithWorkspaceMenu {
                if destination == .logs {
                    if let connections = workspaceConnections, let owner = currentWorkspaceOwner,
                       connections.owner == owner, let workspace = connections.workspace,
                       workspace.owner == owner, let direct = connections.hosts.selectedWorkspace?.nativeClient {
                        HermesLogsDestinationView(hostName: workspaceHostName, owner: owner,
                            http: direct, workspace: workspace, currentOwner: {
                                guard connections.workspace === workspace else { return nil }
                                return currentWorkspaceOwner
                            })
                            .id(owner)
                    } else {
                        WorkspaceUnavailableView(destination: .logs, hostName: workspaceHostName,
                            reason: "Logs require an available direct authenticated Hermes connection.")
                    }
                } else if destination == .voice {
                    VoiceSettingsView(settings: settings, agents: agents.profiles,
                                      selectedAgentID: workspaceAgentID,
                                      client: voiceSettingsClient, scope: voiceSettingsScope,
                                      isCurrent: voiceSettingsIsCurrent)
                } else if destination == .permissions {
                    PermissionsSettingsView(center: permissionCenter)
                } else if destination == .sessionMaintenance || destination == .profileLifecycle {
                    if let coordinator = lifecycleCoordinator,
                       isCurrentSignIn(coordinator.owner), let profileID = lifecycleProfileID,
                       agents.profiles.contains(where: { $0.id == profileID }) {
                        if destination == .sessionMaintenance {
                            coordinator.sessionMaintenanceView(profileID: profileID)
                        } else {
                            coordinator.profileLifecycleView(selectedProfileID: profileID)
                        }
                    } else {
                        WorkspaceUnavailableView(destination: destination, hostName: workspaceHostName,
                            reason: "Reopen this feature for the selected host and profile.")
                    }
                } else if let kind = CapabilitiesManagementKind(destination: destination), opensNativeCapabilities(kind) {
                    nativeCapabilitiesDestination(kind, destination: destination)
                } else if opensHostAdministration(destination) {
                    hostAdministrationDestination(destination)
                } else if let managementStore {
                    WorkspaceManagementView(store: managementStore, destination: destination,
                                            onOpenExisting: openWorkspaceDestination)
                } else {
                    WorkspaceUnavailableView(destination: destination, hostName: workspaceHostName,
                                             reason: "This feature requires an available native host connection.")
                }
            }
        case (.chat(let conversationID), .chat(let model)?):
            let switcher = chatSwitcherColumn(for: conversationID,
                                              agentID: model.memberIDs.count == 1 ? model.memberIDs.first : nil)
            let newChat = newChatSlot(forChat: conversationID, model: model)
            ChatDestinationView(
                model: model,
                appState: appState,
                settings: settings,
                featureStore: featureStore,
                catalog: sessionCatalog,
                agents: agents,
                // One home: ⋯ › Bot page opens the bot's page; nothing presents the editor.
                agentEditorPresentation: nil,
                botModeRooms: botModeRooms,
                skillsAndTools: skillsAndTools,
                hermesWorkspaces: hermesWorkspaces,
                projectMove: model.isBotMode ? nil : chatProjectMove,
                projectGitClient: projectGitClient,
                userIdentity: userIdentity,
                permissionCenter: permissionCenter,
                responseHapticsCoveredByRoot: isHomeDrawerPresented
                    || isHostStatusPresented
                    || isHermesWorkspacePresented || actionErrorMessage != nil,
                onNewChat: { openNewChat() },
                onOpenProviderAccounts: { openWorkspaceDestination(.keys) },
                onNewBotChat: botChatRestart(conversationID),
                onContinueInBranch: { continueInBranch(from: model, $0) },
                consumesSendOnOpen: { appState.sendsDraftOnOpen.remove($0) != nil },
                onEdgeAction: { performWorkspaceAction($0) },
                onOpenAgentSessions: { openSessions(filteredTo: $0) },
                onOpenApproval: {
                    openApproval(request: $0)
                },
                onForkMessage: { itemID in
                    forkSession(sourceID: conversationID, throughItemID: itemID)
                },
                appearanceAuthority: currentWorkspaceOwner?.authority,
                hostFiles: codeFileLinks(sessionID: conversationID),
                chatFolders: { chatFolders(for: model) },
                newChat: newChat
            )
            // New chat's Worktrees sheet presents from its own chat: the root is covered.
            .modifier(CodeSheetsIfShown(isShown: newChat != nil, root: self))
            .environment(\.chatCardInteractions, cardInteractions(for: model))
            // Every chat is a pushed page: Back, the bot (its page) and ⋯.
            .environment(\.agentHomeChrome, .pushedChat(onProfile: { openBotPage(fromChat: $0) }))
            .environment(\.chatDissolveTransition, chatDissolve)
            .environment(connectionKeeper)
            .bighelpSideColumn(screen, isShown: switcher != nil) { switcher }
        case (.scheduledTasks, .scheduledTasks(let store)?):
            routeWithWorkspaceMenu {
                ScheduledTasksView(store: store, agents: agents, onOpen: openScheduledTask)
            }
        case (.scheduledTask(let id, let agentID), .scheduledTasks(let store)?):
            routeWithWorkspaceMenu {
                ScheduledTaskDetailView(store: store, taskID: id, agents: agents, agentID: agentID)
            }
        case (.skillsAndTools, _):
            routeWithWorkspaceMenu {
                SkillsAndToolsCatalogView(
                    store: skillsAndTools,
                    agentID: agents.resolvedAgent(explicitID: nil)?.id ?? "default"
                )
            }
        case (.approval, .approval(let model)?):
            routeWithWorkspaceMenu {
                ApprovalDestinationView(model: model)
            }
        case (.chat(let conversationID), nil) where appState.suspendedChat?.chatID == conversationID
            || featureStore.hasRetiredUnsentChat(id: conversationID):
            // An unsent chat on screen lost its session (Hermes dropped it while the app was away
            // or the computer restarted): open a fresh chat in its place with its text, rather
            // than a dead end.
            ReopeningChatView {
                replaceLostChat(id: conversationID, agentID: nil, text: "")
            }
        case (.chat(let conversationID), nil):
            // A chat on screen whose live state was let go: open it again from its saved session.
            ReopeningChatView {
                reopenChatRoute(id: conversationID)
            }
        default:
            ContentUnavailableView(
                "Route unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("This route could not be prepared. Try again.")
            )
        }
        }
    }

}

/// New chat's project sheets, only on the chat that is New chat: two chats in the stack must not
/// both present the same sheet.
private struct CodeSheetsIfShown: ViewModifier {
    let isShown: Bool
    let root: RootShellView

    func body(content: Content) -> some View {
        if isShown { root.codeSheets(content) } else { content }
    }
}
