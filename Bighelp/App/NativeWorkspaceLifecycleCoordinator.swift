import Foundation

enum NativeWorkspaceLifecycleError: Error, Equatable, LocalizedError, Sendable {
    case ownerChanged
    case invalidConstruction
    case durableSessionUnavailable
    case profileStateCouldNotBeVerified(profileID: String)
    case protectedProfileState(profileID: String, sessionIDs: [String])
    /// Delete only: a reply didn't stop in time.
    case profileBusy(profileID: String)
    /// Delete only: the agent is in these group chats.
    case profileInGroups(profileID: String, groupTitles: [String])
    case sharedStateMismatch

    var errorDescription: String? {
        switch self {
        case .ownerChanged:
            "The selected Hermes connection changed. Reopen this lifecycle screen."
        case .invalidConstruction:
            "Profile and chat lifecycle controls require the retained native Hermes owner."
        case .durableSessionUnavailable:
            "Hermes confirmed this stored chat, but the current profile catalog could not resolve its exact durable identity. Refresh Chats before trying again."
        case .profileStateCouldNotBeVerified:
            "bighelp could not verify every saved draft for this profile, so the profile change was not sent."
        case .protectedProfileState(_, let sessionIDs):
            "Resolve or save the pending work in \(sessionIDs.count) profile chat(s) before renaming or deleting this profile. No profile change was sent."
        case .profileBusy:
            "This bot is still replying and didn't stop. Wait for it to finish, then delete it. Nothing was deleted."
        case .profileInGroups(_, let titles):
            titles.count == 1
                ? "This bot is in the group chat “\(titles[0])”. Delete that group first, then delete the bot. Nothing was deleted."
                : "This bot is in \(titles.count) group chats. Delete those groups first, then delete the bot. Nothing was deleted."
        case .sharedStateMismatch:
            "Hermes confirmed the profile change, but the shared bighelp stores did not reconcile to the exact readback. Reopen Profiles; do not repeat the server operation."
        }
    }
}

/// Retains the one production native owner used by lifecycle views. It builds
/// fixed-route clients from the selected connection and exposes the exact view
/// callbacks; callers must supply navigation/cache reconciliation explicitly.
@MainActor
final class NativeWorkspaceLifecycleCoordinator {
    typealias AdoptedSessionHandler = @MainActor (SessionSummary) async throws -> Void
    typealias RetiredProfileHandler = @MainActor (
        HermesProfileLifecycleChange, [String]
    ) async throws -> Void
    typealias ReconciledProfileHandler = @MainActor (
        HermesProfileLifecycleResult
    ) async throws -> Void
    typealias ReconciledClosedRuntimeHandler = @MainActor (
        String, HermesSessionCloseResult
    ) async throws -> Void

    let owner: WorkspaceOwner
    let hostName: String
    let sessionMaintenanceClient: DirectHermesSessionMaintenanceClient
    let profileLifecycleClient: DirectHermesProfileLifecycleClient

    private let connections: WorkspaceConnectionStore
    private let catalog: SessionCatalogStore
    private let agents: AgentDirectoryStore
    private let bridge: NativeWorkspaceSessionBridge
    private let adoptedSession: AdoptedSessionHandler
    private let retiredProfile: RetiredProfileHandler
    private let reconciledProfile: ReconciledProfileHandler
    /// How long a delete waits for a stopped reply to settle (8 s).
    private let stopSettleAttempts = 16
    private let stopSettleInterval: Duration = .milliseconds(500)

    init(
        owner: WorkspaceOwner,
        connections: WorkspaceConnectionStore,
        catalog: SessionCatalogStore,
        agents: AgentDirectoryStore,
        bridge: NativeWorkspaceSessionBridge,
        adoptedSession: @escaping AdoptedSessionHandler,
        retiredProfile: @escaping RetiredProfileHandler,
        reconciledProfile: @escaping ReconciledProfileHandler,
        reconciledClosedRuntime: @escaping ReconciledClosedRuntimeHandler
    ) throws {
        guard owner.authority.kind == .direct,
              connections.owner == owner,
              bridge.authority == owner.authority,
              let host = connections.selectedDirectHost,
              let direct = connections.hosts.selectedWorkspace?.nativeClient else {
            throw NativeWorkspaceLifecycleError.invalidConstruction
        }
        self.owner = owner
        hostName = host.name
        self.connections = connections
        self.catalog = catalog
        self.agents = agents
        self.bridge = bridge
        self.adoptedSession = adoptedSession
        self.retiredProfile = retiredProfile
        self.reconciledProfile = reconciledProfile
        let currentOwner: @MainActor () -> WorkspaceOwner? = { [weak connections] in
            connections?.owner
        }
        sessionMaintenanceClient = DirectHermesSessionMaintenanceClient(
            rpc: direct, http: direct, owner: owner, currentOwner: currentOwner,
            resolveClosableRuntime: { request in
                guard currentOwner() == owner, bridge.authority == owner.authority else {
                    throw HermesSessionMaintenanceError.ownerChanged
                }
                return try await bridge.resolveClosableRuntime(request)
            },
            reconcileClosedRuntime: { result in
                guard currentOwner() == owner, bridge.authority == owner.authority else {
                    throw HermesSessionMaintenanceError.ownerChanged
                }
                let visibleID = try bridge.reconcileClosedRuntime(result)
                guard currentOwner() == owner,
                      let retained = catalog.session(id: visibleID),
                      retained.kind == .direct, retained.agentIDs.count == 1,
                      retained.agentIDs[0].utf8.elementsEqual(result.profileID.utf8),
                      retained.remoteStoredID.map({
                          $0.utf8.elementsEqual(result.storedSessionID.utf8)
                      }) == true,
                      !retained.isActive else {
                    throw NativeWorkspaceLifecycleError.sharedStateMismatch
                }
                try await reconciledClosedRuntime(visibleID, result)
                guard currentOwner() == owner else {
                    throw HermesSessionMaintenanceError.ownerChanged
                }
            }
        )
        profileLifecycleClient = DirectHermesProfileLifecycleClient(
            rpc: direct, http: direct, owner: owner, currentOwner: currentOwner
        )
    }

