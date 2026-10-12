import Foundation

/// Single-owner prompt admission, turn settlement and durable submission journal.
extension DirectHermesConversationClient {
    /// A method-specific stock refusal before prompt admission, not a lost ACK.
    struct RejectedPrompt: Error {
        let code: Int
        /// 4090 because Hermes is at its cap on open chats, not because another process holds this one.
        var reachedSessionLimit = false
        /// The refused submission, kept in the unsent journal.
        var submissionID: UUID?
    }

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        try await send(message: message, conversationID: conversationID, onDraft: { _ in })
    }

    /// The timeline is still driven by the ordinary native reducer. Voice gets
    /// only this submission's verified final segments, without replaying rows.
    func sendForVoice(message: String) async throws -> ConversationResponse {
        guard preparingAttachmentID == nil else { throw DirectHermesWorkspaceError.reviewRequired }
        return try await submit(message: message, conversationID: conversationID, onDraft: { _ in }, voiceReply: true)
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        try await send(message: action.intent, conversationID: conversationID)
    }

    func send(message: String, conversationID: String,
              onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        guard preparingAttachmentID == nil else { throw DirectHermesWorkspaceError.reviewRequired }
        return try await submit(message: message, conversationID: conversationID, onDraft: onDraft)
    }

    func sendCommand(message: String, selection: SlashCommandSelection, conversationID: String,
                     onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        guard preparingAttachmentID == nil else { throw DirectHermesWorkspaceError.reviewRequired }
        guard SlashCommandIndex(commands: [selection.command]).selection(for: message) == selection else {
            throw RejectedCommand()
        }
        return try await submit(message: message, conversationID: conversationID, onDraft: onDraft,
                                commandSelection: selection)
    }

    func submit(message: String, conversationID: String,
                        onDraft: @escaping (TimelineItem) -> Void,
                        preparedSubmission: DirectHermesDraftStore.Submission? = nil,
                        commandSelection: SlashCommandSelection? = nil,
                        voiceReply: Bool = false) async throws -> ConversationResponse {
        try Task.checkCancellation()
        try validate(conversationID)
        guard !needsRecovery, waiter == nil else { throw DirectHermesWorkspaceError.reviewRequired }
        if let admission = rpc as? any DirectHermesAdmissionPreparing {
            try await admission.prepareForAdmission()
        }
        try await awaitHydrationIfNeeded()
        try validate(conversationID)
        guard !needsRecovery, waiter == nil else { throw DirectHermesWorkspaceError.reviewRequired }
        guard !isHydrating, connected else { throw DirectHermesError.notConnected }
        guard !projection.running || preparedSubmission != nil else { throw DirectHermesWorkspaceError.nativeTurnActive }
        let command = preparedSubmission == nil && message.hasPrefix("/")
        let dispatch = command && commandSelection.map { $0.command.source != .core } == true
        let method = command ? (dispatch ? "command.dispatch" : "slash.exec") : "prompt.submit"
        let submission = try preparedSubmission ?? recordSubmission(message, method: method)
        let owner = generation
        returnsVoiceReply = voiceReply
        voiceReplyItems = []
        voiceReplyUnavailable = false
        queuedVoiceAwaitingTurn = false
        pendingID = submission.id
        pendingTurnID = nil
        admissionOverlapped = false
        submissionTurns = []
        settledSubmissionTurns = [:]
        admitted = false
        terminalSeen = false
        turnFailed = false
        pendingTurnFailed = false
        draftSink = onDraft
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    needsRecovery = true
                    pendingID = nil
                    draftSink = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiter = continuation
                Task { [weak self] in
                    guard let self, self.connected, self.generation == owner,
                          self.pendingID == submission.id else { return }
                    var expandedToPrompt = false
                    do {
                        var params = self.sessionParams
                        if dispatch, let commandSelection {
                            params["name"] = .string(commandSelection.command.name)
                            params["arg"] = .string(commandSelection.arguments)
                        } else {
                            params[command ? "command" : "text"] = .string(message)
                        }
                        if voiceReply {
                            params["surface"] = .string("voice-live")
                            // Hermes runs a spoken turn on Settings' Voice Chat model (auxiliary.voice_chat).
                            if !command { params["voice_turn"] = .boolean(true) }
                        }
                        // If another surface wins the idle race, queue rather
                        // than applying the host's default interrupt/redirect.
                        if !command { params["queued"] = .boolean(true) }
                        if method != "slash.exec" {
                            await self.noteSpeaker()
                            guard self.generation == owner, self.pendingID == submission.id else { return }
                        }
                        let result: BighelpJSONValue
                        do {
                            result = try await self.rpc.request(method, params: params)
                        } catch DirectHermesError.rpcRejected(code: 4018, _) where method == "slash.exec" {
                            // Typed text (a Shortcut, or a command typed without the menu) has
                            // no catalog selection. Hermes refuses skills here, before running
                            // anything, and names command.dispatch; its own clients retry there.
                            guard self.generation == owner, self.pendingID == submission.id else { return }
                            try self.replaceSubmission(submission, text: message, method: "command.dispatch")
                            await self.noteSpeaker()
                            guard self.generation == owner, self.pendingID == submission.id else { return }
                            result = try await self.rpc.request(
                                "command.dispatch", params: Self.dispatchParams(typed: message, base: self.sessionParams))
                        }
                        guard self.generation == owner, self.pendingID == submission.id else { return }
                        var response = result.object ?? [:]
                        // The stock dispatcher returns skill/bundle expansion as
                        // a typed send instruction; it has not submitted a turn.
                        // Forward exact bytes only after that definite response.
                        if command, ["skill", "send"].contains(response["type"]?.string ?? ""),
                           let expanded = response["message"]?.string {
                            var submit = self.sessionParams
                            submit["text"] = .string(expanded)
                            submit["queued"] = .boolean(true)
                            expandedToPrompt = true
                            let accepted = try await self.rpc.request("prompt.submit", params: submit)
                            guard self.generation == owner, self.pendingID == submission.id else { return }
                            response = accepted.object ?? [:]
                        }
                        if command, let output = response["output"]?.string,
                           !["streaming", "queued"].contains(response["status"]?.string ?? "") {
                            let row = TimelineItem(id: "command:\(submission.id)", role: .assistant,
                                sender: .agent(id: self.profile, snapshot: .init(name: "Hermes")),
                                content: .message(output), metadata: .init(source: "Direct Hermes", delivery: "Received"))
                            self.model?.acceptExternal([row])
                            self.admitted = true
                            self.terminalSeen = true
                            self.completeSubmissionIfReady()
                        } else if ["queued", "steered", "redirected"].contains(response["status"]?.string ?? "") {
                            // Admission is definite but a queue receipt does not
                            // identify its eventual turn. Ordinary chat returns
                            // immediately because native lifecycle owns its
                            // presentation; voice must retain its waiter until
                            // a native message.start gives us a turn owner.
                            self.status = "Accepted by Hermes"
                            self.admitted = true
                            if self.returnsVoiceReply {
                                self.queuedVoiceAwaitingTurn = self.submissionTurns.isEmpty
                                self.selectPendingTurn()
                                self.completeSubmissionIfReady()
                            } else {
                                self.retireSubmission(submission.id)
                                self.finishAcceptedSubmission()
                            }
                        } else if ["streaming", "ok"].contains(response["status"]?.string ?? "") {
                            if !command || expandedToPrompt, let row = response["user_row_id"]?.integer {
                                self.model?.bindNewestUnsavedMessage(role: .human, toRow: row, from: self)
                            }
                            self.admissionOverlapped = self.submissionTurns.count > 1
                            self.selectPendingTurn()
                            self.admitted = true
                            self.status = "Working"
                            self.completeSubmissionIfReady()
                        } else {
                            throw DirectHermesError.invalidResponse
                        }
                    } catch {
                        guard self.generation == owner, self.pendingID == submission.id else { return }
                        // An explicit RPC rejection proves non-admission. A lost or
                        // malformed receipt does not; no fallback transport or resend.
                        let commandRejected = command && !expandedToPrompt
                            && (error as? DirectHermesError) == .rpcRejected(code: 4018)
                        if !command, let code = Self.definitePromptRefusalCode(error) {
                            do {
                                try self.retainRejectedSubmission(submission, code: code)
                                self.needsRecovery = false
                                self.status = "Hermes refused this message. Its unsent draft is retained."
                                self.finish(throwing: RejectedPrompt(
                                    code: code, reachedSessionLimit: (error as? DirectHermesError) == .activeSessionLimit,
                                    submissionID: submission.id))
                                return
                            } catch {
                                // Keep the previous durable entry when saving
                                // the refusal fails; never retire or resend it.
                                self.needsRecovery = true
                                self.status = "The refusal could not be saved. The original submission is retained."
                                self.finish(throwing: error)
                                return
                            }
                        } else if commandRejected || (!command && Self.isProvenInputRejection(error)) {
                            self.retireSubmission(submission.id)
                            if self.model?.draft.isEmpty == true { self.model?.draft = message }
                            self.needsRecovery = self.journal.unresolved.contains { $0.id == submission.id }
                        } else { self.needsRecovery = true }
                        self.status = Self.safeMessage(error)
                        self.finish(throwing: commandRejected ? RejectedCommand() : error)
                        if !command, self.needsRecovery, self.connected,
                           self.generation == owner, !Task.isCancelled {
                            // Receiving a reply cannot prove a lost admission
                            // receipt. Reuse exact-owner snapshot/replay once to
                            // restore readiness for independent new input. Keep
                            // the original journal untouched; never resubmit it.
                            try? await self.recover(epoch: self.projection.epoch)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == owner, self.pendingID == submission.id else { return }
                self.needsRecovery = true
                self.finish(throwing: DirectHermesError.cancelled(outcomeUnknown: true))
            }
        }
    }

    func stop(conversationID: String) async throws {
        try validate(conversationID)
        let owner = generation
        let result = try await rpc.request("session.interrupt", params: sessionParams)
        guard owner == generation else { throw DirectHermesError.notConnected }
        guard result.object?["status"]?.string == "interrupted" else { throw DirectHermesError.invalidResponse }
        clearConfirmedLegacyPrompts()
        // The interrupt receipt requests cancellation; the settled session.info
        // remains authoritative for the adapter's terminal state and journal.
        status = "Stop requested"
    }

    /// This chat › Compact: Hermes folds the chat's earlier messages into a summary
    /// (`session.compress`), the same chat with a lighter context. The rail shows at once
    /// and follows Hermes' own status; the receipt adds the exact before and after. A
    /// compaction outlasting the request carries on, and its status still ends the rail.
    func compact(conversationID: String) async throws {
        try validate(conversationID)
        let owner = generation
        model?.beginCompaction()
        let receipt: [String: BighelpJSONValue]
        do {
            receipt = try await rpc.request("session.compress", params: sessionParams).object ?? [:]
        } catch DirectHermesError.timedOut {
            return
        } catch {
            if owner == generation { model?.cancelCompaction() }
            throw error
        }
        guard owner == generation else { return }
        switch receipt["status"]?.string {
        case "compressed" where (receipt["removed"]?.integer ?? 1) > 0:
            model?.finishCompaction(tokensBefore: receipt["before_tokens"]?.integer,
                                    tokensAfter: receipt["after_tokens"]?.integer)
        case "pending":
            break
        default:
            // Too little to fold, or Hermes declined (another compaction holds the chat).
            model?.cancelCompaction()
        }
    }

    /// Hermes compacting this chat: "compressing" for one asked for, "compacting" for one
    /// it starts during a turn. Its next status, or the reply carrying on, ends it.
    func trackCompaction(_ event: DirectHermesEvent, status: DirectHermesStatusUpdate?) {
        if let status, ["compressing", "compacting"].contains(status.kind) {
            model?.beginCompaction(status: status.text)
            return
        }
        guard model?.compaction?.phase == .compacting else { return }
        if status != nil || event.type.hasPrefix("message.") || event.type.hasPrefix("tool.")
            || event.type == "thinking.delta" {
            model?.finishCompaction()
        }
    }

    func sendMidSession(message: String, attachments: [ChatAttachment], conversationID: String,
        behavior: MidSessionChatBehavior, onDraft: @escaping (TimelineItem) -> Void) async throws -> MidSessionSubmissionOutcome {
        try Task.checkCancellation()
        try validate(conversationID)
        if !attachments.isEmpty {
            guard behavior == .queued else { throw DirectHermesWorkspaceError.interruptAndSendUnavailable }
            _ = try await sendFiles(message: message, attachments: attachments, conversationID: conversationID,
                                    queued: true, onDraft: onDraft)
            return .accepted
        }
        guard preparingAttachmentID == nil else { throw DirectHermesWorkspaceError.reviewRequired }
        guard !needsRecovery else { throw DirectHermesWorkspaceError.reviewRequired }
        // `session.steer` targets this adapter's observed live turn. A retained
        // catalog active flag is not enough: sending it to an idle runtime gets
        // a definite rejection and must not silently become a queued/new turn.
        guard behavior != .steer || projection.running else {
            throw DirectHermesWorkspaceError.midSessionRejected
        }
        let method = behavior == .steer ? "session.steer" : "prompt.submit"
        if behavior != .steer {
            // A queued or restarted message starts a new turn; say who's sending
            // before anything is recorded, so a dropped connection leaves nothing behind.
            await noteSpeaker()
            guard !needsRecovery, preparingAttachmentID == nil else { throw DirectHermesWorkspaceError.reviewRequired }
        }
        // Persist the intent before either mutation. A lost stop receipt must
        // never advance to sending, and a lost send receipt must never retry.
        let entry = try recordSubmission(message, method: behavior == .interruptAndSend ? "session.interrupt" : method)
        let owner = generation
        var params = sessionParams
        params["text"] = .string(message)
        if behavior != .steer { params["queued"] = .boolean(true) }
        var didDispatchPrompt = false
        do {
            if behavior == .interruptAndSend {
                let stopped = try await rpc.request("session.interrupt", params: sessionParams)
                guard owner == generation else { throw DirectHermesError.disconnected(outcomeUnknown: true) }
                guard stopped.object?["status"]?.string == "interrupted" else { throw DirectHermesError.invalidResponse }
                clearConfirmedLegacyPrompts()
                try Task.checkCancellation()
                // Stop clears the host's old queue. Enqueue only after its
                // acknowledgment, allowing the old turn to settle naturally.
                // This is deliberately not the different redirect operation.
                _ = try replaceSubmission(entry, text: message, method: method)
            }
            didDispatchPrompt = method == "prompt.submit"
            let result = try await rpc.request(method, params: params)
            guard owner == generation else { throw DirectHermesError.disconnected(outcomeUnknown: true) }
            let receiptStatus = result.object?["status"]?.string
            if behavior == .steer {
                if receiptStatus == "rejected" {
                    throw DirectHermesWorkspaceError.midSessionRejected
                }
                // Stock Hermes confirms true steer admission with `queued`.
                // `streaming` belongs to prompt.submit and cannot prove that
                // these bytes were injected into the current turn.
                guard receiptStatus == "queued" else { throw DirectHermesError.invalidResponse }
            } else {
                guard ["queued", "streaming"].contains(receiptStatus ?? "") else {
                    throw DirectHermesError.invalidResponse
                }
            }
            // This journal protects uncertain delivery, not agent consumption.
            // A validated receipt transfers queue ownership to Hermes. Retiring
            // our receipt never resends text or claims the steer was consumed.
            retireSubmission(entry.id)
            status = behavior == .steer ? "Steer accepted by Hermes" : "Queued on Hermes"
            return .accepted
        } catch {
            if owner == generation {
                if didDispatchPrompt, let code = Self.definitePromptRefusalCode(error) {
                    do { try retainRejectedSubmission(entry, code: code) }
                    catch { needsRecovery = true; throw error }
                    status = "Hermes refused this message. Its unsent draft is retained."
                    throw RejectedPrompt(code: code)
                }
                if Self.isProvenInputRejection(error, method: method) { retireSubmission(entry.id) }
                else { needsRecovery = true }
                status = Self.safeMessage(error)
            }
            throw error
        }
    }

    func recordSubmission(_ text: String, method: String,
                          attachments: [ChatAttachment] = []) throws -> DirectHermesDraftStore.Submission {
        let entry = DirectHermesDraftStore.Submission(id: UUID(), text: text, method: method, createdAt: .now,
            composerText: text, attachments: attachments.isEmpty ? nil : attachments)
        var next = journal
        next.unresolved.append(entry)
        try drafts.save(next, scope: scope)
        journal = next
        if let model { projection.retainVisible(items: model.items, activities: model.activityLedger.allEvents) }
        projection.reserveOrder(model?.items.compactMap(\.metadata.sourceOrder).max() ?? 0)
        return entry
    }

    @discardableResult
    func replaceSubmission(_ entry: DirectHermesDraftStore.Submission, text: String,
                                   method: String) throws -> DirectHermesDraftStore.Submission {
        guard let index = journal.unresolved.firstIndex(where: { $0.id == entry.id }) else {
            throw DirectHermesWorkspaceError.reviewRequired
        }
        let submission = DirectHermesDraftStore.Submission(id: entry.id, text: text, method: method,
            createdAt: entry.createdAt, composerText: entry.composerText, attachments: entry.attachments,
            rejectionCode: entry.rejectionCode)
        var updated = journal
        updated.unresolved[index] = submission
        try drafts.save(updated, scope: scope)
        journal = updated
        return submission
    }

    /// Splits a typed command the way Hermes' slash.exec does: the name after
    /// "/", then the rest.
    static func dispatchParams(typed message: String,
                               base: [String: BighelpJSONValue]) -> [String: BighelpJSONValue] {
        let command = message.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "/" }
        let name = command.prefix { !$0.isWhitespace }
        let arg = command.dropFirst(name.count).drop { $0.isWhitespace }
        var params = base
        params["name"] = .string(name.lowercased())
        params["arg"] = .string(String(arg))
        return params
    }

    static func definitePromptRefusalCode(_ error: Error) -> Int? {
        if (error as? DirectHermesError) == .activeSessionLimit { return 4090 }
        guard case .rpcRejected(let code, _) = error as? DirectHermesError,
              [4001, 4007, 4090].contains(code) else { return nil }
        return code
    }

    func retainRejectedSubmission(_ entry: DirectHermesDraftStore.Submission, code: Int) throws {
        if code == 4001 || code == 4007 { requiresDurableReattachment = true }
        guard let index = journal.unresolved.firstIndex(where: { $0.id == entry.id }) else {
            throw DirectHermesWorkspaceError.reviewRequired
        }
        let current = journal.unresolved[index]
        var next = journal
        next.unresolved[index] = .init(id: current.id, text: current.composerText ?? current.text,
            method: current.method, createdAt: current.createdAt, composerText: current.composerText,
            attachments: current.attachments, rejectionCode: code)
        try drafts.save(next, scope: scope)
        journal = next
    }

    func retireSubmission(_ id: UUID) {
        var next = journal
        next.unresolved.removeAll { $0.id == id }
        do { try drafts.save(next, scope: scope); journal = next }
        catch { needsRecovery = true; status = "The retained submission could not be cleared. Review it before sending again." }
    }

    func selectPendingTurn() {
        pendingTurnID = submissionTurns.first
        terminalSeen = pendingTurnID.flatMap { settledSubmissionTurns[$0] } != nil
        pendingTurnFailed = pendingTurnID.flatMap { settledSubmissionTurns[$0] } ?? false
    }

    func completeSubmissionIfReady() {
        guard admitted, terminalSeen, let id = pendingID else { return }
        if !pendingTurnFailed && !admissionOverlapped {
            retireSubmission(id)
        } else { needsRecovery = true }
        let continuation = waiter
        waiter = nil
        pendingID = nil
        queuedVoiceAwaitingTurn = false
        draftSink = nil
        if returnsVoiceReply {
            if pendingTurnFailed || admissionOverlapped || voiceReplyUnavailable {
                continuation?.resume(throwing: WorkspaceClientError.outcomeUnknown)
            } else {
                continuation?.resume(returning: ConversationResponse(items: voiceReplyItems))
            }
            voiceReplyItems = []
        } else {
            // Ordinary chat already receives its deltas through the retained
            // model. Returning them again would duplicate native timeline rows.
            continuation?.resume(returning: ConversationResponse(items: []))
        }
    }

    private func finishAcceptedSubmission() {
        let continuation = waiter
        waiter = nil
        pendingID = nil
        pendingTurnID = nil
        queuedVoiceAwaitingTurn = false
        draftSink = nil
        if returnsVoiceReply { continuation?.resume(throwing: WorkspaceClientError.outcomeUnknown) }
        else { continuation?.resume(returning: ConversationResponse(items: [])) }
        voiceReplyItems = []
    }

    func finish(throwing error: Error) {
        let continuation = waiter
        waiter = nil
        pendingID = nil
        draftSink = nil
        voiceReplyItems = []
        continuation?.resume(throwing: error)
    }

    private static func isProvenInputRejection(_ error: Error, method: String = "prompt.submit") -> Bool {
        if let workspace = error as? DirectHermesWorkspaceError, case .midSessionRejected = workspace { return true }
        if method == "prompt.submit", (error as? DirectHermesError) == .activeSessionLimit { return true }
        guard let direct = error as? DirectHermesError, case .rpcRejected(let code, _) = direct else { return false }
        // These stock validation/ownership rejections precede prompt admission.
        // An arbitrary server error from a mutating command is not such proof.
        return [4001, 4002, 4004, 4009, 4010, 4030, 4130].contains(code)
            || (method == "prompt.submit" && [4007, 4090].contains(code))
    }
}
