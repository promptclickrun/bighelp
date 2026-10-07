import Foundation

extension ChatModel {
    var retainedUnsentSubmissions: [DirectHermesDraftStore.Submission] {
        guard !referenceOwnerRetired, let native = nativeConversationClient,
              native.model === self else { return [] }
        return native.journal.unresolved.filter { $0.rejectionCode != nil }
    }

    func submitWithoutWaiting(
        message: String,
        attachments: [ChatAttachment]
    ) async throws {
        guard !referenceOwnerRetired, referenceSubmission == nil, !referenceSendInFlight,
              !ReferenceCodec.decode(message).hasValidAppendix else {
            throw ReferenceCanonicalSendError.unavailable
        }
        guard !isSending else { throw ChatQueuedSubmissionError.busy }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ChatQueuedSubmissionError.invalidMessage }
        guard let queuedClient = client as? any QueuedConversationClient else {
            throw ChatQueuedSubmissionError.unavailable
        }

        isSending = true
        defer { isSending = false }
        try await queuedClient.submit(
            message: message,
            attachments: attachments,
            conversationID: conversationID
        )
        let human = humanItem(content: message, attachments: attachments)
        appendItem(human)
        appendProjectedMessage(human)
        persistSession()
        flushPersistence()
    }


    var hasPendingIndependentMessageSubmission: Bool {
        !pendingIndependentMessageIDs.isEmpty
    }


    func send() async {
        // While a turn runs, this chat's own prompt counts as pending until the
        // turn ends, so "ready for a new turn" is false. A plain Send then steers
        // (or queues) through sendMidSession, which has its own checks.
        guard permitsOrdinaryComposerSend, isBotMode || directTransportIsReady || isMidSessionTurnLive else { return }
        guard !isBotMode || botModeExecutionEnabled else {
            failureMessage = "Group chats are unavailable for this Hermes connection."
            return
        }
        if orderedDraftAttachments.isEmpty,
           let argument = DirectHermesGoalControlProjection.argument(from: draft),
           let action = DirectHermesGoalControlProjection.controlAction(for: argument),
           nativeConversationClient != nil {
            let submitted = draft
            if await applyNativeGoalControl(action), draft == submitted {
                draft = ""
                flushPersistence()
            }
            return
        }
        if isSending,
           orderedDraftAttachments.isEmpty,
           DirectHermesGoalControlProjection.argument(from: draft) != nil {
            failureMessage = "Pause, resume, clear, or unwait the current goal while Hermes is working. Set or inspect a goal after this turn finishes."
            return
        }
        if isBotMode, acceptsBotModeFollowUp {
            await sendBotModeFollowUp()
            return
        }
        if isSending {
            await sendMidSession(using: defaultMidSessionBehavior)
            return
        }
        await send(ChatOutgoingMessage(composerOf: self))
    }

    /// Whether a card's answer can go out now. Unlike Send, it doesn't look at
    /// the draft: the answer is its own message and leaves the draft alone.
    var canSendCardReply: Bool {
        if !isBotMode {
            if isSending, let native = nativeConversationClient {
                guard native.hasAuthoritativeEventCoverage, native.preparingAttachmentID == nil,
                      native.sessionActionsAreRunning else { return false }
            } else if !isSending {
                guard directTransportIsReady else { return false }
            } else {
                guard supportsMidSessionSending else { return false }
            }
        }
        guard !isAwaitingAuthoritativeSessionAllocation, !isBotMode || botModeExecutionEnabled,
              botModeRoom?.isRunning != true, botModeRoom?.nativePendingEventID == nil,
              !hasNativeBotModeRetryActions, botModeRoom?.nativeRetryJournal == nil,
              botModeRoom?.nativePendingCancelID == nil,
              !referenceOwnerRetired, referenceSubmission == nil, !referenceSendInFlight,
              !hasExclusiveMidSessionSubmission, !isPDFDraftSendInFlight else { return false }
        return !isSending || isMidSessionTurnLive
    }

    /// Whether `sendCardReply` would send this text now.
    func acceptsCardReply(_ text: String) -> Bool {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !reply.isEmpty && !reply.hasPrefix("/")
            && reply.utf8.count <= ChatOutgoingMessage.maximumCardReplyBytes && canSendCardReply
    }

    /// Sends a card's answer (a form's values, a picked option) to the agent as
    /// the person's next message, steering a running turn like Send does.
    /// Whatever they were typing stays in the composer. Text that starts with
    /// "/" would run as a command, so it isn't sent this way.
    @discardableResult
    func sendCardReply(_ text: String) async -> Bool {
        guard acceptsCardReply(text) else { return false }
        let outgoing = ChatOutgoingMessage(cardReply: text.trimmingCharacters(in: .whitespacesAndNewlines))
        if isSending {
            await sendMidSession(outgoing, using: midSessionBehavior())
        } else {
            await send(outgoing)
        }
        return true
    }

    private func send(_ outgoing: ChatOutgoingMessage) async {
        let message = outgoing.message
        let slashSelection = outgoing.slashSelection
        let nativeAdmissionIDs = Set(nativeConversationClient?.journal.unresolved.map(\.id) ?? [])
        let attachments = outgoing.attachments
        let orderedAttachments = outgoing.orderedAttachments
        let restoresDraft = outgoing.isComposerDraft
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !orderedAttachments.isEmpty else { return }
        if orderedAttachments.contains(where: { $0.pdfSelection != nil }) {
            await sendPDFDraft(
                message: message,
                ordinaryAttachments: attachments,
                orderedAttachments: orderedAttachments,
                midSessionBehavior: nil
            )
            return
        }
        guard orderedAttachments == attachments.map(ChatDraftAttachment.attachment) else {
            failureMessage = "The attachment draft changed. Review it before sending."
            return
        }
        do { try validateAttachmentSupport(attachments) }
        catch { failureMessage = error.localizedDescription; return }
        if isBotMode, !attachments.isEmpty {
            failureMessage = "This Hermes room accepts text only. Remove the attachments before sending."
            return
        }

        isSending = true
        let generation = beginOwnerGeneration()
        hasLocallyPendingPrimaryTurn = true
        failureMessage = nil
        retryRequest = nil
        let isBotModeConversation = if let roomID = botModeRoomID, let botModeRoomStore {
            botModeRoomStore.room(id: roomID) != nil
        } else {
            false
        }
        let priorBotModeEventIDs: Set<String> = if let roomID = botModeRoomID, let botModeRoomStore {
            Set(botModeRoomStore.room(id: roomID)?.visibleEvents.map(\.id) ?? [])
        } else {
            []
        }
        var localHumanID: String?
        if !isBotModeConversation {
            appendItem(humanItem(content: message, attachments: attachments))
            if let item = items.last {
                localHumanID = item.id
                appendProjectedMessage(item)
            }
        }
        if restoresDraft {
            draft = ""
            replyDraft = nil
            draftAttachments = []
            orderedDraftAttachments = []
        }

        if let roomID = botModeRoomID,
           let botModeRoomStore,
           botModeRoomStore.room(id: roomID) != nil {
            do {
                try await botModeRoomStore.send(
                    text: message,
                    roomID: roomID,
                    senderSnapshot: currentUserSnapshot,
                    activitySink: { [weak self] activity in
                        self?.acceptBotModeActivity(activity)
                    }
                )
                guard isCurrentOwner(generation) else { return }
                if botModeRoomStore.room(id: roomID)?.memberFailures.isEmpty == false {
                    failureMessage = hasRetryableBotModeFailures
                        ? "Some agents could not respond. Retry the failed agents."
                        : "Some agents could not respond. You can send a new message."
                    retryRequest = hasRetryableBotModeFailures ? .botModeRetry(roomID) : nil
                }
            } catch is CancellationError {
                guard isCurrentOwner(generation) else { return }
                isSending = botModeRoomStore.room(id: roomID)?.isRunning == true
                return
            } catch let error as MentionError {
                guard isCurrentOwner(generation) else { return }
                if restoresDraft { presentMentionError(error, restoring: message) }
                else { failureMessage = mentionErrorMessage(error) }
            } catch let error as BotModeRoomError where error == .nativeTurnTimedOut {
                guard isCurrentOwner(generation) else { return }
                // A quiet or disconnected poll is not a failed server task.
                failureMessage = nil
                retryRequest = nil
            } catch {
                guard isCurrentOwner(generation) else { return }
                failureMessage = "Message could not be delivered. Try again."
                let currentRoom = botModeRoomStore.room(id: roomID)
                let accepted = currentRoom?.nativePendingDiscussionEventID != nil
                    || (currentRoom?.hasNativeRoom != true && currentRoom?.visibleEvents.contains {
                        $0.kind == .human && !priorBotModeEventIDs.contains($0.id)
                    } == true)
                if accepted {
                    failureMessage = "Hermes accepted the message. The room is being reconciled; do not send it again."
                    retryRequest = hasRetryableBotModeFailures ? .botModeRetry(roomID) : nil
                } else {
                    if currentRoom?.nativePendingEventID != nil {
                        failureMessage = "Delivery is unconfirmed. Recovery will use this same message identity."
                    }
                    if restoresDraft, draft.isEmpty { draft = message }
                    retryRequest = .botModeSend(message, roomID)
                }
                rememberNativeBotModeSendRecovery(message: message, roomID: roomID)
            }
            guard isCurrentOwner(generation) else { return }
            isSending = botModeRoomStore.room(id: roomID)?.isRunning == true
            if !isSending { settleTaskDrawerAfterTurn() }
            flushPersistence()
            return
        }

        await sleeper.sleep()
        guard isCurrentOwner(generation) else {
            if let native = client as? DirectHermesConversationClient {
                // No RPC has begun. An external native start may have superseded
                // the local presentation during the delay: retain unsent intent,
                // not an invented accepted human row beside that server turn.
                // A card's answer isn't composer text: drop its row, keep the draft.
                if !restoresDraft || draft.isEmpty {
                    if restoresDraft {
                        draft = message
                        draftAttachments = attachments
                        orderedDraftAttachments = orderedAttachments
                    }
                    if let localHumanID {
                        removeItem(id: localHumanID)
                        removeProjectedMessage(id: localHumanID)
                        native.retainVisibleState()
                    }
                }
            }
            return
        }

        do {
            let response = try await sendThroughClient(
                message,
                attachments: attachments,
                slashSelection: slashSelection,
                ownerGeneration: generation
            )
            guard isCurrentOwner(generation) else { return }
            try appendValidated(response.items)
            if attachments.isEmpty,
               DirectHermesGoalControlProjection.argument(from: message) != nil {
                await refreshNativeGoalControl(reportFailure: true)
            }
        } catch is ResponseIdentityError {
            guard isCurrentOwner(generation) else { return }
            if attachments.isEmpty,
               DirectHermesGoalControlProjection.argument(from: message) != nil {
                retainGoalCommandDraftAfterFailure(message)
                failureMessage = "The goal response conflicted with this conversation. Reopen the chat before trying again."
                retryRequest = nil
            } else {
                failureMessage = "Response identities conflict with this conversation. Try once more."
                retryRequest = .send(message, attachments)
            }
        } catch {
            guard isCurrentOwner(generation) else { return }
            if attachments.isEmpty,
               DirectHermesGoalControlProjection.argument(from: message) != nil {
                retainGoalCommandDraftAfterFailure(message)
                failureMessage = goalCommandFailureMessage(error)
                retryRequest = nil
            } else if error is DirectHermesConversationClient.RejectedCommand {
                if restoresDraft, draft.isEmpty { draft = message }
                if let localHumanID {
                    removeItem(id: localHumanID)
                    removeProjectedMessage(id: localHumanID)
                    nativeConversationClient?.retainVisibleState()
                }
                failureMessage = "Hermes did not run this command. Your text is ready to edit."
                retryRequest = nil
            } else if let refusal = error as? DirectHermesConversationClient.RejectedPrompt {
                restoreRefusedPrompt(refusal, humanID: localHumanID, message: message,
                                     attachments: attachments, orderedAttachments: orderedAttachments,
                                     restoresDraft: restoresDraft)
            } else if nativeConversationClient != nil,
                      nativeConversationClient?.needsRecovery == true
                        || (error as? DirectHermesError)?.outcomeIsUnknown == true
                        || nativeConversationClient?.journal.unresolved.contains(where: {
                            !nativeAdmissionIDs.contains($0.id)
                        }) == true {
                failureMessage = "\(message.hasPrefix("/") ? "Command" : "Message") delivery is unconfirmed. It will not be sent again automatically."
                retryRequest = nil
            } else if let refused = error as? ChatAttachmentError, let reason = refused.errorDescription {
                // Nothing was sent: say why, instead of a delivery failure.
                failureMessage = reason
                retryRequest = .send(message, attachments)
            } else {
                failureMessage = "Message could not be delivered. Try again."
                retryRequest = .send(message, attachments)
            }
        }

        guard isCurrentOwner(generation) else { return }
        settleTaskDrawerAfterTurn()
        isSending = false
        flushPersistence()
    }

    func stop() async {
        guard canStop else { return }
        if let roomID = botModeRoomID, let botModeRoomStore {
            let generation = ownerGeneration
            isStopping = true
            failureMessage = nil
            do {
                try await botModeRoomStore.stopNativeRoom(roomID: roomID)
                guard isCurrentOwner(generation) else { return }
                _ = beginOwnerGeneration()
                retryRequest = nil
                settleTaskDrawerAfterTurn()
                isSending = false
                flushPersistence()
            } catch is CancellationError {
                guard isCurrentOwner(generation) else { return }
            } catch {
                guard isCurrentOwner(generation) else { return }
                failureMessage = "The active turn could not be stopped. Try again."
            }
            isStopping = false
            return
        }
        guard let stoppableClient = client as? any StoppableConversationClient else { return }
        isStopping = true
        failureMessage = nil
        let stoppingGeneration = ownerGeneration
        do {
            try await stoppableClient.stop(conversationID: conversationID)
            guard isCurrentOwner(stoppingGeneration) else { return }
            if client is DirectHermesConversationClient {
                // Native interrupt is admission only; settled session.info owns
                // completion, including a queued turn racing this receipt.
                return
            }
            _ = beginOwnerGeneration()
            responseHapticsStopped = true
            (client as? any InactiveSessionReconciliationConversationClient)?
                .reconcileInactiveSession(conversationID: conversationID)
            onTurnStopped?()
            retryRequest = nil
            failureMessage = nil
            settleTaskDrawerAfterTurn()
            isSending = false
            flushPersistence()
        } catch {
            guard isCurrentOwner(stoppingGeneration) else { return }
            failureMessage = "The active turn could not be stopped. Try again."
        }
        isStopping = false
    }

    func sendMidSession(using behavior: MidSessionChatBehavior) async {
        guard permitsOrdinaryComposerSend else { return }
        guard allowedMidSessionBehaviors.contains(behavior) else {
            failureMessage = "Attachments can be queued after this turn. Your draft is unchanged."
            return
        }
        await sendMidSession(ChatOutgoingMessage(composerOf: self), using: behavior)
    }

    private func sendMidSession(_ outgoing: ChatOutgoingMessage, using behavior: MidSessionChatBehavior) async {
        guard isMidSessionTurnLive,
              !hasExclusiveMidSessionSubmission,
              let midSessionClient = client as? any MidSessionConversationClient
        else { return }

        let message = outgoing.message
        let attachments = outgoing.attachments
        let orderedAttachments = outgoing.orderedAttachments
        let restoresDraft = outgoing.isComposerDraft
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !orderedAttachments.isEmpty else { return }
        if orderedAttachments.contains(where: { $0.pdfSelection != nil }) {
            await sendPDFDraft(
                message: message,
                ordinaryAttachments: attachments,
                orderedAttachments: orderedAttachments,
                midSessionBehavior: behavior
            )
            return
        }
        guard orderedAttachments == attachments.map(ChatDraftAttachment.attachment) else {
            failureMessage = "The attachment draft changed. Review it before sending."
            return
        }
        do { try validateAttachmentSupport(attachments) }
        catch { failureMessage = error.localizedDescription; return }
        let priorGeneration = ownerGeneration
        let native = nativeConversationClient
        let existingNativeSubmissionIDs = Set(native?.journal.unresolved.map(\.id) ?? [])
        let submissionGeneration = behavior == .interruptAndSend
            ? beginOwnerGeneration()
            : priorGeneration
        let human = humanItem(content: message, attachments: attachments)

        pendingMidSessionSubmissions.append(PendingMidSessionSubmission(
            id: human.id,
            behavior: behavior
        ))
        failureMessage = nil
        appendItem(human)
        appendProjectedMessage(human)
        if restoresDraft {
            draft = ""
            replyDraft = nil
            draftAttachments = []
            orderedDraftAttachments = []
        }
        persistSession()

        do {
            let outcome = try await midSessionClient.sendMidSession(
                message: message,
                attachments: attachments,
                conversationID: conversationID,
                behavior: behavior,
                onDraft: { [weak self] item in
                    self?.acceptStreamingDraft(item, ownerGeneration: submissionGeneration)
                }
            )
            guard pendingMidSessionBehavior(for: human.id) == behavior else { return }
            switch outcome {
            case .accepted:
                break
            case .replacement(let response):
                guard isCurrentOwner(submissionGeneration) else { return }
                try appendValidated(response.items)
                settleTaskDrawerAfterTurn()
                isSending = false
            }
            removePendingMidSessionSubmission(id: human.id)
        } catch is ResponseIdentityError {
            guard pendingMidSessionBehavior(for: human.id) == behavior else { return }
            rollbackMidSessionHuman(human, message: message, attachments: attachments, restoresDraft: restoresDraft)
            failureMessage = "Response identities conflict with this conversation. Try once more."
            if behavior == .interruptAndSend { isSending = false }
            removePendingMidSessionSubmission(id: human.id)
        } catch {
            guard pendingMidSessionBehavior(for: human.id) == behavior else { return }
            if let refusal = error as? DirectHermesConversationClient.RejectedPrompt {
                restoreRefusedPrompt(refusal, humanID: human.id, message: message,
                                     attachments: attachments, orderedAttachments: orderedAttachments,
                                     restoresDraft: restoresDraft)
                removePendingMidSessionSubmission(id: human.id)
                return
            }
            let nativeOutcomeUnknown = native.map { client in
                client.needsRecovery
                    || (error as? DirectHermesError)?.outcomeIsUnknown == true
                    || client.journal.unresolved.contains { !existingNativeSubmissionIDs.contains($0.id) }
            } == true
            if nativeOutcomeUnknown {
                // The optimistic row and native journal are the one unresolved
                // intent. Do not restore it as a sendable draft or manufacture
                // a replacement turn after a lost receipt.
                failureMessage = "Message delivery during the active turn is unconfirmed. It will not be sent again automatically."
            } else {
                rollbackMidSessionHuman(human, message: message, attachments: attachments, restoresDraft: restoresDraft)
                if let workspaceError = error as? DirectHermesWorkspaceError,
                   case .midSessionRejected = workspaceError {
                    failureMessage = "Hermes could not steer this turn. Your message is still available to edit or queue."
                } else if native != nil {
                    failureMessage = DirectHermesConversationClient.safeMessage(error)
                } else {
                    failureMessage = "Message could not be sent during the active turn. Try again."
                }
                if behavior == .interruptAndSend, native == nil { isSending = false }
            }
            removePendingMidSessionSubmission(id: human.id)
        }
    }

    func perform(_ action: QuickAction) async {
        guard canPerformQuickAction else { return }

        isSending = true
        let generation = beginOwnerGeneration()
        failureMessage = nil
        retryRequest = nil
        let human = humanItem(content: action.intent)
        appendItem(human)
        appendProjectedMessage(human)
        persistSession()

        await sleeper.sleep()
        guard isCurrentOwner(generation) else { return }

        do {
            let response = try await client.perform(action: action, conversationID: conversationID)
            guard isCurrentOwner(generation) else { return }
            try appendValidated(response.items)
        } catch is ResponseIdentityError {
            guard isCurrentOwner(generation) else { return }
            failureMessage = "Response identities conflict with this conversation. Try once more."
            retryRequest = .action(action)
        } catch {
            guard isCurrentOwner(generation) else { return }
            failureMessage = "That action could not be completed. Try again."
            retryRequest = .action(action)
        }

        guard isCurrentOwner(generation) else { return }
        settleTaskDrawerAfterTurn()
        isSending = false
        flushPersistence()
    }

    func retry() async {
        guard canRetry else { return }
        let nativeRetry = hasNativeBotModeRetryActions
            ? botModeRoomID.map(RetryRequest.botModeRetry) : nil
        guard !isSending, let request = nativeRetry ?? retryRequest else { return }

        retryRequest = nil
        failureMessage = nil
        isSending = true
        let generation = beginOwnerGeneration()
        do {
            switch request {
            case .botModeSend(let message, let roomID):
                guard let botModeRoomStore else { throw BotModeRoomError.roomNotFound }
                try await botModeRoomStore.send(
                    text: message,
                    roomID: roomID,
                    activitySink: { [weak self] activity in
                        self?.acceptBotModeActivity(activity)
                    }
                )
                guard isCurrentOwner(generation) else { return }
                draft = ""
                if botModeRoomStore.room(id: roomID)?.memberFailures.isEmpty == false {
                    failureMessage = hasRetryableBotModeFailures
                        ? "Some agents could not respond. Retry the failed agents."
                        : "Some agents could not respond. You can send a new message."
                    retryRequest = hasRetryableBotModeFailures ? .botModeRetry(roomID) : nil
                }
            case .botModeRetry(let roomID):
                guard let botModeRoomStore else { throw BotModeRoomError.roomNotFound }
                try await botModeRoomStore.retry(
                    roomID: roomID,
                    activitySink: { [weak self] activity in
                        self?.acceptBotModeActivity(activity)
                    }
                )
                guard isCurrentOwner(generation) else { return }
                if botModeRoomStore.room(id: roomID)?.memberFailures.isEmpty == false {
                    failureMessage = hasRetryableBotModeFailures
                        ? "Some agents could not respond. Retry the failed agents."
                        : "Some agents could not respond. You can send a new message."
                    retryRequest = hasRetryableBotModeFailures ? .botModeRetry(roomID) : nil
                }
            case .send(let message, let attachments):
                await sleeper.sleep()
                let response = try await sendThroughClient(
                    message,
                    attachments: attachments,
                    ownerGeneration: generation
                )
                guard isCurrentOwner(generation) else { return }
                try appendValidated(response.items)
            case .action(let action):
                await sleeper.sleep()
                guard isCurrentOwner(generation) else { return }
                let response = try await client.perform(action: action, conversationID: conversationID)
                guard isCurrentOwner(generation) else { return }
                try appendValidated(response.items)
            }
        } catch let error as MentionError {
            guard isCurrentOwner(generation) else { return }
            if case .botModeSend(let message, _) = request {
                presentMentionError(error, restoring: message)
            } else {
                retryRequest = nil
                failureMessage = mentionErrorMessage(error)
            }
        } catch is ResponseIdentityError {
            guard isCurrentOwner(generation) else { return }
            failureMessage = "Response identities still conflict with this conversation."
        } catch {
            guard isCurrentOwner(generation) else { return }
            switch request {
            case .botModeSend(let message, let roomID):
                draft = message
                retryRequest = .botModeSend(message, roomID)
                failureMessage = "Message could not be delivered. Try again."
                rememberNativeBotModeSendRecovery(message: message, roomID: roomID)
            case .botModeRetry(let roomID):
                retryRequest = .botModeRetry(roomID)
                failureMessage = "Some agents could not respond. Retry the failed agents."
            default:
                failureMessage = "That action is still unavailable."
            }
        }

        guard isCurrentOwner(generation) else { return }
        settleTaskDrawerAfterTurn()
        isSending = false
    }

    func sendThroughClient(
        _ message: String,
        attachments: [ChatAttachment] = [],
        slashSelection: SlashCommandSelection? = nil,
        ownerGeneration: Int
    ) async throws -> ConversationResponse {
        try validateAttachmentSupport(attachments)
        if attachments.isEmpty, let slashSelection, let native = nativeConversationClient {
            return try await native.sendCommand(message: message, selection: slashSelection,
                conversationID: conversationID, onDraft: { [weak self] item in
                    self?.acceptStreamingDraft(item, ownerGeneration: ownerGeneration)
                })
        }
        if let attachmentClient = client as? any AttachmentConversationClient {
            return try await attachmentClient.send(
                message: message,
                attachments: attachments,
                conversationID: conversationID,
                onDraft: { [weak self] item in
                    self?.acceptStreamingDraft(item, ownerGeneration: ownerGeneration)
                }
            )
        }
        guard let streaming = client as? any StreamingConversationClient else {
            return try await client.send(message: message, conversationID: conversationID)
        }
        return try await streaming.send(
            message: message,
            conversationID: conversationID,
            onDraft: { [weak self] item in
                self?.acceptStreamingDraft(item, ownerGeneration: ownerGeneration)
            }
        )
    }

    func acceptStreamingDraft(_ item: TimelineItem, ownerGeneration: Int) {
        guard
            isCurrentOwner(ownerGeneration),
            item.role == .assistant,
            senderBelongsToThisSession(item)
        else { return }
        lastItemMutationWorkCount = 0
        let previous = itemIndexByID[item.id].map { items[$0] }
        if let index = itemIndex(id: item.id) {
            guard canUpdateStreamingItem(items[index], with: item) else { return }
            replaceItem(at: index, with: item.ordered(
                items[index].metadata.sourceOrder ?? takeTranscriptOrder()
            ))
            lastItemMutationWorkCount += 1
            updateProjectedMessage(items[index])
        } else {
            let item = ordered(item)
            appendItem(item)
            lastItemMutationWorkCount += 1
            appendProjectedMessage(item)
        }
        emitResponseTextGrowth(from: previous, to: item)
        persistSession()
    }

    func emitResponseTextGrowth(from previous: TimelineItem?, to item: TimelineItem) {
        // Dropped presentation events are never recovered from the transcript.
        guard !defersTranscriptPresentation, !isHydratingHistory,
              !isStopping, !responseHapticsStopped, !responseHapticsRetired,
              ResponseHapticsPolicy.isGrowing(from: previous, to: item) else { return }
        responseTextGrowthSubject.send(.init(conversationID: conversationID, messageID: item.id))
    }

    func beginOwnerGeneration() -> Int {
        ownerGeneration += 1
        responseHapticsStopped = false
        return ownerGeneration
    }

    func isCurrentOwner(_ generation: Int) -> Bool {
        generation == ownerGeneration
    }

    private func restoreRefusedPrompt(
        _ refusal: DirectHermesConversationClient.RejectedPrompt,
        humanID: String?, message: String, attachments: [ChatAttachment],
        orderedAttachments: [ChatDraftAttachment], restoresDraft: Bool = true
    ) {
        if restoresDraft, draft.isEmpty, orderedDraftAttachments.isEmpty {
            draft = message
            draftAttachments = attachments
            orderedDraftAttachments = orderedAttachments
        }
        // The protected journal retains A even if a newer composer B prevents
        // restoration. Only A's optimistic presentation is removed.
        if let humanID {
            removeItem(id: humanID)
            removeProjectedMessage(id: humanID)
            nativeConversationClient?.retainVisibleState()
        }
        failureMessage = refusal.code == 4090
            ? "Hermes refused this message because another process owns the session or the host's active-session limit was reached. Your text has been kept; it was not sent again."
            : "This session is no longer attached on Hermes. Reopen it before sending. Your text has been kept; it was not sent again."
        retryRequest = nil
        persistSession()
    }

    private func rollbackMidSessionHuman(
        _ human: TimelineItem,
        message: String,
        attachments: [ChatAttachment],
        restoresDraft: Bool
    ) {
        removeItem(id: human.id)
        removeProjectedMessage(id: human.id)
        if restoresDraft {
            draft = message
            draftAttachments = attachments
            orderedDraftAttachments = attachments.map(ChatDraftAttachment.attachment)
        }
        persistSession()
    }

    func removePendingMidSessionSubmission(id: String) {
        pendingMidSessionSubmissions.removeAll { $0.id == id }
    }

    func humanItem(
        content: String,
        attachments: [ChatAttachment] = []
    ) -> TimelineItem {
        let existingIDs = Set(items.map(\.id))
        while existingIDs.contains("\(conversationID)-human-\(nextHumanSequence)") {
            nextHumanSequence += 1
        }

        defer { nextHumanSequence += 1 }
        return TimelineItem(
            id: "\(conversationID)-human-\(nextHumanSequence)",
            role: .human,
            sender: .user(snapshot: currentUserSnapshot),
            content: .message(content),
            metadata: TimelineMetadata(
                delivery: "Sent just now",
                timestamp: Date(),
                sourceOrder: takeTranscriptOrder()
            ),
            attachments: attachments
        )
    }
}

/// What one send carries: the composer's draft, or a card's answer, which is
/// sent for the person without touching what they're typing.
@MainActor
struct ChatOutgoingMessage {
    /// A long form's answers still fit comfortably in one message.
    static let maximumCardReplyBytes = 8_192

    let message: String
    let attachments: [ChatAttachment]
    let orderedAttachments: [ChatDraftAttachment]
    let slashSelection: SlashCommandSelection?
    /// Only the composer's own text is cleared on send and put back on failure.
    let isComposerDraft: Bool

    init(composerOf model: ChatModel) {
        message = model.outgoingDraftText
        attachments = model.draftAttachments
        orderedAttachments = model.orderedDraftAttachments
        slashSelection = model.activeSlashCommand
        isComposerDraft = true
    }

    init(cardReply: String) {
        message = cardReply
        attachments = []
        orderedAttachments = []
        slashSelection = nil
        isComposerDraft = false
    }
}
