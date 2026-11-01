import Foundation

/// Files over 8 MB in a message (#721). The message waits outside the transcript while its files
/// go up (`bigFileSends`), so a reread of the history can't drop it. Each file has one look at a time: while it goes up, and
/// if it doesn't, a tile on the message with its progress (or why, with Try again); once
/// Hermes takes the message, the message's text names the file and the chat shows its line
/// on the rail. A reread of the saved history only has that text, so it looks the same.
extension ChatModel {
    /// Whether this chat's computer takes files over 8 MB; it reads the plugin's context if needed.
    func supportsBigFiles() async -> Bool {
        guard !isBotMode, let host = nativeConversationClient?.bigFileHost else { return false }
        return await host.supportsBigFiles()
    }

    func addDraftBigFile(_ file: ChatBigFile) throws {
        guard !referenceOwnerRetired, !isPDFDraftSendInFlight else { throw CancellationError() }
        guard !isBotMode, nativeConversationClient?.bigFileHost != nil else { throw ChatAttachmentError.unsupportedClient }
        guard !orderedDraftAttachments.contains(where: { $0.sourceAttachmentID == file.id }) else { return }
        guard orderedDraftAttachments.count < 10 else { throw ChatAttachmentError.tooMany }
        orderedDraftAttachments.append(.bigFile(file))
        referenceDraftID = nil
        referenceDraftRevision = nil
    }

    /// Sends a message holding files over 8 MB. The message box is free at once: the message
    /// waits in the chat with its tiles while the files go up, and further messages stage behind
    /// it. During a turn it goes after the turn, since its files take a while.
    func sendBigFileDraft(message: String, ordinaryAttachments: [ChatAttachment],
                          orderedAttachments: [ChatDraftAttachment], retrying rowID: String? = nil) async {
        let files = orderedAttachments.compactMap(\.bigFile)
        guard !files.isEmpty else { return }
        guard !isBotMode, let native = nativeConversationClient, native.bigFileHost != nil else {
            failureMessage = BigFileUploads.updatePluginMessage
            retryRequest = nil
            return
        }
        let startsPrimaryTurn = !isSending
        let generation = startsPrimaryTurn ? beginOwnerGeneration() : ownerGeneration
        let human: TimelineItem
        if let rowID, let existing = bigFileSends.first(where: { $0.id == rowID }) {
            human = existing
        } else {
            human = humanItem(content: message, attachments: ordinaryAttachments).carrying(bigFiles: files)
            bigFileSends.append(human)
        }
        if Data(outgoingDraftText.utf8) == Data(message.utf8), orderedDraftAttachments == orderedAttachments {
            draft = ""
            replyDraft = nil
            draftAttachments = []
            orderedDraftAttachments = []
        }
        failureMessage = nil
        retryRequest = nil
        if startsPrimaryTurn {
            isSending = true
            hasLocallyPendingPrimaryTurn = true
        }
        let board = BigFileUploadBoard.shared
        for file in files { board.uploading(file.id, sentBytes: 0, byteCount: file.byteCount) }
        persistSession()
        defer {
            if startsPrimaryTurn, nativeConversationClient === native {
                isSending = native.sessionActionsAreRunning
                if !isSending { settleTaskDrawerAfterTurn() }
            }
            flushPersistence()
        }
        do {
            let receipt = try await native.sendDraftAttachments(
                message: message,
                draftAttachments: orderedAttachments,
                conversationID: conversationID,
                queued: !startsPrimaryTurn,
                onBigFileProgress: { id, progress in
                    board.uploading(id, sentBytes: progress.sentBytes, byteCount: progress.byteCount)
                },
                onAccepted: { [weak self] text in
                    self?.bigFileMessageAccepted(rowID: human.id, text: text, files: files)
                },
                onDraft: { [weak self] item in
                    self?.acceptStreamingDraft(item, ownerGeneration: generation)
                }
            )
            // A turn that answered at once may not have reported its admission first.
            bigFileMessageAccepted(rowID: human.id, text: receipt.submittedText, files: files)
            guard isCurrentOwner(generation) || !startsPrimaryTurn else { return }
            try appendValidated(receipt.response.items)
            if !receipt.pdfAttachments.isEmpty { pdfAttachmentReceipts = receipt.pdfAttachments }
        } catch is CancellationError {
            failBigFiles(files, rowID: human.id, message: message, ordinaryAttachments: ordinaryAttachments,
                         orderedAttachments: orderedAttachments,
                         reason: BigFileUploadFailure.connection.message)
        } catch {
            guard bigFileSends.contains(where: { $0.id == human.id }) else {
                // Hermes already took the message; what failed came after (the turn itself).
                failureMessage = "Message could not be delivered. Try again."
                return
            }
            if startsPrimaryTurn { hasLocallyPendingPrimaryTurn = false }
            let reason = (error as? BigFileUploadError)?.failure.message ?? BigFileUploadFailure(error).message
            failBigFiles(files, rowID: human.id, message: message, ordinaryAttachments: ordinaryAttachments,
                         orderedAttachments: orderedAttachments, reason: reason)
        }
    }

    /// The one change of look: tiles out, the text Hermes took in. The phone's copies go, since
    /// the computer has each file now.
    func bigFileMessageAccepted(rowID: String, text: String, files: [ChatBigFile]) {
        guard !text.isEmpty, let index = bigFileSends.firstIndex(where: { $0.id == rowID }) else { return }
        // It leaves the waiting row and joins the transcript in one step, so it never shows twice.
        let sent = bigFileSends.remove(at: index).sent(as: text).ordered(takeTranscriptOrder())
        appendItem(sent)
        appendProjectedMessage(sent)
        for file in files {
            BigFileUploadBoard.shared.finish(file.id)
            BigFileStore.remove(file)
        }
        persistSession()
    }

    private func failBigFiles(_ files: [ChatBigFile], rowID: String, message: String,
                              ordinaryAttachments: [ChatAttachment], orderedAttachments: [ChatDraftAttachment],
                              reason: String) {
        for file in files {
            BigFileUploadBoard.shared.failed(file.id, message: reason) { [weak self] in
                // The host kept every piece it had, so trying again sends only the rest.
                Task { @MainActor [weak self] in
                    await self?.sendBigFileDraft(message: message, ordinaryAttachments: ordinaryAttachments,
                                                 orderedAttachments: orderedAttachments, retrying: rowID)
                }
            }
        }
    }
}
