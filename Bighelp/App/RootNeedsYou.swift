import SwiftUI

/// Connects `NeedsYouDeckView` (`1B`) to the shell's live conversations, dashboard attention items,
/// waiting workflow sign-offs, and waiting Bot Chats.
extension RootShellView {
    var needsYouEntries: [NeedsYouEntry] {
        var entries: [NeedsYouEntry] = []
        var seenPromptKeys = Set<String>()
        var coveredAgents = Set<String>()
        let hostLabel = workspaceHostName

        for chatModel in featureStore.allPreparedChatModels {
            guard let client = chatModel.nativeConversationClient else { continue }
            let agentID = client.profile.isEmpty ? (chatModel.memberIDs.first ?? "default") : client.profile
            let profile = agents.profiles.first { $0.id == agentID }
            let agentName = profile?.name ?? chatModel.workingAgentName ?? "Hermes"
            for prompt in client.prompts {
                let id = "prompt:\(prompt.attentionKey)"
                guard seenPromptKeys.insert(id).inserted else { continue }
                coveredAgents.insert(agentID)
                entries.append(
                    NeedsYouEntry(
                        id: id,
                        payload: .directPrompt(
                            .init(
                                client: client,
                                prompt: prompt,
                                agentID: agentID,
                                agentName: agentName,
                                agentRole: profile?.role,
                                hostName: hostLabel,
                                conversationID: chatModel.conversationID
                            )
                        )
                    )
                )
            }
        }

        if let attentionItems = featureStore.dashboardModel.snapshot?.attentionItems {
            for item in attentionItems where item.interaction.isStructuredDecision {
                let agentID = item.agentID ?? "default"
                let profile = agents.profiles.first { $0.id == agentID }
                let agentName = profile?.name ?? "Your agent"
                coveredAgents.insert(agentID)
                entries.append(
                    NeedsYouEntry(
                        id: "dashboard:\(item.id)",
                        payload: .dashboard(
                            .init(
                                model: featureStore.dashboardModel,
                                item: item,
                                agentID: agentID,
                                agentName: agentName,
                                agentRole: profile?.role,
                                hostName: hostLabel
                            )
                        )
                    )
                )
            }
        }

        if let workflowsStore {
            for run in workflowsStore.waiting {
                let defaultProfile = homeAgent ?? agents.profiles.first
                entries.append(
                    NeedsYouEntry(
                        id: "workflow:\(run.id)",
                        payload: .workflow(
                            .init(
                                store: workflowsStore,
                                run: run,
                                agentID: defaultProfile?.id ?? "workflow",
                                agentName: defaultProfile?.name ?? run.workflowName,
                                hostName: hostLabel
                            )
                        )
                    )
                )
            }
        }

        let liveActivities = botChatActivity.liveActivities()
        for (agentID, state) in liveActivities where state == .waiting && !coveredAgents.contains(agentID) {
            let profile = agents.profiles.first { $0.id == agentID }
            entries.append(
                NeedsYouEntry(
                    id: "waiting-bot:\(agentID)",
                    payload: .waitingBot(
                        .init(
                            agentID: agentID,
                            agentName: profile?.name ?? agentID,
                            agentRole: profile?.role,
                            hostName: hostLabel
                        )
                    )
                )
            )
        }

        return entries
    }

    var needsYouDeckContext: NeedsYouDeckContext {
        NeedsYouDeckContext(
            currentConversationID: { appState.chatOnScreen },
            entries: { needsYouEntries },
            openConversation: { conversationID in
                if let record = sessionCatalog.session(id: conversationID) {
                    appState.chatOpenedFromList = true
                    openSession(record.summary)
                }
            },
            openAgentChat: { agentID in
                openCanonicalAgentChat(agentID, fromList: true)
            },
            openWorkflowSignoff: { runID in
                guard prepareWorkflowsStore() != nil else { return }
                showOneHostPageOnSessions([.workflows, .workflowSignoff(runID: runID)])
            },
            refresh: {
                if usesWorkspaceFixtures, workspaceConnections?.isDirectSelected != true {
                    if featureStore.dashboardModel.state == .idle {
                        await featureStore.dashboardModel.load()
                    }
                    if let store = prepareWorkflowsStore(), store.state == .idle {
                        await store.load()
                    }
                } else if let workflowsStore {
                    await workflowsStore.load()
                }
            }
        )
    }

    var menuNeedsYou: (count: Int, open: () -> Void)? {
        let count = needsYouEntries.count
        guard count > 0 else { return nil }
        return (count: count, open: { afterClosingHomeSheets { isNeedsYouPresented = true } })
    }
}
