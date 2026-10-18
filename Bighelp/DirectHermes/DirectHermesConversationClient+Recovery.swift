import Foundation

/// Authoritative activation and replay recovery; never resumes or resends a prompt.
extension DirectHermesConversationClient {
    /// Recover only this already-owned runtime. No resume, second writer, or
    /// submission retry is hidden in foreground recovery.
    func recover(epoch: String) async throws {
        try await recover(epoch: epoch, suspendOnFailure: true)
    }

    /// Explicit refresh starts only from an already verified live lease. A
    /// failed replay must reopen admission on that unchanged socket instead of
    /// converting a read failure into a disconnected composer.
    func recoverPreservingLiveTransport(epoch: String) async throws {
        try await recover(epoch: epoch, suspendOnFailure: false)
    }

    func recover(epoch: String, suspendOnFailure: Bool) async throws {
        guard connected, !requiresDurableReattachment else { throw DirectHermesError.notConnected }
        if let recoveryTask {
            if isHydrating { return try await recoveryTask.value }
            // `recoverOwned` clears hydration before the outer waiter resumes.
            // Do not let that completed flight turn an immediate explicit
            // refresh into a false successful no-op.
            self.recoveryTask = nil
        }
        attachmentAttempts.removeAll()
        resetMediaRetries()
        let owner = generation
        // Only a chat that recovered before and works is catching up. A first load or a
        // reconnect keeps Send closed until it ends.
        isCatchingUp = hasRecovered && isReadyForSubmission
        defer { isCatchingUp = false }
        isHydrating = true
        let task = Task { @MainActor [weak self] in
            guard let self else { throw DirectHermesError.notConnected }
            try await self.recoverOwned(epoch: epoch, owner: owner)
        }
        recoveryTask = task
        defer { if generation == owner { recoveryTask = nil } }
        do { try await task.value }
        catch {
            if suspendOnFailure, generation == owner { suspend() }
            throw error
        }
    }

    /// Probes only the shared authenticated transport. Workspace recovery owns
    /// the durable resume decision after this returns; this client must not start
    /// replay or reopen admission before that binding is established.
    func prepareTransportForAuthoritativeRecovery() async throws {
        guard connected else { throw DirectHermesError.notConnected }
        let owner = generation
        if let transport = rpc as? any DirectHermesAdmissionPreparing {
            try await transport.prepareForAdmission()
        }
        guard connected, generation == owner else { throw DirectHermesError.notConnected }
    }

