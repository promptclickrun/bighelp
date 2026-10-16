import Foundation

extension BotModeRoomStore {
    /// Replays the durable Hermes log into the local presentation cache. This
    /// is used after relaunch and after a Link host switch; the server remains
    /// authoritative for event order and the cursor is persisted locally.
    func syncNativeRoom(roomID: String) async throws {
        let boundary = nativeBoundaryGeneration
        try await syncNativeRoom(roomID: roomID, boundary: boundary)
    }

    func syncNativeRoom(
        roomID: String,
        boundary: Int,
        initialState suppliedState: HermesBotModeRoomState? = nil
    ) async throws {
        try persistence?.prepareNativeStorage()
        guard let nativeClient else { throw BotModeRoomError.executionUnavailable }
        let capabilities = try await negotiatedNativeCapabilities(using: nativeClient, boundary: boundary)
        try requireNativeBoundary(boundary)
        guard capabilities.protocolVersion == 2,
              capabilities.supports("groups.state"), capabilities.supports("groups.log") else {
            throw BotModeRoomError.executionUnavailable
        }
        nativeCapabilities = capabilities
        try requireNativeBoundary(boundary)
        guard let initial = room(id: roomID) else { throw BotModeRoomError.roomNotFound }
        let state = if let suppliedState {
            suppliedState
        } else {
            try await nativeClient.groupsState(roomID: roomID, includeDisbanded: false)
        }
        try requireNativeBoundary(boundary)
        try validateNativeState(state, previous: initial)
        try refreshNativeApprovals(roomID: roomID, driverStatus: state.driverStatus, boundary: boundary)
        var room = initial
        let metadataChanged = room.nativeRoomID != state.roomID
            || room.nativeAuthorityGatewayID != state.authorityGatewayID
            || room.nativeAuthorityEpoch != state.authorityEpoch
            || room.nativeState != state.persistentMetadata
        room.markNativeRoom(state)
        let marked: BotModeRoom
        if metadataChanged {
            if let saved = try compareAndSave(
                room,
                expectedRevision: initial.persistenceRevision,
                expectedOwner: initial.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner
            ) {
                replaceStored(saved)
                marked = saved
            } else {
                // Another native entry point may have persisted the same
                // authoritative state while this caller awaited groups.state.
                // Rebase on that fresh record instead of surfacing a false
                // reopen error, while retaining its current run/pending owner.
                guard let latest = self.room(id: roomID) else {
                    throw BotModeRoomError.persistenceConflict
                }
                try validateNativeState(state, previous: latest)
                let latestMetadataChanged = latest.nativeRoomID != state.roomID
                    || latest.nativeAuthorityGatewayID != state.authorityGatewayID
                    || latest.nativeAuthorityEpoch != state.authorityEpoch
                    || latest.nativeState != state.persistentMetadata
                var rebased = latest
                let sameAuthority = latest.nativeAuthorityGatewayID == state.authorityGatewayID
                    && latest.nativeAuthorityEpoch == state.authorityEpoch
                let responseIsOlder = sameAuthority
                    && (latest.nativeState?.revision ?? 0) > state.revision
                if latestMetadataChanged, !responseIsOlder {
                    rebased.markNativeRoom(state)
                    let expectedOwner = rebased.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner
                    guard let saved = try compareAndSave(
                        rebased,
                        expectedRevision: latest.persistenceRevision,
                        expectedOwner: expectedOwner
                    ) else { throw BotModeRoomError.persistenceConflict }
                    replaceStored(saved)
                    rebased = saved
                }
                marked = rebased
            }
        } else {
            marked = initial
        }
        let recovered = try await recoverNativeSendReceiptIfNeeded(
            room: marked,
            client: nativeClient,
            boundary: boundary
        )
        try reconcileNativeRetryActions(
            roomID: roomID,
            driverStatus: state.driverStatus,
            expectedOwner: recovered.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner,
            boundary: boundary
        )
        try await recoverNativeFollowUpReceipts(roomID: roomID, client: nativeClient, boundary: boundary)

        var cursor = recovered.nativeLogCursor
        var noTerminalTaskIDs = recovered.nativeRetryJournal?.terminalTaskIDs ?? []
        var hasMore = true
        while hasMore {
            try Task.checkCancellation()
            let page = try await nativeClient.groupsLog(
                roomID: roomID,
                sinceSequence: cursor,
                limit: nativeLogPageLimit,
                includeDisbanded: false
            )
            try requireNativeBoundary(boundary)
            try validateNativeAuthority(page.authority, roomID: roomID)
            let expectedOwner = self.room(id: roomID)?.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner
            let complete = try applyNativeEvents(
                page.events,
                cursor: page.cursor,
                roomID: roomID,
                expectedOwner: expectedOwner,
                // A client idempotency key is not the server's canonical
                // discussion event ID. Until Hermes returns that receipt,
                // replay may hydrate messages but cannot settle this pending
                // turn by guessing at its identity.
                discussionEventID: self.room(id: roomID)?.nativePendingDiscussionEventID,
                expectedThreadID: self.room(id: roomID)?.nativePendingThreadID,
                boundaryGeneration: boundary,
                activitySink: nil,
                activityOwner: nil,
                activityTurnID: nil,
                expectedTaskIDs: self.room(id: roomID)?.nativeRetryJournal.map { Set($0.taskIDs) },
                expectedRetryReceipts: self.room(id: roomID)?.nativeRetryJournal?.receipts,
                terminalTaskIDs: &noTerminalTaskIDs
            )
            if complete {
                switch expectedOwner {
                case .owner(let owner):
                    try settleNative(roomID: roomID, owner: owner, clearPending: true)
                case .noOwner:
                    try clearNativePending(roomID: roomID)
                }
            }
            cursor = max(cursor, page.cursor)
            hasMore = page.hasMore
        }
        // A receipt can already identify the discussion when the final log
        // page was consumed by another observer or by the interrupted sender.
        // The persisted terminal marker is the completion proof in that case;
        // cursor coverage prevents settling from a stale partial replay.
        if let current = self.room(id: roomID),
           current.nativePendingEventID != nil,
           let pendingDiscussionID = current.nativePendingDiscussionEventID,
           let latestSequence = state.latestSequence,
           current.nativeLogCursor >= latestSequence,
           current.nativeCompletedDiscussionEventIDs.contains(pendingDiscussionID),
           pendingNativeRetryTaskIDs(roomID: roomID).isEmpty {
            if let owner = current.runOwner {
                try settleNative(roomID: roomID, owner: owner, clearPending: true)
            } else {
                try clearNativePending(roomID: roomID)
            }
        }
        nativeRoomSyncErrors[roomID] = nil
    }