    func sessionMaintenanceView(profileID: String) -> SessionMaintenanceView {
        SessionMaintenanceView(
            hostName: hostName,
            profileID: profileID,
            client: sessionMaintenanceClient,
            onAdoptSession: { [self] request in
                try await onAdoptSession(request)
            }
        )
    }

    /// Deletes an agent's profile the way Profiles does: reviewed, its chats
    /// retired first, then confirmed absent and the app refreshed.
    func deleteAgent(profileID: String) async throws {
        let review = try await profileLifecycleClient.prepareDelete(profileID: profileID)
        let result = try await profileLifecycleClient.delete(reviewed: review) { [self] change in
            try await retireProfileOwnership(change)
        }
        try await onProfileChanged(result)
    }

    func profileLifecycleView(selectedProfileID: String) -> ProfileLifecycleView {
        ProfileLifecycleView(
            hostName: hostName,
            selectedProfileID: selectedProfileID,
            client: profileLifecycleClient,
            retireProfileOwnership: { [self] change in
                try await retireProfileOwnership(change)
            },
            onProfileChanged: { [self] result in
                try await onProfileChanged(result)
            }
        )
    }

    /// Resolves imported, foreign and lineage results through the authoritative
    /// profile catalog, prepares the current bridge coordinate, then delegates
    /// to Root's retained navigation/model adoption path.
    func onAdoptSession(_ request: SessionMaintenanceAdoptionRequest) async throws {
        try requireOwner()
        let record: SessionRecord
        do {
            record = try await catalog.resolveStoredSession(
                profileID: request.profileID,
                storedSessionID: request.storedSessionID
            )
        } catch NativeWorkspaceLifecycleError.durableSessionUnavailable {
            let prepared = try await bridge.prepareStoredSession(
                profileID: request.profileID,
                storedSessionID: request.storedSessionID
            )
            record = try catalog.installWorkspaceRecord(prepared, ownerIsCurrent: { [self] in
                connections.owner == owner
            })
        }
        try requireOwner()
        guard let coordinate = bridge.currentCoordinate(for: record.id),
              coordinate.owner == owner,
              coordinate.profileID.utf8.elementsEqual(request.profileID.utf8),
              coordinate.storedSessionID.map({
                  $0.utf8.elementsEqual(request.storedSessionID.utf8)
              }) == true else {
            throw NativeWorkspaceLifecycleError.durableSessionUnavailable
        }
        try await adoptedSession(record.summary)
        try requireOwner()
    }

