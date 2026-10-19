import Foundation

/// Authoritative stream recovery and reconnect resume under exact-generation leases.
extension NativeWorkspaceSessionBridge {
    /// Recovery eligibility is intentionally weaker than a warm hit. The exact
    /// retained stream/model may need repair precisely because its coordinate is
    /// cleared or its admission gate is closed.
    func canRecoverRetainedSession(_ record: SessionRecord, model: ChatModel) -> Bool {
        guard !retired, let owner = connections.owner, owner.authority == authority,
              let stream = recoverableStream(for: record, model: model, owner: owner) else {
            return false
        }
        return stream.client.model === model
            && model.nativeConversationClient === stream.client
            && model.ownsReferenceSession(record)
    }

    /// Replays and reactivates only the exact retained adapter. Force,
    /// foreground, and gateway reconnect callers join this one flight; none can
    /// replace history, the model, its draft/attachments/scroll, or its journal.
    func recoverAuthoritativeState(
        for record: SessionRecord,
        model expectedModel: ChatModel? = nil
    ) async throws {
        guard !retired, let owner = connections.owner, owner.authority == authority,
              let stream = recoverableStream(for: record, model: expectedModel, owner: owner) else {
            throw WorkspaceClientError.ownerChanged
        }
        let modelIdentity = expectedModel.map { ObjectIdentifier($0) }
        if let flight = authoritativeRecoveryFlights[record.id] {
            guard flight.owner == owner, flight.client === stream.client,
                  flight.modelIdentity == nil || modelIdentity == nil
                    || flight.modelIdentity == modelIdentity else {
                throw WorkspaceClientError.ownerChanged
            }
            return try await flight.task.value
        }

        // Close one client-owned gate before the transport probe. A same-owner
        // caller arriving after this point joins the flight above.
        stream.client.requireTransportCatchup()
        let flightID = UUID()
        let task = Task { @MainActor [weak self, weak client = stream.client] in
            guard let self, let client else { throw WorkspaceClientError.ownerChanged }
            try await self.performAuthoritativeRecovery(
                sessionID: record.id,
                owner: owner,
                client: client,
                modelIdentity: modelIdentity
            )
        }
        authoritativeRecoveryFlights[record.id] = AuthoritativeRecoveryFlight(
            id: flightID,
            owner: owner,
            client: stream.client,
            modelIdentity: modelIdentity,
            task: task
        )
        defer {
            if authoritativeRecoveryFlights[record.id]?.id == flightID {
                authoritativeRecoveryFlights[record.id] = nil
            }
        }
        return try await task.value
    }

    /// Event-driven reconnect uses the same exact per-stream flight as Force.
    /// It never routes through catalog history hydration or creates an adapter.
    func recoverRetainedSessionsAfterTransportReconnect(
        expectedOwner: WorkspaceOwner,
        prioritizing activeID: String?
    ) async throws -> Set<String> {
        guard !retired, connections.owner == expectedOwner,
              expectedOwner.authority == authority else {
            throw WorkspaceClientError.ownerChanged
        }
        var ids = streams.compactMap { id, stream in
            let retained = stream.client.model != nil || !stream.client.journal.unresolved.isEmpty
            return stream.owner == expectedOwner
                && stream.requiresResumeAfterTransportReconnect
                && retained ? id : nil
        }.sorted()
        if let activeID, let index = ids.firstIndex(of: activeID) {
            ids.remove(at: index)
            ids.insert(activeID, at: 0)
        }
        var failed = Set<String>()
        for id in ids {
            try Task.checkCancellation()
            guard !retired, connections.owner == expectedOwner,
                  let stream = streams[id], stream.owner == expectedOwner else {
                throw WorkspaceClientError.ownerChanged
            }
            do {
                try await recoverAuthoritativeState(for: stream.record)
            } catch {
                try Task.checkCancellation()
                guard !retired, connections.owner == expectedOwner else {
                    throw WorkspaceClientError.ownerChanged
                }
                failed.insert(id)
            }
        }
        return failed
    }

