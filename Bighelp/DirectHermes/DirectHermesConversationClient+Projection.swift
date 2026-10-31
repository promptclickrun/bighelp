import Foundation

/// Native presentation readback, reactions, media, context and subagent projection.
extension DirectHermesConversationClient {
    func retainVisibleState() {
        if let model { projection.retainVisible(items: model.items, activities: model.activityLedger.allEvents) }
    }

    func publishNativeMessageReactions() {
        guard let model else { return }
        for rowID in retainedMessageReactions.keys.sorted() {
            if let reaction = retainedMessageReactions[rowID] {
                model.reconcileNativeMessageReaction(reaction, from: self)
            }
        }
    }

    func retainNativeMessageReaction(_ reaction: DirectHermesMessageReaction) {
        if retainedMessageReactions[reaction.rowID] == nil,
           retainedMessageReactions.count >= 4_096,
           let smallestRowID = retainedMessageReactions.keys.min() {
            retainedMessageReactions[smallestRowID] = nil
        }
        retainedMessageReactions[reaction.rowID] = reaction
    }

    @discardableResult
    func publishMessageReactionReadback(
        _ result: DirectHermesMessageReactionResult,
        role: DirectHermesReactionRole,
        connectionGeneration: UUID
    ) -> Bool {
        guard connected, generation == connectionGeneration else { return false }
        let values = result.reactions.map { value -> BighelpJSONValue in
            var object: [String: BighelpJSONValue] = [
                "emoji": .string(value.emoji),
                "author": .string(value.author),
            ]
            if let at = value.at { object["at"] = .number(at) }
            if let seen = value.seen { object["seen"] = .boolean(seen) }
            return .object(object)
        }
        let event = DirectHermesEvent(
            type: "message.reaction",
            sessionID: runtimeID,
            payload: [
                "row_id": .integer(result.rowID),
                "role": .string(role.rawValue),
                "reactions": .array(values),
            ],
            sequence: nil
        )
        guard let reaction = try? DirectHermesMessageReaction(event: event) else { return false }
        retainNativeMessageReaction(reaction)
        model?.reconcileNativeMessageReaction(reaction, from: self)
        return true
    }

    /// Hermes sends an agent's reaction (`message.reaction`) to the chat's saved
    /// session, not to this runtime, so the runtime route dropped it and the
    /// reaction showed only when the person's own reaction read the list back.
    /// Its `seq` counts the saved session's events, so it never enters the
    /// runtime's sequence.
    @discardableResult
    func receiveSavedSessionReaction(_ event: DirectHermesEvent) -> Bool {
        guard connected, event.type == "message.reaction", let sessionID = event.sessionID,
              !storedID.isEmpty, Data(sessionID.utf8) == Data(storedID.utf8),
              Data(sessionID.utf8) != Data(runtimeID.utf8),
              let reaction = try? DirectHermesMessageReaction(event: event) else { return false }
        retainNativeMessageReaction(reaction)
        model?.reconcileNativeMessageReaction(reaction, from: self)
        return true
    }

    func resetNativeMessageReactionsForEpochChange() {
        retainedMessageReactions.removeAll()
        model?.resetNativeMessageReactions(from: self)
    }

    private func hydrateDurableMessageReactions(
        activation: [String: BighelpJSONValue],
        owner: UUID
    ) async {
        do {
            let snapshot: DirectHermesDurableReactionSnapshot?
            if usesCatalogHistory {
                guard let http = rpc as? any DirectHermesAuthenticatedHTTP else { return }
                let capturedRuntimeID = runtimeID
                let capturedStoredID = storedID
                snapshot = try await DirectHermesReactionHistoryLoader.load(
                    http: http,
                    storedSessionID: capturedStoredID,
                    profileID: profile,
                    remainsOwned: { [weak self] in
                        guard let self else { return false }
                        return self.connected && self.generation == owner
                            && Data(self.runtimeID.utf8) == Data(capturedRuntimeID.utf8)
                            && Data(self.storedID.utf8) == Data(capturedStoredID.utf8)
                    }
                )
            } else if let messages = activation["messages"]?.array {
                snapshot = try DirectHermesReactionHistoryDecoder.decode(messages: messages)
            } else {
                snapshot = nil
            }
            guard connected, generation == owner, let snapshot else { return }
            retainedMessageReactions = snapshot.reactionsByRowID
            model?.reconcileAuthoritativeNativeMessageReactions(
                snapshot.reactionsByRowID,
                from: self
            )
        } catch {
            // Reaction hydration is presentation-only. A malformed or legacy
            // response cannot authorize clearing live state or blocking the
            // canonical transcript recovery.
        }
    }

