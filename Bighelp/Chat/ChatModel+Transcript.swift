import Foundation

extension ChatModel {
    func timelineScrollKey(clarificationIDs: [String] = []) -> ChatTimelineScrollKey {
        ChatTimelineScrollKey(revision: transcriptRevision, isSending: isSending,
                              clarificationIDs: clarificationIDs)
    }
    func setTranscriptPresentationDeferred(_ deferred: Bool) {
        guard defersTranscriptPresentation != deferred else { return }
        defersTranscriptPresentation = deferred
        if !deferred, hasDeferredTranscriptChanges {
            hasDeferredTranscriptChanges = false
            rebuildTranscript()
        }
        flushPersistence()
    }

    private func deferTranscriptMutationIfNeeded() -> Bool {
        guard defersTranscriptPresentation else { return false }
        hasDeferredTranscriptChanges = true
        return true
    }
    var presentedItems: [TimelineItem] {
        items
    }

    func projectedMessage(id: String) -> TimelineItem? {
        guard let index = transcriptMessageIndexByID[id],
              case .message(let item) = transcriptEntries[index] else { return nil }
        return item
    }

    /// Retained for working-label compatibility. Interim messages now live in
    /// the transcript instead of a single replaceable side channel.
    var streamingItem: TimelineItem? {
        guard isSending else { return nil }
        return items.last { $0.metadata.delivery == "Streaming" }
    }

    /// Applies a transcript fetched after this chat model was created.
    ///
    /// Session navigation hydrates the canonical catalog before returning to
    /// an existing route. Keep the route-owned model in step with that
    /// canonical transcript without replacing a newer local/live turn.
    func reconcileHydratedSession(
        _ session: SessionRecord,
        goalSnapshot: SessionGoalSnapshot? = nil
    ) {
        guard
            !referenceOwnerRetired,
            session.id == conversationID,
            session.kind == .direct
        else { return }
        companionHistoryRevision &+= 1
        nativeAffectionReaction = nil
        let hasSameContextOwner = sourceSession?.remoteStoredID == session.remoteStoredID
            && sourceSession?.remoteSource == session.remoteSource
            && sourceSession?.agentIDs == session.agentIDs
        if sourceSession != nil, !hasSameContextOwner {
            sessionTodos = nil
            taskDrawer = nil
            sessionSubagentUpdatedAt = 0
            sessionSubagents = []
            nativeMessageReactionSnapshots.removeAll()
            nativeMessageReactionErrors.removeAll()
            pendingNativeMessageReactionRows.removeAll()
            uncertainNativeMessageReactionRows.removeAll()
            unsupportedNativeReactionGeneration = nil
            advanceNativeMessageReactionRevision()
        }
        sourceSession = session
        if let snapshot = session.sessionTodos { reconcileTodos(snapshot) }
        if let snapshot = session.sessionSubagents { reconcileSubagents(snapshot) }
        if let runtime = session.sessionRuntime {
            runtimeControls?.reconcileSessionRuntime(runtime)
        }
        if hasSameContextOwner {
            if let context = session.sessionContext {
                reconcileSessionContext(context, isLive: false)
            }
        } else {
            sessionContext = nil
            sessionGoal = nil
        }
        if let goalSnapshot = goalSnapshot ?? session.sessionGoal {
            reconcileGoal(goalSnapshot)
        }
        if session.isActive,
           let native = nativeConversationClient,
           native.hasAuthoritativeEventCoverage,
           !native.sessionActionsAreRunning {
            // Current recovered liveness outranks an older catalog-active bit.
            // Attachment preparation may close submission without weakening
            // that event coverage or reviving a completed turn.
            reconcileNativeIdle(from: native)
        } else if session.isActive {
            if nativeTurnID == nil, !hasLocallyPendingPrimaryTurn {
                hasRestoredPrimaryTurn = true
            }
            isSending = true
            guard isHydratingHistory || isLoadingPreviousHistory else {
                scheduleGeneratedMediaResolutions()
                return
            }
        }
        let hydratedItems = keepingDeliveredFiles(hasSameContextOwner
            ? ReferenceCanonicalHistory.preservingAcceptedRows(local: items, incoming: session.items)
            : session.items)
        let hasHydratedChanges = hydratedItems != items
            || session.activityEvents != activityLedger.allEvents
        if !session.isActive, isSending {
            if hasLocallyPendingPrimaryTurn {
                guard Self.hasTerminalReplyForPendingTurn(
                    currentItems: referenceSubmission == nil ? items : [],
                    hydratedItems: session.items,
                    pendingMessageID: (client as? any InactiveSessionReconciliationConversationClient)?
                        .pendingMessageID(conversationID: conversationID)
                ) else {
                    return
                }
            }
            _ = beginOwnerGeneration()
            (client as? any InactiveSessionReconciliationConversationClient)?
                .reconcileInactiveSession(conversationID: conversationID)
            isSending = false
            isStopping = false
            pendingMidSessionSubmissions = []
            retryRequest = nil
            failureMessage = nil
            settleTaskDrawerAfterTurn()
        }
        guard hasHydratedChanges else {
            scheduleGeneratedMediaResolutions()
            return
        }
        let orderedContent = ChatTranscriptProjection.orderedContent(
            items: hydratedItems, events: session.activityEvents
        )
        items = orderedContent.items
        rebuildItemIndexes()
        activityLedger = ChatActivityLedger(sessionID: conversationID, events: orderedContent.events)
        if sessionTodos == nil, taskDrawer == nil {
            for event in activityLedger.allEvents {
                taskDrawer = ChatTodoProjection.applying(event, to: taskDrawer)
            }
        }
        nextTranscriptOrder = orderedContent.nextOrder
        nextHumanSequence = (items.filter { $0.role == .human }.count + 1)
        rebuildTranscript()
        resetGeneratedMediaResolutions()
        scheduleGeneratedMediaResolutions()
    }

