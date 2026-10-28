import Foundation

/// Canonical warm reentry, coalesced by exact client/model/owner identity.
extension NativeWorkspaceSessionBridge {
    /// Inspection only: this cannot resume a durable coordinate or make a
    /// disconnected generation appear warm.
    func isWarmSession(_ record: SessionRecord, model: ChatModel) -> Bool {
        guard !retired, let owner = connections.owner, owner.authority == authority,
              let stream = streams[record.id], stream.owner == owner,
              DirectHermesIdentity.sameSessionSource(stream.record.remoteSource, record.remoteSource),
              stream.boundModel === model else { return false }
        return Self.canReturnToPreparedStream(record: record, model: model, owner: owner,
            streamOwner: stream.owner, recoveredCoordinate: stream.recoveredCoordinate, client: stream.client)
    }

    /// Ownership inspection for Force Refresh. Unlike warm readiness, this
    /// accepts a stale transport so the exact retained coordinate can enter the
    /// durable resume path; readiness is required only after re-entry finishes.
    func retainsCanonicalSession(_ record: SessionRecord, model: ChatModel) -> Bool {
        guard !retired, let owner = connections.owner, owner.authority == authority,
              let stream = streams[record.id], stream.boundModel === model else { return false }
        return Self.canReenterRetainedStream(
            record: record, retainedRecord: stream.record, model: model, owner: owner,
            streamOwner: stream.owner, client: stream.client
        )
    }

    /// Re-enters the exact retained session through fresh canonical history,
    /// replay and activation while keeping the mounted model and socket owner.
    /// Same-session callers join one flight. A failed read on the unchanged
    /// socket restores its prior admission state instead of stranding Send.
    func reenterCanonicalSession(
        _ record: SessionRecord,
        model: ChatModel
    ) async throws -> SessionRecord {
        guard retainsCanonicalSession(record, model: model),
              let owner = connections.owner,
              let stream = streams[record.id] else {
            throw WorkspaceClientError.ownerChanged
        }
        let modelIdentity = ObjectIdentifier(model)
        if let flight = canonicalSessionReentryFlights[record.id] {
            guard flight.owner == owner, flight.client === stream.client,
                  flight.modelIdentity == modelIdentity else {
                throw WorkspaceClientError.ownerChanged
            }
            return try await flight.task.value
        }
        let flightID = UUID()
        let task = Task { @MainActor [weak self, weak client = stream.client, weak model] in
            guard let self, let client, let model else {
                throw WorkspaceClientError.ownerChanged
            }
            return try await self.performCanonicalSessionReentry(
                record: record,
                owner: owner,
                client: client,
                model: model
            )
        }
        canonicalSessionReentryFlights[record.id] = CanonicalSessionReentryFlight(
            id: flightID,
            owner: owner,
            client: stream.client,
            modelIdentity: modelIdentity,
            task: task
        )
        defer {
            if canonicalSessionReentryFlights[record.id]?.id == flightID {
                canonicalSessionReentryFlights[record.id] = nil
            }
        }
        return try await task.value
    }

