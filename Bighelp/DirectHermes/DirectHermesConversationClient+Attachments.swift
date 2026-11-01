import Foundation

/// Whole-batch attachment validation, serial staging and retained upload intent.
extension DirectHermesConversationClient {
    func send(message: String, attachments: [ChatAttachment], conversationID: String,
              onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        if attachments.isEmpty {
            return try await send(message: message, conversationID: conversationID, onDraft: onDraft)
        }
        return try await sendFiles(message: message, attachments: attachments, conversationID: conversationID,
                                   queued: false, onDraft: onDraft)
    }

    /// Stages one mixed composer draft in its exact insertion order and submits
    /// the prompt only after every ordinary attachment and PDF-page selection
    /// has a validated receipt. The durable submission journal is written before
    /// the first staging mutation and no uncertain operation is repeated here.
    func sendDraftAttachments(
        message: String,
        draftAttachments: [ChatDraftAttachment],
        conversationID: String,
        queued: Bool,
        onBigFileProgress: @escaping @MainActor (String, BigFileUploader.Progress) -> Void = { _, _ in },
        onAccepted: @escaping @MainActor (String) -> Void = { _ in },
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> DirectHermesDraftAttachmentSendReceipt {
        try Task.checkCancellation()
        try validate(conversationID)
        guard !needsRecovery, preparingAttachmentID == nil,
              queued || (waiter == nil && !projection.running) else {
            throw DirectHermesWorkspaceError.reviewRequired
        }
        guard !draftAttachments.isEmpty,
              draftAttachments.contains(where: { $0.pdfSelection != nil || $0.bigFile != nil }),
              draftAttachments.count <= 10,
              Set(draftAttachments.map(\.sourceAttachmentID)).count == draftAttachments.count,
              message.utf8.count <= 1_048_576 else {
            throw DirectHermesError.messageTooLarge
        }
        let totalBytes = draftAttachments.reduce(into: 0) { total, value in
            let sum = total.addingReportingOverflow(value.byteCount)
            total = sum.overflow ? Int.max : sum.partialValue
        }
        guard totalBytes <= DirectHermesFileAttachments.maximumBatchBytes else {
            throw ChatAttachmentError.invalidSize
        }
        let ordinaryAttachments = draftAttachments.compactMap(\.ordinaryAttachment)
        if !ordinaryAttachments.isEmpty {
            try DirectHermesAttachmentClient.validate(ordinaryAttachments, message: message)
        }
        guard let target = currentPDFAttachmentTarget,
              draftAttachments.compactMap(\.pdfSelection).allSatisfy({ $0.target == target }) else {
            throw DirectHermesPDFAttachmentError.targetChanged
        }

        let owner = generation
        let entry = try recordSubmission(message, method: "pdf.attach", attachments: ordinaryAttachments)
        preparingAttachmentID = entry.id
        var didStartStaging = false
        defer { if preparingAttachmentID == entry.id { preparingAttachmentID = nil } }
        do {
            var references: [String] = []
            var pdfReceipts: [DirectHermesPDFAttachmentReceipt] = []
            let uploader = DirectHermesAttachmentClient(
                rpc: rpc,
                currentPDFTarget: { [weak self] in self?.currentPDFAttachmentTarget }
            )
            for value in draftAttachments {
                try Task.checkCancellation()
                guard connected, owner == generation,
                      currentPDFAttachmentTarget == target else {
                    throw DirectHermesError.notConnected
                }
                didStartStaging = true
                switch value {
                case .attachment(let attachment):
                    let receipt = try await uploader.upload(
                        attachment,
                        runtimeID: target.runtimeID,
                        owner: target.owner
                    )
                    if let reference = receipt.referenceText { references.append(reference) }
                    _ = try replaceSubmission(
                        entry,
                        text: ([message] + references).filter { !$0.isEmpty }.joined(separator: "\n"),
                        method: attachment.kind == .file ? "file.attach" : "image.attach_bytes"
                    )
                case .bigFile(let file):
                    references += try await attachBigFile(file, runtimeID: target.runtimeID, owner: owner,
                                                          onProgress: onBigFileProgress)
                    _ = try replaceSubmission(
                        entry,
                        text: ([message] + references).filter { !$0.isEmpty }.joined(separator: "\n"),
                        method: "file.attach"
                    )
                case .pdfPages(let selection):
                    let receipt = try await uploader.attachPDFPages(selection)
                    guard receipt.target == target else { throw DirectHermesError.invalidResponse }
                    pdfReceipts.append(receipt)
                    _ = try replaceSubmission(
                        entry,
                        text: ([message] + references).filter { !$0.isEmpty }.joined(separator: "\n"),
                        method: "pdf.attach"
                    )
                }
                try Task.checkCancellation()
            }

            let text = ([message] + references).filter { !$0.isEmpty }.joined(separator: "\n")
            let submission = try replaceSubmission(entry, text: text, method: "prompt.submit")
            if needsRecovery, journal.unresolved.allSatisfy({ $0.id == entry.id }) {
                needsRecovery = false
            }
            onSubmissionAdmitted = { onAccepted(text) }
            defer { onSubmissionAdmitted = nil }
            guard !needsRecovery, currentPDFAttachmentTarget == target else {
                throw DirectHermesWorkspaceError.reviewRequired
            }

            let response: ConversationResponse
            if queued {
                try Task.checkCancellation()
                let accepted = try await rpc.request("prompt.submit", params: [
                    "session_id": .string(target.runtimeID),
                    "text": .string(text),
                    "queued": .boolean(true),
                ])
                guard connected, owner == generation, currentPDFAttachmentTarget == target else {
                    throw DirectHermesError.disconnected(outcomeUnknown: true)
                }
                guard ["queued", "streaming"].contains(accepted.object?["status"]?.string ?? "") else {
                    throw DirectHermesError.invalidResponse
                }
                takeSubmissionAdmitted()
                retireSubmission(entry.id)
                status = "PDF pages, files, and message accepted by Hermes"
                response = ConversationResponse(items: [])
            } else {
                response = try await submit(
                    message: text,
                    conversationID: conversationID,
                    onDraft: onDraft,
                    preparedSubmission: submission
                )
            }
            guard connected, owner == generation, currentPDFAttachmentTarget == target else {
                throw DirectHermesError.disconnected(outcomeUnknown: true)
            }
            return DirectHermesDraftAttachmentSendReceipt(
                response: response,
                pdfAttachments: pdfReceipts,
                submittedText: text
            )
        } catch {
            if owner == generation {
                if !didStartStaging { retireSubmission(entry.id) }
                if journal.unresolved.contains(where: { $0.id == entry.id && $0.rejectionCode == nil }) {
                    needsRecovery = true
                }
                status = Self.safeMessage(error)
            }
            throw error
        }
    }

    /// A file over 8 MB: its pieces go to the plugin (`BigFileUploader`), then Hermes' own
    /// `file.attach` takes the file by its path on the computer, as it does for a file already there,
    /// and gives the `@file:` reference. Hermes tells the agent where it is, never its bytes. A video
    /// adds the app's note on its length. The host's record of the upload goes once Hermes has the file.
    func attachBigFile(_ file: ChatBigFile, runtimeID: String, owner: UUID,
                       onProgress: @escaping @MainActor (String, BigFileUploader.Progress) -> Void) async throws -> [String] {
        guard let bigFileHost else { throw BigFileUploadError(failure: .pluginRequired) }
        let uploader = BigFileUploader(host: bigFileHost)
        let staged = try await uploader.upload(file, agentID: profile) { onProgress(file.id, $0) }
        try Task.checkCancellation()
        guard connected, owner == generation else { throw DirectHermesError.notConnected }
        let response = try await rpc.request("file.attach", params: [
            "session_id": .string(runtimeID), "path": .string(staged.path), "name": .string(file.fileName),
        ])
        guard connected, owner == generation else { throw DirectHermesError.disconnected(outcomeUnknown: true) }
        let reference = try DirectHermesFileAttachments.reference(response, allowsInPlace: true)
        await uploader.discard(staged.uploadID)
        return [reference, file.agentNote]
    }

    func sendFiles(message: String, attachments: [ChatAttachment], conversationID: String,
                           queued: Bool, onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        try Task.checkCancellation()
        try validate(conversationID)
        guard !needsRecovery, preparingAttachmentID == nil,
              queued || (waiter == nil && !projection.running) else { throw DirectHermesWorkspaceError.reviewRequired }
        try DirectHermesAttachmentClient.validate(attachments, message: message)
        let owner = generation
        let entry = try recordSubmission(message, method: "file.attach", attachments: attachments)
        preparingAttachmentID = entry.id
        var didStartUpload = false
        var didDispatchQueuedPrompt = false
        defer { if preparingAttachmentID == entry.id { preparingAttachmentID = nil } }
        do {
            var references: [String] = []
            let uploader = DirectHermesAttachmentClient(rpc: rpc, currentOwner: { [weak self] in
                guard let self, self.connected else { return nil }
                return self.generation
            })
            for attachment in attachments {
                try Task.checkCancellation()
                guard connected, owner == generation else { throw DirectHermesError.notConnected }
                didStartUpload = true
                let receipt = try await uploader.upload(attachment, runtimeID: runtimeID, owner: owner)
                guard connected, owner == generation else { throw DirectHermesError.disconnected(outcomeUnknown: true) }
                if let reference = receipt.referenceText { references.append(reference) }
                _ = try replaceSubmission(
                    entry, text: ([message] + references).filter { !$0.isEmpty }.joined(separator: "\n"),
                    method: "file.attach"
                )
                try Task.checkCancellation()
            }
            let text = ([message] + references).filter { !$0.isEmpty }.joined(separator: "\n")
            try Task.checkCancellation()
            let submission = try replaceSubmission(entry, text: text, method: "prompt.submit")
            if needsRecovery, journal.unresolved.allSatisfy({ $0.id == entry.id }) { needsRecovery = false }
            guard !needsRecovery else { throw DirectHermesWorkspaceError.reviewRequired }
            if queued {
                try Task.checkCancellation()
                didDispatchQueuedPrompt = true
                let receipt = try await rpc.request("prompt.submit", params: [
                    "session_id": .string(runtimeID), "text": .string(text), "queued": .boolean(true)
                ])
                guard owner == generation, connected else { throw DirectHermesError.disconnected(outcomeUnknown: true) }
                guard ["queued", "streaming"].contains(receipt.object?["status"]?.string ?? "") else {
                    throw DirectHermesError.invalidResponse
                }
                retireSubmission(entry.id)
                status = "Files and message accepted by Hermes"
                return ConversationResponse(items: [])
            }
            return try await submit(message: text, conversationID: conversationID, onDraft: onDraft,
                                     preparedSubmission: submission)
        } catch {
            if owner == generation {
                if didDispatchQueuedPrompt, let code = Self.definitePromptRefusalCode(error) {
                    do { try retainRejectedSubmission(entry, code: code) }
                    catch { needsRecovery = true; throw error }
                    status = "Hermes refused this message. Its unsent draft is retained."
                    throw RejectedPrompt(code: code)
                }
                if !didStartUpload { retireSubmission(entry.id) }
                if journal.unresolved.contains(where: { $0.id == entry.id && $0.rejectionCode == nil }) { needsRecovery = true }
                status = Self.safeMessage(error)
            }
            throw error
        }
    }
}