    /// Opens the route against authoritative session state while the canonical
    /// transcript is still arriving. Catalog-only previews are cleared, while
    /// a previously hydrated transcript remains visible until Hermes replaces
    /// it so navigation cannot blank a durable conversation.
    func beginHistoryHydration(from session: SessionRecord) {
        guard session.id == conversationID, session.kind == .direct else { return }
        sourceSession = session
        isHydratingHistory = true
        hasPreviousHistory = false
        isLoadingPreviousHistory = false
        previousHistoryErrorMessage = nil
        previousHistoryRevealID = nil
        if !ChatHistoryProjection.isCanonicalTranscript(session.items) {
            resetGeneratedMediaResolutions()
            items = []
            rebuildItemIndexes()
            activityLedger = ChatActivityLedger(sessionID: conversationID, events: [])
            nextTranscriptOrder = 1
            nextHumanSequence = 1
            rebuildTranscript()
        }
        if session.isActive,
           let native = nativeConversationClient,
           native.hasAuthoritativeEventCoverage,
           !native.sessionActionsAreRunning {
            reconcileNativeIdle(from: native)
        } else if session.isActive {
            if nativeTurnID == nil, !hasLocallyPendingPrimaryTurn {
                hasRestoredPrimaryTurn = true
            }
            isSending = true
        } else if isSending {
            _ = beginOwnerGeneration()
            (client as? any InactiveSessionReconciliationConversationClient)?
                .reconcileInactiveSession(conversationID: conversationID)
            isSending = false
            isStopping = false
            pendingMidSessionSubmissions = []
            retryRequest = nil
            failureMessage = nil
            settleTaskDrawerAfterTurn()
        }
    }

    func finishHistoryHydration(hasPreviousHistory: Bool = false) {
        isHydratingHistory = false
        self.hasPreviousHistory = hasPreviousHistory
    }

