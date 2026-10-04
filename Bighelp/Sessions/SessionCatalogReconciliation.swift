import Foundation

@MainActor
enum SessionCatalogReconciliation {
    static func prependingHistory(
        _ older: SessionRecord,
        to newer: SessionRecord
    ) -> SessionRecord {
        var combined = newer
        var itemIDs = Set<String>()
        combined.items = (older.items + newer.items).filter { itemIDs.insert($0.id).inserted }
        combined.activityEvents = ChatActivityLedger(
            sessionID: newer.id,
            events: older.activityEvents + newer.activityEvents
        ).allEvents
        combined.hasAcceptedMessage = older.hasAcceptedMessage || newer.hasAcceptedMessage
        return combined
    }

    static func retained(_ records: [SessionRecord]) -> [SessionRecord] {
        var retained = records
        for candidate in records {
            guard let storedID = candidate.remoteStoredID, candidate.id != storedID else { continue }
            let aliases = retained.filter { isTransientActivityAlias($0, of: candidate) }
            guard !aliases.isEmpty else { continue }
            var canonical = retained.first(where: { $0.id == candidate.id }) ?? candidate
            for alias in aliases {
                canonical = merged(
                    local: promotedTransientAlias(alias, to: canonical),
                    incoming: canonical
                )
            }
            let aliasIDs = Set(aliases.map(\.id))
            retained.removeAll { aliasIDs.contains($0.id) }
            if let index = retained.firstIndex(where: { $0.id == canonical.id }) {
                retained[index] = canonical
            }
        }
        return retained.sorted(by: activitySort)
    }

    static func activitySort(_ lhs: SessionRecord, _ rhs: SessionRecord) -> Bool {
        if lhs.hasActiveWork != rhs.hasActiveWork {
            return lhs.hasActiveWork
        }
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id < rhs.id
    }

    static func reconciled(
        local localRecords: [SessionRecord],
        authoritativeIncoming incomingRecords: [SessionRecord]
    ) -> [SessionRecord] {
        let incoming = incomingRecords.map { incoming in
            matchingLocalRecords(for: incoming, in: localRecords).reduce(incoming) {
                mergedMatchingLocal($1, incoming: $0)
            }
        }
        // A new chat can be omitted until its first message reaches durable
        // host history. Retain its local reference draft/intent in this catalog.
        let retainedReferences = localRecords.filter { local in
            (local.isLocalPresentationDraft
                || local.hasDeferredReferenceState || local.referenceState != nil
                || ReferenceCodec.decode(local.draft).hasValidAppendix)
                && !incoming.contains(where: { remote in
                    remote.id == local.id || (local.remoteStoredID != nil
                        && remote.remoteStoredID == local.remoteStoredID)
                })
        }.map { local in
            var retained = local
            // A native live-only row can remain as the owner of a draft or an
            // uncertain submission, but absence from a successful process-local
            // inventory must not keep advertising work that no longer exists.
            if retained.id.hasPrefix(DirectHermesSessionIdentity.prefix + ":") {
                retained.isActive = false
            }
            return retained
        }
        return retained(incoming + retainedReferences)
    }

    static func merged(
        local localRecords: [SessionRecord],
        incoming incomingRecords: [SessionRecord]
    ) -> [SessionRecord] {
        var mergedRecords = localRecords
        for incomingRecord in incomingRecords {
            let matchingIndices = matchingLocalIndices(for: incomingRecord, in: mergedRecords)
            var canonical = incomingRecord
            for index in matchingIndices {
                canonical = mergedMatchingLocal(mergedRecords[index], incoming: canonical)
            }
            for index in matchingIndices.sorted(by: >) {
                mergedRecords.remove(at: index)
            }
            mergedRecords.append(canonical)
        }
        return retained(mergedRecords)
    }

    static func matchingLocalRecords(
        for incoming: SessionRecord,
        in records: [SessionRecord]
    ) -> [SessionRecord] {
        matchingLocalIndices(for: incoming, in: records).map { records[$0] }
    }

