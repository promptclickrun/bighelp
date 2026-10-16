import Foundation

extension BotModeRoomStore {
    func applyNativeEvents(
        _ events: [HermesBotModeEvent],
        cursor: Int,
        roomID: String,
        expectedOwner: BotModeRunOwnerExpectation,
        discussionEventID: String?,
        expectedThreadID: String?,
        boundaryGeneration: Int,
        activitySink: ((BotModeRunActivity) -> Void)?,
        activityOwner: BotModeRunOwner?,
        activityTurnID: String?,
        expectedTaskIDs: Set<String>?,
        expectedRetryReceipts: [String: HermesBotModeTaskReceipt]?,
        terminalTaskIDs: inout Set<String>
    ) throws -> Bool {
        try requireNativeBoundary(boundaryGeneration)
        guard var room = room(id: roomID) else { throw BotModeRoomError.roomNotFound }
        guard expectedOwner.matches(room) else { throw CancellationError() }
        var complete = false
        var supersededByNewerMessage = false
        var failures = room.memberFailures
        var changed = false
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            if let rename = room.nativePendingRename,
               event.eventID == rename.eventID, event.kind == "room.renamed",
               event.payload["name"]?.string == rename.name {
                room.setNativeRenameIntent(nil)
                changed = true
            }
            if ["turn.settled", "turn.failed", "turn.cancelled", "turn.deferred"].contains(event.kind),
               let taskID = event.taskID, let generation = event.executionGeneration {
                var attempts = terminalNativeAttempts[roomID, default: [:]]
                if generation >= (attempts[taskID]?.generation ?? 0) {
                    attempts[taskID] = (generation, event.sequence)
                }
                if attempts.count > 500, let oldest = attempts.min(by: { $0.value.sequence < $1.value.sequence })?.key {
                    attempts[oldest] = nil
                }
                terminalNativeAttempts[roomID] = attempts
            }
            if ["message.member", "turn.settled", "turn.failed", "turn.cancelled", "turn.deferred"].contains(event.kind),
               let memberID = event.memberID {
                activity.finishTyping(roomID: roomID, memberID: memberID, taskID: event.taskID)
            }
            let isNewEvent = !room.visibleEvents.contains(where: { $0.id == event.eventID })
            if isNewEvent,
               let mapped = event.botModeEvent(sourceOrder: takePresentationOrder()) {
                room.appendNativeShared(mapped)
                changed = true
            }
            let retryReceipt = event.taskID.flatMap { expectedRetryReceipts?[$0] }
            let matchesRetryReceipt = if let retryReceipt {
                event.executionGeneration == retryReceipt.executionGeneration
                    && event.threadID == retryReceipt.threadID
                    && event.turnID == retryReceipt.turnID
            } else {
                false
            }
            let belongsToCurrentDiscussion: Bool
            if expectedRetryReceipts != nil {
                belongsToCurrentDiscussion = matchesRetryReceipt
            } else {
                belongsToCurrentDiscussion = discussionEventID != nil
                    && event.discussionEventID == discussionEventID
                    && (expectedThreadID == nil || event.threadID == expectedThreadID)
            }
            // A message sent while the room worked is its own discussion,
            // queued behind this one; its failures count like this turn's.
            let belongsToFollowUp = expectedRetryReceipts == nil
                && event.discussionEventID.map { id in
                    room.nativeFollowUps.contains { $0.discussionEventID == id }
                } == true
            let expectedTaskMatches = expectedTaskIDs.map { allowed in
                event.taskID.map(allowed.contains) ?? false
            } ?? true
            if expectedRetryReceipts != nil,
               matchesRetryReceipt,
               let taskID = event.taskID,
               ["turn.settled", "turn.failed", "turn.deferred", "turn.cancelled"].contains(event.kind) {
                terminalTaskIDs.insert(taskID)
                if var journal = room.nativeRetryJournal {
                    journal.terminalTaskIDs.insert(taskID)
                    room.setNativeRetryJournal(journal)
                    changed = true
                    complete = journal.isComplete
                } else {
                    complete = expectedRetryReceipts?.keys.allSatisfy { terminalTaskIDs.contains($0) } == true
                }
            }
            let resolvedActivityTurnID = retryReceipt?.turnID ?? activityTurnID
            if isNewEvent,
               belongsToCurrentDiscussion,
               expectedTaskMatches,
               let memberID = event.memberID,
               let member = room.member(id: memberID),
               let activitySink,
               let activityOwner,
               let resolvedActivityTurnID {
                switch event.kind {
                case "message.member":
                    activitySink(runActivity(
                        owner: activityOwner,
                        turnID: resolvedActivityTurnID,
                        member: member,
                        from: nil,
                        lifecycle: .succeeded,
                        summary: "@\(member.handle) responded to the room.",
                        detail: nil
                    ))
                case "turn.failed", "turn.deferred":
                    activitySink(runActivity(
                        owner: activityOwner,
                        turnID: resolvedActivityTurnID,
                        member: member,
                        from: nil,
                        lifecycle: .failed,
                        summary: "@\(member.handle) could not respond.",
                        detail: nil
                    ))
                case "turn.cancelled":
                    activitySink(runActivity(
                        owner: activityOwner,
                        turnID: resolvedActivityTurnID,
                        member: member,
                        from: nil,
                        lifecycle: .cancelled,
                        summary: "@\(member.handle)'s handoff was cancelled.",
                        detail: nil
                    ))
                default:
                    break
                }
            }
            // Hermes cancels a member turn whose thread got a newer message;
            // that's the person moving the conversation on, not a failure.
            let isSuperseded = event.kind == "turn.cancelled"
                && event.payload["reason"]?.string == "superseded_by_newer_user_event"
            if belongsToCurrentDiscussion || belongsToFollowUp, !isSuperseded,
               ["turn.failed", "turn.deferred", "turn.cancelled"].contains(event.kind),
               let memberID = event.memberID,
               let taskID = event.taskID,
               expectedTaskIDs.map({ $0.contains(taskID) }) ?? true {
                let message = event.kind == "turn.deferred"
                    ? "Hermes deferred this member's turn. Retry only when the host offers that action."
                    : "The Hermes member turn did not complete."
                let failure = BotModeMemberFailure(
                    memberID: memberID,
                    message: message,
                    taskID: taskID,
                    status: event.kind == "turn.deferred" ? "deferred" : "failed",
                    discussionEventID: event.discussionEventID,
                    threadID: event.threadID,
                    turnID: event.turnID,
                    executionGeneration: event.executionGeneration
                )
                failures.removeAll { $0.memberID == memberID }
                failures.append(failure)
            }
            if belongsToCurrentDiscussion || belongsToFollowUp,
               event.kind == "turn.settled",
               let taskID = event.taskID {
                let beforeCount = failures.count
                failures.removeAll { failure in
                    guard failure.taskID == taskID else { return false }
                    guard let generation = event.executionGeneration else { return true }
                    return failure.executionGeneration == generation
                        || (matchesRetryReceipt && (failure.executionGeneration ?? 0) < generation)
                }
                changed = changed || failures.count != beforeCount
            }
            if event.kind == "room.activity",
               ["settled", "bounded"].contains(event.payload["status"]?.string),
               let completedDiscussionID = event.discussionEventID {
                let hadCompletionMarker = room.nativeCompletedDiscussionEventIDs.contains(completedDiscussionID)
                room.markNativeDiscussionCompleted(eventID: completedDiscussionID)
                changed = changed || !hadCompletionMarker
                if expectedRetryReceipts == nil,
                   room.settleNativeFollowUps(completedDiscussionID: completedDiscussionID) {
                    // Hermes only drives a thread's newest message. Once a
                    // later one settles, earlier discussions are finished too.
                    for earlier in [room.nativePendingDiscussionEventID, discussionEventID].compactMap({ $0 }) {
                        room.markNativeDiscussionCompleted(eventID: earlier)
                    }
                    supersededByNewerMessage = discussionEventID != nil
                    changed = true
                }
                if expectedRetryReceipts == nil, belongsToCurrentDiscussion {
                    complete = true
                }
            }
        }
        if failures != room.memberFailures { changed = true }
        room.replaceFailures(with: failures)
        if room.nativeLogCursor < cursor { changed = true }
        room.advanceNativeLog(to: cursor)
        complete = complete || supersededByNewerMessage || room.nativeRetryJournal?.isComplete == true
        guard changed else { return complete }
        guard let saved = try compareAndSave(
            room,
            expectedRevision: room.persistenceRevision,
            expectedOwner: expectedOwner
        ) else { throw BotModeRoomError.persistenceConflict }
        replaceStored(saved)
        return complete
    }
}
