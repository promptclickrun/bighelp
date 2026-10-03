import Foundation

extension ChatModel {
    /// Exact persisted source. Opening/closing an unchanged canonical draft must
    /// not reserialize JSON or normalize BOM, CRLF, or Unicode scalar sequences.
    var canonicalReferenceDraft: String {
        if let referenceCanonicalSource { return referenceCanonicalSource }
        return (try? ReferenceCodec.encode(source: draft, references: referenceSnapshots)) ?? draft
    }

    var referenceState: ReferenceCanonicalState? {
        guard !referenceSelections.isEmpty || referenceSubmission != nil else { return nil }
        return ReferenceCanonicalState(
            selections: referenceSelections.map(ReferenceCanonicalSelectionBinding.init),
            submission: referenceSubmission, draftID: referenceDraftID,
            draftRevision: referenceDraftRevision)
    }

    /// First bind is inert. Recipient edits invalidate the prior review without
    /// discarding this user's draft. Account/host/session replacement retires it.
    func bindReferenceOwner(_ owner: ReferenceHubOwner) {
        guard !referenceOwnerRetired else { return }
        guard owner.sessionID == conversationID, owner.agentID == agentID else {
            invalidateReferenceOwnership()
            return
        }
        if let referenceOwner, !ReferenceCanonicalOwner(referenceOwner).matches(owner) {
            if referenceOwner.accountID == owner.accountID,
               referenceOwner.hostID == owner.hostID,
               referenceOwner.deviceID == owner.deviceID,
               referenceOwner.authorizationEpoch == owner.authorizationEpoch,
               referenceOwner.sessionID == owner.sessionID,
               referenceOwner.agentID == owner.agentID {
                // Any unresolved submission retains its original immutable owner.
                // The new recipient set cannot reuse its review or send identity.
                self.referenceOwner = owner
                return
            }
            invalidateReferenceOwnership()
            return
        }
        referenceOwner = owner
    }

    /// Call synchronously before account/host/grant/session/recipient replacement.
    /// No persistence callback may publish retired data into a replacement owner.
    /// The original unresolved intent remains in its original SessionRecord.
    func invalidateReferenceOwnership() {
        referenceOwnerRetired = true
        referenceOwner = nil
        persistenceCheckpointTask?.cancel()
        persistenceCheckpointTask = nil
        hasDirtyPersistence = false
        isReplacingReferenceDraft = true
        draft = ""
        replyDraft = nil
        draftAttachments = []
        orderedDraftAttachments = []
        referenceSelections = []
        referenceCanonicalSource = nil
        referenceDraftID = nil
        referenceDraftRevision = nil
        referenceSubmission = nil
        isReplacingReferenceDraft = false
    }

    /// Native hub source and metadata are one synchronous persistence transaction.
    /// Parent forwards hub edits here, including removals and native Undo/Redo.
    func updateReferenceDraft(source: String, selections: [ReferenceDraftSelection]) throws {
        guard !referenceOwnerRetired else { throw CancellationError() }
        let sameSource = Data(draft.utf8) == Data(source.utf8)
        let sameSelections = Self.sameReferenceSelections(referenceSelections, selections)
        guard !sameSource || !sameSelections else { return }
        let canonical = try ReferenceCodec.encode(source: source, references: selections.map(\.snapshot))
        isReplacingReferenceDraft = true
        draft = source
        referenceSelections = selections
        referenceCanonicalSource = canonical
        referenceDraftID = nil
        referenceDraftRevision = nil
        referencePersistenceNeeded = true
        isReplacingReferenceDraft = false
        persistSession()
    }