    static func matchingLocalIndices(
        for incoming: SessionRecord,
        in records: [SessionRecord]
    ) -> [Int] {
        records.indices.filter { index in
            let local = records[index]
            return local.id == incoming.id
                || hasSameDurableIdentity(local, incoming)
                || isTransientActivityAlias(local, of: incoming)
        }
    }

    static func hasSameDurableIdentity(
        _ lhs: SessionRecord,
        _ rhs: SessionRecord
    ) -> Bool {
        guard let lhsStoredID = lhs.remoteStoredID,
              let rhsStoredID = rhs.remoteStoredID else { return false }
        return lhsStoredID == rhsStoredID
            && lhs.remoteSource == rhs.remoteSource
            && lhs.agentIDs == rhs.agentIDs
    }

    static func isTransientActivityAlias(
        _ local: SessionRecord,
        of incoming: SessionRecord
    ) -> Bool {
        guard let storedID = incoming.remoteStoredID else { return false }
        return local.id != incoming.id
            && local.id == storedID
            && local.remoteStoredID == nil
            && local.remoteSource == nil
            && local.agentIDs.isEmpty
    }

    static func promotedTransientAlias(
        _ local: SessionRecord,
        to incoming: SessionRecord
    ) -> SessionRecord {
        var promoted = local
        promoted.remoteStoredID = incoming.remoteStoredID
        promoted.remoteSource = incoming.remoteSource
        promoted.agentIDs = incoming.agentIDs
        return promoted
    }

    static func mergedMatchingLocal(
        _ local: SessionRecord,
        incoming: SessionRecord
    ) -> SessionRecord {
        let mergeSource = isTransientActivityAlias(local, of: incoming)
            ? promotedTransientAlias(local, to: incoming)
            : local
        return merged(local: mergeSource, incoming: incoming)
    }

    private struct HistoryEventIdentity: Hashable {
        let turnID: String
        let eventID: String
        let kind: String
        init(_ event: ChatActivityEvent) {
            turnID = event.turnID
            eventID = event.eventID
            kind = event.kind.rawValue
        }
    }

