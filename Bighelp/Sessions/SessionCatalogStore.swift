import Foundation
import Observation

enum SessionCatalogLoadOwnershipError: Error {
    case superseded
}

@MainActor
@Observable
final class SessionCatalogStore {
    // State lives here; responsibility extensions operate on this same MainActor
    // owner. Internal implementation seams are not independent state owners.
    static let fixturePageSize = 50
    static let summaryRetentionLimit = 500

    private(set) var records: [SessionRecord] = [] {
        didSet { persistenceRevision &+= 1 }
    }
    private var deferredPresentationRecords: [SessionRecord]?

    /// UI reads a stable snapshot during historical delivery. Routing, merge,
    /// authorization and persistence always use the current canonical records.
    var presentedRecords: [SessionRecord] { deferredPresentationRecords ?? records }

    func setPresentationDeferred(_ deferred: Bool) {
        if deferred {
            if deferredPresentationRecords == nil { deferredPresentationRecords = records }
        } else {
            deferredPresentationRecords = nil
        }
    }
    private(set) var loadErrorMessage: String? = nil
    private(set) var refreshErrorMessage: String? = nil
    var persistenceErrorMessage: String? = nil
    var hasUnsavedChanges = false
    @ObservationIgnored private(set) var lastChatMutationWorkCount = 0
    @ObservationIgnored var repositorySaveCount = 0
    @ObservationIgnored var persistenceCheckpointTask: Task<Void, Never>?
    @ObservationIgnored var persistenceCheckpointID: UUID?
    @ObservationIgnored var persistenceRevision: UInt64 = 0
    let persistenceCheckpointDelay: Duration
    let encodeSnapshot: (@Sendable ([SessionRecord]) async throws -> Data)?

    let client: any SessionCatalogClient
    var canDeleteConversation: Bool { client.canDeleteConversation }
    private let forkClient: any SessionForkClient
    private let nativeFork: (@MainActor (SessionRecord, String) async throws -> SessionRecord)?
    private let defaultActivityVisibility: @MainActor () -> ChatActivityVisibility
    let repository: (any SessionCatalogRepository)?
    let defaults: UserDefaults
    let currentHostID: () -> String?
    var pinPreferences: [String: Bool] = [:]
    var repositoryAllowsWrites = true
    private var hasLoadedCatalogState = false
    var accountGeneration: UInt64 = 0
    private var latestLoadGeneration: UInt64 = 0
    private var loadInvalidationGeneration: UInt64 = 0
    private struct AuthoritativeLoad {
        let id = UUID()
        let task: Task<Void, Error>
        var waiters = Set<UUID>()
    }
    private var authoritativeLoad: AuthoritativeLoad?
    struct InitialHistoryLoad {
        let id = UUID()
        let task: Task<SessionRecord, Error>
        var waiters = Set<UUID>()
    }
    @ObservationIgnored var initialHistoryLoads: [String: InitialHistoryLoad] = [:]
    var latestHydrationGenerationByID: [String: UInt64] = [:]
    var previousHistoryOffsetByID: [String: Int] = [:]
    private var acceptedStopAtByID: [String: Date] = [:]
    private var subagentParentBySessionID: [String: String] = [:]

    init(
        client: any SessionCatalogClient,
        records: [SessionRecord] = [],
        repository: (any SessionCatalogRepository)? = nil,
        loadsRepositoryOnInit: Bool = true,
        forkClient: (any SessionForkClient)? = nil,
        nativeFork: (@MainActor (SessionRecord, String) async throws -> SessionRecord)? = nil,
        defaults: UserDefaults = .standard,
        currentHostID: @escaping () -> String? = { nil },
        persistenceCheckpointDelay: Duration = .seconds(2),
        encodeSnapshot: (@Sendable ([SessionRecord]) async throws -> Data)? = nil,
        defaultActivityVisibility: @escaping @MainActor () -> ChatActivityVisibility = {
            .default
        }
    ) {
        self.client = client
        self.forkClient = forkClient ?? LocalSessionForkClient()
        self.nativeFork = nativeFork
        self.defaultActivityVisibility = defaultActivityVisibility
        self.repository = repository
        self.defaults = defaults
        self.currentHostID = currentHostID
        self.persistenceCheckpointDelay = persistenceCheckpointDelay
        self.encodeSnapshot = encodeSnapshot
        self.records = SessionCatalogReconciliation.retained(records)
        loadPinPreferences()
        migratePinnedRecordsIfNeeded(self.records)
        self.records = applyingPinPreferences(to: self.records)
        hasLoadedCatalogState = !self.records.isEmpty
        if let repository, loadsRepositoryOnInit {
            do {
                self.records = SessionCatalogReconciliation.retained(try repository.load())
                migratePinnedRecordsIfNeeded(self.records)
                self.records = applyingPinPreferences(to: self.records)
                hasLoadedCatalogState = true
            } catch {
                repositoryAllowsWrites = false
                loadErrorMessage = "Sessions could not be loaded. Try again."
            }
        }
        rebuildSubagentParentIndex()
    }

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