    private func recoverOwned(epoch: String, owner: UUID) async throws {
        guard connected, owner == generation else { throw DirectHermesError.notConnected }
        try setPromptContract(.unknown, legacy: [])
        resetLiveTiming()
        isHydrating = true
        var succeeded = false
        defer {
            if generation == owner {
                let replayedHeldEvents = replayHeldEventsIfCovered()
                if !replayedHeldEvents {
                    // The failed probe observed an uncovered live sequence. Keep
                    // admission closed and retain the events for durable catch-up.
                    needsRecovery = true
                    status = "Reconnecting · waiting for Hermes history"
                }
                model?.reconcileNativeReactionConnectionState(from: self)
                settleHydrationWaiters(
                    throwing: succeeded && replayedHeldEvents ? nil : DirectHermesError.notConnected
                )
            }
        }
        let checkpoint = projection.lastSequence
        let replay = try await rpc.request("session.events.since", params: [
            "session_id": .string(runtimeID), "last_seen": .integer(epoch == projection.epoch ? checkpoint : 0)])
        guard connected, owner == generation else { throw DirectHermesError.notConnected }
        guard let before = replay.object, let replayEpoch = before["epoch"]?.string,
              let beforeSequence = before["latest_seq"]?.integer else { throw DirectHermesError.invalidResponse }
        if !projection.epoch.utf8.elementsEqual(replayEpoch.utf8) {
            resetNativeMessageReactionsForEpochChange()
        }
        var activation = sessionParams
        if usesCatalogHistory { activation["omit_messages"] = .boolean(true) }
        let snapshot = try await rpc.request("session.activate", params: activation)
        guard connected, owner == generation else { throw DirectHermesError.notConnected }
        let object = try validatedActivationSnapshot(snapshot)
        let activationTodoState = object["todo_state"]
        // Snapshot and replay use different locks on stock Hermes. Bracket the
        // snapshot instead of pretending latest_seq is an atomic snapshot cursor.
        let tail = try await rpc.request("session.events.since", params: [
            "session_id": .string(runtimeID), "last_seen": .integer(beforeSequence)])
        guard connected, owner == generation else { throw DirectHermesError.notConnected }
        guard let after = tail.object, after["epoch"]?.string == replayEpoch,
              let latest = after["latest_seq"]?.integer else { throw DirectHermesError.invalidResponse }
        let detectedContract: DirectHermesPromptContract
        if let openRequests = after["open_requests"] {
            guard openRequests.array != nil else { throw DirectHermesError.invalidResponse }
            detectedContract = .serverRequests
        } else {
            detectedContract = .legacyEvents
        }
        let beforeEvents = Self.replayEvents(before["events"])
        let afterEvents = Self.replayEvents(after["events"])
        if detectedContract == .legacyEvents {
            let restored = try restoredLegacyPrompts(from: object)
            try setPromptContract(.legacyEvents, legacy: restored)
            for event in afterEvents { try applyLegacyPromptEvent(event) }
        } else {
            try setPromptContract(.serverRequests, legacy: [])
        }
        // Complete every throwing contract/admission check before activation
        // state reaches the retained model. In particular, a valid todo_state
        // cannot publish when the post-snapshot tail or open-request bracket is
        // malformed. Held socket events remain behind isHydrating until return.
        if detectedContract == .serverRequests, let openRequests = after["open_requests"] {
            guard let requests = openRequests.array else { throw DirectHermesError.invalidResponse }
            if let openRequestRecovery {
                try openRequestRecovery(openRequests, runtimeID, object["pending_connection"])
            } else if !requests.isEmpty {
                throw DirectHermesError.invalidResponse
            }
        }
        guard connected, owner == generation else { throw DirectHermesError.notConnected }
        guard !heldEventsOverflowed else { throw DirectHermesError.tooManyRequests }
        let activationTodoSnapshot = activationTodoState.flatMap { todoState in
            projection.validatedRecoveryTodoSnapshot(
                state: todoState,
                epoch: replayEpoch,
                through: latest
            )
        }

        let start = beforeEvents.lastIndex { $0.type == "message.start" }
        let liveBeforeReplay = start.map { Array(beforeEvents[$0...]) } ?? []
        let liveReplay = liveBeforeReplay + afterEvents
        let completeLiveReplay = Self.isContiguous(liveReplay, through: latest)
            && !liveReplay.contains { $0.type == "session.info" && $0.payload["running"]?.boolean == false }
            && !afterEvents.contains { $0.type == "message.start" }
        let exactReplay = replayEpoch == projection.epoch && checkpoint > 0
            && before["truncated"]?.boolean == false && after["truncated"]?.boolean == false
        if !usesCatalogHistory, checkpoint == 0, !projection.hasLiveEvents, journal.unresolved.isEmpty,
           object["running"]?.boolean == true, completeLiveReplay,
           projection.seedLiveReplayHistory(object, epoch: replayEpoch) {
            applySnapshotMetadata(object)
            publishSnapshot()
            replayReceived(liveBeforeReplay)
            if let activationTodoSnapshot { publishTodoSnapshot(activationTodoSnapshot) }
            replayReceived(afterEvents)
            // Corrections/queued text are native state absent from message.start;
            // retain their source without inventing submission IDs or ordering.
            if let inflight = object["inflight"]?.object, inflight["corrections"]?.array?.isEmpty == false {
                projection.retainSourceDetail(key: "corrections", title: "Accepted turn corrections",
                    detail: DirectHermesProjection.jsonText(.object(inflight)) ?? "",
                    summary: "Native correction offsets and text retained as supplied by Hermes.")
            }
            if let queued = object["queued"], queued.object != nil {
                projection.retainSourceDetail(key: "queue", title: "Hermes accepted queue",
                    detail: DirectHermesProjection.jsonText(queued) ?? "", summary: "Accepted on Hermes; not resent.")
            }
            publishSnapshot()
        } else if exactReplay {
            // Retained structured rows + exact replay are better than a lossy
            // inflight text dump. Route replay through the live reducer once.
            applySnapshotMetadata(object)
            replayReceived(beforeEvents)
            if let activationTodoSnapshot { publishTodoSnapshot(activationTodoSnapshot) }
            replayReceived(afterEvents)
            let tailOwnsLiveness = afterEvents.contains { event in
                event.type == "message.start"
                    || event.type == "message.delta"
                    || (event.type == "session.info" && event.payload["running"]?.boolean != nil)
            }
            if !tailOwnsLiveness {
                // Activation is the newest liveness observation unless the
                // post-snapshot tail carries its own start/running transition.
                // Socket-delivered held events replay immediately after this
                // gate and remain newer than both.
                receiveSnapshotLifecycle(object)
            }
            if !projection.running {
                if let model { projection.retainVisible(items: model.items, activities: model.activityLedger.allEvents) }
                if !usesCatalogHistory { projection.reconcileHistory(object["messages"]?.array ?? []) }
                publishSnapshot()
            }
        } else {
            applySnapshot(snapshot, epoch: replayEpoch, publishTodoState: false)
            if let activationTodoSnapshot { publishTodoSnapshot(activationTodoSnapshot) }
            // No complete ring: preserve the exact boundary source, rather than
            // double-appending an unknown overlap to cumulative inflight text.
            // Subsequent live events resume at the accepted per-session cursor.
            if beforeSequence != latest {
                // A fresh empty session can have a lifecycle-only tail while
                // the snapshot and event cursors are being bracketed. That
                // diagnostic source detail is not a completed turn and must
                // not become a visible activity row on an otherwise empty
                // transcript. Keep it reviewable once there is actual visible
                // session content to anchor it to.
                if !projection.items.isEmpty || !projection.activities.isEmpty {
                    projection.retainSourceDetail(key: "snapshot-boundary", title: "Recovery boundary events",
                        detail: DirectHermesProjection.jsonText(after["events"]) ?? "",
                        summary: "Events observed while taking the native snapshot; not replayed as duplicate transcript rows.")
                }
                for event in Self.replayEvents(after["events"]) {
                    if event.type == "session.info" || event.type == "message.start" {
                        replayReceived([event])
                    }
                }
                publishSnapshot()
            }
            projection.seedCheckpoint(latest)
        }
        // A reply that finished while away, without an exact replay of the
        // events it missed, is complete only in saved history.
        needsCatalogHistoryReseed = usesCatalogHistory && workspaceHistoryDeferred
            && !exactReplay && !projection.running
        workspaceHistoryDeferred = false
        guard connected, owner == generation else { throw DirectHermesError.notConnected }
        guard replayHeldEventsIfCovered() else { throw DirectHermesError.tooManyRequests }
        // Legacy receipts lack proof of acceptance. Preserve their exact text
        // locally without making them alerts, retrying them, or blocking an
        // independent new message after the native connection is recovered.
        needsRecovery = false
        status = projection.running ? "Working" : "Ready"
        succeeded = true
        hasRecovered = true
        // Durable reaction metadata is presentation-only. It must not keep the
        // canonical replay gate closed or delay held live events. Hydrate it
        // after this method unwinds and the catch-up defer publishes the stream.
        scheduleDurableMessageReactionHydration(activation: object)
        rosterTask?.cancel()
        rosterTask = Task { @MainActor [weak self] in
            await self?.refreshNativeSubagents(owner: owner)
        }
    }
}
