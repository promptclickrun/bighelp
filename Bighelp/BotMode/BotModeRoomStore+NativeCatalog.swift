import Foundation

extension BotModeRoomStore {
    /// Installs the owner-bound native room client only after the verified
    /// connection and host are known. The caller must invoke this when that
    /// owner changes.
    func configureNativeClient(_ client: (any HermesBotModeClient)?, preservingCatalog: Bool = false) {
        let retainedRooms = catalogRooms
        let retainedState = catalogState
        nativeObservations.values.forEach { $0.cancel() }
        nativeObservations.removeAll()
        nativeObservationTokens.removeAll()
        nativeClient = client
        invalidateNativeExecutionBoundary()
        if preservingCatalog {
            catalogRooms = retainedRooms
            catalogState = retainedState == .loaded ? .loaded : .idle
            isCatalogStale = true
        }
        // A scene suspension retires the transport while durable native work
        // remains in the room cache. The sender's old boundary is correctly
        // fenced out, so the replacement client must explicitly resume an
        // observer for every room with an unsettled send. Chat models can
        // survive the same transition and therefore cannot be the only place
        // that starts this store-owned recovery loop.
        if client != nil {
            for room in rooms where room.hasNativeRoom
                && (room.isRunning || room.nativePendingEventID != nil || !room.nativeFollowUps.isEmpty) {
                beginNativeRoomObservation(roomID: room.id)
            }
        }
    }

    func configureNativeActivityClient(_ client: (any HermesBotModeActivityClient)?) {
        activity.configure(client)
    }

    func beginNativeActivity(roomID: String, viewerID: UUID) {
        guard let room = room(id: roomID), room.hasNativeRoom else { return }
        let boundary = nativeBoundaryGeneration
        activity.begin(
            roomID: roomID, viewerID: viewerID, memberIDs: Set(room.memberIDs),
            isRetired: { [weak self] observation in
                guard let self, boundary == self.nativeBoundaryGeneration else { return true }
                if let terminal = self.terminalNativeAttempts[roomID]?[observation.taskId],
                   terminal.generation >= observation.executionGeneration { return true }
                return self.room(id: roomID)?.visibleEvents.suffix(500).contains { event in
                    event.nativeEvent?.taskID == observation.taskId
                        && (event.nativeEvent?.executionGeneration ?? 0) >= observation.executionGeneration
                        && event.kind == .agent
                } == true
            },
            reconcile: { [weak self] in
                guard let self else { throw CancellationError() }
                try self.requireNativeBoundary(boundary)
                try await self.syncNativeRoom(roomID: roomID, boundary: boundary)
            }
        )
    }

    var nativeExecutionAvailable: Bool {
        nativeCapabilities?.supportsNativeExecution == true
    }

    var nativeOwnerGeneration: Int { nativeBoundaryGeneration }
    var nativePresentationOwnerID: String { "\(instanceID):\(nativeBoundaryGeneration)" }
    var usesNativeRooms: Bool { nativeClient != nil }

    var canCreateNativeRoom: Bool {
        nativeExecutionAvailable && nativeClient is any HermesBotModeCatalogClient
    }

    func nativeRoomIsWorking(roomID: String) -> Bool {
        nativeDriverWorkingByRoom[roomID] == true || room(id: roomID)?.isRunning == true
    }

