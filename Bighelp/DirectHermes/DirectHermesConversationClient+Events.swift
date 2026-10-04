import Foundation

/// Sequence-covered event reduction, held-event replay and live-turn timing.
extension DirectHermesConversationClient {
    func acceptSideTask(_ acceptance: DirectHermesSideTaskAcceptance) {
        retainVisibleState()
        let change = projection.acceptSideTask(acceptance)
        guard !change.activities.isEmpty else { return }
        for activity in change.activities { _ = model?.acceptActivity(activity) }
        status = acceptance.kind == .background ? "Background task accepted" : "BTW question accepted"
        onAdmittedActivity?(change, projection.turnID, false)
    }

    func receive(_ event: DirectHermesEvent) {
        if event.type == "session.reclaimed" {
            receiveReclaim(event)
            return
        }
        guard connected, let eventSessionID = event.sessionID,
              Data(eventSessionID.utf8) == Data(runtimeID.utf8) else { return }
        if isHydrating {
            guard heldEvents.count < 16_384 else {
                heldEventsOverflowed = true
                return
            }
            heldEvents.append(event)
            return
        }
        if event.type == "message.start"
            || ["background.complete", "btw.complete", "review.summary", "notice", "tool.output_risk"]
                .contains(event.type) {
            retainVisibleState()
        }
        let previousSequence = projection.lastSequence
        let change = projection.accept(event)
        var observedDurationItem: TimelineItem?
        if let sequence = event.sequence, sequence <= previousSequence { return }
        if event.type.hasPrefix("subagent.") {
            // A list response that began before this event cannot replace the
            // newer add/remove decision, even when the event was malformed.
            nativeSubagentEventRevision &+= 1
        }
        switch event.type {
        case "message.start", "message.delta":
            onSessionLivenessChange?(true)
        case "session.info":
            if let running = event.payload["running"]?.boolean {
                onSessionLivenessChange?(running)
            }
        default:
            break
        }
        if !isReplayingActivity { acceptLegacyPromptEvent(event) }
        if event.type == "message.start" { turnFailed = false }
        if event.type == "message.start" {
            if isReplayingActivity {
                resetLiveTiming()
            } else {
                liveTurnStart = (projection.epoch, projection.turnID, monotonicNow())
            }
        }
        if change.terminal {
            if !isReplayingActivity,
               let observedDuration = observedLiveTurnDuration(for: projection.turnID),
               let item = projection.applyObservedTurnDuration(observedDuration, turnID: projection.turnID) {
                observedDurationItem = item
            }
            resetLiveTiming()
        }
        if projection.running {
            if event.type == "message.start", pendingID != nil {
                if submissionTurns.count < 2, !submissionTurns.contains(projection.turnID) {
                    submissionTurns.append(projection.turnID)
                }
                if queuedVoiceAwaitingTurn, submissionTurns.contains(projection.turnID) {
                    queuedVoiceAwaitingTurn = false
                }
                selectPendingTurn()
            }
            model?.adoptNativeTurn(from: self, turnID: projection.turnID, running: true)
        }
        if event.type == "session.info" {
            if let value = event.payload["model"]?.string { modelName = value }
            if let value = event.payload["reasoning_effort"]?.string {
                model?.reconcileNativeReasoning(value, isLive: !isReplayingActivity, from: self)
            }
            if let value = event.payload["title"]?.string, !value.isEmpty { title = value; model?.applyRenamedSessionTitle(value) }
            if let value = event.payload["stored_session_id"]?.string { adoptStoredID(value) }
        }
        if ["session.info", "session.usage", "message.complete"].contains(event.type),
           let usage = event.payload["usage"]?.object { acceptUsage(usage) }
        if event.type == "session.title", let value = event.payload["title"]?.string {
            title = value
            model?.applyRenamedSessionTitle(value)
        }
        if let update = change.statusUpdate { status = update.text.isEmpty ? "Working" : update.text }
        if let notice = change.notice, !notice.message.isEmpty { status = notice.message }
        if change.reviewSummary != nil { status = "Background review ready" }
        if event.type == "message.start" { latestSpinnerActivity = nil }
        if event.type == "thinking.delta", let delta = change.thinkingDelta {
            let text = String(delta.text.prefix(256)).trimmingCharacters(in: .whitespacesAndNewlines)
            latestSpinnerActivity = text.isEmpty ? nil : text
            status = text.isEmpty ? "Working" : text
        }
        if let generating = change.toolGenerating {
            status = generating.name.isEmpty ? "Preparing tool" : "Preparing \(generating.name)"
        }
        if let warning = change.toolOutputRisk { status = "Safety warning · \(warning.summary)" }
        if let reaction = change.messageReaction {
            retainNativeMessageReaction(reaction)
            model?.reconcileNativeMessageReaction(reaction, from: self)
        }
        if let affection = change.affectionReaction {
            model?.acceptNativeAffectionReaction(
                affection,
                isLive: !isReplayingActivity,
                from: self
            )
        }
        if event.type == "sudo.request" || event.type == "secret.request" {
            status = "Hermes needs a secure input response. Complete it through Hermes Desktop; this screen will not collect that secret."
        }
        if event.type == "error" { status = "Hermes reported a turn error. Review the conversation before retrying."; turnFailed = true }
        if change.terminalError != nil { turnFailed = true }
        for item in change.items {
            if change.sideTaskResult == nil, returnsVoiceReply, pendingID != nil, pendingTurnID == projection.turnID,
               !voiceReplyUnavailable, item.role == .assistant, item.metadata.delivery == "Received" {
                if let index = voiceReplyItems.firstIndex(where: { $0.id == item.id }) { voiceReplyItems[index] = item }
                else { voiceReplyItems.append(item) }
                let bytes = voiceReplyItems.reduce(0) { count, item in
                    if case .message(let text) = item.content { return count + text.utf8.count }
                    return count
                }
                if voiceReplyItems.count > 64 || bytes > 131_072 {
                    voiceReplyItems = []
                    voiceReplyUnavailable = true
                }
            }
            if let model { model.acceptExternal([item], isLiveAssistantText: change.sideTaskResult == nil) }
            else if let draftSink, pendingTurnID == projection.turnID, !terminalSeen { draftSink(item) }
        }
        for activity in change.activities { _ = model?.acceptActivity(activity) }
        if let todoSnapshot = change.todoSnapshot { publishTodoSnapshot(todoSnapshot) }
        if let control = change.controlSnapshot {
            model?.reconcileNativeGoalControl(control, from: self,
                connectionGeneration: sessionActionsConnectionGeneration)
        }
        if let nativeSubagent = change.nativeSubagent {
            publishNativeSubagent(nativeSubagent)
        }
        if event.type.hasPrefix("subagent.") {
            model?.acceptSubagentEvent(type: event.type, payload: event.payload, from: self)
        }
        if change.terminal {
            latestSpinnerActivity = nil
            if let observedDurationItem {
                if let index = voiceReplyItems.firstIndex(where: { $0.id == observedDurationItem.id }) {
                    voiceReplyItems[index] = observedDurationItem
                }
                model?.updateNativeMetadata(observedDurationItem, from: self)
            }
            if pendingID != nil, submissionTurns.contains(projection.turnID) {
                settledSubmissionTurns[projection.turnID] = turnFailed
                selectPendingTurn()
            }
            status = turnFailed ? "Turn failed · text retained" : "Ready"
            completeSubmissionIfReady()
            if let receipt = acceptedRecovery, event.sequence != nil,
               receipt.epoch == projection.epoch, receipt.turnID == projection.turnID, !turnFailed {
                retireSubmission(receipt.submissionID)
                acceptedRecovery = nil
                needsRecovery = false
            }
            model?.adoptNativeTurn(from: self, turnID: projection.turnID, running: false)
            // Turn completion does not imply consumption of an uncertain steer.
        }
        if !isReplayingActivity { onAdmittedActivity?(change, projection.turnID, turnFailed) }
        if event.type == "message.complete" {
            // Hermes' saved rows for this turn; the reply is on screen by now.
            if !isReplayingActivity, let receipt = event.payload["persisted_turn"]?.object {
                if let row = receipt["user_row_id"]?.integer {
                    model?.bindNewestUnsavedMessage(role: .human, toRow: row, from: self)
                }
                if let row = receipt["final_assistant_row_id"]?.integer {
                    model?.bindNewestUnsavedMessage(role: .assistant, toRow: row, from: self)
                }
            }
            scheduleMessageMedia()
            scheduleDurableMessageReactionHydration(activation: [:])
        }
    }