    private func recoverableStream(
        for record: SessionRecord,
        model expectedModel: ChatModel?,
        owner: WorkspaceOwner
    ) -> Stream? {
        guard let stream = streams[record.id], stream.owner == owner,
              Self.sameOrAdoptingSource(stream.record.remoteSource, record.remoteSource),
              Self.canRebindRetainedStream(
                streamOwner: stream.owner,
                owner: owner,
                record: record,
                profileID: stream.client.profile,
                storedID: stream.client.storedID,
                runtimeID: stream.client.runtimeID
              ),
              expectedModel.map({ stream.boundModel === $0 }) ?? true else {
            return nil
        }
        return stream
    }

    private func performAuthoritativeRecovery(
        sessionID: String,
        owner: WorkspaceOwner,
        client: DirectHermesConversationClient,
        modelIdentity: ObjectIdentifier?
    ) async throws {
        do {
            guard !retired, connections.owner == owner,
                  let initial = streams[sessionID], initial.owner == owner,
                  initial.client === client,
                  recoveryModelMatches(initial, modelIdentity) else {
                throw WorkspaceClientError.ownerChanged
            }

            if client.connected, !initial.requiresResumeAfterTransportReconnect {
                try await client.prepareTransportForAuthoritativeRecovery()
            }
            guard !retired, connections.owner == owner,
                  let probed = streams[sessionID], probed.owner == owner,
                  probed.client === client,
                  recoveryModelMatches(probed, modelIdentity) else {
                throw WorkspaceClientError.ownerChanged
            }

            if probed.requiresResumeAfterTransportReconnect || !client.connected {
                try await resumeRetainedStream(
                    sessionID: sessionID,
                    owner: owner,
                    client: client,
                    modelIdentity: modelIdentity
                )
            }

            // Durable resume (when required) and coordinate/lease binding are
            // complete before the first replay or activation request.
            try await client.recover(epoch: client.projection.epoch)
            guard !retired, connections.owner == owner,
                  var current = streams[sessionID], current.owner == owner,
                  current.client === client,
                  recoveryModelMatches(current, modelIdentity),
                  !current.requiresResumeAfterTransportReconnect else {
                throw WorkspaceClientError.ownerChanged
            }
            current.record.remoteStoredID = client.storedID
            current.record.items = client.projection.items
            current.record.activityEvents = client.projection.activities
            current.record.isActive = client.projection.running
            current.record.sessionContext = client.sessionContext ?? current.record.sessionContext
            if let todoSnapshot = client.projection.todoSnapshot,
               todoSnapshot.supersedes(current.record.sessionTodos) {
                current.record.sessionTodos = todoSnapshot
            }
            current.recoveredCoordinate = try WorkspaceSessionCoordinate(
                owner: owner,
                profileID: client.profile,
                sessionID: sessionID,
                storedSessionID: client.storedID,
                runtimeSessionID: client.runtimeID
            )
            streamVerificationSequence &+= 1
            current.verificationSequence = streamVerificationSequence
            streams[sessionID] = current
        } catch {
            if !retired, connections.owner == owner,
               var current = streams[sessionID], current.owner == owner,
               current.client === client,
               recoveryModelMatches(current, modelIdentity) {
                current.recoveredCoordinate = nil
                streams[sessionID] = current
                if client.connected { client.suspend() }
            }
            throw error
        }
    }