    private func releaseAuthoritativeWaiter(_ waiter: UUID, flightID: UUID) {
        guard authoritativeLoad?.id == flightID else { return }
        authoritativeLoad?.waiters.remove(waiter)
        if authoritativeLoad?.waiters.isEmpty == true {
            let task = authoritativeLoad?.task
            authoritativeLoad = nil
            task?.cancel()
        }
    }

    private func performLoad(requireAuthoritativeRefresh: Bool) async throws {
        let generation = accountGeneration
        loadPinPreferences()
        latestLoadGeneration &+= 1
        let loadGeneration = latestLoadGeneration
        var hasUsableLocalState = hasLoadedCatalogState || !records.isEmpty
        if let repository, !requireAuthoritativeRefresh {
            do {
                let cachedRecords = try repository.load()
                repositoryAllowsWrites = true
                hasLoadedCatalogState = true
                hasUsableLocalState = true
                migratePinnedRecordsIfNeeded(cachedRecords)
                let preferredCachedRecords = applyingPinPreferences(to: cachedRecords)
                records = hasUnsavedChanges || cachedRecords.contains(where: { !$0.isContentLoaded })
                    ? SessionCatalogReconciliation.merged(local: records, incoming: preferredCachedRecords)
                    : SessionCatalogReconciliation.retained(preferredCachedRecords)
                applyKnownSubagentParents()
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
            records = (!requireAuthoritativeRefresh && (repository != nil || hasUnsavedChanges))
                ? SessionCatalogReconciliation.merged(local: records, incoming: protectedIncoming)
                : SessionCatalogReconciliation.reconciled(local: records, authoritativeIncoming: protectedIncoming)
            applyKnownSubagentParents()
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

        persistChangesIfNeeded()
    }

    func resetForAccountBoundary() {
        cancelPersistenceCheckpoint()
        if deferredPresentationRecords != nil { deferredPresentationRecords = [] }
        accountGeneration &+= 1
        loadInvalidationGeneration &+= 1
        authoritativeLoad?.task.cancel()
        authoritativeLoad = nil
        cancelHistoryRefreshes()
        client.resetForAccountBoundary()
        repository?.resetForAccountBoundary()
        records.removeAll()
        loadErrorMessage = nil
        refreshErrorMessage = nil
        persistenceErrorMessage = nil
        hasUnsavedChanges = false
        repositoryAllowsWrites = true
        hasLoadedCatalogState = false
        latestHydrationGenerationByID.removeAll()
        previousHistoryOffsetByID.removeAll()
        acceptedStopAtByID.removeAll()
        subagentParentBySessionID.removeAll()
    }

    static func erasePersistedUserPreferences(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: PreferenceKeys.pinsByHost)
    }

    /// Reads the cache only after the selected-host repository scope changes.
    /// The authoritative remote load remains owned by the account refresh.
    func restoreRepositoryCacheForHostSwitch() {
        guard let repository else { return }
        cancelPersistenceCheckpoint()
        repository.resetForAccountBoundary()
        do {
            loadPinPreferences()
            records = SessionCatalogReconciliation.retained(try repository.load())
            migratePinnedRecordsIfNeeded(records)
            records = applyingPinPreferences(to: records)
            rebuildSubagentParentIndex()
            repositoryAllowsWrites = true
            hasLoadedCatalogState = true
            loadErrorMessage = nil
        } catch {
            records.removeAll()
            repositoryAllowsWrites = false
            hasLoadedCatalogState = false
            loadErrorMessage = "Sessions could not be loaded. Try again."
        }
    }

    func createDirect(agentID: String) async throws -> SessionRecord {
        let generation = accountGeneration
        var record = try await client.create(kind: .direct, agentIDs: [agentID])
        guard generation == accountGeneration else { throw CancellationError() }
        record.activityVisibility = defaultActivityVisibility()
        upsert(record)
        persistChangesIfNeeded()
        return record
    }

    /// Creates an ephemeral local canvas before the authoritative Hermes
    /// session exists. The ID is deliberately local-only and is replaced as
    /// soon as the real session is prepared.
    @discardableResult
    func createLocalPresentationDraft(agentID: String) -> SessionRecord {
        var record = SessionRecord(
            id: "local-draft:\(UUID().uuidString.lowercased())",
            kind: .direct,
            agentIDs: [agentID],
            title: "New chat"
        )
        record.activityVisibility = defaultActivityVisibility()
        upsert(record)
        persistChangesIfNeeded()
        return record
    }

    /// Removes a local presentation draft after its draft has been copied to
    /// the authoritative Hermes session. Never remove a remote or accepted
    /// record through this local-only cleanup path.
    func discardLocalPresentationDraft(id: String) {
        guard let record = session(id: id), record.isLocalPresentationDraft else { return }
        records.removeAll { $0.id == id }
        pinPreferences.removeValue(forKey: id)
        previousHistoryOffsetByID[id] = nil
        latestHydrationGenerationByID[id] = nil
        acceptedStopAtByID[id] = nil
        persistChangesIfNeeded()
    }

    func session(id: String) -> SessionRecord? {
        records.first { $0.id == id }
    }

    /// Explicit selected-chat boundary. Catalog/list lookups remain metadata
    /// only; restoring this one payload never constructs a ChatModel or view.
    @discardableResult
    func restoreSessionContent(id: String) throws -> SessionRecord {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw SessionCatalogError.invalidSession
        }
        guard !records[index].isContentLoaded else { return records[index] }
        guard let repository else { throw ReferenceCanonicalSendError.persistenceUnavailable }
        do {
            let restored = try repository.restoreContent(in: records[index])
            guard restored.id == id, restored.isContentLoaded else {
                throw SessionContentRepositoryError.missingContent(id)
            }
            records[index] = restored
            return restored
        } catch {
            persistenceDidFail()
            throw error
        }
    }

