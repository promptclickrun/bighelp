import Foundation

/// Stream preparation, generation-bound callbacks and live event routing.
extension NativeWorkspaceSessionBridge {
    func bind(_ model: ChatModel, client: any ConversationClient) {
        guard !retired, var stream = streams[model.conversationID], stream.owner == connections.owner,
              (client as? DirectHermesConversationClient) === stream.client else { return }
        stream.client.model = model
        guard stream.boundModel !== model else { return }
        stream.boundModel = model
        streamVerificationSequence &+= 1
        stream.verificationSequence = streamVerificationSequence
        streams[model.conversationID] = stream
        // Events can arrive between canonical page completion and first binding.
        // Adopt the adapter's current projection, never the older awaited page.
        var latest = stream.record
        latest.remoteStoredID = stream.client.storedID
        latest.items = stream.client.projection.items
        latest.activityEvents = stream.client.projection.activities
        latest.isActive = stream.client.projection.running
        latest.sessionContext = stream.client.sessionContext ?? latest.sessionContext
        model.reconcileHydratedSession(latest)
        model.adoptNativeSnapshot(from: stream.client, session: latest)
        model.adoptNativeTurn(from: stream.client, turnID: stream.client.projection.turnID,
                              running: stream.client.projection.running)
        guard let host = connections.selectedDirectHost, connections.owner == stream.owner else { return }
        connections.hosts.nativeChatPrepared?(host, DirectHermesChat(id: model.conversationID,
            client: stream.client, model: model))
    }

    func receive(_ event: DirectHermesEvent) {
        guard !retired, let owner = connections.owner, owner.authority == authority else { return }
        if event.type == "session.reclaimed" {
            for id in Array(streams.keys) {
                guard var stream = streams[id], stream.owner == owner else { continue }
                stream.client.receive(event)
                if !stream.client.connected {
                    // Hermes reaped this runtime while the socket stayed up, so no
                    // gateway.ready will follow. Queue the same durable resume a
                    // transport reconnect uses; otherwise Send stays disabled
                    // until the app relaunches.
                    stream.recoveredCoordinate = nil
                    stream.requiresResumeAfterTransportReconnect = true
                    streams[id] = stream
                }
            }
            return
        }
        for id in Array(streams.keys) {
            guard var stream = streams[id], stream.owner == connections.owner else { continue }
            if event.type == "gateway.ready" {
                stream.recoveredCoordinate = nil
                stream.requiresResumeAfterTransportReconnect = true
                // Close admission synchronously. Same-batch runtime events are
                // then held until durable resume + replay establish coverage.
                stream.client.requireTransportCatchup()
                streams[id] = stream
            }
        }
        guard let runtimeID = event.sessionID else { return }
        for id in Array(streams.keys) {
            guard var stream = streams[id], stream.owner == owner,
                  DirectHermesSessionValidation.same(stream.client.runtimeID, runtimeID) else { continue }
            // A known live delivery hole forbids a warm hit even if the socket
            // has not disconnected. History/recovery remains the repair path.
            if stream.recoveredCoordinate != nil, stream.client.hasAuthoritativeEventCoverage,
               let sequence = event.sequence, sequence > stream.client.projection.lastSequence,
               sequence - stream.client.projection.lastSequence > 1 {
                stream.recoveredCoordinate = nil
                streams[id] = stream
            }
            stream.lease.receive(event)
            guard var current = streams[id], current.owner == owner,
                  current.client === stream.client, current.lease === stream.lease else { return }
            // An exact current-owner runtime event is newer existence evidence
            // than any catalog inventory already in flight. Re-read the stream
            // after delivery so client-owned todo/liveness callbacks are not
            // overwritten by the pre-delivery value.
            streamVerificationSequence &+= 1
            current.verificationSequence = streamVerificationSequence
            streams[id] = current
            return
        }

        let key = DirectHermesSessionIdentity.key(runtimeID)
        if let mapping = activeMappings[key], mapping.owner == owner,
           DirectHermesSessionValidation.same(mapping.runtimeID, runtimeID) {
            if let active = Self.liveness(from: event) {
                try? box.value().reconcileRuntimeLiveness(runtimeID: runtimeID, isActive: active)
                onSessionLivenessChange?(owner, mapping.visibleID, active)
            }
            return
        }
        onUnknownRuntimeEvent?(owner)
    }