    var shouldShowNewConversationWelcome: Bool {
        !isBotMode
            && transcriptEntries.isEmpty
            && !isHydratingHistory
            && !isSending
            && !hasPreviousHistory
            && sourceSession?.hasAcceptedMessage != true
    }

    func beginLoadingPreviousHistory() {
        guard hasPreviousHistory, !isLoadingPreviousHistory else { return }
        isLoadingPreviousHistory = true
        previousHistoryErrorMessage = nil
        previousHistoryRevealID = nil
    }

    func finishLoadingPreviousHistory(
        hasPreviousHistory: Bool,
        errorMessage: String? = nil
    ) {
        isLoadingPreviousHistory = false
        self.hasPreviousHistory = hasPreviousHistory
        previousHistoryErrorMessage = errorMessage
        if errorMessage == nil {
            previousHistoryRevealID = transcriptEntries.first?.id
        }
    }

    private static func hasTerminalReplyForPendingTurn(
        currentItems: [TimelineItem],
        hydratedItems: [TimelineItem],
        pendingMessageID: String?
    ) -> Bool {
        let isTerminalAssistant: (TimelineItem) -> Bool = { item in
            item.role == .assistant && item.metadata.delivery != "Streaming"
        }
        if let latestHumanIndex = currentItems.lastIndex(where: { $0.role == .human }),
           currentItems[currentItems.index(after: latestHumanIndex)...].contains(where: isTerminalAssistant) {
            return true
        }
        // Correlate only the actual Link message ID persisted by Hermes.
        // Equal text or an unseen historical assistant ID is not ownership.
        guard let pendingMessageID else { return false }
        let matches = hydratedItems.indices.filter {
            hydratedItems[$0].role == .human && hydratedItems[$0].metadata.platformMessageID == pendingMessageID
        }
        guard matches.count == 1, let humanIndex = matches.first else { return false }
        return hydratedItems[hydratedItems.index(after: humanIndex)...].contains(where: isTerminalAssistant)
    }

    var activityTurns: [ChatActivityTurn] {
        activityLedger.turnIDs.compactMap { turnID in
            let events = activityLedger.visibleEvents(
                for: turnID,
                visibility: activityVisibility
            )
            guard !events.isEmpty else { return nil }
            return ChatActivityTurn(id: turnID, events: events)
        }
    }

    @discardableResult
    func acceptActivity(_ event: ChatActivityEvent) -> ChatActivityReconciliation {
        let orderedEvent: ChatActivityEvent
        if let existing = activityLedger.event(id: event.id), let order = existing.sourceOrder {
            orderedEvent = event.ordered(order)
        } else if event.sourceOrder == nil {
            orderedEvent = event.ordered(takeTranscriptOrder())
        } else {
            orderedEvent = event
        }
        let result = activityLedger.receive(orderedEvent)
        lastActivityMutationWorkCount = activityLedger.lastMutationWorkCount
        guard result == .inserted || result == .recovered || result == .updated else {
            return result
        }
        if let order = orderedEvent.sourceOrder, order < Int.max {
            nextTranscriptOrder = max(nextTranscriptOrder, order + 1)
        }
        if result == .updated, let accepted = activityLedger.event(id: orderedEvent.id) {
            updateProjectedActivity(accepted)
        } else if let accepted = activityLedger.event(id: orderedEvent.id) {
            appendProjectedActivity(accepted)
        }
        if orderedEvent.toolName == "todo" || orderedEvent.toolName == "todo_list",
           let acceptedEvent = activityLedger.event(id: orderedEvent.id) {
            acceptTodoActivity(acceptedEvent)
        }
        if let acceptedEvent = activityLedger.event(id: orderedEvent.id) {
            scheduleGeneratedMediaResolution(for: acceptedEvent)
        }
        // Tool completion is still part of a streaming turn. Use the same
        // bounded checkpoint as draft updates instead of serializing the whole
        // session for every tool. Turn completion, stop and lifecycle changes
        // retain their explicit durability flushes.
        persistSession()
        return result
    }

