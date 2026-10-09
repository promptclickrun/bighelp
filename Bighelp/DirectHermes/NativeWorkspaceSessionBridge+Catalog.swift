import Foundation

/// Catalog inventory, canonical creation and hydration through the retained stream owner.
extension NativeWorkspaceSessionBridge {
    func list() async throws -> [SessionRecord] {
        guard let owner = connections.owner, owner.authority == authority else {
            throw WorkspaceClientError.transportUnavailable
        }
        let snapshotVerificationSequence = streamVerificationSequence
        let catalog = try box.value()
        var records = try await catalog.list()
        guard !retired, connections.owner == owner else { throw WorkspaceClientError.ownerChanged }
        // The underlying catalog binding can finish an older history read after
        // a live todo callback. Preserve exact-owner live provenance even when
        // that callback preceded this list request; revision alone is not a
        // cross-turn clock.
        for (id, stream) in streams where stream.owner == owner {
            guard let index = records.firstIndex(where: { $0.id == id }),
                  let observed = stream.record.sessionTodos,
                  observed.sessionID.utf8.elementsEqual(id.utf8),
                  observed.supersedes(records[index].sessionTodos) else { continue }
            records[index].sessionTodos = observed.routed(to: id)
        }
        let mappings = try catalog.activeSessionMappings()
        guard !retired, connections.owner == owner,
              mappings.allSatisfy({ $0.owner == owner }) else {
            throw WorkspaceClientError.ownerChanged
        }
        var refreshedMappings = Dictionary(uniqueKeysWithValues: mappings.map {
            (DirectHermesSessionIdentity.key($0.runtimeID), $0)
        })

        // `catalog.list()` commits the inventory it began with. A chat can be
        // resolved and bound while that request is awaiting the host, so its
        // exact binding may be absent from the just-committed older snapshot.
        // Let only a newer, current-owner verification supersede that absence.
        for (id, stream) in streams where stream.owner == owner
            && stream.verificationSequence > snapshotVerificationSequence {
            let mapping = DirectHermesActiveSessionMapping(
                owner: owner,
                visibleID: id,
                profileID: stream.client.profile,
                runtimeID: stream.client.runtimeID,
                sessionKey: stream.client.storedID
            )
            let runtimeKey = DirectHermesSessionIdentity.key(mapping.runtimeID)
            if let existing = refreshedMappings[runtimeKey], existing.visibleID != id {
                // A newer stream cannot take a runtime that this same snapshot
                // assigns to another visible session. Keep the mounted state,
                // but fail this refresh without publishing wrong-owner facts.
                throw WorkspaceClientError.invalidResponse
            }
            refreshedMappings = refreshedMappings.filter { _, candidate in
                candidate.visibleID != id
            }
            refreshedMappings[runtimeKey] = mapping
        }
        activeMappings = refreshedMappings

        let remoteIDs = Set(records.map(\.id))
        var merged = records
        for (id, stream) in streams where stream.owner == owner
            && stream.verificationSequence > snapshotVerificationSequence {
            if let index = merged.firstIndex(where: { $0.id == id }) {
                merged[index] = stream.record
            } else {
                merged.append(stream.record)
            }
        }
        for id in remoteIDs {
            guard var stream = streams[id] else { continue }
            guard stream.verificationSequence <= snapshotVerificationSequence else { continue }
            let record = records.first(where: { $0.id == id })
            if stream.owner != owner {
                guard let record,
                      Self.canRebindRetainedStream(
                        streamOwner: stream.owner,
                        owner: owner,
                        record: record,
                        profileID: stream.client.profile,
                        storedID: stream.client.storedID,
                        runtimeID: stream.client.runtimeID
                      ), Self.sameOrAdoptingSource(stream.record.remoteSource, record.remoteSource) else {
                    streams[id] = nil
                    onSessionRetired?(id)
                    stream.client.suspend()
                    continue
                }
                // Keep the old owner stamp so prepare() must durably resume the
                // stored coordinate before it can publish a new lease.
                stream.record = record
                stream.retainIfOmitted = false
                streams[id] = stream
                continue
            }
            let active = activeMappings[DirectHermesSessionIdentity.key(stream.client.runtimeID)]
            guard active.map({
                $0.owner == owner
                    && $0.visibleID == id
                    && DirectHermesSessionValidation.same($0.runtimeID, stream.client.runtimeID)
            }) == true else {
                streams[id] = nil
                unbindPromptSession(stream, visibleSessionID: id)
                onSessionRetired?(id)
                stream.client.suspend()
                continue
            }
            // Once Hermes exposes the durable row, the remote catalog is the
            // authority again. Do not resurrect this session if a later list
            // omits it because it was archived or removed elsewhere.
            stream.retainIfOmitted = false
            if let record = records.first(where: { $0.id == id }) {
                let adoptsExactLiveIdentity = active.map {
                    $0.owner == owner
                        && $0.visibleID == id
                        && DirectHermesSessionValidation.same($0.runtimeID, stream.client.runtimeID)
                        && DirectHermesSessionValidation.same($0.sessionKey, stream.client.storedID)
                } == true
                let adoptsSavedSource = adoptsExactLiveIdentity
                    && stream.record.remoteSource == nil && record.remoteSource != nil
                if stream.record.agentIDs != record.agentIDs
                    || (!DirectHermesIdentity.matches(stream.record.remoteStoredID, record.remoteStoredID)
                        && !DirectHermesIdentity.matches(record.remoteStoredID, stream.client.storedID)
                        && !adoptsExactLiveIdentity)
                    || (!DirectHermesIdentity.matches(stream.record.remoteSource, record.remoteSource)
                        && !adoptsSavedSource) {
                    // Same visible ID does not grant a replacement coordinate
                    // the old canvas or an in-progress preparation owner.
                    streams[id] = nil
                    unbindPromptSession(stream, visibleSessionID: id)
                    onSessionRetired?(id)
                    stream.client.suspend()
                    continue
                }
                if adoptsSavedSource {
                    try stream.client.adoptVerifiedCatalogSource(previous: stream.record, next: record)
                }
                stream.record = record
            }
            streams[id] = stream
        }
        for id in streams.keys.sorted() {
            guard !remoteIDs.contains(id), let stream = streams[id] else { continue }
            guard stream.verificationSequence <= snapshotVerificationSequence else { continue }
            if stream.retainIfOmitted,
               (stream.owner != owner || activeMappings[DirectHermesSessionIdentity.key(stream.client.runtimeID)] == nil),
               Self.canRebindRetainedStream(
                    streamOwner: stream.owner,
                    owner: owner,
                    record: stream.record,
                    profileID: stream.client.profile,
                    storedID: stream.client.storedID,
                    runtimeID: stream.client.runtimeID
               ) {
                // A verified create can remain absent until its first turn.
                // Inventory omission is not deletion of this unpublished owner.
                // A changed connection still requires durable resume in prepare.
                merged.append(stream.record)
                continue
            }
            let active = activeMappings[DirectHermesSessionIdentity.key(stream.client.runtimeID)]
            guard active.map({
                $0.owner == owner
                    && $0.visibleID == id
                    && DirectHermesSessionValidation.same($0.runtimeID, stream.client.runtimeID)
            }) == true else {
                streams[id] = nil
                unbindPromptSession(stream, visibleSessionID: id)
                onSessionRetired?(id)
                stream.client.suspend()
                continue
            }
            guard stream.retainIfOmitted,
                  stream.owner.authority == owner.authority,
                  stream.owner.authenticationGeneration == owner.authenticationGeneration,
                  stream.record.kind == .direct,
                  stream.record.agentIDs.count == 1,
                  stream.record.remoteStoredID != nil else { continue }
            // A record synthesized here is still a verified Hermes result from
            // `session.create`; it remains marked for retention until Hermes
            // returns the durable row in a later authoritative list.
            merged.append(stream.record)
        }
        return merged
    }