    func observeNativeRoom(roomID: String, boundary: Int) async {
        var unknownFailures = 0
        while !Task.isCancelled {
            do {
                try requireNativeBoundary(boundary)
                guard let room = room(id: roomID) else { return }
                // An active send/retry owns the room's run CAS. Its own loop
                // consumes the log; observation is only for orphaned durable
                // work left by relaunch or transport cancellation.
                if let owner = room.runOwner, nativeActiveRunIDs.contains(owner.runID) {
                    return
                }
                try await syncNativeRoom(roomID: roomID, boundary: boundary)
                unknownFailures = 0
                guard let refreshed = self.room(id: roomID),
                      refreshed.isRunning || refreshed.nativePendingEventID != nil
                        || !refreshed.nativeFollowUps.isEmpty
                        || nativeDriverWorkingByRoom[roomID] == true
                        || roomObservers.values.contains(where: { $0.roomID == roomID && $0.owner != nil }) else {
                    return
                }
                if !refreshed.isRunning,
                   nativeDriverWorkingByRoom[roomID] == false,
                   !pendingNativeRetryTaskIDs(roomID: roomID).isEmpty {
                    return
                }
                try await Task.sleep(nanoseconds: Self.nativePollNanoseconds)
            } catch is CancellationError {
                return
            } catch BotModeRoomError.executionUnavailable {
                guard boundary == nativeBoundaryGeneration else { return }
                nativeRoomSyncErrors[roomID] = "This host cannot currently synchronize native rooms."
                return
            } catch {
                guard boundary == nativeBoundaryGeneration else { return }
                if error is BighelpLinkWorkspaceClientError
                    || error as? BotModeRoomError == .nativeAuthorityMismatch
                    || error as? BotModeRoomError == .persistenceConflict {
                    nativeRoomSyncErrors[roomID] = "Room synchronization could not be verified. Reopen this room before continuing."
                    return
                }
                let knownTransport = BighelpLinkTransientRetry.isRecoverable(error)
                    || error as? WorkspaceClientError == .transportUnavailable
                    || error as? WorkspaceClientError == .outcomeUnknown
                if error is WorkspaceClientError, !knownTransport {
                    nativeRoomSyncErrors[roomID] = "The room connection is no longer usable. Reopen it to refresh the host state."
                    return
                }
                if !knownTransport { unknownFailures += 1 }
                nativeRoomSyncErrors[roomID] = unknownFailures >= 3
                    ? "Room synchronization stopped after repeated failures. Reopen the room to retry."
                    : "Room synchronization was interrupted. Reconnecting with the original message identity."
                guard unknownFailures < 3 else { return }
                do {
                    try await Task.sleep(nanoseconds: Self.nativeTransportRetryNanoseconds)
                } catch {
                    return
                }
            }
        }
    }

