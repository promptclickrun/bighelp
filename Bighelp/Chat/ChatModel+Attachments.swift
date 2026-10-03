import Foundation

extension ChatModel {
    var pdfAttachmentTarget: DirectHermesPDFAttachmentTarget? {
        guard !referenceOwnerRetired, !isBotMode,
              let native = nativeConversationClient else { return nil }
        return native.currentPDFAttachmentTarget
    }

    var pdfPagesAvailability: ChatPDFPagesAttachmentAvailability {
        guard !isBotMode, nativeConversationClient != nil else {
            return .unavailable(reason: "PDF pages require a current native Hermes conversation.")
        }
        guard !isPDFDraftSendInFlight else {
            return .unavailable(reason: "Wait for the current PDF-page send to finish.")
        }
        guard pdfAttachmentTarget != nil else {
            return .unavailable(reason: "Reconnect this native conversation before adding PDF pages.")
        }
        return .available
    }

    var hasStalePDFPageSelections: Bool {
        let current = pdfAttachmentTarget
        return orderedDraftAttachments.contains { value in
            guard let selection = value.pdfSelection else { return false }
            return current == nil || selection.target != current
        }
    }

    var currentPDFPageImageReceipts: [DirectHermesPDFPageImageReceipt] {
        guard let current = pdfAttachmentTarget else { return [] }
        return pdfAttachmentReceipts
            .filter { $0.target == current }
            .flatMap(\.pages)
    }

    func addDraftAttachment(_ attachment: ChatAttachment) throws {
        guard !referenceOwnerRetired, !isPDFDraftSendInFlight else { throw CancellationError() }
        guard client is any AttachmentConversationClient else { throw ChatAttachmentError.unsupportedClient }
        guard supportedAttachmentKinds.contains(attachment.kind) else { throw ChatAttachmentError.unsupportedKind }
        guard !orderedDraftAttachments.contains(where: { $0.sourceAttachmentID == attachment.id }) else { return }
        guard orderedDraftAttachments.count < 10,
              orderedDraftAttachments.reduce(attachment.data.count, { $0 + $1.byteCount }) <= 24 * 1_024 * 1_024
        else { throw ChatAttachmentError.invalidSize }
        draftAttachments.append(attachment)
        orderedDraftAttachments.append(.attachment(attachment))
        referenceDraftID = nil
        referenceDraftRevision = nil
    }

    func addPDFPageSelection(_ selection: DirectHermesPDFPageSelection) throws {
        guard !referenceOwnerRetired, !isPDFDraftSendInFlight else { throw CancellationError() }
        guard let current = pdfAttachmentTarget, current == selection.target else {
            throw DirectHermesPDFAttachmentError.targetChanged
        }
        guard !orderedDraftAttachments.contains(where: {
            $0.sourceAttachmentID == selection.attachment.id
        }) else { return }
        guard orderedDraftAttachments.count < 10,
              orderedDraftAttachments.reduce(selection.attachment.data.count, { $0 + $1.byteCount })
                <= 24 * 1_024 * 1_024 else {
            throw ChatAttachmentError.invalidSize
        }
        orderedDraftAttachments.append(.pdfPages(selection))
        referenceDraftID = nil
        referenceDraftRevision = nil
    }

    var supportedAttachmentKinds: Set<ChatAttachment.Kind> {
        (client as? any AttachmentConversationClient)?.supportedAttachmentKinds ?? []
    }

    func removeDraftAttachment(id: String) {
        guard !isPDFDraftSendInFlight else { return }
        if draftAttachments.contains(where: { $0.id == id }) {
            referenceDraftID = nil
            referenceDraftRevision = nil
        }
        draftAttachments.removeAll { $0.id == id }
        orderedDraftAttachments.removeAll { $0.sourceAttachmentID == id || $0.id == id }
    }

    func removeOrderedDraftAttachment(id: String) {
        guard !isPDFDraftSendInFlight,
              let value = orderedDraftAttachments.first(where: { $0.id == id }) else { return }
        removeDraftAttachment(id: value.sourceAttachmentID)
    }

    func scheduleGeneratedMediaResolutions() {
        for event in activityLedger.allEvents {
            scheduleGeneratedMediaResolution(for: event)
        }
    }

