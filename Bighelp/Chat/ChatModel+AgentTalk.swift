import Foundation

extension ChatModel {
    var agentTalkReader: (any AgentTalkReading)? {
        nativeConversationClient?.agentTalk ?? (client as? ConversationFixtureClient)?.agentTalk
    }

    /// The other agents' own chats, read when someone opens a conversation.
    var agentTalkStepsLoader: AgentTalkStepsLoader? {
        guard let reader = agentTalkReader else { return nil }
        return { agentID, sessionID in await reader.steps(agentID: agentID, sessionID: sessionID) }
    }

    /// Changes when a call to another agent starts or ends, so the chat reads
    /// the feed again then (and keeps reading while one runs).
    var agentTalkFollowKey: String {
        guard !isBotMode else { return "" }
        let calls = activityLedger.allEvents.filter { $0.agentTalkCall != nil }
        guard !calls.isEmpty else { return "" }
        let running = calls.filter { $0.lifecycle == .running }.map(\.id).joined(separator: ",")
        return "\(conversationID)|\(calls.count)|\(running)"
    }

    /// Reads what the agents this chat's agent called are doing, every two
    /// seconds while any is still on it. Real data only: without the plugin's
    /// feed the rails just say who's being asked.
    func followAgentTalk() async {
        guard !agentTalkFollowKey.isEmpty, let reader = agentTalkReader else { return }
        let sessionID = nativeConversationClient?.storedID ?? sourceSession?.remoteStoredID ?? conversationID
        while !Task.isCancelled {
            let calls = activityLedger.allEvents.filter { $0.agentTalkRunQuery != nil }
            guard !calls.isEmpty else { return }
            // The newest calls: the running ones, and the latest ones whose other chat isn't known yet.
            var queries: [AgentTalkRunQuery] = []
            for call in calls.reversed() {
                guard let query = call.agentTalkRunQuery, !queries.contains(query) else { continue }
                queries.append(query)
                if queries.count == DirectHermesAgentTalkReader.maximumCalls { break }
            }
            guard let runs = await reader.runs(agentID: agentID, sessionID: sessionID, calls: queries) else { return }
            guard !Task.isCancelled else { return }
            agentTalkLive.update(runs: runs, calls: calls)
            let waiting = calls.contains { $0.lifecycle == .running } || agentTalkLive.hasWorkingRuns
            guard waiting else { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