    private static func liveness(from event: DirectHermesEvent) -> Bool? {
        switch event.type {
        case "message.start", "message.delta": true
        case "session.info": event.payload["running"]?.boolean
        default: nil
        }
    }

    func prepare(_ record: SessionRecord, catalog: DirectHermesSessionCatalogClient,
                         preserveIfOmitted: Bool = false) async throws -> SessionRecord {
        guard !retired, let owner = connections.owner, owner.authority == authority,
              let transport = connections.hosts.selectedWorkspace?.nativeClient else {
            throw WorkspaceClientError.ownerChanged
        }
        let previous = streams[record.id]
        var provisionalPromptRuntimeIDs: [String] = []
        var retainedPromptRuntimeID: String?
        defer {
            for runtimeID in provisionalPromptRuntimeIDs where runtimeID != retainedPromptRuntimeID {
                unbindPromptSession(
                    owner: owner,
                    transport: transport,
                    profile: previous?.client.profile ?? record.agentIDs.first ?? "",
                    runtimeID: runtimeID,
                    visibleSessionID: record.id
                )
            }
        }

        var resumedIdentity: DirectHermesReleaseContract.ResumedSession?
        var resumedPromptBinding: (store: DirectHermesPromptStore, recovery: DirectHermesOpenRequestRecovery)?
        if let previous,
           previous.owner != owner || previous.requiresResumeAfterTransportReconnect
                || previous.client.requiresDurableReattachment {
            guard Self.canRebindRetainedStream(
                streamOwner: previous.owner,
                owner: owner,
                record: record,
                profileID: previous.client.profile,
                storedID: previous.client.storedID,
                runtimeID: previous.client.runtimeID
            ), Self.sameOrAdoptingSource(previous.record.remoteSource, record.remoteSource) else {
                streams[record.id] = nil
                onSessionRetired?(record.id)
                previous.client.suspend()
                throw WorkspaceClientError.ownerChanged
            }

            // Bind the former runtime before resume so a still-live host cannot
            // race a prompt past the new socket. Bind the returned runtime before
            // adopting it, then retire the former binding only after recovery.
            try catalog.invalidateRuntimeBinding(record, runtimeID: previous.client.runtimeID)
            let priorBinding = try bindPromptSession(
                owner: owner,
                transport: transport,
                profile: previous.client.profile,
                runtimeID: previous.client.runtimeID,
                visibleSessionID: record.id
            )
            provisionalPromptRuntimeIDs.append(previous.client.runtimeID)
            let response = try await transport.request(
                "session.resume",
                params: DirectHermesReleaseContract.resumeParameters(
                    profile: previous.client.profile,
                    storedID: previous.client.storedID
                )
            )
            guard !retired, connections.owner == owner else {
                throw WorkspaceClientError.ownerChanged
            }
            let resumed = try DirectHermesReleaseContract.decodeResumedSession(
                response,
                profile: previous.client.profile
            )
            resumedIdentity = resumed
            if DirectHermesSessionValidation.same(resumed.runtimeID, previous.client.runtimeID) {
                resumedPromptBinding = priorBinding
            } else {
                resumedPromptBinding = try bindPromptSession(
                    owner: owner,
                    transport: transport,
                    profile: previous.client.profile,
                    runtimeID: resumed.runtimeID,
                    visibleSessionID: record.id
                )
                provisionalPromptRuntimeIDs.append(resumed.runtimeID)
            }
        }

        let resolved: DirectHermesResolvedSession
        if let resumedIdentity {
            // Reconcile the catalog only after durable resume. Its follow-up
            // activate/resume is now constrained to the runtime Hermes just
            // returned for this exact stored session.
            let candidate = try await catalog.resolveSession(record)
            guard candidate.coordinate.runtimeSessionID.map({
                DirectHermesSessionValidation.same($0, resumedIdentity.runtimeID)
            }) == true,
            candidate.coordinate.storedSessionID.map({
                DirectHermesSessionValidation.same($0, resumedIdentity.storedID)
            }) == true else {
                throw WorkspaceClientError.invalidResponse
            }
            resolved = candidate
        } else if let attached = try catalog.attachedSession(record) {
            resolved = attached
        } else {
            resolved = try await catalog.resolveSession(record)
        }
        try Task.checkCancellation()
        guard connections.owner == owner, let runtime = resolved.coordinate.runtimeSessionID,
              let stored = resolved.coordinate.storedSessionID, resolved.coordinate.owner == owner,
              DirectHermesIdentity.matches(resolved.coordinate.sessionID, record.id) else {
            throw WorkspaceClientError.ownerChanged
        }
        let lease: DirectHermesOwnedRPC
        if let previous,
           previous.owner == owner,
           !previous.requiresResumeAfterTransportReconnect,
           DirectHermesSessionValidation.same(previous.client.runtimeID, runtime),
           DirectHermesSessionValidation.same(previous.client.storedID, stored) {
            // Keep one event lease for the lifetime of this retained adapter.
            // Replacing its callback during a refresh can strand post-snapshot
            // events on the old lease even though the request itself succeeded.
            lease = previous.lease
        } else {
            lease = try DirectHermesOwnedRPC(
                base: transport,
                owner: owner,
                currentOwner: { [weak connections] in connections?.owner }
            )
        }
        let promptBinding: (store: DirectHermesPromptStore, recovery: DirectHermesOpenRequestRecovery)
        if let resumedPromptBinding {
            promptBinding = resumedPromptBinding
        } else {
            promptBinding = try bindPromptSession(
                owner: owner,
                transport: transport,
                profile: resolved.coordinate.profileID,
                runtimeID: runtime,
                visibleSessionID: record.id
            )
            provisionalPromptRuntimeIDs.append(runtime)
        }
        let adapter: DirectHermesConversationClient
        if let previous {
            guard previous.client.profile == resolved.coordinate.profileID,
                  Self.sameOrAdoptingSource(previous.record.remoteSource, record.remoteSource) else {
                streams[record.id] = nil
                unbindPromptSession(previous, visibleSessionID: record.id)
                onSessionRetired?(record.id)
                previous.client.suspend()
                throw WorkspaceClientError.ownerChanged
            }
            adapter = previous.client
            if previous.owner != owner
                || !DirectHermesSessionValidation.same(adapter.runtimeID, runtime)
                || !DirectHermesSessionValidation.same(adapter.storedID, stored) {
                if previous.owner == owner {
                    unbindPromptSession(previous, visibleSessionID: record.id)
                }
                adapter.suspend()
            }
            // Do not reconnect the adapter while it still names the retired
            // runtime. Journal migration happens inside coordinate adoption and
            // preserves unresolved submissions under both durable scopes.
            try adapter.adoptWorkspaceCoordinate(resolved.coordinate)
            adapter.rebind(lease, openRequestRecovery: promptBinding.recovery)
        } else {
            guard streams.count < SessionCatalogStore.summaryRetentionLimit else {
                throw WorkspaceClientError.capacityExceeded
            }
            adapter = try DirectHermesConversationClient(
                rpc: lease, hostIdentity: authority.cacheScopeID,
                promptHostIdentity: transport.savedConnection.identity,
                profile: resolved.coordinate.profileID,
                runtimeID: runtime, storedID: stored, title: resolved.record.title, epoch: "",
                drafts: drafts, workspaceSession: resolved.coordinate, attachmentResolver: attachmentResolver,
                promptStore: promptBinding.store, openRequestRecovery: promptBinding.recovery
            )
        }
        adapter.speakerNote = speakerNote
        let profileID = resolved.coordinate.profileID
        adapter.supportsCapability = { [weak self] capability in
            guard let self, !self.retired else { return false }
            return self.connections.capabilities.supports(capability, owner: owner, profileID: profileID)
        }
        adapter.onSessionContextChange = { [weak self] snapshot in
            guard let self, !self.retired,
                  self.connections.owner == owner,
                  snapshot.sessionId == record.id else { return }
            self.onSessionContextChange?(owner, snapshot)
        }
        adapter.onSessionTodosChange = { [weak self, weak adapter] snapshot in
            guard let self, let adapter, !self.retired,
                  self.connections.owner == owner,
                  var current = self.streams[record.id], current.owner == owner,
                  current.client === adapter,
                  snapshot.sessionID == record.id else { return }
            if snapshot.supersedes(current.record.sessionTodos) {
                current.record.sessionTodos = snapshot
                self.streams[record.id] = current
            }
            self.onSessionTodosChange?(owner, snapshot)
        }
        adapter.onSessionLivenessChange = { [weak self, weak adapter] running in
            guard let self, let adapter, !self.retired,
                  self.connections.owner == owner,
                  var current = self.streams[record.id], current.owner == owner,
                  current.client === adapter else { return }
            current.record.isActive = running
            self.streams[record.id] = current
            try? self.box.value().reconcileRuntimeLiveness(
                runtimeID: adapter.runtimeID,
                isActive: running
            )
            self.onSessionLivenessChange?(owner, record.id, running)
        }
        adapter.onNativeSubagentsChange = { [weak self, weak adapter] items in
            guard let self, let adapter, !self.retired,
                  self.connections.owner == owner,
                  let current = self.streams[record.id], current.owner == owner,
                  current.client === adapter else { return }
            self.onNativeSubagentRosterChange?(owner, record.id, adapter, items)
        }
        var source = record
        let canSeedContext = DirectHermesIdentity.matches(record.remoteStoredID, stored)
        source.remoteStoredID = stored
        if !canSeedContext { source.sessionContext = nil }
        source.sessionRuntime = resolved.record.sessionRuntime ?? source.sessionRuntime
        try adapter.seedWorkspaceHistory(source)
        lease.onEvent = { [weak adapter] event in adapter?.receive(event) }
        let retainIfOmitted = preserveIfOmitted || streams[record.id]?.retainIfOmitted == true
        streamVerificationSequence &+= 1
        streams[record.id] = Stream(owner: owner, lease: lease, client: adapter,
                                    record: source, verificationSequence: streamVerificationSequence,
                                    retainIfOmitted: retainIfOmitted,
                                    boundModel: streams[record.id]?.boundModel)
        try await adapter.recover(epoch: adapter.projection.epoch)
        // Recovery's validated activation payload already supplied liveness and
        // todo authority. Do not perform a second side-effectful reattach after
        // the replay bracket; it is not a stronger snapshot.
        try Task.checkCancellation()
        guard !retired, connections.owner == owner, streams[record.id]?.lease === lease else {
            throw WorkspaceClientError.ownerChanged
        }
        try await reseedFinishedTurnIfNeeded(adapter, source: source, catalog: catalog) {
            !self.retired && self.connections.owner == owner && self.streams[record.id]?.lease === lease
        }
        source.remoteStoredID = adapter.storedID
        if let refreshedTodos = streams[record.id]?.record.sessionTodos,
           refreshedTodos.supersedes(source.sessionTodos) {
            source.sessionTodos = refreshedTodos
        }
        source.items = adapter.projection.items
        source.activityEvents = adapter.projection.activities
        source.isActive = adapter.projection.running
        source.sessionContext = adapter.sessionContext ?? source.sessionContext
        if var stream = streams[record.id], stream.lease === lease {
            let recoveredCoordinate = try WorkspaceSessionCoordinate(
                owner: owner,
                profileID: adapter.profile,
                sessionID: record.id,
                storedSessionID: adapter.storedID,
                runtimeSessionID: adapter.runtimeID
            )
            stream.record = source
            stream.recoveredCoordinate = recoveredCoordinate
            streamVerificationSequence &+= 1
            stream.verificationSequence = streamVerificationSequence
            streams[record.id] = stream
        }
        retainedPromptRuntimeID = adapter.runtimeID
        return source
    }

    /// A reply that finished while its chat was away, when the events it
    /// missed could not be replayed, is complete only in saved history.
    /// Recovery has confirmed the turn ended, so read that history again.
    /// A failed read keeps the recovered chat; the next refresh catches up.
    func reseedFinishedTurnIfNeeded(
        _ adapter: DirectHermesConversationClient,
        source: SessionRecord,
        catalog: DirectHermesSessionCatalogClient,
        isCurrent: @MainActor () -> Bool
    ) async throws {
        guard adapter.needsCatalogHistoryReseed else { return }
        var request = source
        request.remoteStoredID = adapter.storedID
        let saved: SessionRecord
        do {
            saved = try await catalog.hydrate(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            adapter.needsCatalogHistoryReseed = false
            return
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw WorkspaceClientError.ownerChanged }
        var finished = saved
        finished.remoteStoredID = adapter.storedID
        try adapter.reseedFinishedTurn(finished)
    }
}