    /// `session.reclaimed` is a global notification whose exact owner lives in
    /// its payload. Revoke this writer before publishing any presentation state
    /// so a same-run submit cannot race the backend's retirement notice.
    private func receiveReclaim(_ event: DirectHermesEvent) {
        guard connected, let value = try? DirectHermesSessionReclaim(event: event),
              Data(value.runtimeSessionID.utf8) == Data(runtimeID.utf8),
              Data(value.storedSessionID.utf8) == Data(storedID.utf8),
              event.sessionID.map({ Data($0.utf8) == Data(runtimeID.utf8) }) ?? true else { return }

        retainVisibleState()
        connected = false
        needsRecovery = true
        if let id = pendingID, admitted, !admissionOverlapped, let turnID = pendingTurnID {
            acceptedRecovery = (id, turnID, projection.epoch)
        }
        generation = UUID()
        isHydrating = false
        heldEvents = []
        recoveryTask?.cancel()
        recoveryTask = nil
        rosterTask?.cancel()
        rosterTask = nil
        attachmentTasks.values.forEach { $0.cancel() }
        attachmentTasks.removeAll()
        attachmentAttempts.removeAll()
        resetMediaRetries()

        let change = projection.accept(event)
        for item in change.items { model?.acceptExternal([item], isLiveAssistantText: false) }
        for activity in change.activities { _ = model?.acceptActivity(activity) }
        if !isReplayingActivity { onAdmittedActivity?(change, projection.turnID, true) }

        resetPromptContract()
        model?.suspendNativeTurn(from: self)
        model?.reconcileNativeReactionConnectionState(from: self)
        status = "Session reclaimed by Hermes · reopen before sending"
        finish(throwing: DirectHermesError.disconnected(outcomeUnknown: pendingID != nil))
    }

