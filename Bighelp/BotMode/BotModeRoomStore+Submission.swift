import Foundation

extension BotModeRoomStore {
    /// `onAccepted` hears the room event made for the message as soon as the room takes it, long before
    /// the discussion this returns after ends.
    func send(
        text: String,
        roomID: String,
        senderSnapshot: TimelineSenderSnapshot? = nil,
        activitySink: ((BotModeRunActivity) -> Void)? = nil,
        onAccepted: ((String) -> Void)? = nil
    ) async throws {
        if nativeClient != nil {
            try await sendNative(text: text, roomID: roomID, senderSnapshot: senderSnapshot, activitySink: activitySink,
                                 onAccepted: onAccepted)
            return
        }
        guard executionEnabled else { throw BotModeRoomError.executionUnavailable }
        guard var room = room(id: roomID) else { throw BotModeRoomError.roomNotFound }
        guard !room.hasNativeRoom else { throw BotModeRoomError.executionUnavailable }
        guard !room.isRunning, room.runOwner == nil else { throw BotModeRoomError.runAlreadyActive }
        let targetIDs = try MentionParser.targets(in: text, room: room)
        let owner: BotModeRunOwner?
        if targetIDs.isEmpty {
            owner = nil
        } else {
            nextGeneration += 1
            owner = BotModeRunOwner(instanceID: instanceID, generation: nextGeneration)
        }

        let humanEvent = BotModeEvent.human(text: text, sourceOrder: takePresentationOrder())
        room.appendShared(humanEvent)
        room.replaceFailures(with: [])
        room.beginRun(owner: owner)
        guard let accepted = try compareAndSave(room, expectedRevision: room.persistenceRevision, expectedOwner: .noOwner) else {
            throw BotModeRoomError.persistenceConflict
        }
        replaceStored(accepted)
        onAccepted?(humanEvent.id)
        guard let owner else { return }

        try await runFixtureTurn(
            text: text, roomID: roomID, targetIDs: targetIDs, owner: owner,
            turnID: humanEvent.id, kind: .send, previousRespondingMember: nil,
            activitySink: activitySink
        )
    }

    func retry(
        roomID: String,
        activitySink: ((BotModeRunActivity) -> Void)? = nil
    ) async throws {
        if nativeClient != nil {
            try await retryNative(roomID: roomID, activitySink: activitySink)
            return
        }
        guard executionEnabled else { throw BotModeRoomError.executionUnavailable }
        guard let room = room(id: roomID) else { throw BotModeRoomError.roomNotFound }
        guard !room.isRunning, room.runOwner == nil else { throw BotModeRoomError.runAlreadyActive }
        guard let text = room.visibleEvents.last(where: { $0.kind == .human })?.text,
              !room.memberFailures.isEmpty else { throw BotModeRoomError.noRetryableFailure }

        let targetIDs = room.memberFailures.map(\.memberID)
        nextGeneration += 1
        let owner = BotModeRunOwner(instanceID: instanceID, generation: nextGeneration)
        var acceptedRoom = room
        acceptedRoom.replaceFailures(with: [])
        acceptedRoom.beginRun(owner: owner)
        guard let accepted = try compareAndSave(
            acceptedRoom,
            expectedRevision: room.persistenceRevision,
            expectedOwner: .noOwner
        ) else { throw BotModeRoomError.persistenceConflict }
        replaceStored(accepted)

        let previousRespondingMember = room.visibleEvents.reversed().compactMap { event -> BotModeMember? in
            guard event.kind == .agent, let memberID = event.memberID else { return nil }
            return room.member(id: memberID)
        }.first
        try await runFixtureTurn(
            text: text, roomID: roomID, targetIDs: targetIDs, owner: owner,
            turnID: room.visibleEvents.last(where: { $0.kind == .human })?.id ?? owner.runID,
            kind: .retry, previousRespondingMember: previousRespondingMember,
            activitySink: activitySink
        )
    }

    private enum FixtureTurnKind { case send, retry }