    /// Creates a room on this computer. `peers` are agents on other saved
    /// computers: each joins through its own computer's RoomLink, linked
    /// right after Hermes creates the room.
    @discardableResult
    func createNativeRoom(roomID: String, name: String, profiles: [AgentProfile],
                          peers: [HermesBotModePeerCandidate] = []) async throws -> BotModeRoom {
        try loadNativeStorageIfNeeded()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let nativeClient else { throw BotModeRoomError.executionUnavailable }
        let boundary = nativeBoundaryGeneration
        _ = try await requireNativeCapabilities(using: nativeClient, boundary: boundary)
        try requireNativeBoundary(boundary)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 200,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (2...BotModeRoom.maximumMembers).contains(profiles.count + peers.count),
              Set(profiles.map(\.id)).count == profiles.count else {
            throw WorkspaceClientError.invalidRequest
        }
        if let current = room(id: roomID), current.hasNativeRoom {
            return try await openNativeRoom(roomID: roomID)
        }
        if room(id: roomID) == nil {
            let handles = NativeBotModeHandles.directory(for: profiles)
            var members = try profiles.map { profile in
                guard let handle = handles.first(where: { $0.profileID == profile.id })?.handle else {
                    throw WorkspaceClientError.invalidRequest
                }
                return HermesBotModeRoomMember(
                    memberID: profile.id, profile: profile.id, handle: handle,
                    displayName: profile.name,
                    target: ["kind": .string("local"), "profile": .string(profile.id)]
                )
            }
            var links: [HermesBotModePeerLink] = []
            if !peers.isEmpty {
                guard let peerHosts, nativeClient is any HermesBotModePeerRegistering else {
                    throw BotModeRoomError.executionUnavailable
                }
                var offers: [(candidate: HermesBotModePeerCandidate, link: HermesBotModeRoomLink)] = []
                for peer in peers {
                    do {
                        offers.append((peer, try await peerHosts.roomLink(hostID: peer.hostID, profile: peer.profileID)))
                    } catch let problem as HermesBotModeRoomLink.Problem {
                        throw BotModePeerLinkError(candidate: peer, problem: problem)
                    }
                    try requireNativeBoundary(boundary)
                }
                for peer in HermesBotModePeerMembers.members(for: offers, taken: members) {
                    members.append(peer.member)
                    links.append(peer.link)
                }
            }
            guard members.allSatisfy(HermesBotModeWireCodec.member) else { throw WorkspaceClientError.invalidRequest }
            let intent = HermesBotModeCreationIntent(roomID: roomID, name: name, members: members, wasDispatched: false)
            try persist(room: BotModeRoom(
                id: roomID,
                members: members.map {
                    BotModeMember(profileID: $0.profile, handle: $0.handle, sessionID: "", nativeMemberID: $0.memberID)
                },
                visibleEvents: [], nativePendingCreation: intent, nativePendingPeerLinks: links
            ))
        }
        guard var current = room(id: roomID), var intent = current.nativePendingCreation else {
            throw BotModeRoomError.persistenceConflict
        }
        let state: HermesBotModeRoomState
        if intent.wasDispatched {
            // A lost create receipt may have been followed by a remote rename.
            // Recover by immutable room ID, never by reissuing the old name.
            state = try await nativeClient.groupsState(roomID: intent.roomID, includeDisbanded: true)
        } else {
            intent.wasDispatched = true
            current.setNativeCreationIntent(intent)
            try persist(room: current)
            state = try await nativeClient.groupsCreate(roomID: intent.roomID, name: intent.name, members: intent.members)
        }
        try requireNativeBoundary(boundary)
        guard var latest = room(id: roomID), latest.nativePendingCreation == intent else {
            throw WorkspaceClientError.ownerChanged
        }
        try validateNativeState(state, previous: latest)
        guard state.authorityGatewayID == nativeCapabilities?.authorityGatewayID else {
            throw BotModeRoomError.nativeAuthorityMismatch
        }
        guard state.members == intent.members else { throw WorkspaceClientError.invalidResponse }
        latest.markNativeRoom(state)
        latest.setNativeCreationIntent(nil)
        try persist(room: latest)
        await linkPendingPeers(roomID: roomID)
        await refreshNativeRoomCatalog()
        try requireNativeBoundary(boundary)
        return room(id: roomID) ?? latest
    }

