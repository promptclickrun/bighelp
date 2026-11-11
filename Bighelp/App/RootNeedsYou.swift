import SwiftUI

/// What waits on the person across the computer in use, for the Needs you deck (`NeedsYouDeckView`).
extension RootShellView {
    var needsYouEntries: [NeedsYouEntry] {
        var entries: [NeedsYouEntry] = []
        // Hermes' prompts reach the app twice: on the open chat's own connection, and in the
        // Dashboard's list of every chat's. One prompt is one entry, by its ID; the chat's wins,
        // because it answers every kind of question.
        var promptIDs = Set<String>()
        var coveredAgents = Set<String>()
        let hostName = workspaceHostName

        for chatModel in featureStore.allPreparedChatModels {
            guard let client = chatModel.nativeConversationClient, !client.prompts.isEmpty else { continue }
            let agentID = client.profile.isEmpty ? (chatModel.memberIDs.first ?? "default") : client.profile
            let profile = agents.profiles.first { $0.id == agentID }
            for prompt in client.prompts where promptIDs.insert(prompt.id).inserted {
                coveredAgents.insert(agentID)
                entries.append(NeedsYouEntry(id: "prompt:\(prompt.id)", payload: .directPrompt(.init(
                    client: client, prompt: prompt, agentID: agentID,
                    agentName: profile?.name ?? chatModel.workingAgentName ?? "Hermes",
                    agentRole: profile?.role, hostName: hostName, conversationID: chatModel.conversationID))))
            }
        }

        for item in featureStore.dashboardModel.snapshot?.attentionItems ?? [] where item.interaction.isStructuredDecision {
            let promptID = item.promptID
            if let promptID, !promptIDs.insert(promptID).inserted { continue }
            let agentID = item.agentID ?? "default"
            let profile = agents.profiles.first { $0.id == agentID }
            coveredAgents.insert(agentID)
            entries.append(NeedsYouEntry(id: "prompt:\(promptID ?? item.id)", payload: .dashboard(.init(
                model: featureStore.dashboardModel, item: item, agentID: agentID,
                agentName: profile?.name ?? "Hermes", agentRole: profile?.role, hostName: hostName))))
        }

        if let workflowsStore {
            for run in workflowsStore.waiting {
                entries.append(NeedsYouEntry(id: "workflow:\(run.id)", payload: .workflow(.init(
                    store: workflowsStore, run: run, hostName: hostName))))
            }
        }

        // A bot whose chat isn't open here: the deck only says so. Opening or resuming a chat to
        // read its prompt is never done to find out what waits.
        for (agentID, state) in botChatActivity.liveActivities() where state == .waiting && !coveredAgents.contains(agentID) {
            let profile = agents.profiles.first { $0.id == agentID }
            entries.append(NeedsYouEntry(id: "waiting-bot:\(agentID)", payload: .waitingBot(.init(
                agentID: agentID, agentName: profile?.name ?? agentID, agentRole: profile?.role, hostName: hostName))))
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
                // Both read what the app already has from the computer; neither asks an agent anything.
                await featureStore.dashboardModel.load()
                let usesDemo = usesWorkspaceFixtures && workspaceConnections?.isDirectSelected != true
                if let store = usesDemo ? prepareWorkflowsStore() : workflowsStore { await store.load() }
            }
        )
    }

    /// ☰'s Needs you row, only while something waits.
    var menuNeedsYou: (count: Int, open: () -> Void)? {
        let count = needsYouEntries.count
        guard count > 0 else { return nil }
        return (count: count, open: { afterClosingHomeSheets { isNeedsYouPresented = true } })
    }
}