    /// Fixture-only execution. Native journals and log replay never use this loop.
    private func runFixtureTurn(
        text: String,
        roomID: String,
        targetIDs: [String],
        owner: BotModeRunOwner,
        turnID: String,
        kind: FixtureTurnKind,
        previousRespondingMember initialPreviousMember: BotModeMember?,
        activitySink: ((BotModeRunActivity) -> Void)?
    ) async throws {
        var failures: [BotModeMemberFailure] = []
        var previousRespondingMember = initialPreviousMember
        for memberID in targetIDs {
            guard let current = self.room(id: roomID), current.runOwner == owner,
                  let member = current.member(id: memberID) else {
                throw BotModeRoomError.persistenceConflict
            }
            func emit(
                _ lifecycle: ChatActivityLifecycle,
                summary: String,
                detail: String? = nil,
                fromPreviousMember: Bool = true
            ) {
                activitySink?(runActivity(
                    owner: owner, turnID: turnID, member: member,
                    from: fromPreviousMember ? previousRespondingMember : nil,
                    lifecycle: lifecycle, summary: summary, detail: detail
                ))
            }
            let request = BotModeMemberTurnRequest(
                roomID: roomID,
                memberID: memberID,
                memberSessionID: member.sessionID,
                text: text,
                sharedEvents: current.visibleEvents
            )
            emit(
                .running,
                summary: kind == .send
                    ? "@\(member.handle) is reviewing the shared conversation."
                    : "@\(member.handle) is retrying the shared turn.",
                detail: previousRespondingMember.map { "Context handed off from @\($0.handle)." }
            )
            let result: BotModeMemberTurnResult
            do {
                result = try await client.performMemberTurn(request)
            } catch {
                guard var failed = self.room(id: roomID), failed.runOwner == owner else {
                    emit(.cancelled, summary: "@\(member.handle)'s \(kind == .send ? "handoff" : "retry") was cancelled.")
                    return
                }
                failures.append(BotModeMemberFailure(memberID: memberID, message: error.localizedDescription))
                failed.replaceFailures(with: failures)
                guard let saved = try? compareAndSave(failed, expectedRevision: failed.persistenceRevision, expectedOwner: .owner(owner)) else {
                    recoverAfterPersistenceFailure(roomID: roomID, owner: owner, fallback: failed)
                    emit(
                        .failed,
                        summary: "@\(member.handle) could not complete the \(kind == .send ? "handoff" : "retry").",
                        detail: "The failure could not be saved."
                    )
                    throw BotModeRoomError.persistenceConflict
                }
                replaceStored(saved)
                emit(.failed, summary: "@\(member.handle) could not respond.", detail: error.localizedDescription)
                continue
            }

            guard var settled = self.room(id: roomID), settled.runOwner == owner else {
                emit(.cancelled, summary: "@\(member.handle)'s \(kind == .send ? "handoff" : "retry") was cancelled.")
                return
            }
            let reply: String? = if case .reply(let text) = result,
                                    text.trimmingCharacters(in: .whitespacesAndNewlines) != "(pass)" {
                text
            } else {
                nil
            }
            if let reply {
                settled.appendShared(.agent(
                    memberID: memberID,
                    text: reply,
                    sourceOrder: takePresentationOrder()
                ))
                guard let saved = try? compareAndSave(settled, expectedRevision: settled.persistenceRevision, expectedOwner: .owner(owner)) else {
                    var recoverable = settled
                    // Send preserves preceding failures; retry's historical fallback
                    // retains only the response that could not be saved.
                    recoverable.replaceFailures(with: (kind == .send ? failures : []) + [
                        BotModeMemberFailure(memberID: memberID, message: "Response could not be saved. Try again.")
                    ])
                    recoverAfterPersistenceFailure(roomID: roomID, owner: owner, fallback: recoverable)
                    emit(.failed, summary: "@\(member.handle)'s response could not be saved.")
                    throw BotModeRoomError.persistenceConflict
                }
                replaceStored(saved)
                previousRespondingMember = member
            }
            emit(
                .succeeded,
                summary: reply == nil
                    ? "@\(member.handle) reviewed the \(kind == .send ? "turn" : "retry") and passed."
                    : "@\(member.handle) responded to the room.",
                fromPreviousMember: previousRespondingMember?.profileID != member.profileID
            )
        }

        guard var completed = self.room(id: roomID), completed.runOwner == owner else { return }
        completed.replaceFailures(with: failures)
        completed.settleRun()
        guard let saved = try? compareAndSave(completed, expectedRevision: completed.persistenceRevision, expectedOwner: .owner(owner)) else {
            recoverAfterPersistenceFailure(roomID: roomID, owner: owner, fallback: completed)
            throw BotModeRoomError.persistenceConflict
        }
        replaceStored(saved)
    }
}