    private func resumeRetainedStream(
        sessionID: String,
        owner: WorkspaceOwner,
        client: DirectHermesConversationClient,
        modelIdentity: ObjectIdentifier?
    ) async throws {
        guard !retired, connections.owner == owner,
              let transport = connections.hosts.selectedWorkspace?.nativeClient,
              var stream = streams[sessionID], stream.owner == owner,
              stream.client === client,
              recoveryModelMatches(stream, modelIdentity) else {
            throw WorkspaceClientError.ownerChanged
        }
        let priorRuntimeID = client.runtimeID
        var provisionalPromptRuntimeIDs: [String] = []
        var retainedPromptRuntimeID: String?
        defer {
            for runtimeID in provisionalPromptRuntimeIDs where runtimeID != retainedPromptRuntimeID {
                unbindPromptSession(
                    owner: owner,
                    transport: transport,
                    profile: client.profile,
                    runtimeID: runtimeID,
                    visibleSessionID: sessionID
                )
            }
        }

        let priorBinding = try bindPromptSession(
            owner: owner,
            transport: transport,
            profile: client.profile,
            runtimeID: priorRuntimeID,
            visibleSessionID: sessionID
        )
        provisionalPromptRuntimeIDs.append(priorRuntimeID)
        let response = try await transport.request(
            "session.resume",
            params: DirectHermesReleaseContract.resumeParameters(
                profile: client.profile,
                storedID: client.storedID
            )
        )
        guard !retired, connections.owner == owner else {
            throw WorkspaceClientError.ownerChanged
        }
        let resumed = try DirectHermesReleaseContract.decodeResumedSession(
            response,
            profile: client.profile
        )
        // A changed durable ID can be a compaction successor, but a resume
        // response alone cannot attach an unrelated saved conversation. Reuse
        // the existing exact catalog-coordinate validation only for this case;
        // this resolves metadata, never replaces transcript history.
        if !DirectHermesSessionValidation.same(resumed.storedID, client.storedID) {
            let resolved = try await box.value().resolveSession(stream.record)
            guard resolved.coordinate.owner == owner,
                  resolved.coordinate.sessionID == sessionID,
                  resolved.coordinate.runtimeSessionID.map({ DirectHermesSessionValidation.same($0, resumed.runtimeID) }) == true,
                  resolved.coordinate.storedSessionID.map({ DirectHermesSessionValidation.same($0, resumed.storedID) }) == true else {
                throw WorkspaceClientError.invalidResponse
            }
        }
        let resumedBinding: (store: DirectHermesPromptStore, recovery: DirectHermesOpenRequestRecovery)
        if DirectHermesSessionValidation.same(resumed.runtimeID, priorRuntimeID) {
            resumedBinding = priorBinding
        } else {
            resumedBinding = try bindPromptSession(
                owner: owner,
                transport: transport,
                profile: client.profile,
                runtimeID: resumed.runtimeID,
                visibleSessionID: sessionID
            )
            provisionalPromptRuntimeIDs.append(resumed.runtimeID)
        }
        let coordinate = try WorkspaceSessionCoordinate(
            owner: owner,
            profileID: client.profile,
            sessionID: sessionID,
            storedSessionID: resumed.storedID,
            runtimeSessionID: resumed.runtimeID
        )
        guard !retired, connections.owner == owner,
              let current = streams[sessionID], current.owner == owner,
              current.client === client, current.lease === stream.lease,
              recoveryModelMatches(current, modelIdentity) else {
            throw WorkspaceClientError.ownerChanged
        }
        // The catalog's binding still names the old runtime, which Hermes may have reaped; a later
        // prepare would activate that dead runtime and fail. Without it, prepare resumes durably.
        if !DirectHermesSessionValidation.same(resumed.runtimeID, priorRuntimeID) {
            try? box.value().invalidateRuntimeBinding(stream.record, runtimeID: priorRuntimeID)
        }
        try client.adoptWorkspaceCoordinate(coordinate)
        client.rebind(stream.lease, openRequestRecovery: resumedBinding.recovery)
        stream = current
        stream.record.remoteStoredID = resumed.storedID
        stream.recoveredCoordinate = nil
        stream.requiresResumeAfterTransportReconnect = false
        streams[sessionID] = stream
        retainedPromptRuntimeID = resumed.runtimeID
    }

    private func recoveryModelMatches(
        _ stream: Stream,
        _ expected: ObjectIdentifier?
    ) -> Bool {
        expected.map { expected in
            stream.boundModel.map { ObjectIdentifier($0) } == expected
        } ?? true
    }

    static func canReturnToPreparedStream(
        record: SessionRecord, model: ChatModel, owner: WorkspaceOwner,
        streamOwner: WorkspaceOwner, recoveredCoordinate: WorkspaceSessionCoordinate?,
        client: DirectHermesConversationClient
    ) -> Bool {
        guard streamOwner == owner, let recoveredCoordinate, recoveredCoordinate.owner == owner,
              client.model === model, model.nativeConversationClient === client,
              client.isReadyForSubmission, !client.projection.epoch.isEmpty,
              model.ownsReferenceSession(record),
              canRebindRetainedStream(streamOwner: streamOwner, owner: owner, record: record,
                  profileID: client.profile, storedID: client.storedID, runtimeID: client.runtimeID),
              let coordinate = try? WorkspaceSessionCoordinate(owner: owner, profileID: client.profile,
                  sessionID: record.id, storedSessionID: client.storedID, runtimeSessionID: client.runtimeID)
        else { return false }
        return coordinate == recoveredCoordinate
    }
}