    func canonicalToolCallIDs(for record: SessionRecord) -> Set<String> {
        guard !retired, connections.owner?.authority == authority else { return [] }
        return (try? box.value())?.canonicalToolCallIDs(for: record) ?? []
    }

    func refreshMetadata(_ record: SessionRecord) async throws -> SessionRecord? {
        try await prepare(record, catalog: box.value())
    }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        let client = try box.value()
        let record = try await client.create(kind: kind, agentIDs: agentIDs)
        return try await prepare(record, catalog: client, preserveIfOmitted: true)
    }

    func hydrate(_ record: SessionRecord) async throws -> SessionRecord {
        let owner = try currentOwner()
        let client = try box.value()
        let boundary = streamVerificationSequence
        let hydrated = try preservingTodoObserved(
            after: boundary, owner: owner, in: try await client.hydrate(record)
        )
        return try await prepare(hydrated, catalog: client)
    }

    func hydrate(_ record: SessionRecord, onProgress: @escaping SessionHydrationProgress) async throws -> SessionRecord {
        let owner = try currentOwner()
        let client = try box.value()
        let boundary = streamVerificationSequence
        let hydrated = try await client.hydrate(record) { [weak self] partial in
            guard let self else { throw WorkspaceClientError.ownerChanged }
            try onProgress(try self.preservingTodoObserved(after: boundary, owner: owner, in: partial))
        }
        let protected = try preservingTodoObserved(after: boundary, owner: owner, in: hydrated)
        return try await prepare(protected, catalog: client)
    }

    func hydratePage(_ record: SessionRecord, offset: Int?, turnLimit: Int) async throws -> SessionHydrationPage {
        let owner = try currentOwner()
        let client = try box.value()
        let boundary = streamVerificationSequence
        let page = try await client.hydratePage(record, offset: offset, turnLimit: turnLimit)
        let protected = try preservingTodoObserved(after: boundary, owner: owner, in: page.record)
        guard offset == nil else {
            return SessionHydrationPage(record: protected, nextOffset: page.nextOffset)
        }
        let prepared = try await prepare(protected, catalog: client)
        return SessionHydrationPage(record: prepared, nextOffset: page.nextOffset)
    }

    /// History/catalog reads begin from a captured SessionRecord. If an exact
    /// current-owner stream publishes a full todo state while that read awaits,
    /// carry the newer live authority into every progress/final result before
    /// SessionCatalogStore can merge or persist the stale captured revision.
    private func preservingTodoObserved(
        after verificationBoundary: UInt64,
        owner: WorkspaceOwner,
        in candidate: SessionRecord
    ) throws -> SessionRecord {
        guard !retired, connections.owner == owner else {
            throw WorkspaceClientError.ownerChanged
        }
        guard let stream = streams[candidate.id],
              stream.owner == owner,
              stream.verificationSequence > verificationBoundary,
              let observed = stream.record.sessionTodos,
              observed.sessionID.utf8.elementsEqual(candidate.id.utf8),
              observed.supersedes(candidate.sessionTodos) else { return candidate }
        var result = candidate
        result.sessionTodos = observed.routed(to: candidate.id)
        return result
    }

    func fork(record: SessionRecord, throughItemID: String) async throws -> SessionRecord {
        let client = try box.value()
        let fork = try await client.fork(record: record, throughItemID: throughItemID)
        return try await prepare(fork, catalog: client)
    }

    func rename(_ record: SessionRecord, title: String) async throws {
        try await box.value().rename(record, title: title)
        guard var stream = streams[record.id] else { return }
        stream.record.title = title
        streams[record.id] = stream
    }
    func setPinned(_ record: SessionRecord, pinned: Bool) async throws {
        try await box.value().setPinned(record, pinned: pinned)
        guard var stream = streams[record.id] else { return }
        stream.record.isPinned = pinned
        streams[record.id] = stream
    }
    func archive(_ record: SessionRecord) async throws {
        try await box.value().archive(record)
        guard var stream = streams[record.id] else { return }
        stream.retainIfOmitted = false
        streams[record.id] = stream
    }
    func delete(_ record: SessionRecord) async throws {
        try await box.value().delete(record)
        canonicalSessionReentryFlights.removeValue(forKey: record.id)?.task.cancel()
        authoritativeRecoveryFlights.removeValue(forKey: record.id)?.task.cancel()
        if let stream = streams.removeValue(forKey: record.id) {
            unbindPromptSession(stream, visibleSessionID: record.id)
            stream.client.suspend()
        }
        onSessionRetired?(record.id)
    }

    func canonicalChat(profileID: String) async throws -> SessionRecord {
        let client = try box.value()
        let descriptor: DirectHermesResolvedSession
        let wasCreated: Bool
        switch try await client.resolveCanonicalChat(profileID: profileID) {
        case .resolved(let resolved):
            descriptor = resolved
            wasCreated = false
        case .notCreated:
            descriptor = try await client.createFirstCanonicalChat(profileID: profileID)
            wasCreated = true
        }
        var hydrated = try await client.hydrate(descriptor.record)
        // The registry doesn't report the chat's source, but a stream retained
        // across a reconnect does. Without it, prepare() reads the gap as another
        // chat and retires the stream, so the first tap after a reconnect failed.
        if hydrated.remoteSource == nil { hydrated.remoteSource = streams[hydrated.id]?.record.remoteSource }
        return try await prepare(hydrated, catalog: client,
                                 preserveIfOmitted: Self.preservesUnpublishedCanonical(
                                    hydrated, wasCreated: wasCreated, durability: descriptor.durability))
    }

    static func preservesUnpublishedCanonical(_ record: SessionRecord, wasCreated: Bool,
                                               durability: DirectHermesSessionDurability) -> Bool {
        wasCreated || durability == .draft || (!record.hasAcceptedMessage && record.items.isEmpty)
    }

    /// Maintenance APIs return Hermes' durable ID, including for an archived
    /// lineage descendant that the ordinary Sessions list intentionally omits.
    /// Resolve that ID through the same catalog decoder and bridge preparation
    /// path rather than manufacturing a visible or runtime coordinate.
    func prepareStoredSession(profileID: String, storedSessionID: String) async throws -> SessionRecord {
        try DirectHermesSessionValidation.coordinate(profileID, maximum: 128)
        try DirectHermesSessionValidation.coordinate(storedSessionID)
        let owner = try currentOwner()
        let catalog = try box.value()
        var options = DirectHermesSessionListOptions()
        options.archived = .include
        let records = try await catalog.list(options: options)
        guard !retired, connections.owner == owner else {
            throw WorkspaceClientError.ownerChanged
        }
        let matches = records.filter { record in
            record.kind == .direct
                && record.agentIDs.count == 1
                && DirectHermesSessionValidation.same(record.agentIDs[0], profileID)
                && record.remoteStoredID.map {
                    DirectHermesSessionValidation.same($0, storedSessionID)
                } == true
        }
        guard matches.count == 1, let record = matches.first else {
            throw NativeWorkspaceLifecycleError.durableSessionUnavailable
        }
        return try await prepare(record, catalog: catalog)
    }
}