    /// Called by the fixed-route lifecycle client after review recheck and
    /// before mutation. Default activation changes no current ownership.
    /// Rename refuses while any target draft, uncertain submission, prompt,
    /// live turn, group membership or unreadable local payload remains: the
    /// chats survive a rename. Delete removes the agent and its chats, so it
    /// stops replies and clears unsent drafts instead; only group chats (and a
    /// reply that won't stop) hold it back.
    func retireProfileOwnership(_ change: HermesProfileLifecycleChange) async throws {
        try requireOwner()
        let profileID: String
        let isDelete: Bool
        switch change {
        case .renamed(let from, _): profileID = from; isDelete = false
        case .deleted(let deleted): profileID = deleted; isDelete = true
        case .defaultActivated:
            return
        case .imported, .descriptionChanged, .onboardingFactsSaved:
            throw NativeWorkspaceLifecycleError.invalidConstruction
        }

        catalog.flushPersistence()
        var blocked = Set<String>()
        var groupTitles: [String] = []
        var localDrafts: [String] = []
        let scoped = catalog.records.filter { record in
            record.agentIDs.contains { $0.utf8.elementsEqual(profileID.utf8) }
        }
        for summary in scoped {
            let record: SessionRecord
            do {
                record = try catalog.restoreSessionContent(id: summary.id)
            } catch {
                if isDelete { continue }
                throw NativeWorkspaceLifecycleError.profileStateCouldNotBeVerified(
                    profileID: profileID
                )
            }
            if isDelete {
                if record.kind == .botMode { groupTitles.append(record.title) }
                else if record.isLocalPresentationDraft { localDrafts.append(record.id) }
                continue
            }
            if record.kind == .botMode
                || record.isLocalPresentationDraft
                || !record.draft.isEmpty
                || record.referenceState?.submission != nil
                || record.hasDeferredReferenceState
                || record.hasActiveWork {
                blocked.insert(record.id)
            }
        }

        if isDelete {
            guard groupTitles.isEmpty else {
                throw NativeWorkspaceLifecycleError.profileInGroups(
                    profileID: profileID, groupTitles: groupTitles.sorted()
                )
            }
            try await stopProfileWork(profileID: profileID)
            for id in localDrafts { catalog.discardLocalPresentationDraft(id: id) }
        } else {
            for state in try bridge.profileSessionOwnership(profileID: profileID)
                where state.blocksDestructiveRetirement {
                blocked.insert(state.sessionID)
            }
            guard blocked.isEmpty else {
                throw NativeWorkspaceLifecycleError.protectedProfileState(
                    profileID: profileID,
                    sessionIDs: blocked.sorted()
                )
            }
        }

        let retiredStreamIDs = try bridge.retireProfileSessions(profileID: profileID, discardingLocalWork: isDelete)
        let affectedSessionIDs = Set(scoped.map(\.id)).union(retiredStreamIDs).sorted()
        try await retiredProfile(change, affectedSessionIDs)
        try requireOwner()
    }

    /// Asks each running reply to stop, then waits a few seconds for Hermes to
    /// settle it. Throws `profileBusy` if one is still running.
    private func stopProfileWork(profileID: String) async throws {
        func isWorking() throws -> Bool {
            try bridge.profileSessionOwnership(profileID: profileID).contains(where: \.hasActiveOperation)
        }
        guard try isWorking() else { return }
        await bridge.stopProfileWork(profileID: profileID)
        for _ in 0..<stopSettleAttempts {
            try requireOwner()
            guard try isWorking() else { return }
            try await Task.sleep(for: stopSettleInterval)
        }
        guard try !isWorking() else {
            throw NativeWorkspaceLifecycleError.profileBusy(profileID: profileID)
        }
    }

    /// Reconciles only after the lifecycle client has exact server readback.
    /// Internal caches/stores are refreshed first; Root then receives one
    /// mandatory callback to reconcile selected profile and navigation.
    func onProfileChanged(_ result: HermesProfileLifecycleResult) async throws {
        try requireOwner()
        switch result.change {
        case .renamed(let from, let to):
            agents.remapProfilePreferences(from: from, to: to)
            try catalog.remapProfileOwnership(from: from, to: to)
            bridge.invalidateCatalogAfterProfileChange()
        case .deleted(let profileID):
            agents.removeProfilePreferences(profileID: profileID)
            bridge.invalidateCatalogAfterProfileChange()
        case .imported:
            bridge.invalidateCatalogAfterProfileChange()
        case .defaultActivated, .descriptionChanged, .onboardingFactsSaved:
            break
        }

        try await agents.reloadAfterProfileLifecycleChange()
        try requireOwner()
        try await catalog.load(requireAuthoritativeRefresh: true)
        try requireOwner()
        try verifySharedReadback(result)
        try await reconciledProfile(result)
        try requireOwner()
    }

    private func verifySharedReadback(_ result: HermesProfileLifecycleResult) throws {
        let agentIDs = agents.profiles.map(\.id)
        func containsAgent(_ id: String) -> Bool {
            agentIDs.contains { $0.utf8.elementsEqual(id.utf8) }
        }
        let expectedAgentIDs = Set(result.catalog.profiles.map { Data($0.id.utf8) })
        let actualAgentIDs = Set(agentIDs.map { Data($0.utf8) })
        guard actualAgentIDs == expectedAgentIDs else {
            throw NativeWorkspaceLifecycleError.sharedStateMismatch
        }
        switch result.change {
        case .renamed(let from, let to):
            guard containsAgent(to), !containsAgent(from),
                  !catalog.records.contains(where: { record in
                      record.agentIDs.contains { $0.utf8.elementsEqual(from.utf8) }
                  }) else { throw NativeWorkspaceLifecycleError.sharedStateMismatch }
        case .deleted(let profileID):
            guard !containsAgent(profileID),
                  !catalog.records.contains(where: { record in
                      record.agentIDs.contains { $0.utf8.elementsEqual(profileID.utf8) }
                  }) else { throw NativeWorkspaceLifecycleError.sharedStateMismatch }
        case .imported(let profileID), .defaultActivated(let profileID),
             .descriptionChanged(let profileID), .onboardingFactsSaved(let profileID):
            guard containsAgent(profileID) else {
                throw NativeWorkspaceLifecycleError.sharedStateMismatch
            }
        }
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard connections.owner == owner,
              owner.authority == bridge.authority else {
            throw NativeWorkspaceLifecycleError.ownerChanged
        }
    }
}