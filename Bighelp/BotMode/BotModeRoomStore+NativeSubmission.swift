import Foundation

extension BotModeRoomStore {
    func sendNative(
        text: String,
        roomID: String,
        senderSnapshot: TimelineSenderSnapshot?,
        activitySink: ((BotModeRunActivity) -> Void)?
    ) async throws {
        guard let nativeClient else { throw BotModeRoomError.executionUnavailable }
        if let working = room(id: roomID), working.isNativeWorking {
            // Hermes queues a message sent while members work behind the
            // room's active drive, so it goes out now instead of waiting.
            try await sendNativeFollowUp(text: text, roomID: roomID, senderSnapshot: senderSnapshot)
            return
        }
        let boundary = nativeBoundaryGeneration
        _ = try await requireNativeCapabilities(using: nativeClient, boundary: boundary)
        try requireNativeBoundary(boundary)
        guard var room = room(id: roomID) else { throw BotModeRoomError.roomNotFound }
        guard !room.isRunning, room.runOwner == nil else { throw BotModeRoomError.runAlreadyActive }

        let pendingText = room.nativePendingText
        if let state = room.nativeState, !state.members.isEmpty,
           !HermesBotModeRoomSummary(room: state, capabilities: nativeCapabilities).canExecute {
            throw BotModeRoomError.executionUnavailable
        }
        if let pendingText, pendingText != text {
            // A persisted pending send is resumed with its original text and
            // idempotency key by the next explicit retry path.
            throw BotModeRoomError.runAlreadyActive
        }
        let outboundText = pendingText ?? text
        guard !outboundText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              outboundText.utf8.count <= 64 * 1024,
              !outboundText.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && !"\n\r\t".unicodeScalars.contains($0)
              }) else {
            throw WorkspaceClientError.invalidRequest
        }
        if room.nativeRoomID == nil {
            guard (2...BotModeRoom.maximumMembers).contains(room.members.count) else {
                throw BotModeRoomError.invalidMember
            }
            let remote = try await nativeClient.groupsCreate(
                roomID: room.id,
                name: "Bot Mode",
                members: room.members.map(HermesBotModeRoomMember.init(member:))
            )
            try requireNativeBoundary(boundary)
            guard remote.authorityGatewayID == nativeCapabilities?.authorityGatewayID else {
                throw BotModeRoomError.nativeAuthorityMismatch
            }
            room.markNativeRoom(remote)
        } else {
            // A relaunch may have advanced the gateway while the local cache
            // still has an older cursor. Drain it before admitting a new turn.
            let state = try await nativeClient.groupsState(roomID: room.id, includeDisbanded: false)
            try requireNativeBoundary(boundary)
            try refreshNativeApprovals(roomID: roomID, driverStatus: state.driverStatus, boundary: boundary)
            try reconcileNativeRetryActions(
                roomID: roomID,
                driverStatus: state.driverStatus,
                expectedOwner: .noOwner,
                boundary: boundary
            )
            let metadataChanged = room.nativeRoomID != state.roomID
                || room.nativeAuthorityGatewayID != state.authorityGatewayID
                || room.nativeAuthorityEpoch != state.authorityEpoch
                || room.nativeState != state.persistentMetadata
            room.markNativeRoom(state)
            if metadataChanged {
                let expectedRevision = room.persistenceRevision
                guard let marked = try compareAndSave(
                    room,
                    expectedRevision: expectedRevision,
                    expectedOwner: .noOwner
                ) else { throw BotModeRoomError.persistenceConflict }
                replaceStored(marked)
                room = marked
            }
            var cursor = room.nativeLogCursor
            var noTerminalTaskIDs = Set<String>()
            var hasMore = true
            while hasMore {
                let page = try await nativeClient.groupsLog(
                    roomID: room.id,
                    sinceSequence: cursor,
                    limit: nativeLogPageLimit,
                    includeDisbanded: false
                )
                try requireNativeBoundary(boundary)
                try validateNativeAuthority(page.authority, roomID: roomID)
                _ = try applyNativeEvents(
                    page.events,
                    cursor: page.cursor,
                    roomID: roomID,
                    expectedOwner: .noOwner,
                    discussionEventID: room.nativePendingDiscussionEventID,
                    expectedThreadID: room.nativePendingThreadID,
                    boundaryGeneration: boundary,
                    activitySink: nil,
                    activityOwner: nil,
                    activityTurnID: nil,
                    expectedTaskIDs: nil,
                    expectedRetryReceipts: nil,
                    terminalTaskIDs: &noTerminalTaskIDs
                )
                cursor = max(cursor, page.cursor)
                hasMore = page.hasMore
            }
            guard let refreshed = self.room(id: roomID) else { throw BotModeRoomError.roomNotFound }
            room = refreshed
        }
        let eventID = room.nativePendingEventID ?? "bot-user-\(UUID().uuidString)"
        let threadID = room.nativePendingThreadID ?? HermesBotModeWireCodec.mainThreadID(roomID: room.id)
        nextGeneration += 1
        let owner = BotModeRunOwner(instanceID: instanceID, generation: nextGeneration)
        nativeActiveRunIDs.insert(owner.runID)
        defer {
            nativeActiveRunIDs.remove(owner.runID)
            // A transport failure can leave an accepted Hermes task running
            // after this caller is cancelled or returns an error. Hand the
            // durable pending send to the store-owned observer under the same
            // verified boundary; explicit stop remains the only cancellation
            // operation sent to Hermes.
            if boundary == nativeBoundaryGeneration,
               let current = self.room(id: roomID),
               current.nativePendingEventID != nil || current.isRunning || !current.nativeFollowUps.isEmpty {
                beginNativeRoomObservation(roomID: roomID)
            }
        }
        let expectedRevision = room.persistenceRevision
        room.prepareNativeTurn(
            eventID: eventID, threadID: threadID, text: outboundText, owner: owner,
            senderSnapshot: senderSnapshot
        )
        guard let accepted = try compareAndSave(room, expectedRevision: expectedRevision, expectedOwner: .noOwner) else {
            throw BotModeRoomError.persistenceConflict
        }
        replaceStored(accepted)

        do {
            let result = try await nativeClient.groupsSend(
                roomID: room.id,
                eventID: eventID,
                payload: HermesBotModeUserPayload(text: outboundText, threadID: threadID)
            )
            try requireNativeBoundary(boundary)
            guard result.accepted, result.clientEventID == eventID else {
                throw BotModeRoomError.nativeSendRejected
            }
            guard var marked = self.room(id: roomID), marked.runOwner == owner else {
                throw CancellationError()
            }
            marked.markNativeDiscussion(eventID: result.event.eventID)
            guard let saved = try compareAndSave(
                marked,
                expectedRevision: marked.persistenceRevision,
                expectedOwner: .owner(owner)
            ) else { throw BotModeRoomError.persistenceConflict }
            replaceStored(saved)
            var complete = false
            var discussionSettled = false
            var noTerminalTaskIDs = Set<String>()
            var cursor = self.room(id: roomID)?.nativeLogCursor ?? 0
            while !complete {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: Self.nativePollNanoseconds)
                try requireNativeBoundary(boundary)
                let state = try await nativeClient.groupsState(roomID: roomID, includeDisbanded: false)
                try requireNativeBoundary(boundary)
                try refreshNativeApprovals(roomID: roomID, driverStatus: state.driverStatus, boundary: boundary)
                try reconcileNativeRetryActions(
                    roomID: roomID,
                    driverStatus: state.driverStatus,
                    expectedOwner: .owner(owner),
                    boundary: boundary
                )
                if state.driverStatus?["working"]?.boolean == false,
                   !pendingNativeRetryTaskIDs(roomID: roomID).isEmpty {
                    // Hermes has stopped this turn and retained an exact
                    // retry action. Release the local run owner so UI can
                    // offer retry while preserving the pending send key.
                    try settleNative(roomID: roomID, owner: owner, clearPending: false)
                    return
                }
                // A message sent meanwhile whose answer was lost supersedes
                // this discussion; only its receipt can tell when it settles.
                if self.room(id: roomID)?.nativeFollowUps.contains(where: { $0.discussionEventID == nil }) == true {
                    try? await recoverNativeFollowUpReceipts(roomID: roomID, client: nativeClient, boundary: boundary)
                }
                let page = try await nativeClient.groupsLog(
                    roomID: roomID,
                    sinceSequence: cursor,
                    limit: nativeLogPageLimit,
                    includeDisbanded: false
                )
                try requireNativeBoundary(boundary)
                try validateNativeAuthority(page.authority, roomID: roomID)
                discussionSettled = try applyNativeEvents(
                    page.events,
                    cursor: page.cursor,
                    roomID: roomID,
                    expectedOwner: .owner(owner),
                    discussionEventID: result.event.eventID,
                    expectedThreadID: threadID,
                    boundaryGeneration: boundary,
                    activitySink: activitySink,
                    activityOwner: owner,
                    activityTurnID: result.event.eventID,
                    expectedTaskIDs: nil,
                    expectedRetryReceipts: nil,
                    terminalTaskIDs: &noTerminalTaskIDs
                ) || discussionSettled
                cursor = max(cursor, page.cursor)
                // Messages sent meanwhile are queued behind (or supersede) this
                // discussion: the room works until Hermes settles them too.
                complete = discussionSettled && self.room(id: roomID)?.hasUnsettledNativeFollowUps != true
            }
            try settleNative(roomID: roomID, owner: owner, clearPending: true)
        } catch is CancellationError {
            // Task cancellation may be a view/account lifecycle event. Keep
            // the durable room task running; explicit stopNative is the only
            // path that calls groups.stop.
            throw CancellationError()
        } catch {
            // Preserve the pending event id/text so a later retry can safely
            // re-submit the same server idempotency key after a transport loss.
            try? settleNative(roomID: roomID, owner: owner, clearPending: false)
            throw error
        }
    }

    /// Sends a message while the room's members are still working. Hermes
    /// appends it and queues it behind the active drive. The intent is saved
    /// before dispatch, and the same text sent again after a lost answer
    /// reuses its idempotency key.
    func sendNativeFollowUp(
        text: String,
        roomID: String,
        senderSnapshot: TimelineSenderSnapshot?
    ) async throws {
        guard let nativeClient else { throw BotModeRoomError.executionUnavailable }
        let boundary = nativeBoundaryGeneration
        _ = try await requireNativeCapabilities(using: nativeClient, boundary: boundary)
        try requireNativeBoundary(boundary)
        guard var room = room(id: roomID) else { throw BotModeRoomError.roomNotFound }
        guard room.hasNativeRoom, room.nativePendingCancelID == nil,
              room.nativeRetryJournal?.awaitingReceipt.isEmpty != false else {
            throw BotModeRoomError.runAlreadyActive
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 64 * 1024,
              !text.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && !"\n\r\t".unicodeScalars.contains($0)
              }) else {
            throw WorkspaceClientError.invalidRequest
        }
        let followUp: HermesBotModeFollowUp
        if let unconfirmed = room.nativeFollowUps.first(where: { $0.discussionEventID == nil && $0.text == text }) {
            followUp = unconfirmed
        } else {
            guard room.nativeFollowUps.count < HermesBotModeFollowUp.maximumPending else {
                throw BotModeRoomError.runAlreadyActive
            }
            followUp = HermesBotModeFollowUp(
                eventID: "bot-user-\(UUID().uuidString)",
                threadID: HermesBotModeWireCodec.mainThreadID(roomID: room.id),
                text: text,
                senderSnapshot: senderSnapshot
            )
            room.queueNativeFollowUp(followUp)
            guard let saved = try compareAndSave(
                room,
                expectedRevision: room.persistenceRevision,
                expectedOwner: room.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner
            ) else { throw BotModeRoomError.persistenceConflict }
            replaceStored(saved)
        }

        defer {
            // The run that was working may have finished meanwhile, or the
            // answer was lost: the store's observer then follows (and
            // re-sends, under the same key) until Hermes settles it.
            if boundary == nativeBoundaryGeneration, let current = self.room(id: roomID),
               !current.nativeFollowUps.isEmpty,
               !(current.runOwner.map { nativeActiveRunIDs.contains($0.runID) } ?? false) {
                beginNativeRoomObservation(roomID: roomID)
            }
        }
        let result = try await nativeClient.groupsSend(
            roomID: roomID,
            eventID: followUp.eventID,
            payload: HermesBotModeUserPayload(text: followUp.text, threadID: followUp.threadID)
        )
        try requireNativeBoundary(boundary)
        guard result.accepted, result.clientEventID == followUp.eventID else {
            // Hermes answered and refused it: nothing to recover.
            try? dropNativeFollowUp(roomID: roomID, eventID: followUp.eventID)
            throw BotModeRoomError.nativeSendRejected
        }
        try recordNativeFollowUpReceipt(roomID: roomID, eventID: followUp.eventID,
                                        discussionEventID: result.event.eventID)
    }

    private func dropNativeFollowUp(roomID: String, eventID: String) throws {
        guard var current = room(id: roomID), current.removeNativeFollowUp(eventID: eventID) else { return }
        guard let saved = try compareAndSave(
            current,
            expectedRevision: current.persistenceRevision,
            expectedOwner: current.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner
        ) else { throw BotModeRoomError.persistenceConflict }
        replaceStored(saved)
    }

    func recordNativeFollowUpReceipt(roomID: String, eventID: String, discussionEventID: String) throws {
        guard var current = room(id: roomID),
              current.nativeFollowUps.contains(where: { $0.eventID == eventID && $0.discussionEventID == nil })
        else { return }
        current.markNativeFollowUpReceipt(eventID: eventID, discussionEventID: discussionEventID)
        guard let saved = try compareAndSave(
            current,
            expectedRevision: current.persistenceRevision,
            expectedOwner: current.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner
        ) else { throw BotModeRoomError.persistenceConflict }
        replaceStored(saved)
    }

    func retryNative(
        roomID: String,
        activitySink: ((BotModeRunActivity) -> Void)?
    ) async throws {
        guard let nativeClient else { throw BotModeRoomError.executionUnavailable }
        let boundary = nativeBoundaryGeneration
        _ = try await requireNativeCapabilities(using: nativeClient, boundary: boundary)
        try requireNativeBoundary(boundary)
        guard let initial = room(id: roomID) else { throw BotModeRoomError.roomNotFound }
        guard !initial.isRunning, initial.runOwner == nil else { throw BotModeRoomError.runAlreadyActive }
        // Refresh the server-owned retry actions before deciding whether this
        // room is retryable. Hermes can expose an exact task ID in state before
        // any terminal failure event has reached the local transcript.
        let initialState = try await nativeClient.groupsState(roomID: roomID, includeDisbanded: false)
        try requireNativeBoundary(boundary)
        try refreshNativeApprovals(roomID: roomID, driverStatus: initialState.driverStatus, boundary: boundary)
        try reconcileNativeRetryActions(
            roomID: roomID,
            driverStatus: initialState.driverStatus,
            expectedOwner: .noOwner,
            boundary: boundary
        )
        guard let refreshed = room(id: roomID) else { throw BotModeRoomError.roomNotFound }
        if refreshed.nativeRetryJournal?.awaitingReceipt.isEmpty == false {
            throw WorkspaceClientError.outcomeUnknown
        }
        let persistedTaskIDs = refreshed.memberFailures
            .filter { ["indeterminate", "deferred"].contains($0.status) }
            .compactMap(\.taskID)
        var taskIDs = persistedTaskIDs
        for taskID in pendingNativeRetryTaskIDs(roomID: roomID) where !taskIDs.contains(taskID) {
            taskIDs.append(taskID)
        }
        if let journal = refreshed.nativeRetryJournal { taskIDs = journal.taskIDs }
        guard !taskIDs.isEmpty else { throw BotModeRoomError.noRetryableFailure }
        nextGeneration += 1
        let owner = BotModeRunOwner(instanceID: instanceID, generation: nextGeneration)
        nativeActiveRunIDs.insert(owner.runID)
        defer {
            nativeActiveRunIDs.remove(owner.runID)
            if boundary == nativeBoundaryGeneration,
               let current = self.room(id: roomID),
               current.nativePendingEventID != nil || current.isRunning {
                beginNativeRoomObservation(roomID: roomID)
            }
        }
        var acceptedRoom = refreshed
        if acceptedRoom.nativeRetryJournal == nil {
            acceptedRoom.setNativeRetryJournal(.init(taskIDs: taskIDs))
        }
        acceptedRoom.beginRun(owner: owner)
        guard let accepted = try compareAndSave(
            acceptedRoom,
            expectedRevision: refreshed.persistenceRevision,
            expectedOwner: .noOwner
        ) else { throw BotModeRoomError.persistenceConflict }
        replaceStored(accepted)

        do {
            var retryReceipts = accepted.nativeRetryJournal?.receipts ?? [:]
            for taskID in taskIDs {
                if retryReceipts[taskID] != nil { continue }
                try requireNativeBoundary(boundary)
                guard var sending = room(id: roomID), sending.runOwner == owner,
                      var journal = sending.nativeRetryJournal else {
                    throw WorkspaceClientError.ownerChanged
                }
                journal.awaitingReceipt.insert(taskID)
                sending.setNativeRetryJournal(journal)
                guard let savedIntent = try compareAndSave(
                    sending, expectedRevision: sending.persistenceRevision, expectedOwner: .owner(owner)
                ) else { throw BotModeRoomError.persistenceConflict }
                replaceStored(savedIntent)
                let receipt = try await nativeClient.groupsRetry(roomID: roomID, taskID: taskID)
                try requireNativeBoundary(boundary)
                // Hermes returns the authoritative task receipt after the
                // fenced requeue. Keep every identity coordinate intact and
                // reject a transport that claims success for another task or
                // an unusable generation; otherwise later log events could be
                // attributed to the wrong retry.
                guard receipt.retried,
                      receipt.task.roomID == roomID,
                      receipt.task.taskID == taskID,
                      receipt.task.status == "queued",
                      !receipt.task.threadID.isEmpty,
                      !receipt.task.turnID.isEmpty,
                      receipt.task.executionGeneration > 0,
                      receipt.task.cancelGeneration >= 0 else {
                    throw BotModeRoomError.nativeRetryRejected
                }
                retryReceipts[taskID] = receipt.task
                guard var received = room(id: roomID), received.runOwner == owner,
                      var journal = received.nativeRetryJournal else {
                    throw WorkspaceClientError.ownerChanged
                }
                journal.receipts[taskID] = receipt.task
                journal.awaitingReceipt.remove(taskID)
                received.setNativeRetryJournal(journal)
                guard let savedReceipt = try compareAndSave(
                    received, expectedRevision: received.persistenceRevision, expectedOwner: .owner(owner)
                ) else { throw BotModeRoomError.persistenceConflict }
                replaceStored(savedReceipt)
            }
            var cursor = accepted.nativeLogCursor
            var terminalTaskIDs = accepted.nativeRetryJournal?.terminalTaskIDs ?? []
            var complete = false
            while !complete {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: Self.nativePollNanoseconds)
                try requireNativeBoundary(boundary)
                let state = try await nativeClient.groupsState(roomID: roomID, includeDisbanded: false)
                try requireNativeBoundary(boundary)
                try refreshNativeApprovals(roomID: roomID, driverStatus: state.driverStatus, boundary: boundary)
                try reconcileNativeRetryActions(
                    roomID: roomID,
                    driverStatus: state.driverStatus,
                    expectedOwner: .owner(owner),
                    boundary: boundary
                )
                let page = try await nativeClient.groupsLog(
                    roomID: roomID,
                    sinceSequence: cursor,
                    limit: nativeLogPageLimit,
                    includeDisbanded: false
                )
                try requireNativeBoundary(boundary)
                try validateNativeAuthority(page.authority, roomID: roomID)
                complete = try applyNativeEvents(
                    page.events,
                    cursor: page.cursor,
                    roomID: roomID,
                    expectedOwner: .owner(owner),
                    discussionEventID: nil,
                    expectedThreadID: nil,
                    boundaryGeneration: boundary,
                    activitySink: activitySink,
                    activityOwner: owner,
                    activityTurnID: nil,
                    expectedTaskIDs: Set(taskIDs),
                    expectedRetryReceipts: retryReceipts,
                    terminalTaskIDs: &terminalTaskIDs
                )
                cursor = max(cursor, page.cursor)
            }
            try settleNative(roomID: roomID, owner: owner, clearPending: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try? settleNative(roomID: roomID, owner: owner, clearPending: false)
            throw error
        }
    }
}