    private func contentSession(id: String) -> SessionRecord? {
        try? restoreSessionContent(id: id)
    }

    func visibleSessionID(resolvingProtocolSessionID sessionID: String) -> String? {
        if let canonical = records.first(where: {
            $0.id != sessionID && $0.remoteStoredID == sessionID
        }) {
            return canonical.id
        }
        return self.session(id: sessionID)?.id
    }

    func reconcileSubagentWork(_ snapshot: SessionSubagentRosterSnapshot) {
        guard let index = records.firstIndex(where: { $0.id == snapshot.sessionID }),
              records[index].sessionSubagents != snapshot,
              snapshot.supersedes(records[index].sessionSubagents) else { return }
        records[index].sessionSubagents = snapshot
        schedulePersistenceCheckpoint()
    }

    func reconcileSessionTodos(_ snapshot: SessionTodoSnapshot) {
        guard let index = records.firstIndex(where: { $0.id == snapshot.sessionID }),
              snapshot.supersedes(records[index].sessionTodos) else { return }
        records[index].sessionTodos = snapshot
        schedulePersistenceCheckpoint()
    }

    func reconcileSubagentSessions(parentSessionID: String, childSessionIDs: [String]) {
        var changed = false
        for childSessionID in childSessionIDs where childSessionID != parentSessionID {
            let visibleID = visibleSessionID(resolvingProtocolSessionID: childSessionID)
                ?? childSessionID
            subagentParentBySessionID[childSessionID] = parentSessionID
            subagentParentBySessionID[visibleID] = parentSessionID
            guard let index = records.firstIndex(where: { $0.id == visibleID }) else { continue }
            let parentAgents = session(id: parentSessionID)?.agentIDs ?? []
            guard records[index].agentIDs.isEmpty || parentAgents.isEmpty
                || !Set(records[index].agentIDs).isDisjoint(with: parentAgents) else { continue }
            if records[index].agentIDs.isEmpty && !parentAgents.isEmpty {
                records[index].agentIDs = parentAgents
                changed = true
            }
            if records[index].parentSessionID != parentSessionID {
                records[index].parentSessionID = parentSessionID
                changed = true
            }
        }
        if changed { schedulePersistenceCheckpoint() }
    }