    @discardableResult
    func openNativeRoom(roomID: String) async throws -> BotModeRoom {
        try persistence?.prepareNativeStorage()
        try loadNativeStorageIfNeeded()
        guard let nativeClient else { throw BotModeRoomError.executionUnavailable }
        let boundary = nativeBoundaryGeneration
        let capabilities = try await negotiatedNativeCapabilities(using: nativeClient, boundary: boundary)
        try requireNativeBoundary(boundary)
        guard capabilities.protocolVersion == 2,
              capabilities.supports("groups.state"), capabilities.supports("groups.log") else {
            throw BotModeRoomError.executionUnavailable
        }
        nativeCapabilities = capabilities
        let state = try await nativeClient.groupsState(roomID: roomID, includeDisbanded: true)
        try requireNativeBoundary(boundary)
        guard state.roomID == roomID, state.disbandedAt == nil,
              !state.members.isEmpty, state.members.count <= 128 else {
            throw WorkspaceClientError.invalidResponse
        }
        if let existing = room(id: roomID) {
            try validateNativeState(state, previous: existing)
            var updated = existing
            if let creation = updated.nativePendingCreation {
                guard state.members == creation.members else { throw WorkspaceClientError.invalidResponse }
                updated.setNativeCreationIntent(nil)
            }
            updated.markNativeRoom(state)
            try persist(room: updated)
        } else {
            let members = state.members.map {
                BotModeMember(profileID: $0.profile, handle: $0.handle, sessionID: "", nativeMemberID: $0.memberID)
            }
            let created = try BotModeRoom(
                id: roomID, members: members, visibleEvents: [],
                nativeRoomID: roomID, nativeAuthorityGatewayID: state.authorityGatewayID,
                nativeAuthorityEpoch: state.authorityEpoch, nativeState: state
            )
            try persist(room: created)
        }
        try await syncNativeRoom(roomID: roomID, boundary: boundary, initialState: state)
        await linkPendingPeers(roomID: roomID)
        guard let room = room(id: roomID) else { throw BotModeRoomError.roomNotFound }
        return room
    }