    private func performCanonicalSessionReentry(
        record: SessionRecord,
        owner: WorkspaceOwner,
        client: DirectHermesConversationClient,
        model: ChatModel
    ) async throws -> SessionRecord {
        guard !retired, connections.owner == owner,
              let initial = streams[record.id], initial.owner == owner,
              initial.client === client, initial.boundModel === model,
              Self.canContinueCanonicalReentry(client) else {
            throw WorkspaceClientError.ownerChanged
        }
        var rollback = initial.record
        rollback.items = model.items
        rollback.activityEvents = model.activityLedger.allEvents
        rollback.isActive = client.projection.running
        rollback.sessionContext = client.sessionContext ?? rollback.sessionContext

        do {
            // This history read does not touch the mounted adapter. If it fails,
            // the existing live stream and composer never leave ready state.
            let catalog = try box.value()
            let canonical = try await catalog.hydrate(record)
            try Task.checkCancellation()
            guard !retired, connections.owner == owner,
                  let beforeProbe = streams[record.id], beforeProbe.owner == owner,
                  beforeProbe.client === client, beforeProbe.boundModel === model,
                  Self.canContinueCanonicalReentry(client) else {
                throw WorkspaceClientError.ownerChanged
            }

            if !client.isReadyForSubmission {
                // A stale/disconnected retained session cannot take the warm
                // path. Use the existing durable reattach pipeline so Force
                // Refresh can repair Send instead of rejecting the action.
                return try await prepare(canonical, catalog: catalog)
            }

            try await initial.lease.prepareForAdmission()
            guard !retired, connections.owner == owner,
                  let probed = streams[record.id], probed.owner == owner,
                  probed.client === client, probed.boundModel === model,
                  Self.canContinueCanonicalReentry(client) else {
                throw WorkspaceClientError.ownerChanged
            }
            if probed.requiresResumeAfterTransportReconnect || !client.connected {
                // The transport really changed while probing. The ordinary
                // durable reattach path owns that new generation.
                return try await prepare(canonical, catalog: catalog)
            }

            try client.seedWorkspaceHistory(canonical)
            try await client.recoverPreservingLiveTransport(epoch: client.projection.epoch)
            try Task.checkCancellation()
            try await reseedFinishedTurnIfNeeded(client, source: canonical, catalog: catalog) {
                !self.retired && self.connections.owner == owner
                    && self.streams[record.id]?.client === client
                    && self.streams[record.id]?.lease === initial.lease
            }
            guard !retired, connections.owner == owner,
                  var current = streams[record.id], current.owner == owner,
                  current.client === client, current.lease === initial.lease,
                  current.boundModel === model,
                  !current.requiresResumeAfterTransportReconnect,
                  client.isReadyForSubmission else {
                throw WorkspaceClientError.ownerChanged
            }

            var refreshed = canonical
            refreshed.remoteStoredID = client.storedID
            refreshed.items = model.items
            refreshed.activityEvents = model.activityLedger.allEvents
            refreshed.isActive = client.projection.running
            refreshed.sessionContext = client.sessionContext ?? refreshed.sessionContext
            if let todoSnapshot = client.projection.todoSnapshot,
               todoSnapshot.supersedes(refreshed.sessionTodos) {
                refreshed.sessionTodos = todoSnapshot
            }
            current.record = refreshed
            current.recoveredCoordinate = try WorkspaceSessionCoordinate(
                owner: owner,
                profileID: client.profile,
                sessionID: record.id,
                storedSessionID: client.storedID,
                runtimeSessionID: client.runtimeID
            )
            streamVerificationSequence &+= 1
            current.verificationSequence = streamVerificationSequence
            streams[record.id] = current
            return refreshed
        } catch {
            // Explicit refresh uses a non-destructive recovery policy. Restore
            // only the prior visible snapshot when the exact lease is still
            // live and admission was reopened by the client.
            if !retired, connections.owner == owner,
               let current = streams[record.id], current.owner == owner,
               current.client === client, current.lease === initial.lease,
               !current.requiresResumeAfterTransportReconnect,
               client.isReadyForSubmission {
                rollback.activityEvents = Self.mergingPostSnapshotActivity(
                    rollback.activityEvents,
                    current: model.activityLedger.allEvents
                )
                model.reconcileHydratedSession(rollback)
                model.adoptNativeTurn(
                    from: client,
                    turnID: client.projection.turnID,
                    running: rollback.isActive
                )
                var restored = initial
                restored.record = rollback
                restored.boundModel = model
                streamVerificationSequence &+= 1
                restored.verificationSequence = streamVerificationSequence
                streams[record.id] = restored
            }
            throw error
        }
    }

    static func canContinueCanonicalReentry(_ client: DirectHermesConversationClient) -> Bool {
        !client.hasPendingSubmission
    }

    /// Preserves activity that arrived after the rollback snapshot. Unchanged
    /// snapshot rows keep their exact prior value; new or advanced lifecycle
    /// rows are merged through the canonical activity ledger.
    static func mergingPostSnapshotActivity(
        _ snapshot: [ChatActivityEvent],
        current: [ChatActivityEvent]
    ) -> [ChatActivityEvent] {
        let snapshotByID = Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ledger = ChatActivityLedger(
            sessionID: snapshot.first?.sessionID ?? current.first?.sessionID ?? "",
            events: snapshot
        )
        for event in current where snapshotByID[event.id] != event {
            _ = ledger.receive(event)
        }
        return ledger.allEvents
    }

    static func canReenterRetainedStream(
        record: SessionRecord,
        retainedRecord: SessionRecord,
        model: ChatModel,
        owner: WorkspaceOwner,
        streamOwner: WorkspaceOwner,
        client: DirectHermesConversationClient
    ) -> Bool {
        guard retainedRecord.id == record.id,
              retainedRecord.kind == record.kind,
              retainedRecord.agentIDs == record.agentIDs,
              retainedRecord.remoteStoredID == record.remoteStoredID,
              DirectHermesIdentity.sameSessionSource(retainedRecord.remoteSource, record.remoteSource),
              streamOwner == owner,
              client.model === model,
              model.nativeConversationClient === client,
              model.ownsReferenceSession(record),
              canRebindRetainedStream(
                streamOwner: streamOwner, owner: owner, record: record,
                profileID: client.profile, storedID: client.storedID,
                runtimeID: client.runtimeID
              ),
              let coordinate = try? WorkspaceSessionCoordinate(
                owner: owner, profileID: client.profile, sessionID: record.id,
                storedSessionID: client.storedID, runtimeSessionID: client.runtimeID
              ),
              coordinate.owner == owner else {
            return false
        }
        return true
    }
}