    static func merged(
        local: SessionRecord,
        incoming: SessionRecord,
        preferIncomingTranscript: Bool = false,
        canonicalToolCallIDs: Set<String> = []
    ) -> SessionRecord {
        var merged = incoming
        // A legacy or partial catalog response may omit the persisted remote
        // coordinate. Never discard a verified local coordinate in that case;
        // it is required to hydrate history after a cold launch.
        if merged.remoteStoredID == nil {
            merged.remoteStoredID = local.remoteStoredID
        }
        if merged.remoteSource == nil {
            merged.remoteSource = local.remoteSource
        }
        if preferIncomingTranscript,
           merged.workspaceID == nil,
           merged.workspaceName == nil {
            merged.workspaceID = local.workspaceID
            merged.workspaceName = local.workspaceName
        }
        let hasExactNativeAppIdentity = local.id == incoming.id
            && local.id.hasPrefix(DirectHermesSessionIdentity.prefix + ":")
            && local.kind == .direct && incoming.kind == .direct
            && local.agentIDs == incoming.agentIDs
            && (local.remoteSource == nil || local.remoteSource == merged.remoteSource)
        let hasSameTranscriptOwner = (local.remoteStoredID == merged.remoteStoredID
            && local.remoteSource == merged.remoteSource) || hasExactNativeAppIdentity
        if hasSameTranscriptOwner, local.agentIDs == merged.agentIDs,
           let roster = local.sessionSubagents,
           roster.updatedAt >= (merged.sessionSubagents?.updatedAt ?? 0) {
            merged.sessionSubagents = roster.routed(to: merged.id)
        }
        // Todo revisions are transcript-owned and survive list/history refresh.
        // Preserve local on equality so a same-revision changed or empty payload
        // cannot erase current state; only a strictly newer revision replaces it.
        if hasSameTranscriptOwner, local.agentIDs == merged.agentIDs,
           let todos = local.sessionTodos,
           todos.revision >= (merged.sessionTodos?.revision ?? -1) {
            merged.sessionTodos = todos.routed(to: merged.id)
        }
        if hasSameTranscriptOwner && merged.parentSessionID == nil {
            merged.parentSessionID = local.parentSessionID
        }
        // `list` intentionally carries a one-item preview so the catalog can
        // render quickly. Once a full transcript has been hydrated, that
        // preview must not replace the canonical transcript on a later
        // refresh. A hydrated history is authoritative for the transcript,
        // even when a stale local cache contains more protocol-only rows.
        if hasSameTranscriptOwner
            && !preferIncomingTranscript
            && (incoming.items.isEmpty || ChatHistoryProjection.isSummaryProjection(incoming.items))
            && (local.items.count > incoming.items.count
                || (local.items.count == incoming.items.count
                    && ChatHistoryProjection.isCanonicalTranscript(local.items))) {
            merged.items = local.items
        }
        // A legacy Hermes catalog can return an unmarked human preview. If a
        // locally verified transcript already contains an assistant turn,
        // that degraded projection must never erase the answer on reopen.
        // History is append-only from the client's perspective; retain the
        // canonical rows until a full transcript hydration replaces them.
        if hasSameTranscriptOwner
            && !preferIncomingTranscript
            && local.items.contains(where: { $0.role == .assistant })
            && !incoming.items.contains(where: { $0.role == .assistant }) {
            merged.items = local.items
        }
        // A running turn can be visible before Hermes flushes its durable
        // display page. Preserve a verified transcript through that temporary
        // empty page; a later non-empty hydration remains authoritative.
        if hasSameTranscriptOwner
            && preferIncomingTranscript
            && incoming.isActive
            && incoming.items.isEmpty
            && ChatHistoryProjection.isCanonicalTranscript(local.items) {
            merged.items = local.items
        }
        // Live activity can arrive before Hermes persists the child row. Hydration
        // is allowed to replace transcript fields, but it must reconcile activity
        // through the canonical ledger so a detached stale row cannot erase it.
        // This also folds a later terminal event with a new eventID into the
        // provisional tool entry and keeps the canonical detail/lifecycle.
        if hasSameTranscriptOwner {
            if local.activityEvents.isEmpty {
                merged.activityEvents = incoming.activityEvents
            } else {
                let canonicalCalls = Dictionary(grouping: incoming.activityEvents.filter { $0.toolCallID != nil }, by: { $0.toolCallID! })
                // Keep every conflicting stored variant. They already replace
                // the disposable live overlay for that exact native call ID;
                // retaining both would append a second "More completed work" fold.
                let coveredCalls = Set(canonicalCalls.filter { $0.value.count == 1 }.keys)
                    .union(canonicalToolCallIDs)
                let canonicalIdentities = Dictionary(grouping: incoming.activityEvents, by: HistoryEventIdentity.init)
                    .mapValues { Set($0.map(\.id)) }
                let retained = preferIncomingTranscript
                    ? local.activityEvents.filter { event in
                        // A page boundary can refine an orphan result into a
                        // linked tool call (or back). It is still the same stored
                        // event in the same turn, not another visible work trail.
                        if let identities = canonicalIdentities[HistoryEventIdentity(event)],
                           !identities.contains(event.id) { return false }
                        guard let call = event.toolCallID else { return true }
                        return !coveredCalls.contains(call)
                    } : local.activityEvents
                merged.activityEvents = ChatActivityLedger(
                    sessionID: merged.id,
                    events: retained.map { $0.routed(to: merged.id) }
                        + incoming.activityEvents.map { $0.routed(to: merged.id) }
                ).allEvents
            }
        }
        if hasSameTranscriptOwner, let runtime = local.sessionRuntime,
           runtime.observedAt > (merged.sessionRuntime?.observedAt ?? .distantPast) {
            merged.sessionRuntime = runtime
        }
        if hasSameTranscriptOwner {
            // Selection/receipt state is app-local authority, never a remote
            // catalog default. Refresh must not erase an ambiguous submission.
            merged.referenceState = local.referenceState
            merged.referenceGitHubCredentialID = local.referenceGitHubCredentialID
            merged.referenceGitHubDisabled = local.referenceGitHubDisabled
            merged.items = ReferenceCanonicalHistory.preservingAcceptedRows(
                local: local.items, incoming: merged.items)
        }
        // Both list overlays and history can carry an older copied draft.
        // They own remote state, not the current local composer. Preserve a
        // newer edit or explicit clear, including an empty post-send draft.
        if hasSameTranscriptOwner, local.kind == merged.kind, local.agentIDs == merged.agentIDs {
            merged.draft = local.draft
        }
        if hasSameTranscriptOwner && incoming.botModeRoomID == nil {
            merged.botModeRoomID = local.botModeRoomID
        }
        if hasSameTranscriptOwner, let localGoal = local.sessionGoal?.routed(to: merged.id),
           localGoal.supersedes(merged.sessionGoal) {
            merged.sessionGoal = localGoal
        }
        if hasSameTranscriptOwner,
            local.sessionContext.map({ localContext in
               merged.sessionContext.map({ $0.updatedAt < localContext.updatedAt }) ?? true
           }) == true {
            merged.sessionContext = local.sessionContext?.routed(to: merged.id)
        }
        if hasSameTranscriptOwner
            && local.botModePrivateHistory.count > incoming.botModePrivateHistory.count {
            merged.botModePrivateHistory = local.botModePrivateHistory
        }
        merged.activityVisibility = local.activityVisibility
        // Pinning is intentionally app-local. Remote list/hydration rows may
        // carry a legacy or default false value, so an existing local record
        // remains authoritative for its pin state across every refresh.
        merged.isPinned = local.isPinned
        // The host's saved last activity wins once nothing is in progress here. Keeping the newer
        // of the two kept times Hermes had stamped on merely reopened chats forever.
        merged.updatedAt = local.isActive ? max(local.updatedAt, incoming.updatedAt) : incoming.updatedAt
        merged.hasAcceptedMessage = (hasSameTranscriptOwner && local.hasAcceptedMessage)
            || incoming.hasAcceptedMessage
            || merged.items.contains(where: { $0.role == .human })
        if hasSameTranscriptOwner && !preferIncomingTranscript {
            if !local.isContentLoaded {
                // A remote list preview is not a replacement transcript. Keep
                // the local pointer through refreshes and alias promotion;
                // explicit open restores it before authoritative hydration.
                merged.localContentRevision = local.localContentRevision
                merged.localContentScope = local.localContentScope
                merged.catalogPreview = incoming.catalogPreview
                    ?? (incoming.items.isEmpty ? local.catalogPreview : String(incoming.summary.preview.prefix(512)))
                merged.hasDeferredReferenceState = local.hasDeferredReferenceState
                merged.draft = ""
                merged.referenceState = nil
                merged.items = []
                merged.botModePrivateHistory = []
                merged.activityEvents = []
            } else if !incoming.isContentLoaded {
                // Re-reading the metadata cache must not unload an already
                // mounted/edited conversation or resurrect its saved draft.
                merged.localContentRevision = nil
                merged.localContentScope = nil
                merged.catalogPreview = nil
                merged.hasDeferredReferenceState = false
                merged.draft = local.draft
                merged.referenceState = local.referenceState
                merged.items = local.items
                merged.botModePrivateHistory = local.botModePrivateHistory
                merged.activityEvents = local.activityEvents
            }
        }
        return merged
    }

    static func isSummaryProjection(_ items: [TimelineItem]) -> Bool {
        guard items.count == 1 else { return false }
        return items[0].id.hasSuffix(":summary-preview")
    }

    static func isCanonicalTranscript(_ items: [TimelineItem]) -> Bool {
        !items.isEmpty && !isSummaryProjection(items)
    }
}