    func scheduleGeneratedMediaResolution(for event: ChatActivityEvent) {
        guard GeneratedMediaProjection.kind(for: event) != nil,
              event.lifecycle == .succeeded,
              event.generatedMedia == nil || event.generatedMedia?.state == .unavailable else { return }
        let activityID = event.id
        let payload = event.result ?? ""
        guard generatedMediaResolutionTasks[activityID] == nil,
              generatedMediaResolutionAttempts[activityID] != payload else { return }
        guard let generatedMediaResolver,
              let storedID = sourceSession?.remoteStoredID,
              let toolCallID = event.toolCallID else {
            updateGeneratedMedia(
                activityID: activityID,
                resolution: GeneratedMediaResolution(state: .unavailable)
            )
            return
        }

        let generation = generatedMediaResolutionGeneration
        generatedMediaResolutionAttempts[activityID] = payload
        let expectedSessionID = event.sessionID
        let expectedTurnID = event.turnID
        let expectedAgentID = agentID
        generatedMediaResolutionTasks[activityID] = Task { @MainActor [weak self] in
            defer {
                if self?.generatedMediaResolutionGeneration == generation {
                    self?.generatedMediaResolutionTasks[activityID] = nil
                    if let current = self?.activityLedger.event(id: activityID) {
                        self?.scheduleGeneratedMediaResolution(for: current)
                    }
                }
            }
            let resolution: GeneratedMediaResolution
            do {
                do {
                    resolution = try await generatedMediaResolver.resolve(
                        agentID: expectedAgentID,
                        storedID: storedID,
                        event: event
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try await Task.sleep(for: .milliseconds(500))
                    try Task.checkCancellation()
                    resolution = try await generatedMediaResolver.resolve(
                        agentID: expectedAgentID,
                        storedID: storedID,
                        event: event
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                resolution = GeneratedMediaResolution(state: .unavailable)
            }
            guard let self,
                  self.generatedMediaResolutionGeneration == generation,
                  self.agentID == expectedAgentID,
                  self.sourceSession?.remoteStoredID == storedID,
                  let current = self.activityLedger.event(id: activityID),
                  current.sessionID == expectedSessionID,
                  current.turnID == expectedTurnID,
                  current.toolCallID == toolCallID,
                  current.result == event.result,
                  current.generatedMedia == nil || current.generatedMedia?.state == .unavailable else { return }
            self.updateGeneratedMedia(activityID: activityID, resolution: resolution)
        }
    }

    /// The finished message now carries these cards' pictures; the cards keep
    /// only their labels so each picture shows once.
    func markGeneratedMediaShownInReply(eventIDs: [String]) {
        for id in eventIDs {
            guard var resolution = activityLedger.event(id: id)?.generatedMedia,
                  resolution.state == .ready, !resolution.shownInReply else { continue }
            resolution.shownInReply = true
            updateGeneratedMedia(activityID: id, resolution: resolution)
        }
    }

    private func updateGeneratedMedia(
        activityID: String,
        resolution: GeneratedMediaResolution
    ) {
        guard let event = activityLedger.event(id: activityID),
              GeneratedMediaProjection.kind(for: event) != nil,
              event.lifecycle == .succeeded else { return }
        let updated = event.resolvingGeneratedMedia(resolution)
        guard activityLedger.receive(updated) == .updated,
              let accepted = activityLedger.event(id: activityID) else { return }
        updateProjectedActivity(accepted)
        persistSession()
        flushPersistence()
        // A finished message may be waiting on this card's bytes.
        nativeConversationClient?.scheduleMessageMedia()
    }

    func resetGeneratedMediaResolutions() {
        generatedMediaResolutionGeneration &+= 1
        for task in generatedMediaResolutionTasks.values { task.cancel() }
        generatedMediaResolutionTasks.removeAll()
        generatedMediaResolutionAttempts.removeAll()
    }

    func cancelGeneratedMediaResolutionRequests() {
        resetGeneratedMediaResolutions()
    }

    func sendPDFDraft(
        message: String,
        ordinaryAttachments: [ChatAttachment],
        orderedAttachments: [ChatDraftAttachment],
        midSessionBehavior: MidSessionChatBehavior?
    ) async {
        guard !isPDFDraftSendInFlight,
              let native = nativeConversationClient,
              let target = native.currentPDFAttachmentTarget,
              pdfAttachmentTarget == target,
              orderedAttachments.compactMap(\.pdfSelection).allSatisfy({ $0.target == target }),
              orderedAttachments.compactMap(\.ordinaryAttachment) == ordinaryAttachments else {
            failureMessage = "These PDF pages belong to an earlier Hermes session. Remove them and add the pages again; your message text is unchanged."
            retryRequest = nil
            return
        }
        if let midSessionBehavior, midSessionBehavior != .queued {
            failureMessage = "PDF pages can be queued during an active turn, but cannot steer or replace it. Your draft is unchanged."
            retryRequest = nil
            return
        }

        let startsPrimaryTurn = midSessionBehavior == nil
        let submissionGeneration = startsPrimaryTurn ? beginOwnerGeneration() : ownerGeneration
        let human = humanItem(content: message, attachments: ordinaryAttachments)
        isPDFDraftSendInFlight = true
        failureMessage = nil
        retryRequest = nil
        if startsPrimaryTurn {
            isSending = true
            hasLocallyPendingPrimaryTurn = true
        } else {
            pendingMidSessionSubmissions.append(.init(id: human.id, behavior: .queued))
        }
        appendItem(human)
        appendProjectedMessage(human)
        persistSession()

        defer {
            isPDFDraftSendInFlight = false
            removePendingMidSessionSubmission(id: human.id)
            if startsPrimaryTurn, nativeConversationClient === native {
                isSending = native.sessionActionsAreRunning
                if !isSending { settleTaskDrawerAfterTurn() }
            }
            flushPersistence()
        }

        if startsPrimaryTurn {
            await sleeper.sleep()
            guard isCurrentOwner(submissionGeneration), nativeConversationClient === native,
                  native.currentPDFAttachmentTarget == target else {
                removeItem(id: human.id)
                removeProjectedMessage(id: human.id)
                failureMessage = "The Hermes session changed before sending. Remove and re-add the PDF pages; your message text is unchanged."
                return
            }
        }

        do {
            let receipt = try await native.sendDraftAttachments(
                message: message,
                draftAttachments: orderedAttachments,
                conversationID: conversationID,
                queued: midSessionBehavior == .queued,
                onDraft: { [weak self] item in
                    self?.acceptStreamingDraft(item, ownerGeneration: submissionGeneration)
                }
            )
            guard nativeConversationClient === native,
                  native.currentPDFAttachmentTarget == target,
                  receipt.pdfAttachments.allSatisfy({ $0.target == target }) else {
                failureMessage = "Hermes accepted work for the earlier session. The local PDF draft is retained and must not be sent again."
                retryRequest = nil
                return
            }
            try appendValidated(receipt.response.items)
            pdfAttachmentReceipts = receipt.pdfAttachments
            if Data(outgoingDraftText.utf8) == Data(message.utf8),
               draftAttachments == ordinaryAttachments,
               orderedDraftAttachments == orderedAttachments {
                draft = ""
                replyDraft = nil
                draftAttachments = []
                orderedDraftAttachments = []
            }
            failureMessage = nil
            retryRequest = nil
        } catch is ResponseIdentityError {
            failureMessage = "Hermes may have accepted these PDF pages, but the response identity was not valid. The draft is retained and will not be retried."
            retryRequest = nil
        } catch {
            if native.currentPDFAttachmentTarget != target {
                failureMessage = "The Hermes session changed while attaching PDF pages. Your text and selections are retained as stale and will not be retried."
            } else {
                failureMessage = "PDF-page delivery is unconfirmed. Your exact draft is retained for review and will not be retried."
            }
            retryRequest = nil
        }
    }

    func validateAttachmentSupport(_ attachments: [ChatAttachment]) throws {
        guard !attachments.isEmpty else { return }
        guard let attachmentClient = client as? any AttachmentConversationClient else {
            throw ChatAttachmentError.unsupportedClient
        }
        guard attachments.allSatisfy({ attachmentClient.supportedAttachmentKinds.contains($0.kind) }) else {
            throw ChatAttachmentError.unsupportedKind
        }
    }
}