    func requireNativeCapabilities(
        using client: any HermesBotModeClient,
        boundary: Int
    ) async throws -> HermesBotModeCapabilities {
        try persistence?.prepareNativeStorage()
        if let nativeCapabilities {
            guard nativeCapabilities.supportsNativeExecution else {
                throw BotModeRoomError.executionUnavailable
            }
            return nativeCapabilities
        }
        let capabilities = try await client.groupsCapabilities()
        try requireNativeBoundary(boundary)
        guard capabilities.supportsNativeExecution else {
            nativeCapabilities = nil
            throw BotModeRoomError.executionUnavailable
        }
        nativeCapabilities = capabilities
        return capabilities
    }

    /// Reuse the capability snapshot negotiated by catalog discovery or an
    /// earlier native operation. A room open otherwise paid for a second
    /// `groups.capabilities` round trip immediately before replaying its log.
    func negotiatedNativeCapabilities(
        using client: any HermesBotModeClient,
        boundary: Int
    ) async throws -> HermesBotModeCapabilities {
        if let nativeCapabilities { return nativeCapabilities }
        let capabilities = try await client.groupsCapabilities()
        try requireNativeBoundary(boundary)
        nativeCapabilities = capabilities
        return capabilities
    }

    func refreshNativeApprovals(
        roomID: String,
        driverStatus: [String: BighelpJSONValue]?,
        boundary: Int
    ) throws {
        try requireNativeBoundary(boundary)
        let actions = try HermesBotModePendingApproval.decode(roomID: roomID, driverStatus: driverStatus)
        nativePendingApprovalsByRoom[roomID] = actions.reduce(into: [:]) { result, action in
            result[action.id] = action
        }
    }

    /// Re-obtain an accepted `groups.send` receipt after a client lost the
    /// response or relaunched. Hermes treats the original client event ID as
    /// the idempotency key; retrying this exact payload recovers its canonical
    /// discussion ID without appending a second human message.
    private func recoverNativeSendReceiptIfNeeded(
        room: BotModeRoom,
        client: any HermesBotModeClient,
        boundary: Int
    ) async throws -> BotModeRoom {
        guard room.nativePendingDiscussionEventID == nil,
              let eventID = room.nativePendingEventID,
              let text = room.nativePendingText,
              let threadID = room.nativePendingThreadID else { return room }
        let result = try await client.groupsSend(
            roomID: room.id,
            eventID: eventID,
            payload: HermesBotModeUserPayload(text: text, threadID: threadID)
        )
        try requireNativeBoundary(boundary)
        guard result.accepted, result.clientEventID == eventID else {
            throw BotModeRoomError.nativeSendRejected
        }
        guard var current = self.room(id: room.id) else {
            throw CancellationError()
        }
        if let existingDiscussionID = current.nativePendingDiscussionEventID {
            // Another observer may have received the same idempotent Hermes
            // receipt first. It is success only when the server returned the
            // exact same canonical discussion identity.
            guard current.nativePendingEventID == eventID,
                  current.runOwner == room.runOwner,
                  existingDiscussionID == result.event.eventID else {
                throw BotModeRoomError.nativeSendRejected
            }
            return current
        }
        if current.nativePendingEventID == nil,
           current.nativeCompletedDiscussionEventIDs.contains(result.event.eventID) {
            // The same discussion may have been fully settled by a competing
            // sync while this idempotent receipt request was still in flight.
            // The persisted terminal marker is the proof that this result is
            // already complete; do not resurrect the cleared pending send.
            return current
        }
        guard current.nativePendingEventID == eventID,
              current.runOwner == room.runOwner else {
            throw CancellationError()
        }
        current.markNativeDiscussion(eventID: result.event.eventID)
        let expectedOwner = current.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner
        guard let saved = try compareAndSave(
            current,
            expectedRevision: current.persistenceRevision,
            expectedOwner: expectedOwner
        ) else { throw BotModeRoomError.persistenceConflict }
        replaceStored(saved)
        return saved
    }

    /// Messages sent while the room worked whose answer was lost are sent
    /// again with their own key; Hermes returns the original receipt.
    func recoverNativeFollowUpReceipts(
        roomID: String,
        client: any HermesBotModeClient,
        boundary: Int
    ) async throws {
        for followUp in room(id: roomID)?.nativeFollowUps ?? [] where followUp.discussionEventID == nil {
            let result = try await client.groupsSend(
                roomID: roomID,
                eventID: followUp.eventID,
                payload: HermesBotModeUserPayload(text: followUp.text, threadID: followUp.threadID)
            )
            try requireNativeBoundary(boundary)
            guard result.accepted, result.clientEventID == followUp.eventID else {
                throw BotModeRoomError.nativeSendRejected
            }
            try recordNativeFollowUpReceipt(roomID: roomID, eventID: followUp.eventID,
                                            discussionEventID: result.event.eventID)
        }
    }

