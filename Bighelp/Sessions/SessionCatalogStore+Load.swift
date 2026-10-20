import Foundation

/// Loading the catalog: the saved copy, then what the host lists, merged into the records.
extension SessionCatalogStore {
    func load(requireAuthoritativeRefresh: Bool = false) async throws {
        guard requireAuthoritativeRefresh else {
            try await performLoad(requireAuthoritativeRefresh: false)
            return
        }
        try Task.checkCancellation()
        let account = accountGeneration
        let flight: AuthoritativeLoad
        if let existing = authoritativeLoad {
            flight = existing
        } else {
            let invalidation = loadInvalidationGeneration
            flight = AuthoritativeLoad(task: Task { @MainActor in
                while true {
                    try Task.checkCancellation()
                    guard account == self.accountGeneration else { throw CancellationError() }
                    do {
                        try await self.performLoad(requireAuthoritativeRefresh: true)
                        return
                    } catch SessionCatalogLoadOwnershipError.superseded {
                        // A normal list may win while opening a session. Retry
                        // once it yields; an accepted Stop must still fence us.
                        guard invalidation == self.loadInvalidationGeneration else {
                            throw SessionCatalogLoadOwnershipError.superseded
                        }
                    }
                }
            })
            authoritativeLoad = flight
        }
        let waiter = UUID()
        let flightID = flight.id
        authoritativeLoad?.waiters.insert(waiter)
        defer { releaseAuthoritativeWaiter(waiter, flightID: flightID) }
        try await withTaskCancellationHandler {
            try await flight.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseAuthoritativeWaiter(waiter, flightID: flightID)
            }
        }
        try Task.checkCancellation()
        guard account == accountGeneration else { throw CancellationError() }
    }

    func releaseAuthoritativeWaiter(_ waiter: UUID, flightID: UUID) {
        guard authoritativeLoad?.id == flightID else { return }
        authoritativeLoad?.waiters.remove(waiter)
        if authoritativeLoad?.waiters.isEmpty == true {
            let task = authoritativeLoad?.task
            authoritativeLoad = nil
            task?.cancel()
        }
    }

    func performLoad(requireAuthoritativeRefresh: Bool) async throws {
        let generation = accountGeneration
        loadPinPreferences()
        latestLoadGeneration &+= 1
        let loadGeneration = latestLoadGeneration
        var hasUsableLocalState = hasLoadedCatalogState || !records.isEmpty
        var changed = false
        // While a checkpoint is pending, the records are ahead of the saved copy: reading it back
        // would return chats the host's last list no longer had (archived on another device).
        if let repository, !requireAuthoritativeRefresh, !hasUnsavedChanges {
            do {
                let cachedRecords = try repository.load()
                repositoryAllowsWrites = true
                hasLoadedCatalogState = true
                hasUsableLocalState = true
                migratePinnedRecordsIfNeeded(cachedRecords)
                let preferredCachedRecords = applyingPinPreferences(to: cachedRecords)
                changed = adopt(cachedRecords.contains(where: { !$0.isContentLoaded })
                    ? SessionCatalogReconciliation.merged(local: records, incoming: preferredCachedRecords)
                    : SessionCatalogReconciliation.retained(preferredCachedRecords))
                changed = applyKnownSubagentParents() || changed
            } catch {
                repositoryAllowsWrites = false
                hasUsableLocalState = hasLoadedCatalogState || !records.isEmpty
            }
        }

        do {
            let incomingRecords = try await BighelpLinkTransientRetry.perform {
                try await self.client.list()
            }
            guard generation == accountGeneration else { throw CancellationError() }
            guard loadGeneration == latestLoadGeneration else {
                throw SessionCatalogLoadOwnershipError.superseded
            }
            let protectedIncoming = applyingPinPreferences(
                to: incomingRecords.map(protectAcceptedStop)
            )
            changed = adopt((!requireAuthoritativeRefresh && (repository != nil || hasUnsavedChanges))
                ? SessionCatalogReconciliation.merged(local: records, incoming: protectedIncoming)
                : SessionCatalogReconciliation.reconciled(local: records, authoritativeIncoming: protectedIncoming)) || changed
            changed = applyKnownSubagentParents() || changed
            hasLoadedCatalogState = true
            loadErrorMessage = nil
            refreshErrorMessage = nil
        } catch {
            guard generation == accountGeneration else { throw CancellationError() }
            guard loadGeneration == latestLoadGeneration else {
                throw SessionCatalogLoadOwnershipError.superseded
            }
            if error is CancellationError {
                throw CancellationError()
            }
            if hasUsableLocalState {
                loadErrorMessage = nil
                refreshErrorMessage = "Sessions could not be refreshed. Try again."
                if !requireAuthoritativeRefresh {
                    return
                }
                throw error
            }
            refreshErrorMessage = nil
            loadErrorMessage = "Sessions could not be loaded. Try again."
            throw error
        }

        // A host with thousands of scheduled runs says `sessions.changed` every few seconds. A
        // refresh that found nothing new writes nothing, and one that did encodes off the main
        // actor with the next checkpoint; nothing here waits on the catalog being on disk.
        if changed || hasUnsavedChanges { schedulePersistenceCheckpoint() }
    }
}
