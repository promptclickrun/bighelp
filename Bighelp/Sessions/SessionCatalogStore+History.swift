import Foundation

extension SessionCatalogStore {
    func hasPreviousHistory(id: String) -> Bool {
        previousHistoryOffsetByID[id] != nil
    }

    private func publishLivePresentation(_ page: SessionHydrationPage, record: SessionRecord) {
        if let live = page.livePresentation, let owner = page.presentationOwner {
            onLivePresentation?(record, live, owner)
        }
    }

    func installSessionStateSnapshot(_ page: SessionHydrationPage, source: SessionRecord) throws -> SessionRecord {
        let id = source.id
        let generation = (latestHydrationGenerationByID[id] ?? 0) &+ 1
        latestHydrationGenerationByID[id] = generation
        let record = try applyHydration(page.record, id: id, source: source,
            accountGeneration: accountGeneration, hydrationGeneration: generation)
        previousHistoryOffsetByID[id] = page.nextOffset
        publishLivePresentation(page, record: record)
        return record
    }

    func hydrateInitialPage(
        id: String,
        turnLimit: Int = 8
    ) async throws -> SessionRecord {
        try Task.checkCancellation()
        let account = accountGeneration
        let flight: InitialHistoryLoad
        if let existing = initialHistoryLoads[id] { flight = existing }
        else {
            flight = InitialHistoryLoad(task: Task { @MainActor in
                try await self.performInitialHistoryLoad(id: id, turnLimit: turnLimit)
            })
            initialHistoryLoads[id] = flight
        }
        let waiter = UUID()
        let flightID = flight.id
        initialHistoryLoads[id]?.waiters.insert(waiter)
        defer { releaseHistoryWaiter(waiter, sessionID: id, flightID: flightID) }
        let record = try await withTaskCancellationHandler {
            try await flight.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseHistoryWaiter(waiter, sessionID: id, flightID: flightID)
            }
        }
        try Task.checkCancellation()
        guard accountGeneration == account else { throw CancellationError() }
        return record
    }

    private func releaseHistoryWaiter(_ waiter: UUID, sessionID: String, flightID: UUID) {
        guard initialHistoryLoads[sessionID]?.id == flightID else { return }
        initialHistoryLoads[sessionID]?.waiters.remove(waiter)
        if initialHistoryLoads[sessionID]?.waiters.isEmpty == true {
            initialHistoryLoads.removeValue(forKey: sessionID)?.task.cancel()
        }
    }

    func cancelHistoryRefreshes() {
        let flights = initialHistoryLoads
        initialHistoryLoads = [:]
        for (id, flight) in flights {
            latestHydrationGenerationByID[id] = (latestHydrationGenerationByID[id] ?? 0) &+ 1
            flight.task.cancel()
        }
    }

    private func performInitialHistoryLoad(id: String, turnLimit: Int) async throws -> SessionRecord {
        let record = try restoreSessionContent(id: id)
        let generation = accountGeneration
        let hydrationGeneration = (latestHydrationGenerationByID[id] ?? 0) &+ 1
        latestHydrationGenerationByID[id] = hydrationGeneration
        let page = try await client.hydratePage(
            record,
            offset: nil,
            turnLimit: turnLimit
        )
        try Task.checkCancellation()
        let merged = try applyHydration(
            page.record,
            id: id,
            source: record,
            accountGeneration: generation,
            hydrationGeneration: hydrationGeneration
        )
        previousHistoryOffsetByID[id] = page.nextOffset
        publishLivePresentation(page, record: merged)
        return merged
    }

    func hydratePreviousPage(
        id: String,
        turnLimit: Int = 8
    ) async throws -> SessionRecord {
        _ = try restoreSessionContent(id: id)
        guard
            let record = session(id: id),
            let offset = previousHistoryOffsetByID[id]
        else { throw SessionCatalogError.invalidSession }
        let generation = accountGeneration
        let hydrationGeneration = (latestHydrationGenerationByID[id] ?? 0) &+ 1
        latestHydrationGenerationByID[id] = hydrationGeneration
        let page = try await client.hydratePage(
            record,
            offset: offset,
            turnLimit: turnLimit
        )
        let combined = SessionCatalogReconciliation.prependingHistory(page.record, to: record)
        let merged = try applyHydration(
            combined,
            id: id,
            source: record,
            accountGeneration: generation,
            hydrationGeneration: hydrationGeneration
        )
        previousHistoryOffsetByID[id] = page.nextOffset
        publishLivePresentation(page, record: merged)
        return merged
    }

    func hydrateSession(id: String) async throws -> SessionRecord {
        try await hydrateSession(id: id, onProgress: { _ in })
    }

    func hydrateSession(
        id: String,
        onProgress: @escaping SessionHydrationProgress
    ) async throws -> SessionRecord {
        let record = try restoreSessionContent(id: id)
        let generation = accountGeneration
        let hydrationGeneration = (latestHydrationGenerationByID[id] ?? 0) &+ 1
        latestHydrationGenerationByID[id] = hydrationGeneration
        var lastClientProgress: SessionRecord?
        let hydrated = try await client.hydrate(record) { [self] partial in
            let merged = try applyHydration(
                partial,
                id: id,
                source: record,
                accountGeneration: generation,
                hydrationGeneration: hydrationGeneration
            )
            lastClientProgress = partial
            try onProgress(merged)
        }
        if lastClientProgress != hydrated {
            let merged = try applyHydration(
                hydrated,
                id: id,
                source: record,
                accountGeneration: generation,
                hydrationGeneration: hydrationGeneration
            )
            try onProgress(merged)
            return merged
        }
        guard let current = session(id: id) else {
            throw SessionCatalogError.invalidSession
        }
        return current
    }

    private func applyHydration(
        _ hydrated: SessionRecord,
        id: String,
        source record: SessionRecord,
        accountGeneration generation: UInt64,
        hydrationGeneration: UInt64
    ) throws -> SessionRecord {
        guard
            generation == accountGeneration,
            latestHydrationGenerationByID[id] == hydrationGeneration,
            let current = session(id: id),
            current.agentIDs == record.agentIDs,
            current.remoteStoredID == record.remoteStoredID,
            DirectHermesIdentity.sameSessionSource(current.remoteSource, record.remoteSource)
        else { throw CancellationError() }
        guard hydrated.id == id else { throw SessionCatalogError.invalidSession }
        let protectedHydration = protectAcceptedStop(hydrated)
        let merged = SessionCatalogReconciliation.merged(
            local: current,
            incoming: protectedHydration,
            preferIncomingTranscript: true,
            canonicalToolCallIDs: client.canonicalToolCallIDs(for: protectedHydration)
        )
        upsert(merged)
        schedulePersistenceCheckpoint()
        return merged
    }

    /// Refreshes one already-discovered session without repeating the global
    /// catalog request. If another consumer wins an overlapping hydration, its
    /// canonical result is returned instead of turning ownership supersession
    /// into a permanently frozen child-session surface.
    func refreshKnownSession(id: String) async throws -> SessionRecord {
        guard session(id: id) != nil else { throw SessionCatalogError.invalidSession }
        if initialHistoryLoads[id] != nil { return try await hydrateInitialPage(id: id) }
        let generation = accountGeneration
        let expectedHydrationGeneration = (latestHydrationGenerationByID[id] ?? 0) &+ 1
        do {
            let refreshed = try await hydrateSession(id: id)
            try Task.checkCancellation()
            return refreshed
        } catch is CancellationError {
            try Task.checkCancellation()
            guard generation == accountGeneration else { throw CancellationError() }
            guard
                latestHydrationGenerationByID[id] != expectedHydrationGeneration,
                let winner = session(id: id)
            else { throw CancellationError() }
            return winner
        }
    }

    /// Brings an open chat up to date when the app comes back: its newest page, with the earlier
    /// messages it already holds, and where "load earlier" goes on from. Reading its whole history
    /// here swapped a long chat's page for every message it ever had, read and laid out on the main
    /// thread just as the person scrolled.
    func refreshHeldHistory(id: String) async throws -> SessionHydrationPage {
        guard session(id: id) != nil else { throw SessionCatalogError.invalidSession }
        if initialHistoryLoads[id] != nil {
            let record = try await hydrateInitialPage(id: id)
            return SessionHydrationPage(record: record, nextOffset: previousHistoryOffsetByID[id])
        }
        let record = try restoreSessionContent(id: id)
        let generation = accountGeneration
        let hydrationGeneration = (latestHydrationGenerationByID[id] ?? 0) &+ 1
        latestHydrationGenerationByID[id] = hydrationGeneration
        do {
            let page = try await client.hydratePage(record, offset: nil, turnLimit: 8)
            try Task.checkCancellation()
            return page
        } catch is CancellationError {
            // Another read of this chat won (it was opened meanwhile): its result is current.
            try Task.checkCancellation()
            guard generation == accountGeneration, latestHydrationGenerationByID[id] != hydrationGeneration,
                  let winner = session(id: id) else { throw CancellationError() }
            return SessionHydrationPage(record: winner, nextOffset: previousHistoryOffsetByID[id])
        }
    }

    /// A confirmed history mutation cannot join a read started before that
    /// mutation. Retire only this session's old flight and fetch canonical state.
    func refreshAfterNativeHistoryMutation(id: String) async throws -> SessionRecord {
        if let old = initialHistoryLoads.removeValue(forKey: id) {
            latestHydrationGenerationByID[id] = (latestHydrationGenerationByID[id] ?? 0) &+ 1
            old.task.cancel()
        }
        return try await hydrateSession(id: id)
    }

    /// Discovers a child session at most once. A successful list persists its
    /// summary before hydration starts, so a transient history failure causes
    /// the next attempt to use the scoped refresh instead of listing again.
    func refreshOrPrepareSession(id: String) async throws -> SessionRecord {
        if session(id: id) != nil {
            return try await refreshKnownSession(id: id)
        }
        return try await prepareExistingSession(id: id)
    }

    /// Refreshes Hermes' authoritative row before a saved session is shown.
    /// Transcript hydration remains a separate operation so the route can
    /// present its canvas while history pages arrive.
    func refreshExistingSession(id: String) async throws -> SessionRecord {
        if let source = session(id: id) {
            let boundary = accountGeneration
            let revision = (latestHydrationGenerationByID[id] ?? 0) &+ 1
            latestHydrationGenerationByID[id] = revision
            if let refreshed = try await client.refreshMetadata(source) {
                return try applyHydration(refreshed, id: id, source: source,
                    accountGeneration: boundary, hydrationGeneration: revision)
            }
        }
        // A persisted catalog row can outlive Hermes resume/branch coordinate
        // changes. Refresh the authoritative catalog before every externally
        // addressed open so hydration targets the exact currently listed row.
        while true {
            try Task.checkCancellation()
            do {
                try await load(requireAuthoritativeRefresh: true)
                break
            } catch SessionCatalogLoadOwnershipError.superseded {
                continue
            }
        }
        guard let record = session(id: id) else {
            throw SessionCatalogError.invalidSession
        }
        return record
    }

    /// Resolves an externally addressed session to its canonical transcript.
    /// Deep links and notifications may arrive before the summary catalog has
    /// loaded, so opening is a two-step operation: discover, then hydrate.
    func prepareExistingSession(id: String) async throws -> SessionRecord {
        _ = try await refreshExistingSession(id: id)
        return try await hydrateSession(id: id)
    }

    /// Resolves a maintenance/import result by its exact durable coordinate,
    /// then prepares that existing row through the installed catalog client.
    /// A durable ID is never treated as a user-facing or live runtime ID.
    func resolveStoredSession(profileID: String, storedSessionID: String) async throws -> SessionRecord {
        try WorkspaceAuthority.validateIdentifier(profileID, maximumBytes: 128)
        try WorkspaceAuthority.validateIdentifier(storedSessionID, maximumBytes: 512)
        let account = accountGeneration
        while true {
            try Task.checkCancellation()
            guard account == accountGeneration else { throw CancellationError() }
            do {
                try await load(requireAuthoritativeRefresh: true)
                break
            } catch SessionCatalogLoadOwnershipError.superseded {
                continue
            }
        }
        guard account == accountGeneration else { throw CancellationError() }
        let matches = records.filter { record in
            record.kind == .direct
                && record.agentIDs.count == 1
                && record.agentIDs.first.map {
                    $0.utf8.elementsEqual(profileID.utf8)
                } == true
                && record.remoteStoredID.map {
                    $0.utf8.elementsEqual(storedSessionID.utf8)
                } == true
        }
        guard matches.count == 1, let match = matches.first else {
            throw NativeWorkspaceLifecycleError.durableSessionUnavailable
        }
        let prepared = try await refreshExistingSession(id: match.id)
        guard account == accountGeneration,
              prepared.agentIDs.count == 1,
              prepared.agentIDs[0].utf8.elementsEqual(profileID.utf8),
              prepared.remoteStoredID.map({
                  $0.utf8.elementsEqual(storedSessionID.utf8)
              }) == true else {
            throw NativeWorkspaceLifecycleError.durableSessionUnavailable
        }
        return prepared
    }
}
