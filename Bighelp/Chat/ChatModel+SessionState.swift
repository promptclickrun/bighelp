import Foundation

extension ChatModel {
    var goalRailState: ChatGoalRailState? {
        sessionGoal?.railState
    }

    /// The catalog persists this same snapshot (including terminal tombstones)
    /// and supplies it as initialGoalSnapshot when recreating the route.
    func reconcileGoal(_ snapshot: SessionGoalSnapshot) {
        guard snapshot.sessionID == conversationID,
              (sourceSession?.remoteStoredID).map({ $0 == snapshot.storedSessionID }) ?? true,
              snapshot.supersedes(sessionGoal)
        else { return }
        sessionGoal = snapshot
        sourceSession?.sessionGoal = snapshot
        onGoalSnapshotChange?(snapshot)
    }

    /// Adopts only a control snapshot returned by or sequenced through this
    /// exact native conversation. The local observation clock is monotonic so
    /// pause/clear revisions that retain Hermes' persisted timestamp still
    /// supersede the previous durable rail state.
    func reconcileNativeGoalControl(
        _ control: DirectHermesSessionControlSnapshot,
        from native: DirectHermesConversationClient,
        connectionGeneration: UUID? = nil,
        afterObservation: Int? = nil
    ) {
        guard nativeConversationClient === native,
              !referenceOwnerRetired, native.connected,
              afterObservation.map({ $0 == (sessionGoal?.updatedAt ?? 0) }) ?? true,
              connectionGeneration.map({ $0 == native.sessionActionsConnectionGeneration }) ?? true,
              native.conversationID == conversationID,
              sourceSession?.remoteStoredID.map({ Data($0.utf8) == Data(native.storedID.utf8) }) ?? true
        else { return }
        do {
            let snapshot = try DirectHermesGoalControlProjection.retainedSnapshot(
                from: control,
                visibleSessionID: conversationID,
                storedSessionID: native.storedID,
                observedAt: nextGoalObservationTime()
            )
            if let previous = sessionGoal,
               previous.status == snapshot.status,
               Data(previous.storedSessionID.utf8) == Data(snapshot.storedSessionID.utf8),
               previous.summary.map({ Data($0.utf8) }) == snapshot.summary.map({ Data($0.utf8) }) {
                return
            }
            reconcileGoal(snapshot)
        } catch {
            // Unknown/malformed fields are absence of authority, never an empty
            // goal. Preserve the last validated pill and tombstone.
        }
    }