    func setReasoningVisible(_ isVisible: Bool) {
        guard activityVisibility.showReasoning != isVisible else { return }
        activityVisibility.showReasoning = isVisible
    }

    func setToolCallsVisible(_ isVisible: Bool) {
        guard activityVisibility.showToolCalls != isVisible else { return }
        activityVisibility.showToolCalls = isVisible
    }

    /// Only authenticated live assistant delivery opts in. History, fixtures,
    /// attachment preparation and generic external projections stay silent.
    func acceptExternal(_ newItems: [TimelineItem], isLiveAssistantText: Bool = false) {
        guard !isBotMode else { return }
        lastItemMutationWorkCount = 0
        var didChange = false
        for item in newItems {
            guard senderBelongsToThisSession(item) else { continue }
            let previous = itemIndexByID[item.id].map { items[$0] }
            if let index = itemIndex(id: item.id) {
                guard canUpdateStreamingItem(items[index], with: item) else { continue }
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
            if isLiveAssistantText { emitResponseTextGrowth(from: previous, to: item) }
            didChange = true
        }
        guard didChange else { return }
        persistSession()
        if !defersTranscriptPresentation, newItems.contains(where: { $0.metadata.delivery != "Streaming" }) {
            flushPersistence()
        }
    }

    /// A completed native message can acquire authenticated media bytes later.
    /// Keep its exact owner, identity, source order, and newer timing metadata.
    @discardableResult
    /// The host's saved copy of a message still names its files as `MEDIA:`
    /// lines. Where this device already shows those files for that exact text,
    /// keep them rather than going back to loading tiles.
    func keepingDeliveredFiles(_ incoming: [TimelineItem]) -> [TimelineItem] {
        guard !deliveredFileSources.isEmpty else { return incoming }
        return incoming.map { row in
            guard row.attachments.isEmpty, case .message(let text) = row.content,
                  deliveredFileSources[row.id] == text, let index = itemIndexByID[row.id],
                  items[index].role == row.role, !items[index].attachments.isEmpty else { return row }
            let shown = items[index]
            return TimelineItem(id: row.id, role: row.role, sender: row.sender, content: shown.content,
                                metadata: row.metadata, attachments: shown.attachments)
        }
    }

    func applyNativeMedia(_ item: TimelineItem, replacing source: TimelineItem,
                          from owner: DirectHermesConversationClient) -> Bool {
        guard (client as? DirectHermesConversationClient) === owner,
              !referenceOwnerRetired, !isBotMode, senderBelongsToThisSession(item),
              item.id == source.id, item.role == source.role,
              let index = itemIndexByID[item.id] else { return false }
        let existing = items[index]
        if case .message(let text) = source.content, deliveredFileSources[item.id] == text,
           existing.role == source.role, !existing.attachments.isEmpty {
            // Already showing these files: a history reload kept them.
            return true
        }
        guard existing.role == source.role, existing.sender == source.sender, existing.content == source.content,
              existing.attachments == source.attachments else { return false }
        replaceItem(at: index, with: TimelineItem(id: existing.id, role: existing.role, sender: existing.sender,
            content: item.content, metadata: existing.metadata, attachments: item.attachments))
        if !item.attachments.isEmpty, case .message(let text) = source.content {
            deliveredFileSources[item.id] = text
        }
        updateProjectedMessage(items[index])
        persistSession()
        flushPersistence()
        return true
    }

    /// Applies metadata from the authenticated native reducer to an existing
    /// transcript row without reopening its delivery state or changing its
    /// source order. Completed assistant rows are immutable through ordinary
    /// streaming admission, but a measured native duration arrives only after
    /// that row has already become Received.
    func appendValidated(_ newItems: [TimelineItem]) throws {
        var batchIDs = Set<String>()

        for item in newItems {
            guard batchIDs.insert(item.id).inserted else {
                throw ResponseIdentityError.collision
            }
            guard senderBelongsToThisSession(item) else {
                throw ResponseIdentityError.collision
            }
            if let index = itemIndexByID[item.id],
               !canUpdateStreamingItem(items[index], with: item) {
                throw ResponseIdentityError.collision
            }
        }

        for item in newItems {
            let previous = itemIndexByID[item.id].map { items[$0] }
            if let index = itemIndexByID[item.id] {
                replaceItem(at: index, with: item.ordered(
                    items[index].metadata.sourceOrder ?? takeTranscriptOrder()
                ))
                updateProjectedMessage(items[index])
            } else {
                let item = ordered(item)
                appendItem(item)
                appendProjectedMessage(item)
            }
            emitResponseTextGrowth(from: previous, to: item)
        }
        persistSession()
    }

    func canUpdateStreamingItem(
        _ existing: TimelineItem,
        with replacement: TimelineItem
    ) -> Bool {
        existing.metadata.delivery == "Streaming"
            && existing.role == replacement.role
            && existing.sender.id == replacement.sender.id
            && existing.sender.kind == replacement.sender.kind
    }

    func itemIndex(id: String) -> Int? {
        lastItemMutationWorkCount += 1
        return itemIndexByID[id]
    }

    func removeItem(id: String) {
        guard let index = itemIndexByID[id] else { return }
        if index == items.indices.last {
            items.removeLast()
            itemIndexByID[id] = nil
        } else {
            items.remove(at: index)
            rebuildItemIndexes()
        }
    }

    func appendItem(_ item: TimelineItem) {
        // Native events and locally submitted messages share one presentation
        // sequence. A supplied native order must advance the next local row.
        if let order = item.metadata.sourceOrder, order < Int.max {
            nextTranscriptOrder = max(nextTranscriptOrder, order + 1)
        }
        itemIndexByID[item.id] = items.count
        items.append(item)
    }

    func replaceItem(at index: Int, with item: TimelineItem) {
        let previousID = items[index].id
        items[index] = item
        if previousID != item.id { itemIndexByID[previousID] = nil }
        itemIndexByID[item.id] = index
    }

    func rebuildItemIndexes() {
        itemIndexByID.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() where itemIndexByID[item.id] == nil {
            itemIndexByID[item.id] = index
        }
    }

    func ordered(_ item: TimelineItem) -> TimelineItem {
        guard item.metadata.sourceOrder == nil else { return item }
        return item.ordered(takeTranscriptOrder())
    }

    func takeTranscriptOrder() -> Int {
        defer { nextTranscriptOrder += 1 }
        return nextTranscriptOrder
    }

    func rebuildTranscript(from requestedOrder: Int? = nil) {
        guard !deferTranscriptMutationIfNeeded() else { return }
        let projectedItems = isBotMode ? botModeTimelineItems : items
        let events = activityLedger.allEvents
        var work = 0
        // Authoritative replacement must not retain rows from the old projection.
        // Only explicit live-tail updates may keep an unchanged prefix.
        guard !isBotMode, let requestedOrder else {
            work += projectedItems.count + events.count
            transcriptEntries = ChatTranscriptProjection.entries(
                items: projectedItems,
                activityEvents: events,
                visibility: activityVisibility,
                isBotMode: isBotMode,
                isScheduled: sourceSession?.isCronSession == true,
                reactedTo: agentReacted(to:)
            )
            rebuildTranscriptIndexes(work: &work)
            recordProjectionWork(work)
            return
        }

        work += transcriptEntries.count
        let invalidationOrder = transcriptEntries.reduce(requestedOrder) { boundary, entry in
            guard case .activity(let turn) = entry else { return boundary }
            let orders = turn.events.compactMap(\.sourceOrder)
            guard let first = orders.min(), let last = orders.max(), first <= boundary, boundary <= last else {
                return boundary
            }
            return first
        }
        let prefix = transcriptEntries.prefix { entry in
            switch entry {
            case .message(let item):
                return (item.metadata.sourceOrder ?? .max) < invalidationOrder
            case .activity(let turn):
                return (turn.events.compactMap(\.sourceOrder).max() ?? .max) < invalidationOrder
            }
        }
        work += transcriptEntries.count
        work += projectedItems.count + events.count
        let suffixItems = projectedItems.filter {
            ($0.metadata.sourceOrder ?? .max) >= invalidationOrder
        }
        let suffixEvents = events.filter {
            ($0.sourceOrder ?? .max) >= invalidationOrder
        }
        work += prefix.count + suffixItems.count + suffixEvents.count
        transcriptEntries = Array(prefix) + ChatTranscriptProjection.entries(
            items: suffixItems,
            activityEvents: suffixEvents,
            visibility: activityVisibility,
            isBotMode: false,
            isScheduled: sourceSession?.isCronSession == true,
            after: projectedItems.last {
                ($0.metadata.sourceOrder ?? .max) < invalidationOrder && ChatSilentReply.isConversationMessage($0)
            },
            reactedTo: agentReacted(to:)
        )
        rebuildTranscriptIndexes(work: &work)
        recordProjectionWork(work)
    }

    func appendProjectedMessage(_ item: TimelineItem) {
        guard !deferTranscriptMutationIfNeeded() else { return }
        guard let item = silentReplyPresented(item) else { return }
        guard !isBotMode else {
            rebuildTranscript()
            return
        }
        let itemOrder = item.metadata.sourceOrder ?? .max
        if let last = transcriptEntries.last, transcriptUpperOrder(last) > itemOrder {
            rebuildTranscript(from: item.metadata.sourceOrder)
            return
        }
        let index = transcriptEntries.count
        transcriptEntries.append(.message(item))
        transcriptMessageIndexByID[item.id] = index
        recordProjectionWork(1)
    }

    /// A live reply as shown (see ChatSilentReply), or nil when it stays silent.
    private func silentReplyPresented(_ item: TimelineItem) -> TimelineItem? {
        let lane: ChatSilentReply.Lane = isBotMode ? .room : sourceSession?.isCronSession == true ? .scheduled : .chat
        // Only a finished bare marker in a chat needs what it answered.
        var previous: TimelineItem?
        if lane == .chat, item.metadata.delivery != "Streaming", case .message(let text) = item.content,
           ChatSilentReply.isMarker(text), let index = items.lastIndex(where: { $0.id == item.id }) {
            previous = items[..<index].last(where: ChatSilentReply.isConversationMessage)
        }
        let answeredWithReaction = previous.map(agentReacted(to:)) ?? false
        switch ChatSilentReply.presentation(of: item, after: previous, lane: lane,
                                            answeredWithReaction: answeredWithReaction) {
        case .show: return item
        case .hide: return nil
        case .notice: return ChatSilentReply.noticeItem(replacing: item)
        }
    }

    /// The agent reacted to this person's message, live or saved.
    func agentReacted(to item: TimelineItem) -> Bool {
        guard item.role == .human, itemIndexByID[item.id] != nil else { return false }
        return nativeMessageReactionPresentation(for: item).reactions.contains { $0.author == .agent }
    }

    private func transcriptUpperOrder(_ entry: ChatTranscriptEntry) -> Int {
        switch entry {
        case .message(let item):
            item.metadata.sourceOrder ?? .max
        case .activity(let turn):
            turn.upperSourceOrder
        }
    }

    func updateProjectedMessage(_ item: TimelineItem) {
        guard !deferTranscriptMutationIfNeeded() else { return }
        guard let item = silentReplyPresented(item) else {
            removeProjectedMessage(id: item.id)
            return
        }
        guard !isBotMode, let index = transcriptMessageIndexByID[item.id] else {
            rebuildTranscript(from: item.metadata.sourceOrder)
            return
        }
        transcriptEntries[index] = .message(item)
        recordProjectionWork(1)
    }

    func removeProjectedMessage(id: String) {
        guard !deferTranscriptMutationIfNeeded() else { return }
        guard !isBotMode, let index = transcriptMessageIndexByID[id] else { return }
        if index == transcriptEntries.indices.last {
            transcriptEntries.removeLast()
            transcriptMessageIndexByID[id] = nil
            recordProjectionWork(1)
            return
        }
        transcriptEntries.remove(at: index)
        var work = 1
        rebuildTranscriptIndexes(work: &work)
        recordProjectionWork(work)
    }

    func updateProjectedActivity(_ event: ChatActivityEvent) {
        guard !deferTranscriptMutationIfNeeded() else { return }
        guard let index = transcriptActivityIndexByEventID[event.id],
              let eventIndex = transcriptActivityPositionByEventID[event.id],
              case .activity(let turn) = transcriptEntries[index] else {
            rebuildTranscript(from: event.sourceOrder)
            return
        }
        turn.update(event, at: eventIndex)
        transcriptRevision &+= 1
        recordProjectionWork(1)
    }

    private func appendProjectedActivity(_ event: ChatActivityEvent) {
        guard !deferTranscriptMutationIfNeeded() else { return }
        guard !isBotMode else {
            rebuildTranscript()
            return
        }
        guard event.isVisible(using: activityVisibility) else {
            recordProjectionWork(1)
            return
        }
        let eventOrder = event.sourceOrder ?? .max
        if let last = transcriptEntries.last, transcriptUpperOrder(last) > eventOrder {
            rebuildTranscript(from: event.sourceOrder)
            return
        }
        if let lastIndex = transcriptEntries.indices.last,
           case .activity(let turn) = transcriptEntries[lastIndex],
           turn.events.last?.turnID == event.turnID {
            let eventIndex = turn.events.count
            turn.append(event)
            transcriptRevision &+= 1
            transcriptActivityIndexByEventID[event.id] = lastIndex
            transcriptActivityPositionByEventID[event.id] = eventIndex
            recordProjectionWork(1)
            return
        }
        let index = transcriptEntries.count
        transcriptEntries.append(.activity(ChatActivityTurn(
            id: "\(event.turnID):\(event.eventID)",
            events: [event]
        )))
        transcriptActivityIndexByEventID[event.id] = index
        transcriptActivityPositionByEventID[event.id] = 0
        recordProjectionWork(1)
    }

    private func rebuildTranscriptIndexes(work: inout Int) {
        transcriptMessageIndexByID.removeAll(keepingCapacity: true)
        transcriptActivityIndexByEventID.removeAll(keepingCapacity: true)
        transcriptActivityPositionByEventID.removeAll(keepingCapacity: true)
        for (index, entry) in transcriptEntries.enumerated() {
            work += 1
            switch entry {
            case .message(let item):
                transcriptMessageIndexByID[item.id] = index
            case .activity(let turn):
                for (eventIndex, event) in turn.events.enumerated() {
                    work += 1
                    transcriptActivityIndexByEventID[event.id] = index
                    transcriptActivityPositionByEventID[event.id] = eventIndex
                }
            }
        }
    }

    private func recordProjectionWork(_ work: Int) {
        lastTranscriptProjectionWorkCount = work
        transcriptProjectionWorkCount += work
    }
    func senderBelongsToThisSession(_ item: TimelineItem) -> Bool {
        switch item.role {
        case .human:
            item.sender.kind == .user && item.sender.id == UserIdentity.stableID
        case .assistant:
            item.sender.kind == .system
                || (item.sender.kind == .agent && item.sender.id == agentID)
        }
    }
}