    func renameNativeRoom(roomID: String, name: String) async throws {
        try persistence?.prepareNativeStorage()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = nativeClient as? any HermesBotModeCatalogClient,
              nativeCapabilities?.protocolVersion == 2,
              nativeCapabilities?.supports("groups.rename") == true else {
            throw BotModeRoomError.executionUnavailable
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 200,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var current = room(id: roomID), current.hasNativeRoom else {
            throw WorkspaceClientError.invalidRequest
        }
        let boundary = nativeBoundaryGeneration
        if let pending = current.nativePendingRename, pending.name != name {
            throw WorkspaceClientError.outcomeUnknown
        }
        let intent = current.nativePendingRename
            ?? HermesBotModeRenameIntent(eventID: "rename-\(UUID().uuidString)", name: name)
        current.setNativeRenameIntent(intent)
        try persist(room: current)
        let state = try await client.groupsRename(roomID: roomID, eventID: intent.eventID, name: intent.name)
        try requireNativeBoundary(boundary)
        guard var latest = room(id: roomID), latest.nativePendingRename == intent else {
            throw WorkspaceClientError.ownerChanged
        }
        try validateNativeState(state, previous: latest)
        latest.markNativeRoom(state)
        latest.setNativeRenameIntent(nil)
        try persist(room: latest)
        await refreshNativeRoomCatalog()
    }

    func deleteNativeRoom(roomID: String) async throws {
        guard let client = nativeClient as? any HermesBotModeCatalogClient,
              nativeCapabilities?.protocolVersion == 2,
              nativeCapabilities?.supports("groups.disband") == true else {
            throw BotModeRoomError.executionUnavailable
        }
        let boundary = nativeBoundaryGeneration
        try await client.groupsDisband(roomID: roomID)
        try requireNativeBoundary(boundary)
        // Any catalog read started before this receipt may still contain the room.
        catalogRefreshID = nil
        try remove(roomID: roomID)
        catalogRooms.removeAll { $0.roomID == roomID }
        catalogState = .loaded
    }

    func refreshNativeRoomCatalog() async {
        guard let client = nativeClient as? any HermesBotModeCatalogClient else {
            // A missing client during reconnect is not evidence that Hermes
            // lacks rooms. Keep the scoped cached catalog until it is rebound.
            isCatalogStale = true
            return
        }
        let boundary = nativeBoundaryGeneration
        let refreshID = UUID()
        catalogRefreshID = refreshID
        if catalogRooms.isEmpty { catalogState = .loading }
        do {
            let capabilities = try await client.groupsCapabilities()
            try Task.checkCancellation()
            try requireNativeBoundary(boundary)
            guard catalogRefreshID == refreshID else { return }
            nativeCapabilities = capabilities
            guard capabilities.protocolVersion == 2, capabilities.supports("groups.list") else {
                catalogState = .unavailable("This Hermes host does not support the required room catalog.")
                return
            }
            var rooms: [HermesBotModeRoomState] = []
            var offset = 0
            repeat {
                let page = try await client.groupsList(offset: offset, limit: 50)
                try Task.checkCancellation()
                try requireNativeBoundary(boundary)
                guard catalogRefreshID == refreshID else { return }
                guard page.rooms.allSatisfy({ room in
                    !rooms.contains { $0.roomID == room.roomID }
                        && room.disbandedAt == nil
                }), rooms.count + page.rooms.count <= 256 else {
                    throw BighelpLinkWorkspaceClientError.invalidResponse
                }
                rooms.append(contentsOf: page.rooms)
                guard let next = page.nextOffset else { break }
                guard next > offset, !page.rooms.isEmpty else {
                    throw BighelpLinkWorkspaceClientError.invalidResponse
                }
                offset = next
            } while true
            let updated = rooms.map { HermesBotModeRoomSummary(room: $0, capabilities: capabilities) }
            if catalogRooms != updated { catalogRooms = updated }
            catalogState = .loaded
            isCatalogStale = false
        } catch is CancellationError {
            guard boundary == nativeBoundaryGeneration, catalogRefreshID == refreshID else { return }
            catalogState = .idle
            isCatalogStale = !catalogRooms.isEmpty
        } catch {
            guard boundary == nativeBoundaryGeneration, catalogRefreshID == refreshID else { return }
            nativeCapabilities = nil
            catalogState = .failed("Rooms could not be refreshed. Check the connection and try again.")
            isCatalogStale = !catalogRooms.isEmpty
        }
    }

    /// Current approval actions read from Hermes' driver status. These are
    /// deliberately memory-only and owner-bound; a relaunch must rediscover
    /// them from `groups.state` rather than trusting an old action card.
    func pendingApprovals(roomID: String) -> [HermesBotModePendingApproval] {
        nativePendingApprovalsByRoom[roomID, default: [:]].values.sorted { $0.id < $1.id }
    }

    /// Retry actions are authoritative Hermes state. They may exist before a
    /// terminal log event reaches this cache, so expose their exact task IDs
    /// without manufacturing a member, turn, or discussion identity.
    func pendingNativeRetryTaskIDs(roomID: String) -> [String] {
        (nativePendingRetryTaskIDsByRoom[roomID] ?? []).sorted()
    }

    /// Refreshes the negotiated groups contract after a Link connection or
    /// host changes. Capability methods are advertised even while the durable
    /// driver is stopped, so callers must use the full readiness predicate.
    func refreshNativeCapabilities() async {
        guard let nativeClient else {
            nativeCapabilities = nil
            return
        }
        let boundary = nativeBoundaryGeneration
        do {
            let capabilities = try await nativeClient.groupsCapabilities()
            guard boundary == nativeBoundaryGeneration else { return }
            nativeCapabilities = capabilities
        } catch {
            guard boundary == nativeBoundaryGeneration else { return }
            nativeCapabilities = nil
        }
    }

    /// Invalidates in-flight native work after an account or verified-host
    /// boundary. The server keeps durable work; a stale UI task cannot write
    /// its events into the newly selected host's local room cache.
    func invalidateNativeExecutionBoundary() {
        activity.configure(nil)
        terminalNativeAttempts = [:]
        nativeRoomSyncErrors = [:]
        nativePeerLinkProblems = [:]
        nativeObservations.values.forEach { $0.cancel() }
        nativeObservations.removeAll()
        nativeObservationTokens.removeAll()
        nativePendingApprovalsByRoom.removeAll()
        nativePendingRetryTaskIDsByRoom.removeAll()
        nativeDriverWorkingByRoom.removeAll()
        nativeBoundaryGeneration += 1
        nativeCapabilities = nil
        catalogRefreshID = nil
        catalogRooms = []
        catalogState = .idle
        isCatalogStale = false
    }

    /// Starts a store-owned replay monitor for a durable Hermes room. The
    /// monitor is idempotent for a room and survives chat-view/model teardown;
    /// host/account invalidation cancels it without issuing `groups.stop`.
    func beginNativeRoomObservation(roomID: String) {
        guard nativeClient != nil, nativeObservations[roomID] == nil else { return }
        let boundary = nativeBoundaryGeneration
        let token = UUID()
        nativeObservationTokens[roomID] = token
        nativeObservations[roomID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.observeNativeRoom(roomID: roomID, boundary: boundary)
            guard self.nativeObservationTokens[roomID] == token else { return }
            self.nativeObservationTokens.removeValue(forKey: roomID)
            self.nativeObservations.removeValue(forKey: roomID)
        }
    }

    /// Explicitly stops durable Hermes work for a room. Lifecycle cancellation
    /// of `send` deliberately does not call this operation.
    func stopNativeRoom(roomID: String, cancelID: String = "loopdy-stop-\(UUID().uuidString)") async throws {
        try persistence?.prepareNativeStorage()
        guard let nativeClient else { throw BotModeRoomError.executionUnavailable }
        let boundary = nativeBoundaryGeneration
        guard var room = room(id: roomID), room.nativeRoomID != nil else {
            throw BotModeRoomError.roomNotFound
        }
        let resolvedCancelID = room.nativePendingCancelID ?? cancelID
        room.setNativeCancelIntent(resolvedCancelID)
        try persist(room: room)
        try await nativeClient.groupsStop(roomID: roomID, cancelID: resolvedCancelID)
        try requireNativeBoundary(boundary)
        guard var current = self.room(id: roomID) else { return }
        let expectedOwner = current.runOwner.map(BotModeRunOwnerExpectation.owner) ?? .noOwner
        current.clearNativeTurn()
        current.clearNativeFollowUps()
        current.setNativeRetryJournal(nil)
        current.setNativeCancelIntent(nil)
        current.settleRun()
        guard let saved = try compareAndSave(
            current,
            expectedRevision: current.persistenceRevision,
            expectedOwner: expectedOwner
        ) else { throw BotModeRoomError.persistenceConflict }
        replaceStored(saved)
        nativePendingRetryTaskIDsByRoom.removeValue(forKey: roomID)
        nativeDriverWorkingByRoom.removeValue(forKey: roomID)
    }

    /// Resolves one exact Hermes approval action and immediately refreshes the
    /// server-owned driver status. A stale card cannot approve a newer task,
    /// generation, command, or request under the same room.
    @discardableResult
    func resolveNativeApproval(
        roomID: String,
        approval: HermesBotModePendingApproval,
        choice: HermesBotModeApprovalChoice
    ) async throws -> HermesBotModeApprovalReceipt {
        guard let nativeClient,
              let approvalClient = nativeClient as? any HermesBotModeApprovalClient else {
            throw BotModeRoomError.executionUnavailable
        }
        let boundary = nativeBoundaryGeneration
        try requireNativeBoundary(boundary)
        guard approval.roomID == roomID,
              approval.choices.contains(choice),
              pendingApprovals(roomID: roomID).contains(where: { $0 == approval }) else {
            throw BotModeRoomError.nativeApprovalStale
        }

        // Read the authoritative state before the mutation. This closes the
        // race where a card was rendered from an earlier state poll.
        let before = try await nativeClient.groupsState(roomID: roomID, includeDisbanded: false)
        try requireNativeBoundary(boundary)
        try refreshNativeApprovals(roomID: roomID, driverStatus: before.driverStatus, boundary: boundary)
        guard pendingApprovals(roomID: roomID).contains(where: { $0 == approval }) else {
            throw BotModeRoomError.nativeApprovalStale
        }

        let receipt = try await approvalClient.groupsApprove(
            roomID: roomID,
            memberID: approval.memberID,
            taskID: approval.taskID,
            executionGeneration: approval.executionGeneration,
            requestID: approval.requestID,
            choice: choice
        )
        try requireNativeBoundary(boundary)
        guard receipt.approved else { throw BotModeRoomError.nativeApprovalRejected }

        // The approval response is only an acknowledgement. The next state
        // snapshot is the source of truth for whether the action disappeared
        // or was replaced while Hermes advanced the task.
        let after = try await nativeClient.groupsState(roomID: roomID, includeDisbanded: false)
        try requireNativeBoundary(boundary)
        try refreshNativeApprovals(roomID: roomID, driverStatus: after.driverStatus, boundary: boundary)
        if let replacement = pendingApprovals(roomID: roomID).first(where: { $0.id == approval.id }),
           replacement != approval {
            throw BotModeRoomError.nativeApprovalStale
        }
        return receipt
    }
}