    /// Agent-authored reactions are durable SessionDB metadata and may not have
    /// a client event bridge on non-Desktop sessions. Refresh once at the native
    /// terminal event (and after recovery), never on a timer or in the replay
    /// critical path.
    func scheduleDurableMessageReactionHydration(
        activation: [String: BighelpJSONValue]
    ) {
        guard usesCatalogHistory else { return }
        let owner = generation
        reactionHydrationTask?.cancel()
        reactionHydrationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.hydrateDurableMessageReactions(
                activation: activation,
                owner: owner
            )
            if self.generation == owner {
                self.reactionHydrationTask = nil
            }
        }
    }

    func publishSnapshot() {
        var record = workspaceRecord ?? SessionRecord(id: conversationID, kind: .direct, agentIDs: [profile], title: title,
            remoteStoredID: storedID, remoteSource: "direct-hermes", draft: journal.draft,
            items: projection.items, activityEvents: projection.activities, isActive: projection.running)
        record.remoteStoredID = storedID
        record.title = title
        record.items = projection.items
        record.activityEvents = projection.activities
        record.isActive = projection.running
        record.sessionContext = sessionContext ?? record.sessionContext
        if usesCatalogHistory { workspaceRecord = record }
        model?.adoptNativeSnapshot(from: self, session: record)
        scheduleMessageMedia()
    }

    /// Downloads never hold up text, turn settlement, or navigation. A failed
    /// or empty read is asked again a few times (it can lose to Hermes saving
    /// the turn or to a reload), then the message shows why its files didn't
    /// come, with Try again, instead of a loading tile or a host path.
    func scheduleMessageMedia() {
        guard connected, let attachmentResolver else { return }
        markLinkedPicturesShownInReply()
        let owner = generation
        let stored = storedID
        // The rows on screen: a reread of the saved history can put a reply only into the chat.
        // Newest first: a chat opens at its bottom, where the latest files are.
        for item in (model?.items ?? projection.items).reversed() {
            guard attachmentTasks.count < 2 else { break }
            guard item.metadata.delivery != "Streaming", item.attachments.isEmpty,
                  case .message(let text) = item.content,
                  DirectHermesGeneratedMediaClient.hasAttachmentDirectives(text, role: item.role),
                  attachmentTasks[item.id] == nil else { continue }
            // Stopped: it waits for Try again, and keeps its reason through a reload.
            if model?.agentFileFailure(itemID: item.id, text: text) != nil {
                model?.showAgentFileFailure(itemID: item.id)
                continue
            }
            let key = stored + "\0" + item.role.rawValue + "\0" + text
            guard attachmentAttempts[item.id] != key else { continue }
            attachmentAttempts[item.id] = key
            if item.role == .assistant {
                switch livePictures(for: item, text: text) {
                case .ready(let resolved, let eventIDs) where applyMessageMedia(resolved, replacing: item):
                    model?.markGeneratedMediaShownInReply(eventIDs: eventIDs)
                    attachmentAttempts[item.id] = nil
                    continue
                case .loading where (mediaFailures[item.id + "\0live"] ?? 0) < 5:
                    // The live card is still reading this file. It asks again when it
                    // lands; a card that never does stops holding the message up.
                    mediaFailures[item.id + "\0live", default: 0] += 1
                    waitForLiveCard(item, key: key, owner: owner)
                    continue
                case .ready, .loading, .none:
                    break
                }
            }
            attachmentTasks[item.id] = Task { @MainActor [weak self] in
                guard let self else { return }
                var applied = false
                var failure = AgentFileFailure.unknown
                defer {
                    // A cancelled load leaves the row to whatever cancelled it (a disconnect or suspend).
                    if self.generation == owner, !Task.isCancelled {
                        self.attachmentTasks[item.id] = nil
                        if !applied, self.connected, self.storedID == stored {
                            // Asked again a little later; the original marker stays meanwhile.
                            self.retryMessageMedia(item, key: key, owner: owner, failure: failure)
                        } else if !applied, self.attachmentAttempts[item.id] == key, self.mediaRetryTasks[item.id] == nil {
                            // Nothing will ask again on its own: the next schedule does, so the row
                            // never waits on an attempt that ended.
                            self.attachmentAttempts[item.id] = nil
                        }
                        self.scheduleMessageMedia()
                    }
                }
                do {
                    let results = try await attachmentResolver.resolve(agentID: self.profile, storedID: stored,
                        items: [.init(id: item.id, text: text, role: item.role)])
                    try Task.checkCancellation()
                    guard self.connected, self.generation == owner, self.storedID == stored else { return }
                    if results.count == 1, let result = results.first, result.id == item.id {
                        if !result.attachments.isEmpty { applied = self.applyMessageMedia(result, replacing: item) }
                        failure = result.failure ?? failure
                    }
                    // Shown. If a reload brings the row back without its files,
                    // they're read again (from this device's copy) rather than skipped.
                    if applied { self.attachmentAttempts[item.id] = nil }
                } catch is CancellationError {
                    return
                } catch {
                    failure = AgentFileFailure(error)
                }
            }
        }
    }

    /// A hosted image tool's picture lives at the provider's address. When the
    /// finished reply links it, the reply's preview draws it, so the tool's
    /// card keeps only its label and the picture shows once.
    private func markLinkedPicturesShownInReply() {
        guard let model,
              UserDefaults.standard.object(forKey: LinkPreviewPreferences.enabledKey) as? Bool ?? true
        else { return }
        var cards: [URL: String] = [:]
        for event in model.activityLedger.allEvents where event.generatedMedia?.state == .ready
            && event.generatedMedia?.shownInReply == false {
            guard let kind = GeneratedMediaProjection.kind(for: event) else { continue }
            for address in DirectHermesGeneratedMediaClient.providerURLs(event.result, kind: kind) {
                cards[address] = event.id
            }
        }
        guard !cards.isEmpty else { return }
        var shown: [String] = []
        for item in model.items where item.role == .assistant && item.metadata.delivery != "Streaming" {
            guard case .message(let text) = item.content,
                  let linked = LinkPreviewCandidate.firstURL(inMarkdown: text).flatMap(LinkPreviewPolicy.loadableURL),
                  let id = cards[linked] else { continue }
            shown.append(id)
        }
        if !shown.isEmpty { model.markGeneratedMediaShownInReply(eventIDs: shown) }
    }

    @discardableResult
    private func applyMessageMedia(_ result: ResolvedAgentAttachmentItem, replacing item: TimelineItem) -> Bool {
        if let enriched = projection.resolveMedia(result, replacing: item) {
            return model?.applyNativeMedia(enriched, replacing: item, from: self) ?? true
        }
        // Not in the live projection (or not the same there): the files go on the row on screen.
        guard let model, result.id == item.id,
              !result.attachments.isEmpty || item.content != .message(result.text) else { return false }
        return model.applyNativeMedia(TimelineItem(id: item.id, role: item.role, sender: item.sender,
            content: .message(result.text), metadata: item.metadata, attachments: result.attachments),
            replacing: item, from: self)
    }

    private func waitForLiveCard(_ item: TimelineItem, key: String, owner: UUID) {
        let delay = mediaRetryDelays.first ?? .seconds(2)
        mediaRetryTasks[item.id]?.cancel()
        mediaRetryTasks[item.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.generation == owner,
                  self.attachmentAttempts[item.id] == key else { return }
            self.mediaRetryTasks[item.id] = nil
            self.attachmentAttempts[item.id] = nil
            self.scheduleMessageMedia()
        }
    }

    /// Try again on a message whose files stopped loading: its tries start over. False when
    /// this chat has no connection to ask.
    func retryMessageMedia(itemID: String) -> Bool {
        guard connected, attachmentResolver != nil else { return false }
        let prefix = itemID + "\0"
        mediaFailures = mediaFailures.filter { !$0.key.hasPrefix(prefix) }
        AgentFileLoad.log.info("Try again on a message's files")
        // A load still under way goes on, with its tries counted from here.
        guard attachmentTasks[itemID] == nil else { return true }
        mediaRetryTasks[itemID]?.cancel()
        mediaRetryTasks[itemID] = nil
        attachmentAttempts[itemID] = nil
        scheduleMessageMedia()
        return true
    }

    private func retryMessageMedia(_ item: TimelineItem, key: String, owner: UUID, failure: AgentFileFailure) {
        let failureKey = item.id + "\0" + key
        let failures = (mediaFailures[failureKey] ?? 0) + 1
        mediaFailures[failureKey] = failures
        AgentFileLoad.log.notice("A message's files didn't load, try \(failures, privacy: .public): \(failure.rawValue, privacy: .public)")
        guard failures <= mediaRetryDelays.count else {
            // The row says why, with Try again. A reload keeps that until Try again or the chat opens
            // anew, rather than going back to a loading tile. Anything else keeps its attempt, so it
            // isn't asked for again and again.
            if item.role == .assistant, case .message(let text) = item.content,
               model?.markAgentFilesFailed(failure, itemID: item.id, text: text, from: self) == true {
                attachmentAttempts[item.id] = nil
            }
            return
        }
        let delay = mediaRetryDelays[failures - 1]
        mediaRetryTasks[item.id]?.cancel()
        mediaRetryTasks[item.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.generation == owner,
                  self.attachmentAttempts[item.id] == key else { return }
            self.mediaRetryTasks[item.id] = nil
            self.attachmentAttempts[item.id] = nil
            self.scheduleMessageMedia()
        }
    }

    enum LivePictures {
        case ready(ResolvedAgentAttachmentItem, eventIDs: [String])
        case loading
        case none
    }

    /// A finished message naming the file a live card in this chat reported
    /// reuses the card's bytes: no second download, nothing to lose to a reload
    /// in between, and one copy on screen.
    func livePictures(for item: TimelineItem, text: String) -> LivePictures {
        let markers = DirectHermesGeneratedMediaClient.mediaMarkers(text)
        guard !markers.isEmpty, let model else { return .none }
        var cards: [Data: ChatActivityEvent] = [:]
        for event in model.activityLedger.allEvents
        where event.lifecycle == .succeeded && GeneratedMediaProjection.kind(for: event) != nil {
            let paths = DirectHermesGeneratedMediaClient.outputPaths(event.result)
            if paths.count == 1, let path = paths.first { cards[Data(path.utf8)] = event }
        }
        var attachments: [ChatAttachment] = []
        var eventIDs: [String] = []
        for marker in markers {
            guard let card = cards[Data(marker.path.utf8)] else { return .none }
            switch card.generatedMedia?.state {
            case .ready?:
                guard let resolution = card.generatedMedia, resolution.attachments.count == 1 else { return .none }
                attachments += resolution.attachments
                if !eventIDs.contains(card.id) { eventIDs.append(card.id) }
            case nil:
                return .loading
            case .unavailable?, .oversized?:
                return .none
            }
        }
        let delivered = Set(markers.map { Data($0.line.utf8) })
        let remaining = text.components(separatedBy: "\n").filter { !delivered.contains(Data($0.utf8)) }
        return .ready(.init(id: item.id, text: remaining.joined(separator: "\n"), attachments: attachments),
                      eventIDs: eventIDs)
    }

    func validatedActivationSnapshot(
        _ value: BighelpJSONValue
    ) throws -> [String: BighelpJSONValue] {
        guard let object = value.object,
              let snapshotRuntimeID = object["session_id"]?.string,
              Data(snapshotRuntimeID.utf8) == Data(runtimeID.utf8) else {
            throw DirectHermesError.invalidResponse
        }
        if usesCatalogHistory {
            guard let sessionKey = object["session_key"]?.string,
                  Data(sessionKey.utf8) == Data(storedID.utf8) else {
                throw DirectHermesError.invalidResponse
            }
        }
        let durableAliases = ["session_key", "stored_session_id", "resumed"].compactMap {
            object[$0]?.string
        }
        guard !durableAliases.isEmpty,
              durableAliases.allSatisfy({ Data($0.utf8) == Data(storedID.utf8) }) else {
            throw DirectHermesError.invalidResponse
        }
        if object.keys.contains(where: {
            ["session_key", "stored_session_id", "resumed"].contains($0)
                && object[$0]?.string == nil
        }) {
            throw DirectHermesError.invalidResponse
        }
        guard object["running"]?.boolean != nil else {
            throw DirectHermesError.invalidResponse
        }
        return object
    }

    func publishTodoSnapshot(_ snapshot: SessionTodoSnapshot) {
        if projection.todoSnapshot != snapshot,
           !projection.adoptTodoSnapshot(snapshot) { return }
        model?.reconcileTodos(snapshot)
        onSessionTodosChange?(snapshot)
    }

    func applySnapshotMetadata(_ snapshot: [String: BighelpJSONValue]) {
        if let id = snapshot["session_id"]?.string, id != runtimeID {
            projection.resetCheckpoint()
            runtimeID = id
        }
        adoptStoredID(snapshot["stored_session_id"]?.string ?? snapshot["session_key"]?.string
            ?? snapshot["resumed"]?.string ?? storedID)
        let info = snapshot["info"]?.object ?? [:]
        if let name = info["model"]?.string { modelName = name }
        if let usage = info["usage"]?.object { acceptUsage(usage) }
        if let value = info["title"]?.string, !value.isEmpty {
            title = value
            model?.applyRenamedSessionTitle(value)
        }
    }

    func acceptUsage(_ usage: [String: BighelpJSONValue]) {
        func count(_ key: String) -> Int? {
            guard let value = usage[key]?.integer, value >= 0, value <= 1_000_000_000_000 else { return nil }
            return value
        }
        // Missing usage on a lazy/older host does not erase a previously observed window.
        guard let used = count("context_used"), let maximum = count("context_max"), maximum > 0 else { return }
        let value = SessionContextSnapshot(sessionId: conversationID, title: title,
            model: usage["model"]?.string ?? modelName, contextUsed: used, contextMax: maximum,
            contextPercent: Int(min(100, (Double(used) / Double(maximum) * 100).rounded())),
            compressions: count("compressions") ?? 0, isCompacting: false,
            updatedAt: max(Int(Date.now.timeIntervalSince1970 * 1000), (sessionContext?.updatedAt ?? 0) + 1),
            sessionInputTokens: count("prompt"), sessionOutputTokens: count("output"),
            sessionCachedTokens: count("cached"), sessionTotalTokens: count("total"),
            sessionIncludesSubagents: false)
        sessionContext = value
        model?.reconcileSessionContext(value)
        onSessionContextChange?(value)
    }

    func publishNativeSubagent(_ item: NativeSubagentRailItem) {
        if item.lifecycle.isTerminal {
            nativeSubagentsByID[item.id] = nil
            terminalNativeSubagentIDs.insert(item.id)
        } else {
            terminalNativeSubagentIDs.remove(item.id)
            nativeSubagentsByID[item.id] = item.merging(nativeSubagentsByID[item.id])
        }
        nativeSubagents = nativeSubagentsByID.values.sorted {
            ($0.startedAt ?? Int.max, $0.id) < ($1.startedAt ?? Int.max, $1.id)
        }
        onNativeSubagentsChange?(nativeSubagents)
        model?.reconcileNativeSubagents(nativeSubagents)
    }

    private func clearNativeSubagents() {
        guard !nativeSubagents.isEmpty || !nativeSubagentsByID.isEmpty else { return }
        nativeSubagentsByID.removeAll(keepingCapacity: true)
        terminalNativeSubagentIDs.removeAll(keepingCapacity: true)
        nativeSubagents = []
        onNativeSubagentsChange?([])
        model?.reconcileNativeSubagents([])
    }

    func refreshNativeSubagents(owner: UUID) async {
        guard connected, generation == owner else { return }
        let eventRevision = nativeSubagentEventRevision
        do {
            let result = try await rpc.request("subagent.list", params: [
                "session_id": .string(runtimeID)
            ])
            guard !Task.isCancelled, connected, generation == owner,
                  nativeSubagentEventRevision == eventRevision else { return }
            guard let object = result.object,
                  let rows = object["subagents"]?.array else { return }
            let parsed = Self.nativeSubagentItems(from: object)
            guard parsed.count == rows.count,
                  Set(parsed.map(\.id)).count == parsed.count else { return }
            let listed = parsed.filter { !terminalNativeSubagentIDs.contains($0.id) }
            nativeSubagentsByID = Dictionary(uniqueKeysWithValues: listed.map { item in
                (item.id, item.merging(nativeSubagentsByID[item.id]))
            })
            nativeSubagents = nativeSubagentsByID.values.sorted {
                ($0.startedAt ?? Int.max, $0.id) < ($1.startedAt ?? Int.max, $1.id)
            }
            onNativeSubagentsChange?(nativeSubagents)
            model?.reconcileNativeSubagents(nativeSubagents)
        } catch {
            // The native stream remains authoritative when a host does not
            // expose the optional roster method or it races child cleanup.
        }
    }

    static func nativeSubagentItems(from object: [String: BighelpJSONValue]) -> [NativeSubagentRailItem] {
        guard let rows = object["subagents"]?.array else { return [] }
        return rows.compactMap { value in
            guard let row = value.object,
                  let id = nonempty(row["subagent_id"]?.string) else { return nil }
            let status = nonempty(row["status"]?.string)
            let lifecycle: ChatActivityLifecycle = switch status?.lowercased() {
            case "failed", "error", "errored": .failed
            case "cancelled", "canceled", "interrupted": .cancelled
            case "completed", "complete", "done", "success", "succeeded": .succeeded
            default: .running
            }
            let startedAt = row["started_at"]?.number.flatMap {
                $0.isFinite && $0 >= 0 && $0 <= Double(Int.max) ? Int($0) : nil
            }
            let toolCount = row["tool_count"]?.integer.flatMap { $0 >= 0 ? $0 : nil }
            return NativeSubagentRailItem(
                id: id,
                childSessionID: nonempty(row["child_session_id"]?.string),
                parentID: nonempty(row["parent_id"]?.string),
                goal: nonempty(row["goal"]?.string) ?? "Subagent task",
                lifecycle: lifecycle,
                status: status,
                model: nonempty(row["model"]?.string),
                toolCount: toolCount,
                startedAt: startedAt
            )
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

extension DirectHermesConversationClient {
    /// A reload, reconnect or suspension starts every file read afresh.
    func resetMediaRetries() {
        mediaRetryTasks.values.forEach { $0.cancel() }
        mediaRetryTasks.removeAll()
        mediaFailures.removeAll()
    }
}