    private static func sameReferenceSelections(_ lhs: [ReferenceDraftSelection],
                                               _ rhs: [ReferenceDraftSelection]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
            $0.id == $1.id && Data($0.providerID.utf8) == Data($1.providerID.utf8)
                && Data($0.sourceKindLabel.utf8) == Data($1.sourceKindLabel.utf8)
                && $0.snapshot == $1.snapshot
        }
    }

    /// A local presentation canvas has no Hermes identity yet. Keep its
    /// composer editable, but make sending impossible until the coordinator
    /// replaces the route with the authoritative session ID.
    var isAwaitingAuthoritativeSessionAllocation: Bool {
        conversationID.hasPrefix("local-draft:")
    }

    var permitsOrdinaryComposerSend: Bool {
        guard !isAwaitingAuthoritativeSessionAllocation else {
            failureMessage = "This chat is still connecting to Hermes. Your draft is saved."
            return false
        }
        guard !richDraftRecovery.hasUnexportedChanges else { return false }
        guard !referenceOwnerRetired, referenceSubmission == nil, !referenceSendInFlight,
              referenceSelections.isEmpty, !ReferenceCodec.decode(draft).hasValidAppendix else {
            failureMessage = "References must be verified before sending. A pending reference message must be reconciled, not retried."
            return false
        }
        return true
    }

    /// No provider work occurs here: only the immutable, already-revalidated
    /// snapshot is accepted. The live predicate must include hub.owns(frozen)
    /// AND the root's actual current account/host/device/epoch/session/recipients.
    @discardableResult
    func sendReferenceDraft(
        _ frozen: ReferenceFrozenDraft,
        using behavior: MidSessionChatBehavior? = nil,
        remainsOwned: @escaping @MainActor () -> Bool
    ) async -> ReferenceCanonicalSendOutcome {
        guard !richDraftRecovery.hasUnexportedChanges else { return .unavailable }
        guard referenceSubmission == nil, !referenceSendInFlight else {
            failureMessage = "This reference message is awaiting reconciliation. It will not be sent again."
            return .indeterminate
        }
        guard ownsReferenceDraft(frozen, remainsOwned: remainsOwned), !Task.isCancelled else {
            return .superseded
        }
        guard !orderedDraftAttachments.contains(where: { $0.pdfSelection != nil }) else {
            failureMessage = "PDF pages and session references must be sent in separate messages. Your draft is unchanged."
            return .unavailable
        }
        // BotModeRoomStore's current public send API parses its sole text and
        // creates new per-run/member intent IDs. It cannot honor this contract.
        guard botModeRoomID == nil, frozen.owner.recipientIDs == [agentID],
              let canonicalClient = client as? any ReferenceCanonicalConversationClient,
              !hasExclusiveMidSessionSubmission, !isStopping,
              onReferenceStateChange != nil, onSessionChange != nil else {
            failureMessage = botModeRoomID != nil
                ? "References are available in one-on-one chats, not group chats. Your draft is unchanged."
                : "Reference sending is unavailable for this conversation. Your draft is unchanged."
            return .unavailable
        }
        let selectedBehavior = isSending ? (behavior ?? defaultMidSessionBehavior) : nil
        if isSending && !supportsMidSessionSending { return .unavailable }
        let submission: ReferenceCanonicalSubmission
        do {
            submission = try canonicalClient.prepareReferenceSubmission(frozen,
                attachments: draftAttachments, behavior: selectedBehavior)
        } catch {
            failureMessage = "The reference message cannot be prepared for this transport. Your draft is unchanged."
            return .unavailable
        }
        guard ownsReferenceDraft(frozen, remainsOwned: remainsOwned) else { return .superseded }
        referenceSubmission = submission
        referenceCanonicalSource = frozen.canonicalText
        referenceDraftID = frozen.draftID
        referenceDraftRevision = frozen.revision
        referencePersistenceNeeded = true
        retryRequest = nil
        do {
            // Synchronous durable commit BEFORE uploads or any external write.
            try persistReferenceStateNow()
        } catch {
            referenceSubmission = nil
            failureMessage = "The reference send intent could not be saved. Nothing was sent."
            return .unavailable
        }
        guard ownsReferenceDraft(frozen, remainsOwned: remainsOwned) else { return .superseded }
        referenceSendInFlight = true
        if let selectedBehavior {
            pendingMidSessionSubmissions.append(.init(id: submission.message.messageID,
                behavior: selectedBehavior))
        }
        defer {
            referenceSendInFlight = false
            removePendingMidSessionSubmission(id: submission.message.messageID)
        }
        // Persist ambiguity pessimistically: termination at any subsequent await
        // must not turn a possibly delivered message into a fresh Send.
        referenceSubmission?.phase = .indeterminate
        do {
            try persistReferenceStateNow()
        } catch {
            failureMessage = "The reference intent could not be saved. Nothing was sent."
            return .unavailable
        }
        let liveOwnership: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.referenceSubmission?.submissionID == frozen.submissionID
                && self.ownsReferenceDraft(frozen, remainsOwned: remainsOwned)
                && self.draftAttachments == submission.attachments
                && self.orderedDraftAttachments == submission.attachments.map(ChatDraftAttachment.attachment)
        }
        guard liveOwnership(), !Task.isCancelled else { return .superseded }
        let startsPrimaryTurn = selectedBehavior == nil || selectedBehavior == .interruptAndSend
        let submissionGeneration = startsPrimaryTurn ? beginOwnerGeneration() : ownerGeneration
        if startsPrimaryTurn {
            isSending = true
            hasLocallyPendingPrimaryTurn = true
            hasExternallyOwnedPrimaryTurn = true
        }
        do {
            try await canonicalClient.submitReference(submission, remainsOwned: liveOwnership)
        } catch {
            guard liveOwnership() else { return .superseded }
            // Only the guarded socket may prove rejection. Generic network,
            // identity, cancellation and unknown errors retain the exact intent.
            if error as? ReferenceCanonicalSendError == .rejected {
                referenceSubmission = nil
                if startsPrimaryTurn, isCurrentOwner(submissionGeneration) { isSending = false }
                do { try persistReferenceStateNow() } catch {
                    var rejected = submission
                    rejected.phase = .rejected
                    referenceSubmission = rejected
                    failureMessage = "The rejected intent could not be cleared locally. Reconciliation is required."
                    return .indeterminate
                }
                failureMessage = "The reference message was rejected. Your draft is unchanged."
                return .rejected
            }
            failureMessage = "Delivery is unconfirmed. Your exact reference message is retained; refresh history to reconcile it."
            return .indeterminate
        }
        guard liveOwnership() else { return .superseded }
        referenceSubmission?.phase = .accepted
        // Do not wait for a final. Existing unsolicited/history output owns it.
        // In particular, never restart a turn whose final arrived before ack.
        finishReferenceAcceptance(submission)
        return .accepted
    }

    private func ownsReferenceDraft(_ frozen: ReferenceFrozenDraft,
                                   remainsOwned: @MainActor () -> Bool) -> Bool {
        guard !referenceOwnerRetired, remainsOwned(),
              let referenceOwner, ReferenceCanonicalOwner(referenceOwner).matches(frozen.owner),
              frozen.owner.sessionID == conversationID, frozen.owner.agentID == agentID,
              Data(draft.utf8) == Data(frozen.routingSource.utf8),
              Self.sameReferenceSelections(referenceSelections, frozen.selections),
              !frozen.snapshots.isEmpty,
              let canonical = try? ReferenceCodec.encode(source: frozen.routingSource,
                  references: frozen.snapshots)
        else { return false }
        return Data(canonical.utf8) == Data(frozen.canonicalText.utf8)
    }

    private func persistReferenceStateNow() throws {
        guard !referenceOwnerRetired, let onReferenceStateChange, let onSessionChange else {
            throw ReferenceCanonicalSendError.persistenceUnavailable
        }
        onSessionChange(persistedDraft, items.filter {
            !pendingIndependentMessageIDs.contains($0.id)
        }, activityLedger, activityVisibility)
        try onReferenceStateChange(persistedDraft, referenceState)
        lastReferenceCheckpoint = (Data(persistedDraft.utf8), referenceState)
        hasDirtyPersistence = false
    }

    /// Recovery uses only authenticated existing history/platform_message_id or
    /// an already accepted local receipt. No provider fetch and no resubmission.
    @discardableResult
    func reconcileReferenceSubmission(
        owner: ReferenceHubOwner,
        remainsOwned: @MainActor () -> Bool
    ) -> ReferenceCanonicalSendOutcome {
        guard !referenceOwnerRetired, !referenceSendInFlight, remainsOwned(),
              let referenceOwner, ReferenceCanonicalOwner(referenceOwner).matches(owner),
              let submission = referenceSubmission, submission.owner.matches(owner) else {
            return .superseded
        }
        guard submission.frozenDraft != nil else { return .indeterminate }
        if submission.phase == .rejected {
            referenceSubmission = nil
            do {
                try persistReferenceStateNow()
                failureMessage = "The reference message was rejected. Your draft is unchanged."
                return .rejected
            } catch {
                referenceSubmission = submission
                return .indeterminate
            }
        }
        guard submission.phase == .accepted
                || ReferenceCanonicalHistory.matchingHuman(in: sourceSession?.items ?? [],
                    submission: submission) != nil else { return .indeterminate }
        finishReferenceAcceptance(submission)
        return .accepted
    }

    private func finishReferenceAcceptance(_ submission: ReferenceCanonicalSubmission) {
        guard referenceSubmission?.submissionID == submission.submissionID else { return }
        if !items.contains(where: {
            $0.id == submission.message.messageID || $0.metadata.platformMessageID == submission.message.messageID
        }) {
            let human = TimelineItem(id: submission.message.messageID, role: .human,
                sender: .user(snapshot: currentUserSnapshot), content: .message(submission.message.text),
                metadata: TimelineMetadata(delivery: "Accepted", timestamp: Date(timeIntervalSince1970:
                    TimeInterval(submission.message.sentAt)), sourceOrder: takeTranscriptOrder(),
                    platformMessageID: submission.message.messageID), attachments: submission.attachments)
            appendItem(human)
            appendProjectedMessage(human)
        }
        let oldDraft = draft
        let oldCanonical = referenceCanonicalSource
        let oldSelections = referenceSelections
        let oldAttachments = draftAttachments
        let oldOrderedAttachments = orderedDraftAttachments
        let oldDraftID = referenceDraftID
        let oldRevision = referenceDraftRevision
        let matchesDraft = referenceDraftID == submission.draftID
            && referenceDraftRevision == submission.revision
            && Data(canonicalReferenceDraft.utf8) == Data(submission.message.text.utf8)
            && draftAttachments == submission.attachments
            && orderedDraftAttachments == submission.attachments.map(ChatDraftAttachment.attachment)
        isReplacingReferenceDraft = true
        if matchesDraft {
            draft = ""
            referenceCanonicalSource = nil
            referenceSelections = []
            draftAttachments = []
            orderedDraftAttachments = []
            referenceDraftID = nil
            referenceDraftRevision = nil
        }
        referenceSubmission = nil
        isReplacingReferenceDraft = false
        do {
            try persistReferenceStateNow()
            failureMessage = nil
        } catch {
            // Receipt is known, but durable cleanup is not. Never resend it.
            isReplacingReferenceDraft = true
            draft = oldDraft
            referenceCanonicalSource = oldCanonical
            referenceSelections = oldSelections
            draftAttachments = oldAttachments
            orderedDraftAttachments = oldOrderedAttachments
            referenceDraftID = oldDraftID
            referenceDraftRevision = oldRevision
            var accepted = submission
            accepted.phase = .accepted
            referenceSubmission = accepted
            isReplacingReferenceDraft = false
            failureMessage = "The message was accepted, but local cleanup could not be saved. Do not send it again."
        }
    }

    func persistSession() {
        guard !referenceOwnerRetired, !isReplacingReferenceDraft else { return }
        hasDirtyPersistence = true
        guard persistenceCheckpointTask == nil else { return }
        let delay = persistenceCheckpointDelay
        persistenceCheckpointTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            self?.persistenceCheckpointTask = nil
            self?.flushPersistence()
        }
    }

    func flushPersistence() {
        persistenceCheckpointTask?.cancel()
        persistenceCheckpointTask = nil
        guard !referenceOwnerRetired else { return }
        guard hasDirtyPersistence else { return }
        hasDirtyPersistence = false
        let acceptedItems = pendingIndependentMessageIDs.isEmpty
            ? items
            : items.filter { !pendingIndependentMessageIDs.contains($0.id) }
        let savedDraft = persistedDraft
        onSessionChange?(savedDraft, acceptedItems, activityLedger, activityVisibility)
        if referencePersistenceNeeded, let onReferenceStateChange, !referenceOwnerRetired {
            let draftBytes = Data(savedDraft.utf8)
            let state = referenceState
            guard lastReferenceCheckpoint?.draft != draftBytes
                    || lastReferenceCheckpoint?.state != state else { return }
            do {
                try onReferenceStateChange(savedDraft, state)
                lastReferenceCheckpoint = (draftBytes, state)
            } catch {
                hasDirtyPersistence = true
                failureMessage = "The reference draft could not be saved. It has not been discarded."
            }
        }
    }
}