    /// A replacement socket has no covered session checkpoint yet. The bridge
    /// calls this synchronously from `gateway.ready` before any same-batch live
    /// event can reach the reducer or any new prompt can be admitted.
    func requireTransportCatchup() {
        guard connected else { return }
        if !isHydrating {
            heldEventsOverflowed = false
            isHydrating = true
        }
    }

    func awaitHydrationIfNeeded() async throws {
        guard isHydrating else { return }
        let owner = generation
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled, connected, generation == owner else {
                    continuation.resume(throwing: DirectHermesError.notConnected)
                    return
                }
                guard isHydrating else {
                    continuation.resume()
                    return
                }
                hydrationWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let continuation = self?.hydrationWaiters.removeValue(forKey: id) else { return }
                continuation.resume(throwing: CancellationError())
            }
        }
        guard connected, generation == owner, !isHydrating else {
            throw DirectHermesError.notConnected
        }
    }

    func settleHydrationWaiters(throwing error: (any Error)?) {
        let waiters = hydrationWaiters.values
        hydrationWaiters.removeAll()
        for continuation in waiters {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }

    /// Reopens admission only when every event observed during recovery extends
    /// the accepted cursor without a gap. On failure the untouched held buffer
    /// remains available to the next durable catch-up attempt.
    func replayHeldEventsIfCovered() -> Bool {
        guard !heldEventsOverflowed, heldEvents.allSatisfy({ $0.sequence != nil }) else {
            return false
        }
        let checkpoint = projection.lastSequence
        let pending = heldEvents
            .filter { ($0.sequence ?? 0) > checkpoint }
            .sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
        guard pending.enumerated().allSatisfy({ index, event in
            event.sequence == checkpoint + index + 1
        }) else {
            return false
        }
        isHydrating = false
        heldEvents = []
        heldEventsOverflowed = false
        for event in pending { receive(event) }
        return true
    }

    func replayReceived(_ events: [DirectHermesEvent]) {
        let previousReplay = isReplayingActivity
        isReplayingActivity = true
        defer { isReplayingActivity = previousReplay }
        let holding = isHydrating
        isHydrating = false
        for event in events.sorted(by: { ($0.sequence ?? 0) < ($1.sequence ?? 0) }) { receive(event) }
        isHydrating = holding
    }

    func receiveSnapshotLifecycle(_ object: [String: BighelpJSONValue]) {
        var info = object["info"]?.object ?? [:]
        info["running"] = object["running"] ?? .boolean(false)
        replayReceived([DirectHermesEvent(type: "session.info", sessionID: runtimeID, payload: info, sequence: nil)])
        if !projection.running, pendingID == nil { model?.reconcileNativeIdle(from: self) }
    }

    func applySnapshot(
        _ value: BighelpJSONValue,
        epoch: String,
        publishTodoState: Bool = true
    ) {
        guard let snapshot = value.object else { return }
        if publishTodoState, let todoState = snapshot["todo_state"],
           let todoSnapshot = SessionTodoSnapshot.native(
                sessionID: conversationID,
                state: todoState
           ) {
            publishTodoSnapshot(todoSnapshot)
        }
        if projection.epoch != epoch { resetLiveTiming() }
        let previousTurn = projection.turnID
        applySnapshotMetadata(snapshot)
        if let model { projection.retainVisible(items: model.items, activities: model.activityLedger.allEvents) }
        if !usesCatalogHistory { projection.reconcileHistory(snapshot["messages"]?.array ?? []) }
        projection.seedSnapshot(snapshot, epoch: epoch)
        publishSnapshot()
        onSessionLivenessChange?(projection.running)
        if projection.running {
            model?.adoptNativeTurn(from: self, turnID: projection.turnID, running: true)
        } else {
            model?.adoptNativeTurn(from: self, turnID: previousTurn, running: false)
            if pendingID != nil {
                // A replacement snapshot cannot prove admission of a lost RPC.
                // Release its waiter without retiring or resending the journal.
                needsRecovery = true
                finish(throwing: DirectHermesError.cancelled(outcomeUnknown: true))
            }
            model?.reconcileNativeIdle(from: self)
        }
    }

    func resetLiveTiming() {
        liveTurnStart = nil
    }

    private func observedLiveTurnDuration(for turnID: String) -> Int? {
        guard let start = liveTurnStart,
              start.epoch == projection.epoch, start.turnID == turnID else { return nil }
        let end = monotonicNow()
        guard end >= start.nanoseconds else { return nil }
        let elapsedNanoseconds = end - start.nanoseconds
        let maximumNanoseconds = UInt64(86_400_000) * 1_000_000
        guard elapsedNanoseconds <= maximumNanoseconds else { return nil }
        return Int((elapsedNanoseconds + 500_000) / 1_000_000)
    }

    static func isContiguous(_ events: [DirectHermesEvent], through latest: Int) -> Bool {
        guard let first = events.first?.sequence, events.last?.sequence == latest else { return false }
        return events.enumerated().allSatisfy { $0.element.sequence == first + $0.offset }
    }

    static func replayEvents(_ value: BighelpJSONValue?) -> [DirectHermesEvent] {
        (value?.array ?? []).compactMap { frame in
            // Stock events.since returns params dictionaries, not envelopes.
            guard let parameters = frame.object?["params"]?.object ?? frame.object,
                  let type = parameters["type"]?.string else { return nil }
            return DirectHermesEvent(type: type, sessionID: parameters["session_id"]?.string,
                payload: parameters["payload"]?.object ?? [:], sequence: parameters["seq"]?.integer,
                parameters: parameters)
        }.sorted { ($0.sequence ?? 0) < ($1.sequence ?? 0) }
    }
}