    func renameSession(id: String, title value: String) async throws {
        guard let record = session(id: id) else { throw SessionCatalogError.invalidSession }
        let title = try SessionTitleRules.validated(value)
        let generation = accountGeneration
        try await client.rename(record, title: title)
        guard generation == accountGeneration else { throw CancellationError() }
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw SessionCatalogError.invalidSession
        }
        records[index].title = title
        persistChangesIfNeeded()
    }

    func reconcileLiveSessionTitle(id: String, title value: String?, persist: Bool = true) {
        guard let value,
              let title = try? SessionTitleRules.validated(value),
              let index = records.firstIndex(where: { $0.id == id }),
              records[index].title != title else { return }
        records[index].title = title
        if persist { persistChangesIfNeeded() } else { schedulePersistenceCheckpoint() }
    }

    func reconcileSessionGoal(_ snapshot: SessionGoalSnapshot) {
        guard let index = records.firstIndex(where: { $0.id == snapshot.sessionID }),
              records[index].remoteStoredID == nil || records[index].remoteStoredID == snapshot.storedSessionID,
              snapshot.supersedes(records[index].sessionGoal) else { return }
        records[index].sessionGoal = snapshot
        schedulePersistenceCheckpoint()
    }

    func reconcileSessionContext(_ snapshot: SessionContextSnapshot) {
        guard let index = records.firstIndex(where: { $0.id == snapshot.sessionId }) else {
            return
        }
        guard records[index].sessionContext != snapshot,
              records[index].sessionContext.map({
            snapshot.updatedAt >= $0.updatedAt
        }) ?? true else { return }
        records[index].sessionContext = snapshot
        if let value = snapshot.title,
           let title = try? SessionTitleRules.validated(value) {
            records[index].title = title
        }
        schedulePersistenceCheckpoint()
    }

    /// Stores the workspace returned by a completed Hermes selection on the
    /// session summary. The caller must have obtained this pair from the
    /// workspace client's verified readback; an absent pair means Hermes
    /// confirmed that the session is unassigned.
    func reconcileSessionWorkspace(
        id workspaceID: String?,
        name workspaceName: String?,
        sessionID: String
    ) {
        guard let index = records.firstIndex(where: { $0.id == sessionID }) else { return }
        guard workspaceID == nil || workspaceName != nil else { return }
        let name = workspaceID == nil ? nil : workspaceName
        guard records[index].workspaceID != workspaceID || records[index].workspaceName != name else {
            return
        }
        records[index].workspaceID = workspaceID
        records[index].workspaceName = name
        persistChangesIfNeeded()
    }

    func setSessionPinned(id: String, pinned: Bool) async throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw SessionCatalogError.invalidSession
        }
        records[index].isPinned = pinned
        pinPreferences[id] = pinned
        persistPinPreferences()
        persistChangesIfNeeded()
    }

    func archiveSession(id: String) async throws {
        try await removeSession(id: id, using: client.archive)
    }

    /// Remove only the local chat projection after Hermes confirms disbanding.
    func removeConfirmedHostedGroup(roomID: String) {
        let ids = records.filter { $0.remoteSource == "hermes-room" && $0.botModeRoomID == roomID }.map(\.id)
        records.removeAll { ids.contains($0.id) }
        deferredPresentationRecords?.removeAll { ids.contains($0.id) }
        for id in ids {
            pinPreferences.removeValue(forKey: id)
            previousHistoryOffsetByID[id] = nil
            latestHydrationGenerationByID[id] = nil
            acceptedStopAtByID[id] = nil
        }
        persistPinPreferences()
        persistChangesIfNeeded()
    }

    func deleteSession(id: String) async throws {
        guard canDeleteConversation else {
            throw WorkspaceClientError.unavailable(.conversationDeletionUnsupported)
        }
        try await removeSession(id: id, using: client.delete)
    }

    private func removeSession(
        id: String,
        using mutation: (SessionRecord) async throws -> Void
    ) async throws {
        guard let record = session(id: id) else { throw SessionCatalogError.invalidSession }
        let generation = accountGeneration
        try await mutation(record)
        guard generation == accountGeneration else { throw CancellationError() }
        // A list read before the host removed the chat would put it back.
        latestLoadGeneration &+= 1
        records.removeAll { $0.id == id }
        pinPreferences.removeValue(forKey: id)
        persistPinPreferences()
        previousHistoryOffsetByID[id] = nil
        latestHydrationGenerationByID[id] = nil
        acceptedStopAtByID[id] = nil
        persistChangesIfNeeded()
    }

    /// Creates the bounded local summary needed to display a live child before
    /// Hermes has flushed its durable session row. The supplied id is the
    /// authenticated child coordinate from Link; no child identity is inferred.
    @discardableResult
    func ensureActiveChild(id: String, title: String, agentID: String? = nil, persist: Bool = true) -> SessionRecord {
        if let existing = session(id: id) {
            return existing
        }
        let record = SessionRecord(
            id: id,
            kind: .direct,
            agentIDs: agentID.map { [$0] } ?? [],
            title: title,
            parentSessionID: subagentParentBySessionID[id],
            isActive: true,
            updatedAt: .now
        )
        upsert(record)
        if persist { persistChangesIfNeeded() } else { schedulePersistenceCheckpoint() }
        return record
    }

    @discardableResult
    func installWorkspaceRecord(_ record: SessionRecord, ownerIsCurrent: @MainActor () -> Bool) throws -> SessionRecord {
        guard ownerIsCurrent(), !record.id.isEmpty, record.id.utf8.count <= 4_096,
              !record.agentIDs.isEmpty, record.agentIDs.count <= BotModeRoom.maximumMembers else {
            throw SessionCatalogError.invalidSession
        }
        if var existing = session(id: record.id) {
            guard existing.kind == record.kind, existing.agentIDs == record.agentIDs,
                  existing.botModeRoomID == record.botModeRoomID else { throw SessionCatalogError.invalidSession }
            existing.title = record.title
            existing.remoteStoredID = record.remoteStoredID ?? existing.remoteStoredID
            existing.remoteSource = record.remoteSource ?? existing.remoteSource
            upsert(existing)
            persistChangesIfNeeded()
            return existing
        }
        upsert(record)
        persistChangesIfNeeded()
        return record
    }

    var hasLoadedState: Bool {
        hasLoadedCatalogState
    }

    var onLivePresentation: ((SessionRecord, [String: BighelpJSONValue], String) -> Void)?

    /// A verified rename keeps the same durable transcripts. Remapping the
    /// local owner before authoritative refresh lets canonical merge preserve
    /// cache, pin and transcript state under Hermes' new visible session IDs.
    func remapProfileOwnership(from oldProfileID: String, to newProfileID: String) throws {
        try WorkspaceAuthority.validateIdentifier(oldProfileID, maximumBytes: 128)
        try WorkspaceAuthority.validateIdentifier(newProfileID, maximumBytes: 128)
        guard !oldProfileID.utf8.elementsEqual(newProfileID.utf8) else { return }
        let affected = records.indices.filter { records[$0].agentIDs.contains(where: {
            $0.utf8.elementsEqual(oldProfileID.utf8)
        }) }
        // Validate every row before changing any owner. A later protected draft
        // must not leave earlier records partially remapped in memory.
        for index in affected {
            guard records[index].referenceState?.submission == nil,
                  records[index].draft.isEmpty,
                  !records[index].hasDeferredReferenceState else {
                throw NativeWorkspaceLifecycleError.protectedProfileState(
                    profileID: oldProfileID,
                    sessionIDs: [records[index].id]
                )
            }
        }
        for index in affected {
            records[index].agentIDs = records[index].agentIDs.map {
                $0.utf8.elementsEqual(oldProfileID.utf8) ? newProfileID : $0
            }
        }
        persistChangesIfNeeded()
    }

    /// Publishes an accepted Stop immediately and invalidates catalog/history
    /// reads that began before it. A subsequent authoritative refresh owns a
    /// newer generation and may report genuinely newer active work.
    func markInactiveAfterAcceptedStop(id: String) {
        latestLoadGeneration &+= 1
        loadInvalidationGeneration &+= 1
        latestHydrationGenerationByID[id] = (latestHydrationGenerationByID[id] ?? 0) &+ 1
        acceptedStopAtByID[id] = .now
        mutate(id, requiresContent: false) { record in
            record.isActive = false
        }
        persistChangesIfNeeded()
    }

    func markActiveForLocalTurn(id: String) {
        acceptedStopAtByID[id] = nil
        mutate(id, requiresContent: false) { record in
            record.isActive = true
        }
        persistChangesIfNeeded()
    }

    func markInactiveAfterAuthoritativeTerminal(id: String, persist: Bool = true) {
        acceptedStopAtByID[id] = nil
        mutate(id, requiresContent: false) { record in
            record.isActive = false
        }
        if persist { persistChangesIfNeeded() } else { schedulePersistenceCheckpoint() }
    }

    /// Applies only owner-scoped native runtime observations. A locally accepted
    /// Stop remains authoritative until Hermes reports its idle bookend; after
    /// that bookend, a later native start may represent genuinely new work.
    func reconcileNativeSessionLiveness(id: String, isActive: Bool) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if isActive, acceptedStopAtByID[id] != nil { return }
        if !isActive { acceptedStopAtByID[id] = nil }
        guard records[index].isActive != isActive else { return }
        records[index].isActive = isActive
        if isActive { records[index].updatedAt = .now }
        schedulePersistenceCheckpoint()
    }

    func forkSession(id: String, throughItemID: String) async throws -> SessionRecord {
        _ = try restoreSessionContent(id: id)
        guard
            let source = session(id: id),
            source.kind == .direct,
            let checkpointIndex = source.items.firstIndex(where: { $0.id == throughItemID }),
            case .message(let checkpointText) = source.items[checkpointIndex].content,
            let agentID = source.agentIDs.first,
            !agentID.isEmpty
        else { throw SessionCatalogError.invalidSession }

        if let nativeFork {
            let generation = accountGeneration
            let fork = try await nativeFork(source, throughItemID)
            guard generation == accountGeneration, fork.id != source.id,
                  fork.agentIDs == source.agentIDs, fork.kind == .direct else { throw SessionCatalogError.invalidSession }
            upsert(fork)
            persistChangesIfNeeded()
            return fork
        }
        let prefix = Array(source.items.prefix(through: checkpointIndex))
        let userTurn = prefix.reduce(into: 0) { count, item in
            guard item.role == .human, case .message = item.content else { return }
            count += 1
        }
        guard userTurn > 0 else { throw SessionCatalogError.invalidSession }
        let checkpointRole: SessionForkCheckpointRole = source.items[checkpointIndex].role == .human
            ? .user
            : .assistant
        let requestedID = "fork_\(UUID().uuidString.lowercased())"
        let requestedTitle = Self.forkTitle(source.title)
        let request = SessionForkRequest(
            sourceSessionID: source.id,
            forkSessionID: requestedID,
            agentID: agentID,
            checkpoint: SessionForkCheckpoint(
                userTurn: userTurn,
                role: checkpointRole,
                content: checkpointText
            ),
            title: requestedTitle
        )
        let generation = accountGeneration
        let receipt = try await forkClient.fork(request)
        guard generation == accountGeneration else { throw CancellationError() }
        guard
            receipt.forkSessionID == requestedID,
            session(id: receipt.forkSessionID) == nil,
            !receipt.title.isEmpty,
            receipt.title.count <= 240
        else { throw SessionCatalogError.invalidSession }

        let fork = SessionRecord(
            id: receipt.forkSessionID,
            kind: .direct,
            agentIDs: source.agentIDs,
            title: receipt.title,
            items: prefix,
            activityVisibility: source.activityVisibility,
            hasAcceptedMessage: prefix.contains(where: { $0.role == .human })
        )
        upsert(fork)
        persistChangesIfNeeded()
        return fork
    }

    var recentSummaries: [SessionSummary] {
        recentSummaries(includeCronSessions: false)
    }

    func recentSummaries(includeCronSessions: Bool) -> [SessionSummary] {
        presentedRecords
            .filter { !$0.isSubagentSession && !$0.isWorkflowSession && ($0.hasAcceptedMessage || $0.hasActiveWork) }
            .filter { includeCronSessions || !$0.isCronSession }
            .sorted(by: SessionCatalogReconciliation.activitySort)
            .prefix(Self.summaryRetentionLimit)
            .map(\.summary)
    }

    /// Synchronous durable checkpoint for the canonical send boundary. Unlike
    /// the ordinary best-effort/debounced snapshot callback, failure propagates
    /// so ChatModel cannot upload before its immutable intent is on disk.
    func updateReferenceState(
        canonicalDraft: String,
        state: ReferenceCanonicalState?,
        for sessionID: String
    ) throws {
        _ = try restoreSessionContent(id: sessionID)
        guard let index = records.firstIndex(where: { $0.id == sessionID }) else {
            throw SessionCatalogError.invalidSession
        }
        if let state {
            let decoded = ReferenceCodec.decode(canonicalDraft)
            guard state.selections.isEmpty || (decoded.hasValidAppendix
                && ReferenceCanonicalState.restoreSelections(decoded.references,
                    bindings: state.selections) != nil) else {
                throw ReferenceCanonicalSendError.invalidDraft
            }
            if let submission = state.submission {
                guard submission.owner.sessionID == sessionID,
                      records[index].agentIDs == submission.owner.recipientIDs,
                      submission.frozenDraft != nil else {
                    throw ReferenceCanonicalSendError.invalidDraft
                }
            }
        }
        guard let repository, repositoryAllowsWrites else {
            persistenceDidFail()
            throw ReferenceCanonicalSendError.persistenceUnavailable
        }
        let previous = records[index]
        records[index].draft = canonicalDraft
        records[index].referenceState = state
        do {
            try repository.save(records)
            repositorySaveCount += 1
            persistenceDidSucceed()
        } catch {
            records[index] = previous
            persistenceDidFail()
            throw error
        }
    }

    func selectReferenceGitHubCredential(_ id: String?, for sessionID: String, disabled: Bool = false) throws {
        _ = try restoreSessionContent(id: sessionID)
        guard let index = records.firstIndex(where: { $0.id == sessionID }),
              let repository, repositoryAllowsWrites else {
            throw ReferenceCanonicalSendError.persistenceUnavailable
        }
        let previous = records[index].referenceGitHubCredentialID
        let previouslyDisabled = records[index].referenceGitHubDisabled
        records[index].referenceGitHubCredentialID = id
        records[index].referenceGitHubDisabled = disabled
        do {
            try repository.save(records)
            repositorySaveCount += 1
            persistenceDidSucceed()
        } catch {
            records[index].referenceGitHubCredentialID = previous
            records[index].referenceGitHubDisabled = previouslyDisabled
            persistenceDidFail()
            throw error
        }
    }

    func updateDraft(_ draft: String, for sessionID: String) {
        guard contentSession(id: sessionID) != nil else { return }
        mutate(sessionID) { record in
            record.draft = draft
        }
        persistChangesIfNeeded()
    }

    func replaceItems(_ items: [TimelineItem], for sessionID: String) {
        guard contentSession(id: sessionID) != nil else { return }
        mutate(sessionID) { record in
            guard record.kind != .botMode else { return }
            let knownIDs = Set(record.items.map(\.id))
            let hasNewTurn = items.contains {
                !knownIDs.contains($0.id) && ($0.role == .human || $0.role == .assistant)
            }
            record.items = items
            record.hasAcceptedMessage = record.hasAcceptedMessage
                || items.contains(where: { $0.role == .human })
            if hasNewTurn {
                record.updatedAt = .now
            }
        }
        persistChangesIfNeeded()
    }

    func updateChatSnapshot(
        draft: String,
        items: [TimelineItem],
        activityEvents: [ChatActivityEvent] = [],
        activityVisibility: ChatActivityVisibility = .default,
        persist: Bool = true,
        for sessionID: String
    ) {
        lastChatMutationWorkCount = items.count + activityEvents.count
        guard contentSession(id: sessionID) != nil else { return }
        mutate(sessionID) { record in
            record.draft = draft
            if record.kind != .botMode {
                let knownIDs = Set(record.items.map(\.id))
                let hasNewTurn = items.contains {
                    !knownIDs.contains($0.id) && ($0.role == .human || $0.role == .assistant)
                }
                record.items = items
                record.hasAcceptedMessage = record.hasAcceptedMessage
                    || items.contains(where: { $0.role == .human })
                if hasNewTurn {
                    record.updatedAt = .now
                }
            }
            record.activityEvents = Array(activityEvents.suffix(500))
            record.activityVisibility = activityVisibility
        }
        if persist {
            schedulePersistenceCheckpoint()
        } else {
            hasUnsavedChanges = true
        }
    }

    func updateStreamingTail(_ item: TimelineItem, for sessionID: String) {
        guard contentSession(id: sessionID) != nil else { return }
        lastChatMutationWorkCount = 0
        mutate(sessionID) { record in
            guard record.kind != .botMode else { return }
            guard let lastIndex = record.items.indices.last else {
                record.items.append(item)
                lastChatMutationWorkCount = 1
                return
            }
            lastChatMutationWorkCount += 1
            if record.items[lastIndex].id == item.id {
                record.items[lastIndex] = item
                lastChatMutationWorkCount += 1
            } else if let itemOrder = item.metadata.sourceOrder,
                      let lastOrder = record.items[lastIndex].metadata.sourceOrder,
                      itemOrder > lastOrder {
                record.items.append(item)
                lastChatMutationWorkCount += 1
            } else if let index = record.items.indices.dropLast().first(where: { index in
                lastChatMutationWorkCount += 1
                return record.items[index].id == item.id
            }) {
                record.items[index] = item
                lastChatMutationWorkCount += 1
            } else {
                record.items.append(item)
                lastChatMutationWorkCount += 1
            }
            record.hasAcceptedMessage = record.hasAcceptedMessage || item.role == .human
        }
        hasUnsavedChanges = true
    }

    func accept(_ item: TimelineItem, for sessionID: String) {
        guard contentSession(id: sessionID) != nil else { return }
        update(sessionID) { record in
            guard !record.items.contains(where: { $0.id == item.id }) else { return }
            record.items.append(item)
            record.hasAcceptedMessage = true
        }
        persistChangesIfNeeded()
    }

    /// Live, authenticated activity may establish liveness, but finishing a
    /// tool or a reasoning segment is never a terminal session event.
    func reconcileActivityLiveness(_ event: ChatActivityEvent, for sessionID: String) {
        // Delegation has its own roster. A child starting after the parent
        // final must not resurrect the parent's model-generation flag.
        guard event.lifecycle == .running, event.kind != .subagent,
              let record = contentSession(id: sessionID) else { return }
        let occurredAt = DashboardWorkProjection.activityDate(for: event)
        if let stoppedAt = acceptedStopAtByID[sessionID], occurredAt <= stoppedAt { return }
        let finalDate = record.items.filter {
            $0.role == .assistant && $0.metadata.delivery != "Streaming"
        }.compactMap(\.metadata.timestamp).max()
        if let finalDate, occurredAt.timeIntervalSince1970.rounded(.down) <= finalDate.timeIntervalSince1970 { return }
        mutate(sessionID) { $0.isActive = true }
        hasUnsavedChanges = true
    }

    func acceptExternalTimelineItem(_ item: TimelineItem, for sessionID: String) {
        guard let record = contentSession(id: sessionID), record.kind != .botMode else { return }
        // A delayed draft must not replace the accepted final with the same ID.
        if item.metadata.delivery == "Streaming", record.items.contains(where: {
            $0.id == item.id && $0.metadata.delivery != "Streaming"
        }) { return }
        updateStreamingTail(item, for: sessionID)
        schedulePersistenceCheckpoint()
    }

    /// Called only with an authenticated assistant-message envelope, not with
    /// tool completions or generative UI cards that happen to use Delivered.
    func reconcileAssistantLiveness(
        sessionID: String, turnID: String? = nil, sentAt: Date, isStreaming: Bool
    ) {
        guard let record = contentSession(id: sessionID) else { return }
        if let stoppedAt = acceptedStopAtByID[sessionID], sentAt <= stoppedAt { return }
        if let turnID,
           let latest = record.activityEvents.max(by: { DashboardWorkProjection.activityDate(for: $0) < DashboardWorkProjection.activityDate(for: $1) }),
           latest.turnID != turnID,
           record.activityEvents.contains(where: { $0.turnID == turnID }) {
            return
        }
        let newestMessage = record.items.compactMap(\.metadata.timestamp).max() ?? .distantPast
        let newestActivity = record.activityEvents.map {
            DashboardWorkProjection.activityDate(for: $0)
        }.max() ?? .distantPast
        // Assistant envelopes have second precision. A demonstrably newer
        // turn wins; equal-second delivery retains authenticated stream order.
        guard newestMessage.timeIntervalSince1970.rounded(.down) <= sentAt.timeIntervalSince1970,
              newestActivity.timeIntervalSince1970.rounded(.down) <= sentAt.timeIntervalSince1970
        else { return }
        mutate(sessionID) { $0.isActive = isStreaming }
        // The following timeline update flushes the terminal message and this
        // status together, rather than writing the same conversation twice.
        hasUnsavedChanges = true
    }

    static let activityRetentionLimit = 500

    func replaceActivity(
        _ events: [ChatActivityEvent],
        visibility: ChatActivityVisibility,
        for sessionID: String
    ) {
        guard contentSession(id: sessionID) != nil else { return }
        mutate(sessionID) { record in
            record.activityEvents = Array(events.suffix(Self.activityRetentionLimit))
            record.activityVisibility = visibility
        }
        schedulePersistenceCheckpoint()
    }

    @discardableResult
    func convertToBotMode(
        sessionID: String,
        memberIDs: [String],
        roomID: String,
        privateHistory: [TimelineItem]? = nil
    ) -> Bool {
        guard contentSession(id: sessionID) != nil else { return false }
        guard !memberIDs.isEmpty,
              let index = records.firstIndex(where: { $0.id == sessionID }) else { return false }
        let previous = records[index]
        var converted = previous
        converted.kind = .botMode
        converted.agentIDs = memberIDs
        converted.botModeRoomID = roomID
        converted.botModePrivateHistory = previous.kind == .direct
            ? (privateHistory ?? previous.items)
            : previous.botModePrivateHistory
        if previous.kind == .direct {
            converted.items = []
        }
        converted.updatedAt = .now
        records[index] = converted
        guard repositoryAllowsWrites else {
            records[index] = previous
            persistenceDidFail()
            return false
        }
        do {
            try repository?.save(records)
            persistenceDidSucceed()
            return true
        } catch {
            records[index] = previous
            persistenceDidFail()
            return false
        }
    }

    @discardableResult
    func convertToDirect(
        sessionID: String,
        roomID: String,
        remainingAgentID: String,
        privateHistory: [TimelineItem]
    ) -> Bool {
        guard contentSession(id: sessionID) != nil else { return false }
        guard !remainingAgentID.isEmpty,
              let index = records.firstIndex(where: { $0.id == sessionID }),
              records[index].kind == .botMode,
              records[index].botModeRoomID == roomID
        else { return false }
        let previous = records[index]
        var converted = previous
        converted.kind = .direct
        converted.agentIDs = [remainingAgentID]
        converted.items = privateHistory
        converted.botModeRoomID = nil
        converted.botModePrivateHistory = []
        converted.hasAcceptedMessage = privateHistory.contains(where: { $0.role == .human })
        converted.updatedAt = .now
        records[index] = converted
        guard repositoryAllowsWrites else {
            records[index] = previous
            persistenceDidFail()
            return false
        }
        do {
            try repository?.save(records)
            persistenceDidSucceed()
            return true
        } catch {
            records[index] = previous
            persistenceDidFail()
            return false
        }
    }

    func reassignDirectAgent(sessionID: String, to agentID: String) -> DirectChatAgentSelectionResult {
        guard client.allowsLocalAgentReassignment else { return .unavailable }
        guard contentSession(id: sessionID) != nil else { return .unavailable }
        guard !agentID.isEmpty,
              let index = records.firstIndex(where: { $0.id == sessionID }),
              records[index].kind == .direct,
              records[index].agentIDs.count == 1
        else { return .unavailable }
        let previous = records[index]
        guard previous.agentIDs != [agentID] else { return .unchanged }
        guard !previous.hasAcceptedMessage, previous.items.isEmpty,
              previous.referenceState?.submission == nil else { return .blockedByHistory }

        var reassigned = previous
        reassigned.agentIDs = [agentID]
        reassigned.remoteStoredID = nil
        reassigned.remoteSource = nil
        reassigned.updatedAt = .now
        records[index] = reassigned
        guard repositoryAllowsWrites else {
            records[index] = previous
            persistenceDidFail()
            return .unavailable
        }
        do {
            try repository?.save(records)
            persistenceDidSucceed()
            return .reassigned
        } catch {
            records[index] = previous
            persistenceDidFail()
            return .unavailable
        }
    }

    private func update(_ sessionID: String, change: (inout SessionRecord) -> Void) {
        mutate(sessionID, change: change)
        guard let index = records.firstIndex(where: { $0.id == sessionID }) else { return }
        records[index].updatedAt = .now
    }

    private func mutate(
        _ sessionID: String,
        requiresContent: Bool = true,
        change: (inout SessionRecord) -> Void
    ) {
        guard !requiresContent || contentSession(id: sessionID) != nil else { return }
        guard let index = records.firstIndex(where: { $0.id == sessionID }) else { return }
        change(&records[index])
    }

    func upsert(_ record: SessionRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records = SessionCatalogReconciliation.retained(records)
    }

    /// Live activity from every session shares one bounded checkpoint. This is
    /// a throttle, not a trailing debounce: continuous streams still get saved.
    private func rebuildSubagentParentIndex() {
        subagentParentBySessionID.removeAll()
        for record in records {
            guard let parentSessionID = record.parentSessionID else { continue }
            subagentParentBySessionID[record.id] = parentSessionID
            if let storedID = record.remoteStoredID {
                subagentParentBySessionID[storedID] = parentSessionID
            }
        }
    }

    private func applyKnownSubagentParents() {
        for index in records.indices {
            let record = records[index]
            let parentSessionID = subagentParentBySessionID[record.id]
                ?? record.remoteStoredID.flatMap { subagentParentBySessionID[$0] }
            guard let parentSessionID else { continue }
            records[index].parentSessionID = parentSessionID
        }
    }

    func protectAcceptedStop(_ incoming: SessionRecord) -> SessionRecord {
        guard let acceptedAt = acceptedStopAtByID[incoming.id] else { return incoming }
        guard incoming.isActive, incoming.updatedAt <= acceptedAt else {
            acceptedStopAtByID[incoming.id] = nil
            return incoming
        }
        var protected = incoming
        protected.isActive = false
        return protected
    }

    private static func forkTitle(_ title: String) -> String {
        let suffix = " · Fork"
        return String(title.prefix(max(1, 240 - suffix.count))) + suffix
    }
}

enum DirectChatAgentSelectionResult: Equatable {
    case reassigned
    case unchanged
    case blockedByHistory
    case unavailable
}