    /// Hermes exposes retry actions in `driver_status.pending_actions` even
    /// when the corresponding terminal log event has not reached this cache.
    /// Promote only a matching persisted task failure, preserving its member,
    /// discussion, thread, turn, and execution-generation coordinates. A bare
    /// task ID never creates an invented member failure.
    func reconcileNativeRetryActions(
        roomID: String,
        driverStatus: [String: BighelpJSONValue]?,
        expectedOwner: BotModeRunOwnerExpectation,
        boundary: Int
    ) throws {
        try requireNativeBoundary(boundary)
        let previousWorking = nativeDriverWorkingByRoom[roomID]
        nativeDriverWorkingByRoom[roomID] = driverStatus?["working"]?.boolean
        if previousWorking != nativeDriverWorkingByRoom[roomID] {
            notifyRoomChanged(roomID)
        }
        guard let rawActions = driverStatus?["pending_actions"],
              case .array(let actions) = rawActions else {
            nativePendingRetryTaskIDsByRoom.removeValue(forKey: roomID)
            return
        }
        let retryTaskIDs = actions.compactMap { rawAction -> String? in
            guard case .object(let action) = rawAction,
                  action["kind"]?.string == "retry" else { return nil }
            guard let taskID = action["task_id"]?.string,
                  !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return taskID
        }
        nativePendingRetryTaskIDsByRoom[roomID] = Set(retryTaskIDs)
        guard !retryTaskIDs.isEmpty else { return }
        guard var room = room(id: roomID), expectedOwner.matches(room) else { return }
        var failures = room.memberFailures
        var changed = false
        for taskID in retryTaskIDs {
            guard let index = failures.firstIndex(where: { $0.taskID == taskID }),
                  !["indeterminate", "deferred"].contains(failures[index].status) else { continue }
            let failure = failures[index]
            failures[index] = BotModeMemberFailure(
                memberID: failure.memberID,
                message: failure.message,
                taskID: failure.taskID,
                status: "indeterminate",
                discussionEventID: failure.discussionEventID,
                threadID: failure.threadID,
                turnID: failure.turnID,
                executionGeneration: failure.executionGeneration,
                cancelGeneration: failure.cancelGeneration
            )
            changed = true
        }
        guard changed else { return }
        room.replaceFailures(with: failures)
        guard let saved = try compareAndSave(
            room,
            expectedRevision: room.persistenceRevision,
            expectedOwner: expectedOwner
        ) else { throw BotModeRoomError.persistenceConflict }
        replaceStored(saved)
    }

    func requireNativeBoundary(_ boundary: Int) throws {
        guard boundary == nativeBoundaryGeneration else { throw CancellationError() }
    }

    func validateNativeState(_ state: HermesBotModeRoomState, previous: BotModeRoom) throws {
        guard state.roomID == previous.id,
              state.authorityEpoch > 0,
              previous.nativeAuthorityGatewayID.map({ $0 == state.authorityGatewayID }) ?? true,
              previous.nativeAuthorityEpoch.map({ $0 <= state.authorityEpoch }) ?? true else {
            throw BotModeRoomError.nativeAuthorityMismatch
        }
    }

    func validateNativeAuthority(_ authority: HermesBotModeAuthority, roomID: String) throws {
        guard let room = room(id: roomID),
              room.nativeAuthorityGatewayID == authority.gatewayID,
              room.nativeAuthorityEpoch == authority.epoch else {
            throw BotModeRoomError.nativeAuthorityMismatch
        }
    }

    private func clearNativePending(roomID: String) throws {
        guard var room = room(id: roomID), room.runOwner == nil,
              room.nativePendingEventID != nil || room.nativeRetryJournal != nil else { return }
        room.clearNativeTurn()
        room.setNativeRetryJournal(nil)
        guard let saved = try compareAndSave(room, expectedRevision: room.persistenceRevision, expectedOwner: .noOwner) else {
            throw BotModeRoomError.persistenceConflict
        }
        replaceStored(saved)
    }

    func settleNative(roomID: String, owner: BotModeRunOwner, clearPending: Bool) throws {
        guard var room = room(id: roomID), room.runOwner == owner else { return }
        if clearPending {
            room.clearNativeTurn()
            room.setNativeRetryJournal(nil)
        }
        room.settleRun()
        guard let saved = try compareAndSave(
            room,
            expectedRevision: room.persistenceRevision,
            expectedOwner: .owner(owner)
        ) else { throw BotModeRoomError.persistenceConflict }
        replaceStored(saved)
    }
}
