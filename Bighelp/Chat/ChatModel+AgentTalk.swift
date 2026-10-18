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
        return "\(conversationID)|\(calls.count)|\(running)|\(agentTalkAwaitingDeliveries.count)"
    }

    /// `message_agent` messages whose delivery hasn't ended yet. Each ends with Hermes' notice in this chat,
    /// after any answer; the answer itself may be written by another Hermes process, which never streams here.
    var agentTalkAwaitingDeliveries: [String] {
        let processes = activityLedger.allEvents.compactMap { event -> String? in
            guard event.agentTalkCall?.route == .message, event.agentTalkReply?.outcome == .queued else { return nil }
            return event.agentTalkReply?.processID
        }
        guard !processes.isEmpty else { return [] }
        let ended = Set(items.compactMap { item -> String? in
            guard item.role == .human, case .message(let text) = item.content else { return nil }
            return AgentTalkDelivery.parse(text)?.processID
        })
        return processes.filter { !ended.contains($0) }
    }

    /// Reads what the agents this chat's agent called are doing, every two
    /// seconds while any is still on it. Real data only: without the plugin's
    /// feed the rails just say who's being asked. While a `message_agent`
    /// answer is due, the chat also reads its saved history: when the other
    /// agent stops working, and every 15 seconds for up to 20 minutes.
    func followAgentTalk() async {
        guard !agentTalkFollowKey.isEmpty else { return }
        let reader = agentTalkReader
        let sessionID = nativeConversationClient?.storedID ?? sourceSession?.remoteStoredID ?? conversationID
        let started = ContinuousClock.now
        var lastHistoryRead = started
        var wasWorking = false
        while !Task.isCancelled {
            let calls = activityLedger.allEvents.filter { $0.agentTalkRunQuery != nil }
            var working = false
            if let reader, !calls.isEmpty {
                // The newest calls: the running ones, and the latest ones whose other chat isn't known yet.
                var queries: [AgentTalkRunQuery] = []
                for call in calls.reversed() {
                    guard let query = call.agentTalkRunQuery, !queries.contains(query) else { continue }
                    queries.append(query)
                    if queries.count == DirectHermesAgentTalkReader.maximumCalls { break }
                }
                if let runs = await reader.runs(agentID: agentID, sessionID: sessionID, calls: queries) {
                    guard !Task.isCancelled else { return }
                    agentTalkLive.update(runs: runs, calls: calls)
                    working = agentTalkLive.hasWorkingRuns
                }
            }
            let awaiting = !agentTalkAwaitingDeliveries.isEmpty
                && ContinuousClock.now - started < .seconds(20 * 60)
            if awaiting, (wasWorking && !working) || ContinuousClock.now - lastHistoryRead >= .seconds(15) {
                lastHistoryRead = .now
                refreshFromHostSoon()
            }
            wasWorking = working
            guard calls.contains(where: { $0.lifecycle == .running }) || working || awaiting else { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

extension ChatModel {
    /// Hermes ran a turn this device didn't send: a background process finished, or another agent or
    /// device wrote in. Only its answer streams here, so the chat reads what Hermes saved.
    func hostTurnEnded(from owner: DirectHermesConversationClient) {
        guard (client as? DirectHermesConversationClient) === owner, !isBotMode else { return }
        refreshFromHostSoon()
    }

    /// One read at a time; asks made while one runs are folded into one more read after it.
    func refreshFromHostSoon() {
        guard hostHistoryRefresh != nil else { return }
        hostRefreshRequested = true
        guard hostRefreshTask == nil else { return }
        hostRefreshTask = Task { @MainActor [weak self] in
            while let self, self.hostRefreshRequested, !Task.isCancelled {
                self.hostRefreshRequested = false
                // Let the turn's own last events land first; a send of the person's own goes first too.
                try? await Task.sleep(for: .milliseconds(400))
                for _ in 0..<30 where self.isSending { try? await Task.sleep(for: .seconds(1)) }
                try? await self.hostHistoryRefresh?()
            }
            self?.hostRefreshTask = nil
        }
    }
}

extension ChatModel {
    /// The watch restarts with the chat, and pauses while this device's own turn runs.
    var otherProcessFollowKey: String {
        guard !isBotMode, agentTalkReader != nil, !isSending else { return "" }
        return conversationID
    }

    /// An agent another one asked answers in its own Hermes process, which never streams here. While
    /// the chat is open, the plugin says when another process is running it: the chat shows the agent
    /// working and offers Stop, and reads what Hermes saved as the run goes and once it ends.
    func followOtherProcess() async {
        guard !otherProcessFollowKey.isEmpty, let reader = agentTalkReader else {
            otherProcessRun = nil
            return
        }
        var reads = 0
        while !Task.isCancelled {
            let sessionID = nativeConversationClient?.storedID ?? sourceSession?.remoteStoredID ?? conversationID
            let reading = await reader.otherProcessRun(agentID: agentID, sessionID: sessionID)
            guard !Task.isCancelled else { return }
            switch reading {
            case .unavailable, .idle:
                if otherProcessRun != nil {
                    otherProcessRun = nil
                    refreshFromHostSoon()
                }
                // An older plugin can't say; asking again won't change that.
                if reading == .unavailable { return }
            case .running(let run):
                reads += 1
                if otherProcessRun == nil || run.toolName != otherProcessRun?.toolName || reads % 3 == 0 {
                    refreshFromHostSoon()
                }
                otherProcessRun = run
            }
            try? await Task.sleep(for: .seconds(otherProcessRun == nil ? 10 : 4))
        }
    }

    func stopOtherProcessRun() async {
        guard otherProcessRun?.canStop == true, let reader = agentTalkReader else { return }
        let sessionID = nativeConversationClient?.storedID ?? sourceSession?.remoteStoredID ?? conversationID
        guard await reader.stopOtherProcessRun(agentID: agentID, sessionID: sessionID) else { return }
        otherProcessRun = nil
        refreshFromHostSoon()
    }
}