    /// Applies the latest authenticated Hermes context projection for this
    /// route. The socket may replay events after reconnecting, so an older
    /// projection must never restore a stale usage value or compaction state.
    func reconcileSessionContext(_ snapshot: SessionContextSnapshot, isLive: Bool = true) {
        guard snapshot.sessionId == conversationID else { return }
        guard sessionContext.map({ snapshot.updatedAt >= $0.updatedAt }) ?? true else {
            return
        }
        let changed = sessionContext != snapshot
        sessionContext = snapshot
        if changed, isLive || runtimeControls?.currentModel == nil {
            runtimeControls?.reconcileSessionRuntime(.init(
                model: snapshot.model,
                provider: runtimeControls?.currentModel == snapshot.model ? runtimeControls?.currentProvider : nil,
                observedAt: isLive ? Date() : .distantPast
            ))
        }
        if let title = snapshot.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            sessionTitle = title
        }
    }

    func applyRenamedSessionTitle(_ title: String) {
        sessionTitle = title
    }

    func reconcileTodos(_ snapshot: SessionTodoSnapshot) {
        guard snapshot.sessionID == conversationID,
              snapshot.supersedes(sessionTodos) else { return }
        sessionTodos = snapshot
        taskDrawer = snapshot.taskDrawer
        onTodoSnapshotChange?(snapshot)
    }

    func reconcileSubagents(_ snapshot: SessionSubagentRosterSnapshot) {
        guard snapshot.sessionID == conversationID,
              snapshot.updatedAt > sessionSubagentUpdatedAt
        else { return }
        sessionSubagentUpdatedAt = snapshot.updatedAt
        sessionSubagents = snapshot.subagents
    }

    func reconcileNativeSubagents(_ items: [NativeSubagentRailItem]) {
        guard !referenceOwnerRetired, !isBotMode else { return }
        nativeSubagents = items
        subagentCanvases.seed(items)
    }

    /// Sends voice work without changing the user's composer or retry intent.
    func sendNativeVoiceMessage(_ message: String) async throws -> ConversationResponse {
        guard !referenceOwnerRetired, !isBotMode, !isSending, referenceSubmission == nil,
              !referenceSendInFlight, !ReferenceCodec.decode(message).hasValidAppendix,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              message.utf8.count <= 3_072 else { throw ChatQueuedSubmissionError.busy }
        isSending = true
        hasLocallyPendingPrimaryTurn = true
        let generation = beginOwnerGeneration()
        failureMessage = nil
        retryRequest = nil
        let human = humanItem(content: message)
        appendItem(human)
        appendProjectedMessage(human)
        persistSession()
        defer {
            if isCurrentOwner(generation) {
                hasLocallyPendingPrimaryTurn = false
                isSending = nativeConversationClient?.projection.running ?? false
                if !isSending { settleTaskDrawerAfterTurn() }
                flushPersistence()
            }
        }
        do {
            if let native = nativeConversationClient {
                let response = try await native.sendForVoice(message: message)
                guard nativeConversationClient === native, !referenceOwnerRetired, native.connected else {
                    throw WorkspaceClientError.ownerChanged
                }
                // Native lifecycle changes the presentation generation at both
                // start and finish. Its own submission owner validates this
                // result, which has already been rendered by the native reducer.
                return response
            }
            let response = try await sendThroughClient(message, ownerGeneration: generation)
            guard isCurrentOwner(generation) else { throw WorkspaceClientError.ownerChanged }
            try appendValidated(response.items)
            return response
        } catch {
            if isCurrentOwner(generation) {
                failureMessage = "Voice work was not confirmed. Check this chat before requesting it again."
                // The native submission journal owns recovery. Never install a
                // retry that creates another voice turn after an uncertain send.
                retryRequest = nil
            }
            throw error
        }
    }

    /// Goal management uses stock Hermes' closed `session.control` action set.
    /// Replacing the goal still uses the ordinary `/goal <text>` composer path,
    /// which Direct Hermes routes through `slash.exec`/`command.dispatch`.
    /// Neither path borrows or clears the user's existing composer draft.
    func submitGoalCommand(_ argument: String) async {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let action = DirectHermesGoalControlProjection.controlAction(for: trimmed),
           nativeConversationClient != nil {
            _ = await applyNativeGoalControl(action)
            return
        }
        guard !isSending else {
            failureMessage = "Pause, resume, or clear the current goal while Hermes is working. Set a replacement goal after this turn finishes."
            return
        }
        await submitAuxiliaryGoalMessage("/goal \(trimmed)")
    }

    private func submitAuxiliaryGoalMessage(_ message: String) async {
        guard !isSending else { return }
        isSending = true
        let generation = beginOwnerGeneration()
        failureMessage = nil
        retryRequest = nil
        let human = humanItem(content: message)
        appendItem(human)
        appendProjectedMessage(human)
        persistSession()

        await sleeper.sleep()
        guard isCurrentOwner(generation) else { return }
        do {
            let response = try await sendThroughClient(
                message,
                ownerGeneration: generation
            )
            guard isCurrentOwner(generation) else { return }
            try appendValidated(response.items)
            await refreshNativeGoalControl(reportFailure: true)
        } catch is ResponseIdentityError {
            guard isCurrentOwner(generation) else { return }
            failureMessage = "The goal response conflicted with this conversation. Reopen the chat before trying again."
            retryRequest = nil
        } catch {
            guard isCurrentOwner(generation) else { return }
            retainGoalCommandDraftAfterFailure(message)
            retryRequest = nil
            failureMessage = goalCommandFailureMessage(error)
        }

        guard isCurrentOwner(generation) else { return }
        settleTaskDrawerAfterTurn()
        isSending = nativeConversationClient?.sessionActionsAreRunning ?? false
        flushPersistence()
    }

    @discardableResult
    func applyNativeGoalControl(_ action: DirectHermesSessionControlAction) async -> Bool {
        guard let native = nativeConversationClient else { return false }
        let observedBeforeAction = sessionGoal?.updatedAt ?? 0
        let connectionGeneration = native.sessionActionsConnectionGeneration
        let actions = native.sessionActions
        failureMessage = nil
        retryRequest = nil
        do {
            let result = try await actions.applyControl(action)
            guard nativeConversationClient === native,
                  native.sessionActionsConnectionGeneration == connectionGeneration else { return false }
            reconcileNativeGoalControl(
                result.control,
                from: native,
                connectionGeneration: connectionGeneration,
                afterObservation: observedBeforeAction
            )
            switch result.continuation {
            case .rejected:
                failureMessage = "Hermes updated the goal, but rejected its continuation turn. The retained goal state is authoritative."
            case .outcomeUnknown:
                failureMessage = "Hermes updated the goal, but the continuation receipt is unknown. Do not resume it again; reopen the chat to reconcile."
            case .notRequired, .accepted:
                failureMessage = nil
            }
            return true
        } catch {
            guard nativeConversationClient === native,
                  native.sessionActionsConnectionGeneration == connectionGeneration else { return false }
            retryRequest = nil
            let observedBeforeReadback = sessionGoal?.updatedAt ?? 0
            if let readback = try? await actions.readControl(),
               nativeConversationClient === native,
               native.sessionActionsConnectionGeneration == connectionGeneration {
                reconcileNativeGoalControl(
                    readback,
                    from: native,
                    connectionGeneration: connectionGeneration,
                    afterObservation: observedBeforeReadback
                )
                failureMessage = "Hermes did not return a valid goal-change receipt. Its current goal was read back, but the action will not be repeated automatically."
            } else {
                failureMessage = "Hermes may have received this goal change. The previous pill remains until authoritative readback; reopen the chat before trying again."
            }
            return false
        }
    }

    func refreshNativeGoalControl(reportFailure: Bool = false) async {
        guard let native = nativeConversationClient else { return }
        let observedBeforeRead = sessionGoal?.updatedAt ?? 0
        let connectionGeneration = native.sessionActionsConnectionGeneration
        let actions = native.sessionActions
        do {
            let control = try await actions.readControl()
            guard nativeConversationClient === native,
                  native.sessionActionsConnectionGeneration == connectionGeneration else { return }
            reconcileNativeGoalControl(
                control,
                from: native,
                connectionGeneration: connectionGeneration,
                afterObservation: observedBeforeRead
            )
        } catch {
            guard reportFailure, nativeConversationClient === native,
                  native.sessionActionsConnectionGeneration == connectionGeneration else { return }
            failureMessage = "Hermes could not read back the current goal. The last confirmed goal remains visible."
        }
    }

    func scheduleNativeGoalControlRefresh() {
        guard nativeConversationClient != nil else { return }
        Task { @MainActor [weak self] in
            await self?.refreshNativeGoalControl()
        }
    }

    private func nextGoalObservationTime() -> Int {
        let now = Int((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        return max(now, (sessionGoal?.updatedAt ?? 0) + 1)
    }

    func retainGoalCommandDraftAfterFailure(_ message: String) {
        guard draft.isEmpty else { return }
        draft = message
    }

    func goalCommandFailureMessage(_ error: Error) -> String {
        if (error as? DirectHermesError)?.outcomeIsUnknown == true
            || nativeConversationClient?.needsRecovery == true {
            return "Hermes may have received this goal command. It is retained in the composer, but must not be resent until the chat is reopened and the goal is read back."
        }
        return "Hermes did not accept this goal command. It remains in the composer for editing."
    }

    func acceptTurnEnded(turnID: String) {
        // Turn settlement is not todo authority. Retain the latest full snapshot
        // (and any legacy projection) until a newer explicit empty snapshot.
        _ = turnID
    }

    func acceptTodoActivity(_ event: ChatActivityEvent) {
        // Once canonical revision metadata exists, unrevisioned activity detail
        // is presentation history only and cannot replace durable authority.
        guard sessionTodos == nil else { return }
        let next = ChatTodoProjection.applying(event, to: taskDrawer)
        guard next != taskDrawer else { return }
        taskDrawer = next
    }

    func settleTaskDrawerAfterTurn() {
        guard let turnID = taskDrawer?.turnID else { return }
        acceptTurnEnded(turnID: turnID)
    }
}
