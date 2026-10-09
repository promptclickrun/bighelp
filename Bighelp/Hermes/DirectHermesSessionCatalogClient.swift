import Foundation

enum DirectHermesActiveSessionStatus: String, CaseIterable, Sendable {
    case idle, starting, waiting, working, streaming, resuming

    var hasActiveWork: Bool { self != .idle }
}

struct DirectHermesActiveSessionItem: Equatable, Sendable {
    let runtimeID: String
    let sessionKey: String
    let title: String
    let preview: String
    let startedAt: Date
    let lastActive: Date
    let messageCount: Int
    let model: String
    let status: DirectHermesActiveSessionStatus
    let current: Bool
}

struct DirectHermesActiveSessionMapping: Equatable, Sendable {
    let owner: WorkspaceOwner
    let visibleID: String
    let profileID: String
    let runtimeID: String
    let sessionKey: String
}

enum DirectHermesActiveSessionsDecoder {
    private static let resultFields: Set<String> = ["sessions"]
    private static let itemFields: Set<String> = [
        "id", "session_key", "title", "preview", "started_at", "last_active",
        "message_count", "model", "status", "current",
    ]

    static func decode(
        _ response: [String: BighelpJSONValue]
    ) throws -> [DirectHermesActiveSessionItem] {
        guard Set(response.keys) == resultFields,
              let values = response["sessions"]?.array,
              values.count <= DirectHermesSessionValidation.maximumSessions else {
            throw WorkspaceClientError.invalidResponse
        }
        var runtimeIDs = Set<String>()
        return try values.map { value in
            guard let row = value.object, Set(row.keys) == itemFields else {
                throw WorkspaceClientError.invalidResponse
            }
            let runtimeID = try DirectHermesSessionValidation.string(row["id"])
            let sessionKey = try DirectHermesSessionValidation.string(row["session_key"])
            guard runtimeIDs.insert(DirectHermesSessionIdentity.key(runtimeID)).inserted,
                  let titleValue = row["title"]?.string,
                  let previewValue = row["preview"]?.string,
                  let modelValue = row["model"]?.string,
                  let startedAt = try DirectHermesSessionValidation.date(row["started_at"]),
                  let lastActive = try DirectHermesSessionValidation.date(row["last_active"]),
                  let messageCount = row["message_count"]?.integer,
                  (0...DirectHermesSessionValidation.maximumHistoryRows).contains(messageCount),
                  let statusValue = row["status"]?.string,
                  let status = DirectHermesActiveSessionStatus(rawValue: statusValue),
                  let current = row["current"]?.boolean else {
                throw WorkspaceClientError.invalidResponse
            }
            return DirectHermesActiveSessionItem(
                runtimeID: runtimeID,
                sessionKey: sessionKey,
                title: try DirectHermesSessionValidation.text(titleValue, maximum: 4_096),
                preview: HermesUserMessageDisplay.preview(
                    try DirectHermesSessionValidation.text(previewValue, maximum: 64 * 1_024)
                ),
                startedAt: startedAt,
                lastActive: lastActive,
                messageCount: messageCount,
                model: try DirectHermesSessionValidation.text(modelValue, maximum: 512),
                status: status,
                current: current
            )
        }
    }
}

@MainActor
final class DirectHermesSessionCatalogClient: SessionCatalogClient {
    typealias SelectedFolderPath = @MainActor (String) async throws -> String?
    typealias CreationStateChange = @MainActor (DirectHermesSessionCreationState) throws -> Void

    private struct Registry {
        let id: String
        let resolvedID: String?
    }
    private struct Profile {
        let id: String
        let displayName: String
        let canonical: Registry?
    }
    private struct ProjectAssociation {
        let id: String
        let name: String
    }
    /// Evidence is distinct from a REST row, restored draft, or live status.
    /// It is never persisted across workspace/connection ownership boundaries.
    private struct RuntimeOwnership {
        let revision = UUID()
        let runtimeID: String
        let sessionKey: String
        let profileID: String
        let epoch: String?
        let isReceipt: Bool
    }
    private struct OwnedActiveSession {
        let item: DirectHermesActiveSessionItem
        let ownership: RuntimeOwnership
    }
    private struct Binding {
        var coordinate: WorkspaceSessionCoordinate
        let anchorID: String
        var record: SessionRecord
        var durability: DirectHermesSessionDurability
        var cwd: String?
        var canonicalRegistryID: String?
        var catalog: DirectHermesCatalogCoordinate? = nil
        var runtimeSessionKey: String? = nil
        var isLiveDiscoveryOnly = false
        var ownership: RuntimeOwnership? = nil
    }
    private struct HistoryWindow {
        let storedID: String
        let rows: [DirectHermesHistoryRow]
        let nextOffset: Int?
    }
    private struct HistoryPage {
        let storedID: String
        let rows: [DirectHermesHistoryRow]
        let returned: Int
        let limit: Int
    }

    private let workspace: any WorkspaceOperationPerforming
    private let owner: WorkspaceOwner
    private let currentOwner: @MainActor () -> WorkspaceOwner?
    private let selectedFolderPath: SelectedFolderPath?
    private let onCreationStateChange: CreationStateChange?
    private let now: @MainActor () -> Date
    private var retired = false
    private var profiles: [String: Profile] = [:]
    private var bindings: [String: Binding] = [:]
    private var canonicalIDs: [String: Registry] = [:]
    private var creations: [String: DirectHermesSessionCreationState] = [:]
    private var creatingProfiles: Set<String> = []
    /// Agents whose "Bot Chat" title a hidden chat holds; asked once per connection.
    private var canonicalTitleTaken: Set<String> = []
    private var hydrationTokens: [String: UUID] = [:]
    private var historyWindows: [String: HistoryWindow] = [:]
    private var historyCacheOrder: [String] = []
    private var historyCacheBytes: [String: Int] = [:]
    private var listToken: UUID?
    private var replayEpoch: String?
    private var ownershipRevision = UUID()
    /// Chats archived here. Hermes keeps a chat you had open running for a
    /// while after, and live discovery must not bring it back. Hermes listing
    /// it again (unarchived elsewhere) clears it.
    private var archivedKeys: Set<String> = []
    private struct StaleOwnershipDiscovery: Error {}
    private(set) var historyProjections: [String: DirectHermesHistoryProjection] = [:]

    init(
        workspace: any WorkspaceOperationPerforming,
        owner: WorkspaceOwner,
        currentOwner: @escaping @MainActor () -> WorkspaceOwner?,
        selectedFolderPath: SelectedFolderPath? = nil,
        onCreationStateChange: CreationStateChange? = nil,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.workspace = workspace
        self.owner = owner
        self.currentOwner = currentOwner
        self.selectedFolderPath = selectedFolderPath
        self.onCreationStateChange = onCreationStateChange
        self.now = now
    }

    var canCreate: Bool { onCreationStateChange != nil && !retired }
    var canDeleteConversation: Bool { false }
    var allowsLocalAgentReassignment: Bool { false }

    func coordinate(for visibleID: String) throws -> WorkspaceSessionCoordinate {
        try requireOwner()
        guard let binding = bindings[visibleID] else { throw WorkspaceClientError.invalidRequest }
        return hasOwnership(binding) ? binding.coordinate : removingLiveBinding(binding).coordinate
    }

    func activeSessionMappings() throws -> [DirectHermesActiveSessionMapping] {
        try requireOwner()
        var result: [DirectHermesActiveSessionMapping] = []
        var runtimeIDs = Set<String>()
        for (visibleID, binding) in bindings {
            guard hasOwnership(binding),
                  let runtimeID = binding.coordinate.runtimeSessionID,
                  let sessionKey = binding.runtimeSessionKey else { continue }
            guard runtimeIDs.insert(DirectHermesSessionIdentity.key(runtimeID)).inserted else {
                throw WorkspaceClientError.invalidResponse
            }
            result.append(.init(
                owner: owner,
                visibleID: visibleID,
                profileID: binding.coordinate.profileID,
                runtimeID: runtimeID,
                sessionKey: sessionKey
            ))
        }
        return result
    }

    func reconcileRuntimeLiveness(runtimeID: String, isActive: Bool) throws {
        try requireOwner()
        try DirectHermesSessionValidation.coordinate(runtimeID)
        let matches = bindings.keys.filter { id in
            bindings[id]?.coordinate.runtimeSessionID.map {
                DirectHermesSessionValidation.same($0, runtimeID)
            } == true
        }
        guard matches.count <= 1 else { throw WorkspaceClientError.invalidResponse }
        guard let id = matches.first, var binding = bindings[id] else { return }
        binding.record.isActive = isActive
        setBinding(binding, for: id)
    }

    func pendingCreation(profileID: String) throws -> DirectHermesSessionCreationState? {
        try requireOwner()
        try DirectHermesSessionValidation.coordinate(profileID, maximum: 128)
        return creations[DirectHermesSessionIdentity.key(profileID)]
    }

    func restoreCreationState(_ state: DirectHermesSessionCreationState) throws {
        try requireOwner()
        let state = try state.validated(for: owner)
        let key = DirectHermesSessionIdentity.key(state.profileID)
        guard !creatingProfiles.contains(key), creations[key] == nil,
              creations.count < 128 else { throw WorkspaceClientError.conflict }
        creations[key] = state
        if let stored = state.canonicalRegistryID {
            canonicalIDs[key] = Registry(id: stored, resolvedID: nil)
        }
    }

    func resetForAccountBoundary() {
        retired = true
        profiles = [:]
        ownershipRevision = UUID()
        setBindings([:])
        canonicalIDs = [:]
        creations = [:]
        creatingProfiles = []
        hydrationTokens = [:]
        historyWindows = [:]
        historyCacheOrder = []
        historyCacheBytes = [:]
        historyProjections = [:]
        listToken = nil
        replayEpoch = nil
        archivedKeys = []
    }

    func list() async throws -> [SessionRecord] {
        try await list(options: .init())
    }

    func list(options: DirectHermesSessionListOptions) async throws -> [SessionRecord] {
        try validate(options)
        let token = UUID()
        listToken = token
        let ownershipTicket = ownershipRevision
        let startingRevisions = bindings.compactMapValues { $0.ownership?.revision }
        let loaded = try await loadProfiles()
        let discoversActiveSessions = options == DirectHermesSessionListOptions()
        var records: [SessionRecord] = []
        var pending: [String: Binding] = [:]
        var claimedRetainedVisibleIDs = Set<String>()
        // A profile can have many sessions sharing one cwd. Resolve each
        // distinct path once for this authoritative catalog load; the result
        // is never inferred from the currently selected project.
        var projectAssociationsByCWD: [String: ProjectAssociation] = [:]
        var projectlessCWDs: Set<String> = []
        for profile in loaded {
            var offset = 0
            var seen: Set<String> = []
            while true {
                var payload: [String: BighelpJSONValue] = [
                    "profile": .string(profile.id), "limit": .integer(100), "offset": .integer(offset),
                    "archived": .string(options.archived.rawValue), "order": .string(options.order.rawValue),
                ]
                if !options.sources.isEmpty { payload["sources"] = .string(options.sources.joined(separator: ",")) }
                if !options.excludedSources.isEmpty { payload["exclude_sources"] = .string(options.excludedSources.joined(separator: ",")) }
                if let path = options.cwdPrefix { payload["cwd_prefix"] = .string(path) }
                let response = try await perform(.sessionsList, payload)
                guard listToken == token else { throw CancellationError() }
                guard let rows = response["sessions"]?.array,
                      rows.count <= DirectHermesSessionValidation.maximumSessions,
                      response["offset"]?.integer == offset, response["limit"]?.integer == 100 else {
                    throw WorkspaceClientError.invalidResponse
                }
                if let total = response["total"]?.integer {
                    guard total >= 0, total <= DirectHermesSessionValidation.maximumSessions else {
                        throw WorkspaceClientError.invalidResponse
                    }
                }
                for row in rows {
                    guard let object = row.object else { throw WorkspaceClientError.invalidResponse }
                    let stored = try DirectHermesSessionValidation.string(object["id"])
                    if !seen.insert(DirectHermesSessionIdentity.key(stored)).inserted {
                        // REST pages include pinned sessions as a back-fill on
                        // every page (Hermes 0.21.x sends them with `pinned: true`
                        // and no `has_more`). They are safe to skip after the first
                        // occurrence; any other repeat still means history changed.
                        guard response["has_more"]?.boolean != nil
                                || (try? DirectHermesSessionValidation.flag(object["pinned"])) == true else {
                            throw DirectHermesSessionError.historyChanged
                        }
                        continue
                    }
                    var binding = try catalogBinding(object, profile: profile)
                    if options.archived == .exclude { archivedKeys.subtract(identityKeys(binding)) }
                    binding = try coalescingSavedBinding(
                        binding,
                        claimedRetainedVisibleIDs: &claimedRetainedVisibleIDs
                    )
                    if let cwd = binding.cwd, !cwd.isEmpty {
                        let associationKey = projectAssociationKey(profile: profile, cwd: cwd)
                        if let association = projectAssociationsByCWD[associationKey] {
                            binding.record.workspaceID = association.id
                            binding.record.workspaceName = association.name
                        } else if projectlessCWDs.contains(associationKey) {
                            // A validated `project: null` response is an
                            // authoritative unassigned session.
                        } else if let association = try await projectAssociation(
                            for: cwd, profile: profile
                        ) {
                            projectAssociationsByCWD[associationKey] = association
                            binding.record.workspaceID = association.id
                            binding.record.workspaceName = association.name
                        } else {
                            projectlessCWDs.insert(associationKey)
                        }
                    }
                    guard pending[binding.record.id] == nil else { throw WorkspaceClientError.invalidResponse }
                    pending[binding.record.id] = binding
                    records.append(binding.record)
                    guard records.count <= DirectHermesSessionValidation.maximumSessions else {
                        throw WorkspaceClientError.capacityExceeded
                    }
                }
                let hasMore = Self.pageHasMore(response, offset: offset, rows: rows.count)
                if rows.isEmpty || !hasMore { break }
                offset += response["limit"]?.integer ?? rows.count
                guard offset <= DirectHermesSessionValidation.maximumSessions else { throw WorkspaceClientError.capacityExceeded }
            }
        }
        if !discoversActiveSessions {
            try requireOwner()
            guard listToken == token else { throw CancellationError() }
            var committed = pending.mapValues(preservingLiveBinding)
            for (id, current) in bindings where committed[id] == nil
                && (current.coordinate.runtimeSessionID != nil || current.durability == .draft) {
                committed[id] = hasOwnership(current) ? current : removingLiveBinding(current)
            }
            guard committed.count <= DirectHermesSessionValidation.maximumSessions else {
                throw WorkspaceClientError.capacityExceeded
            }
            setBindings(committed)
            return records
        }
        // active_list is process-global. REST membership never attributes its
        // runtime handles; enrich only after independent, epoch-fenced proof.
        var discovered: [OwnedActiveSession]?
        do {
            discovered = try await discoverActiveSessions(profiles: loaded, token: token,
                                                          ownershipTicket: ownershipTicket)
        } catch is CancellationError {
            throw CancellationError()
        } catch WorkspaceClientError.ownerChanged {
            throw WorkspaceClientError.ownerChanged
        } catch {
            discovered = nil
        }
        try requireOwner()
        guard listToken == token else { throw CancellationError() }
        if ownershipRevision != ownershipTicket { discovered = nil }
        var committed: [String: Binding] = [:]
        let savedOrder = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.id, $0.offset) })
        records = []
        for profile in loaded {
            var rows = pending.values.filter {
                DirectHermesSessionValidation.same($0.coordinate.profileID, profile.id)
            }
            // Preserve REST order (dictionary iteration must not reorder rows).
            rows.sort { (savedOrder[$0.record.id] ?? Int.max) < (savedOrder[$1.record.id] ?? Int.max) }
            if let discovered {
                rows = rows.map(removingLiveBinding)
                let savedRows = rows
                do {
                    try overlayActiveSessions(discovered.filter {
                        DirectHermesSessionValidation.same($0.ownership.profileID, profile.id)
                    }, profile: profile, bindings: &rows)
                } catch {
                    rows = savedRows
                }
            } else {
                rows = rows.map(preservingLiveBinding)
            }
            var represented = Set(rows.map { $0.record.id })
            for current in bindings.values where
                DirectHermesSessionValidation.same(current.coordinate.profileID, profile.id)
                && !represented.contains(current.record.id) {
                // Keep local draft intent even when its runtime is now gone.
                // A failed optional discovery may retain only proven live facts.
                let ownDraft = current.durability == .draft && !current.isLiveDiscoveryOnly
                let newerReceipt = current.ownership.map {
                    $0.isReceipt && $0.revision != startingRevisions[current.record.id]
                } == true && hasOwnership(current)
                guard ownDraft || newerReceipt || (discovered == nil && hasOwnership(current)) else { continue }
                rows.append((newerReceipt || discovered == nil) && hasOwnership(current) ? current : removingLiveBinding(current))
                represented.insert(current.record.id)
            }
            for var row in rows {
                if let current = bindings[row.record.id], let proof = current.ownership,
                   proof.isReceipt, proof.revision != startingRevisions[row.record.id], hasOwnership(current) {
                    // A create/resume completed while catalog reads suspended.
                    row = current
                }
                if row.coordinate.runtimeSessionID != nil && !hasOwnership(row) { row = removingLiveBinding(row) }
                committed[row.record.id] = row
                records.append(row.record)
            }
        }
        // Retain remote row identity for an already mounted conversation, but
        // do not advertise an absent/unproven remote draft in the sidebar.
        for (id, current) in bindings where committed[id] == nil && current.isLiveDiscoveryOnly {
            committed[id] = removingLiveBinding(current)
        }
        guard committed.count <= DirectHermesSessionValidation.maximumSessions else {
            throw WorkspaceClientError.capacityExceeded
        }
        setBindings(committed)
        return records
    }

    func search(_ query: String, profileID: String, limit: Int = 20) async throws -> [DirectHermesSessionSearchResult] {
        _ = try DirectHermesSessionValidation.text(query, maximum: 4096, allowsEmpty: false)
        guard (1...100).contains(limit) else { throw WorkspaceClientError.invalidRequest }
        let profile = try await requireProfile(profileID)
        let response = try await perform(.sessionSearch, [
            "profile": .string(profile.id), "q": .string(query), "limit": .integer(limit),
            "exclude_sources": .string("tool,kanban,bot_room"),
        ])
        guard let rows = response["results"]?.array, rows.count <= limit else { throw WorkspaceClientError.invalidResponse }
        var result: [DirectHermesSessionSearchResult] = []
        var seen: Set<String> = []
        var pending: [String: Binding] = [:]
        var projectAssociationsByCWD: [String: ProjectAssociation] = [:]
        var projectlessCWDs: Set<String> = []
        for row in rows {
            guard var object = row.object else { throw WorkspaceClientError.invalidResponse }
            let stored = try DirectHermesSessionValidation.string(object["id"] ?? object["session_id"])
            if let returned = object["profile"]?.string,
               !DirectHermesSessionValidation.same(returned, profile.id) { throw WorkspaceClientError.invalidResponse }
            object["id"] = .string(stored)
            object["profile"] = .string(profile.id)
            var binding = try catalogBinding(object, profile: profile)
            if let cwd = binding.cwd, !cwd.isEmpty {
                let associationKey = projectAssociationKey(profile: profile, cwd: cwd)
                if let association = projectAssociationsByCWD[associationKey] {
                    binding.record.workspaceID = association.id
                    binding.record.workspaceName = association.name
                } else if projectlessCWDs.contains(associationKey) {
                    // Keep a validated project:null association unassigned.
                } else if let association = try await projectAssociation(for: cwd, profile: profile) {
                    projectAssociationsByCWD[associationKey] = association
                    binding.record.workspaceID = association.id
                    binding.record.workspaceName = association.name
                } else {
                    projectlessCWDs.insert(associationKey)
                }
            }
            guard seen.insert(binding.record.id).inserted else { throw WorkspaceClientError.invalidResponse }
            let snippet = try DirectHermesSessionValidation.optionalText(object["snippet"], maximum: 64 * 1024) ?? ""
            result.append(.init(record: binding.record, snippet: snippet))
            pending[binding.record.id] = preservingLiveBinding(binding)
        }
        guard Set(bindings.keys).union(pending.keys).count <= DirectHermesSessionValidation.maximumSessions else {
            throw WorkspaceClientError.capacityExceeded
        }
        for (id, binding) in pending { setBinding(preservingLiveBinding(binding), for: id) }
        return result
    }

    func resolveCanonicalChat(profileID: String, previouslyKnownID: String? = nil) async throws -> DirectHermesCanonicalChatResolution {
        let profile = try await requireProfile(profileID)
        let key = DirectHermesSessionIdentity.key(profileID)
        if let previouslyKnownID {
            try DirectHermesSessionValidation.coordinate(previouslyKnownID)
            if canonicalIDs[key] == nil { canonicalIDs[key] = .init(id: previouslyKnownID, resolvedID: nil) }
        }
        if let canonical = profile.canonical {
            canonicalIDs[key] = canonical
            return .resolved(try await openRegistry(canonical, profile: profile))
        }
        if let canonical = try await registry(profileID: profile.id) {
            canonicalIDs[key] = canonical
            return .resolved(try await openRegistry(canonical, profile: profile))
        }
        if let resolved = try await resumeCanonicalByTitle(profile: profile) { return .resolved(resolved) }
        if let known = canonicalIDs[key] {
            throw DirectHermesSessionError.canonicalMissing(profileID: profile.id, knownID: known.id)
        }
        return .notCreated(profileID: profile.id)
    }

    /// Read coverage only from this owner's matching retained history window.
    /// Ambiguous stored variants keep their source rows but still cover a live ID.
    func canonicalToolCallIDs(for record: SessionRecord) -> Set<String> {
        do { try requireOwner() } catch { return [] }
        guard let window = historyWindows[record.id],
              let projection = historyProjections[record.id],
              record.agentIDs == bindings[record.id]?.record.agentIDs,
              record.remoteStoredID.map({ DirectHermesSessionValidation.same($0, window.storedID) }) == true else { return [] }
        return Set(projection.tools.compactMap(\.toolCallID))
    }

    /// Reuse an already validated runtime; recovery supplies fresh live state.
    func attachedSession(_ record: SessionRecord) throws -> DirectHermesResolvedSession? {
        let candidate = try candidate(for: record)
        guard hasOwnership(candidate) else { return nil }
        return descriptor(candidate)
    }

    /// Called only by explicit retained-session reattachment, never discovery.
    /// Revoke the exact stale handle without discarding its durable coordinate.
    func invalidateRuntimeBinding(_ record: SessionRecord, runtimeID: String) throws {
        _ = try candidate(for: record)
        guard let current = bindings[record.id], let runtime = current.coordinate.runtimeSessionID else { return }
        guard DirectHermesSessionValidation.same(runtime, runtimeID) else {
            throw WorkspaceClientError.ownerChanged
        }
        setBinding(removingLiveBinding(current), for: record.id)
    }

    func resolveSession(_ record: SessionRecord) async throws -> DirectHermesResolvedSession {
        let candidate = try candidate(for: record)
        let profile = try await requireProfile(candidate.coordinate.profileID)
        let receipt: (response: [String: BighelpJSONValue], epoch: String?)
        let live = hasOwnership(candidate) ? candidate.coordinate.runtimeSessionID : nil
        if let live {
            receipt = try await performReceipt(.sessionActivate, [
                "profile": .string(profile.id), "session_id": .string(live), "omit_messages": .boolean(true),
            ], expectedOwnership: candidate.ownership)
        } else {
            receipt = try await resume(profileID: profile.id, storedID: candidate.anchorID)
        }
        let binding: Binding
        do {
            binding = try attachedBinding(receipt.response, original: candidate, profile: profile,
                                          expectedRuntime: live, receiptEpoch: receipt.epoch)
        } catch {
            if live != nil, let current = bindings[record.id],
               current.ownership?.revision == candidate.ownership?.revision {
                setBinding(removingLiveBinding(current), for: record.id)
            }
            throw error
        }
        setBinding(binding, for: record.id)
        return descriptor(binding)
    }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        guard kind == .direct, agentIDs.count == 1, let profileID = agentIDs.first else {
            throw WorkspaceClientError.invalidRequest
        }
        return try await createOrdinarySession(profileID: profileID).record
    }

    func createOrdinarySession(profileID: String) async throws -> DirectHermesResolvedSession {
        try requireOwner()
        try DirectHermesSessionValidation.coordinate(profileID, maximum: 128)
        // The agent picker/catalog already loaded this owner-scoped profile.
        // Canonical registry resolution keeps its fresh discovery path; an
        // ordinary new chat needs only the chosen profile and Hermes create.
        let profile: Profile
        if let cached = profiles[DirectHermesSessionIdentity.key(profileID)] { profile = cached }
        else { profile = try await requireProfile(profileID) }
        let key = DirectHermesSessionIdentity.key(profileID)
        try beginCreation(key: key, profileID: profileID)
        defer { creatingProfiles.remove(key) }
        // Only the agent's first canonical chat must be reconciled before another
        // create: a duplicate there would compete for its registry. An unfinished
        // ordinary new chat can at most leave one unused empty chat on the host,
        // so a new attempt replaces it. (Blocking here used to lock an agent out
        // of new chats for good, across restarts, after one timed-out create.)
        if var pending = creations[key], pending.purpose == .firstCanonical,
           pending.phase != .complete, pending.phase != .canonicalResolved {
            // A Bot Chat whose title was asked for is settled by the registry: it
            // has the chat, or the title never landed. Either way a new chat is safe.
            // (Left pending, a refused title locked the agent out of new chats.)
            guard pending.phase == .titleRequested || pending.phase == .awaitingRegistry else {
                throw DirectHermesSessionError.creationUnconfirmed(profileID: profileID)
            }
            if let found = try await registry(profileID: profileID) {
                canonicalIDs[key] = found
                pending.phase = .canonicalResolved
                pending.canonicalRegistryID = found.id
            } else {
                pending.phase = .complete
            }
            try retain(pending)
        }
        var state = try await newCreation(profile: profile, purpose: .ordinary)
        let binding: Binding
        do {
            binding = try await dispatchCreate(&state, profile: profile)
        } catch DirectHermesSessionError.workspaceNotConfirmed where state.requestedCWD != nil {
            // Hermes starts a chat only in a folder that exists, else somewhere
            // else. A project whose folder is gone must not lock its agent out of
            // new chats: start it without the project, in the agent's own folder.
            state = try await newCreation(profile: profile, purpose: .ordinary, inProjectFolder: false)
            binding = try await dispatchCreate(&state, profile: profile)
        }
        state.phase = .complete
        try retain(state)
        setBinding(binding, for: binding.record.id)
        return descriptor(binding)
    }

    /// Call only for an explicitly authorized first chat, such as after a
    /// confirmed new-profile creation. Registry absence alone is not consent.
    func createFirstCanonicalChat(profileID: String) async throws -> DirectHermesResolvedSession {
        let profile = try await requireProfile(profileID)
        let key = DirectHermesSessionIdentity.key(profileID)
        guard !canonicalTitleTaken.contains(key) else { throw WorkspaceClientError.rejected(code: "4022") }
        try beginCreation(key: key, profileID: profileID)
        defer { creatingProfiles.remove(key) }
        if let found = try await registry(profileID: profileID) {
            canonicalIDs[key] = found
            let resolved = try await openRegistry(found, profile: profile)
            if var pending = creations[key], pending.purpose == .firstCanonical {
                pending.phase = .canonicalResolved
                pending.canonicalRegistryID = found.id
                try retain(pending)
            }
            return resolved
        }
        if let known = canonicalIDs[key] {
            throw DirectHermesSessionError.canonicalMissing(profileID: profileID, knownID: known.id)
        }
        var state: DirectHermesSessionCreationState
        var binding: Binding
        if let pending = creations[key], !(pending.purpose == .ordinary && pending.phase == .complete) {
            guard pending.purpose == .firstCanonical, pending.phase == .created,
                  let stored = pending.storedSessionID else {
                throw DirectHermesSessionError.creationUnconfirmed(profileID: profileID)
            }
            state = pending
            let record = try draftRecord(profile: profile, storedID: stored, title: "Bot Chat")
            let candidate = try Binding(
                coordinate: WorkspaceSessionCoordinate(owner: owner, profileID: profileID, sessionID: record.id,
                                                       storedSessionID: stored, runtimeSessionID: nil),
                anchorID: stored, record: record, durability: .draft, cwd: pending.requestedCWD,
                canonicalRegistryID: nil
            )
            let receipt = try await resume(profileID: profileID, storedID: stored)
            binding = try attachedBinding(receipt.response, original: candidate, profile: profile, receiptEpoch: receipt.epoch)
            if let requested = state.requestedCWD,
               binding.cwd.map({ DirectHermesSessionValidation.same($0, requested) }) != true {
                throw DirectHermesSessionError.workspaceNotConfirmed
            }
        } else {
            state = try await newCreation(profile: profile, purpose: .firstCanonical)
            binding = try await dispatchCreate(&state, profile: profile)
        }
        guard let runtime = binding.coordinate.runtimeSessionID else { throw WorkspaceClientError.invalidResponse }
        state.runtimeSessionID = runtime
        state.phase = .titleRequested
        try persistBeforeDispatch(state)
        do {
            let title = try await perform(.sessionTitle, ["session_id": .string(runtime), "title": .string("Bot Chat")])
            guard title["pending"]?.boolean == false, title["title"]?.string == "Bot Chat" else {
                throw DirectHermesSessionError.creationUnconfirmed(profileID: profileID)
            }
        } catch let error as WorkspaceClientError {
            if case .rejected(code: "4022") = error {
                if let winner = try await registry(profileID: profileID) {
                    canonicalIDs[key] = winner
                    let resolved = try await openRegistry(winner, profile: profile)
                    state.phase = .canonicalResolved
                    state.canonicalRegistryID = winner.id
                    try retain(state)
                    return resolved
                }
                if let holder = try await resumeCanonicalByTitle(profile: profile) {
                    state.phase = .canonicalResolved
                    state.canonicalRegistryID = canonicalIDs[key]?.id
                    try retain(state)
                    if let stored = binding.coordinate.storedSessionID {
                        _ = try? await perform(.sessionDelete, ["session_id": .string(stored), "profile": .string(profileID)])
                    }
                    return holder
                }
                // A chat Hermes doesn't list (one from its API server) holds the
                // title, so this agent has no Bot Chat here. Settle the attempt: it
                // must not block new chats or make another empty chat every tap.
                canonicalTitleTaken.insert(key)
                state.phase = .complete
                try retain(state)
                // The empty chat made for it goes too, so none piles up on the host.
                if let stored = binding.coordinate.storedSessionID {
                    _ = try? await perform(.sessionDelete, ["session_id": .string(stored), "profile": .string(profileID)])
                }
            }
            throw error
        }
        state.phase = .awaitingRegistry
        try retain(state)
        guard let registered = try await registry(profileID: profileID) else {
            throw DirectHermesSessionError.creationUnconfirmed(profileID: profileID)
        }
        canonicalIDs[key] = registered
        let resolved = try await openRegistry(registered, profile: profile)
        state.phase = .canonicalResolved
        state.canonicalRegistryID = registered.id
        try retain(state)
        return resolved
    }

    func hydrate(_ record: SessionRecord) async throws -> SessionRecord {
        try await hydrate(record, onProgress: { _ in })
    }

    func hydrate(_ record: SessionRecord, onProgress: @escaping SessionHydrationProgress) async throws -> SessionRecord {
        var binding = try candidate(for: record)
        let startingStoredID = binding.coordinate.storedSessionID
        let token = UUID()
        hydrationTokens[record.id] = token
        var rows: [DirectHermesHistoryRow] = []
        var seen: Set<Int> = []
        var bytes = 0
        var first = true
        while true {
            let offset = first ? 0 : rows.count - 1
            let limit = first ? 200 : 201
            let page = try await historyPage(binding: binding, offset: offset, limit: limit, order: "oldest")
            try requireHydration(record.id, token: token, startingStoredID: startingStoredID, receivedStoredID: page.storedID)
            if first {
                binding = try rebinding(binding, storedID: page.storedID)
            } else {
                guard DirectHermesSessionValidation.same(page.storedID, binding.coordinate.storedSessionID ?? ""),
                      let anchor = rows.last, let repeated = page.rows.first,
                      try sameRow(anchor, repeated) else { throw DirectHermesSessionError.historyChanged }
            }
            let newRows = first ? page.rows : Array(page.rows.dropFirst())
            for row in newRows {
                guard seen.insert(row.id).inserted else { throw DirectHermesSessionError.historyChanged }
                bytes += try JSONEncoder().encode(BighelpJSONValue.object(row.raw)).count
                guard rows.count < DirectHermesSessionValidation.maximumHistoryRows,
                      bytes <= DirectHermesSessionValidation.maximumHistoryBytes else {
                    throw WorkspaceClientError.capacityExceeded
                }
                rows.append(row)
            }
            if page.returned < page.limit { break }
            guard !newRows.isEmpty else { throw DirectHermesSessionError.historyChanged }
            first = false
        }
        let projected = try project(rows: rows, source: record, binding: binding)
        let hydrated = projected.record
        try requireHydration(record.id, token: token, startingStoredID: startingStoredID,
                             receivedStoredID: binding.coordinate.storedSessionID ?? binding.anchorID)
        try onProgress(hydrated)
        try requireHydration(record.id, token: token, startingStoredID: startingStoredID,
                             receivedStoredID: binding.coordinate.storedSessionID ?? binding.anchorID)
        setBinding(preservingLiveBinding(bindingWithRecord(binding, record: hydrated)), for: record.id)
        retainHistory(id: record.id, projection: projected.projection,
                      window: .init(storedID: binding.coordinate.storedSessionID ?? binding.anchorID, rows: rows, nextOffset: nil),
                      bytes: bytes)
        return hydrated
    }

    func hydratePage(_ record: SessionRecord, offset: Int?, turnLimit: Int) async throws -> SessionHydrationPage {
        guard (1...10).contains(turnLimit), offset == nil || offset! > 0 else {
            throw WorkspaceClientError.invalidRequest
        }
        var binding = try candidate(for: record)
        let startingStoredID = binding.coordinate.storedSessionID
        let token = UUID()
        hydrationTokens[record.id] = token
        let rowLimit = min(400, turnLimit * 40)
        let page: HistoryPage
        let combined: [DirectHermesHistoryRow]
        let nextOffset: Int?
        if let offset {
            guard let window = historyWindows[record.id], window.nextOffset == offset,
                  let oldest = window.rows.first else { throw DirectHermesSessionError.historyChanged }
            binding = try rebinding(binding, storedID: window.storedID)
            page = try await historyPage(binding: binding, offset: offset - 1, limit: rowLimit + 1, order: "latest")
            try requireHydration(record.id, token: token, startingStoredID: startingStoredID, receivedStoredID: page.storedID)
            guard DirectHermesSessionValidation.same(page.storedID, window.storedID),
                  let anchor = page.rows.last, try sameRow(oldest, anchor) else {
                throw DirectHermesSessionError.historyChanged
            }
            let older = Array(page.rows.dropLast())
            guard Set(older.map(\.id)).isDisjoint(with: Set(window.rows.map(\.id))) else {
                throw DirectHermesSessionError.historyChanged
            }
            combined = older + window.rows
            nextOffset = page.returned == page.limit ? combined.count : nil
        } else {
            page = try await historyPage(binding: binding, offset: 0, limit: rowLimit, order: "latest")
            try requireHydration(record.id, token: token, startingStoredID: startingStoredID, receivedStoredID: page.storedID)
            binding = try rebinding(binding, storedID: page.storedID)
            combined = page.rows
            nextOffset = page.returned == page.limit ? combined.count : nil
        }
        let bytes = try combined.reduce(0) { sum, row in
            sum + (try JSONEncoder().encode(BighelpJSONValue.object(row.raw)).count)
        }
        guard combined.count <= DirectHermesSessionValidation.maximumHistoryRows,
              bytes <= DirectHermesSessionValidation.maximumHistoryBytes else {
            throw WorkspaceClientError.capacityExceeded
        }
        let projected = try project(rows: combined, source: record, binding: binding)
        let hydrated = projected.record
        try requireHydration(record.id, token: token, startingStoredID: startingStoredID, receivedStoredID: page.storedID)
        setBinding(preservingLiveBinding(bindingWithRecord(binding, record: hydrated)), for: record.id)
        retainHistory(id: record.id, projection: projected.projection,
                      window: .init(storedID: page.storedID, rows: combined, nextOffset: nextOffset), bytes: bytes)
        return SessionHydrationPage(record: hydrated, nextOffset: nextOffset)
    }

    /// Creates a native Hermes branch at the exact visible message selected by
    /// the caller.  The branch endpoint counts visible messages, while the
    /// catalog may only have retained its latest page, so hydrate the complete
    /// source transcript before deriving the checkpoint.
    func fork(record: SessionRecord, throughItemID: String) async throws -> SessionRecord {
        let resolved = try await resolveSession(record)
        let hydrated = try await hydrate(resolved.record)
        try requireOwner()

        guard hydrated.kind == .direct, hydrated.agentIDs.count == 1,
              let checkpointIndex = hydrated.items.firstIndex(where: { $0.id == throughItemID }),
              let checkpointText = Self.messageText(hydrated.items[checkpointIndex]),
              !checkpointText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceClientError.invalidRequest
        }
        let prefix = Array(hydrated.items.prefix(through: checkpointIndex))
        let branchMessages = prefix.compactMap { item -> (TimelineItem, String)? in
            guard let text = Self.messageText(item),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (item, text)
        }
        let count = branchMessages.count
        guard count > 0, count <= DirectHermesSessionValidation.maximumHistoryRows,
              branchMessages.contains(where: { $0.0.role == .human }) else {
            throw WorkspaceClientError.invalidRequest
        }

        let binding = try candidate(for: hydrated)
        guard let runtime = binding.coordinate.runtimeSessionID else {
            throw WorkspaceClientError.invalidResponse
        }
        let parentStored = binding.coordinate.storedSessionID ?? binding.anchorID
        let title = try Self.forkTitle(hydrated.title)
        let receipt = try await performReceipt(.sessionBranch, [
            "session_id": .string(runtime), "count": .integer(count), "name": .string(title),
        ], expectedOwnership: binding.ownership)
        let response = receipt.response
        try requireOwner()

        let childRuntime = try DirectHermesSessionValidation.string(response["session_id"])
        let childStored = try DirectHermesSessionValidation.string(response["stored_session_id"])
        guard !DirectHermesSessionValidation.same(childRuntime, runtime),
              !DirectHermesSessionValidation.same(childStored, parentStored),
              let returnedTitle = try DirectHermesSessionValidation.optionalText(response["title"], maximum: 240),
              returnedTitle == title,
              let parent = response["parent"]?.string,
              DirectHermesSessionValidation.same(parent, parentStored),
              let returnedCount = response["message_count"]?.integer,
              returnedCount == count,
              let values = response["messages"]?.array,
              values.count == count,
              let info = response["info"]?.object,
              let returnedProfile = info["profile_name"]?.string,
              DirectHermesSessionValidation.same(returnedProfile, binding.coordinate.profileID) else {
            throw WorkspaceClientError.invalidResponse
        }
        try DirectHermesSessionValidation.coordinate(childStored)
        guard let running = try DirectHermesSessionValidation.flag(info["running"]) else {
            throw WorkspaceClientError.invalidResponse
        }
        let model = try DirectHermesSessionValidation.optionalText(info["model"], maximum: 512)
        let provider = try DirectHermesSessionValidation.optionalText(info["provider"], maximum: 128)
        var userTurn = 0
        for (index, value) in values.enumerated() {
            let expected = branchMessages[index]
            let expectedRole: String
            switch expected.0.role {
            case .human:
                expectedRole = "user"
                userTurn += 1
            case .assistant:
                expectedRole = "assistant"
            }
            guard let object = value.object,
                  object["role"]?.string == expectedRole,
                  let returnedText = try DirectHermesSessionValidation.optionalText(object["text"], maximum: 1_048_576),
                  returnedText == expected.1,
                  object["row_id"].map({ raw in
                      guard let rowID = raw.integer, let expectedID = Self.historyRowID(expected.0) else { return false }
                      return rowID == expectedID
                  }) ?? true else {
                throw WorkspaceClientError.invalidResponse
            }
            let checkpoint = SessionForkCheckpoint(
                userTurn: userTurn, role: expected.0.role == .human ? .user : .assistant,
                content: expected.1
            )
            guard checkpoint.matches(content: returnedText) else {
                throw WorkspaceClientError.invalidResponse
            }
        }

        let childID = try DirectHermesSessionIdentity.appID(
            owner: owner, profileID: binding.coordinate.profileID, anchorID: childStored
        )
        guard childID != hydrated.id, bindings[childID] == nil else {
            throw WorkspaceClientError.invalidResponse
        }
        var child = SessionRecord(
            id: childID, kind: .direct, agentIDs: [binding.coordinate.profileID],
            title: returnedTitle, remoteStoredID: childStored, remoteSource: hydrated.remoteSource,
            workspaceID: hydrated.workspaceID, workspaceName: hydrated.workspaceName,
            parentSessionID: hydrated.id, items: branchMessages.map { $0.0 },
            activityVisibility: hydrated.activityVisibility, isActive: running,
            isPinned: false, createdAt: now(), updatedAt: now(),
            hasAcceptedMessage: branchMessages.contains { $0.0.role == .human }
        )
        if let model, !model.isEmpty {
            child.sessionRuntime = .init(model: model, provider: provider, observedAt: now())
        }
        let childBinding = try Binding(
            coordinate: .init(owner: owner, profileID: binding.coordinate.profileID, sessionID: childID,
                              storedSessionID: childStored, runtimeSessionID: childRuntime),
            anchorID: childStored, record: child, durability: .persisted, cwd: nil,
            canonicalRegistryID: nil, runtimeSessionKey: childStored,
            ownership: .init(runtimeID: childRuntime, sessionKey: childStored,
                             profileID: binding.coordinate.profileID, epoch: receipt.epoch, isReceipt: true)
        )
        setBinding(childBinding, for: childID)
        return child
    }

    private func historyPage(binding: Binding, offset: Int, limit: Int, order: String) async throws -> HistoryPage {
        let response = try await perform(.sessionHistory, [
            "session_id": .string(binding.coordinate.storedSessionID ?? binding.anchorID),
            "profile": .string(binding.coordinate.profileID), "limit": .integer(limit),
            "offset": .integer(offset), "order": .string(order), "include_compacted": .boolean(true),
        ])
        let stored = try DirectHermesSessionValidation.string(response["session_id"])
        if let profile = response["profile"] {
            guard let profile = profile.string,
                  DirectHermesSessionValidation.same(profile, binding.coordinate.profileID) else {
                throw WorkspaceClientError.invalidResponse
            }
        }
        let values = response["messages"]?.array ?? response["data"]?.array
        guard let values, values.count <= limit,
              let pagination = response["pagination"]?.object,
              pagination["offset"]?.integer == offset, pagination["limit"]?.integer == limit,
              pagination["order"]?.string == order, pagination["returned"]?.integer == values.count else {
            throw WorkspaceClientError.invalidResponse
        }
        let rows = try values.map { try DirectHermesHistoryRow($0, sessionID: stored) }
        guard Set(rows.map(\.id)).count == rows.count else { throw DirectHermesSessionError.historyChanged }
        return .init(storedID: stored, rows: rows, returned: rows.count, limit: limit)
    }

    private func project(rows: [DirectHermesHistoryRow], source: SessionRecord, binding: Binding) throws
        -> (record: SessionRecord, projection: DirectHermesHistoryProjection) {
        let projection = try DirectHermesHistoryProjection(
            rows: rows, appID: source.id, profileID: binding.coordinate.profileID,
            source: binding.record.remoteSource, sourceOrderBase: -rows.count
        )
        var record = source
        record.items = projection.messages
        record.activityEvents = projection.activityEvents(sessionID: source.id)
        if let todos = Self.todoSnapshot(
            from: projection.tools,
            sessionID: source.id
        ), todos.supersedes(record.sessionTodos) {
            record.sessionTodos = todos
        }
        record.remoteStoredID = binding.coordinate.storedSessionID
        record.remoteSource = binding.record.remoteSource
        record.hasAcceptedMessage = record.hasAcceptedMessage || rows.contains { $0.role == "user" && $0.isVisible }
        return (record, projection)
    }

    /// Canonical history may contain either a legacy/direct `todo` call or the
    /// first-party `tool_call({calls:[{name:"todo_list", ...}]})` wrapper. Only
    /// the newest recognized invocation is considered: a malformed newer result
    /// is unsupported, never permission to resurrect an older list.
    private static func todoSnapshot(
        from tools: [DirectHermesHistoryToolRecord],
        sessionID: String
    ) -> SessionTodoSnapshot? {
        for tool in tools.reversed() where isTodoInvocation(tool) {
            guard let result = tool.result,
                  result.utf8.count <= 512_000,
                  let value = decodeJSON(result) else { return nil }
            let state: BighelpJSONValue
            if let response = value.object?["response"] {
                state = response
            } else {
                state = value
            }
            return SessionTodoSnapshot.native(sessionID: sessionID, state: state)
        }
        return nil
    }

    private static func isTodoInvocation(_ tool: DirectHermesHistoryToolRecord) -> Bool {
        guard let name = tool.name else { return false }
        if name == "todo" || name == "todo_list" { return true }
        guard name == "tool_call", let arguments = tool.arguments,
              arguments.utf8.count <= 1_048_576,
              let object = decodeJSON(arguments)?.object else { return false }
        let calls: [BighelpJSONValue]
        if let values = object["calls"]?.array {
            calls = values
        } else if object["name"] != nil {
            calls = [.object(object)]
        } else {
            return false
        }
        guard calls.count == 1, let call = calls.first?.object,
              let nested = call["name"]?.string else { return false }
        return nested == "todo" || nested == "todo_list"
    }

    private static func decodeJSON(_ text: String) -> BighelpJSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BighelpJSONValue.self, from: data)
    }

    private func retainHistory(id: String, projection: DirectHermesHistoryProjection, window: HistoryWindow, bytes: Int) {
        historyCacheOrder.removeAll { $0 == id }
        historyCacheBytes[id] = nil
        while historyCacheOrder.count >= 4 || historyCacheBytes.values.reduce(0, +) + bytes > 64 * 1024 * 1024 {
            guard !historyCacheOrder.isEmpty else { break }
            let removed = historyCacheOrder.removeFirst()
            historyCacheBytes[removed] = nil
            historyWindows[removed] = nil
            historyProjections[removed] = nil
        }
        historyCacheOrder.append(id)
        historyCacheBytes[id] = bytes
        historyWindows[id] = window
        historyProjections[id] = projection
    }

    private func requireHydration(_ id: String, token: UUID, startingStoredID: String?, receivedStoredID: String) throws {
        try requireOwner()
        guard hydrationTokens[id] == token else { throw CancellationError() }
        if let current = bindings[id]?.coordinate.storedSessionID,
           startingStoredID.map({ DirectHermesSessionValidation.same(current, $0) }) != true,
           !DirectHermesSessionValidation.same(current, receivedStoredID) {
            throw DirectHermesSessionError.historyChanged
        }
    }

    private func rebinding(_ source: Binding, storedID: String) throws -> Binding {
        var binding = source
        let unchanged = source.coordinate.storedSessionID.map { DirectHermesSessionValidation.same($0, storedID) } == true
        binding.coordinate = try .init(
            owner: owner, profileID: source.coordinate.profileID, sessionID: source.record.id,
            storedSessionID: storedID, runtimeSessionID: unchanged ? source.coordinate.runtimeSessionID : nil
        )
        if !unchanged {
            binding.runtimeSessionKey = nil
            binding.ownership = nil
        }
        binding.record.remoteStoredID = storedID
        if !binding.isLiveDiscoveryOnly { binding.durability = .persisted }
        return binding
    }

    private func bindingWithRecord(_ binding: Binding, record: SessionRecord) -> Binding {
        var result = binding
        result.record = record
        if !result.isLiveDiscoveryOnly { result.durability = .persisted }
        return result
    }

    private func sameRow(_ lhs: DirectHermesHistoryRow, _ rhs: DirectHermesHistoryRow) throws -> Bool {
        guard lhs.id == rhs.id else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(BighelpJSONValue.object(lhs.raw)) == encoder.encode(BighelpJSONValue.object(rhs.raw))
    }

    func rename(_ record: SessionRecord, title: String) async throws {
        let title = try SessionTitleRules.validated(title)
        var binding = try candidate(for: record)
        guard !binding.isLiveDiscoveryOnly else {
            throw DirectHermesSessionError.sessionNotPersisted
        }
        guard binding.canonicalRegistryID == nil else { throw WorkspaceClientError.unavailable(.policyRestricted) }
        let targetID: String
        if let live = binding.coordinate.runtimeSessionID {
            let response = try await perform(.sessionTitle, ["session_id": .string(live), "title": .string(title)])
            guard response["pending"]?.boolean == false, response["title"]?.string == title else {
                throw WorkspaceClientError.outcomeUnknown
            }
            let resolved = try await resolveSession(record)
            binding = try candidate(for: resolved.record)
            targetID = try DirectHermesSessionValidation.string(binding.coordinate.storedSessionID.map(BighelpJSONValue.string))
        } else {
            let catalog = try await refreshedCatalogCoordinate(for: binding)
            guard catalog.canonicalRegistryID == nil else { throw WorkspaceClientError.unavailable(.policyRestricted) }
            targetID = catalog.rowID
            binding.catalog = catalog
            let response = try await perform(.sessionUpdate, [
                "session_id": .string(targetID),
                "profile": .string(binding.coordinate.profileID), "title": .string(title),
            ])
            guard response["ok"]?.boolean == true, response["title"]?.string == title else {
                throw WorkspaceClientError.invalidResponse
            }
        }
        let detail = try await detail(profileID: binding.coordinate.profileID, storedID: targetID)
        guard detail["title"]?.string == title else { throw WorkspaceClientError.conflict }
        binding.record.title = title
        binding.durability = .persisted
        setBinding(preservingLiveBinding(binding), for: record.id)
    }

    func setPinned(_ record: SessionRecord, pinned: Bool) async throws {
        try await setFlags(record, flags: .init(pinned: pinned))
    }

    func archive(_ record: SessionRecord) async throws {
        try await setFlags(record, flags: .init(archived: true))
        if let binding = bindings[record.id] {
            // Bounded: the oldest archives have long since been closed by Hermes.
            if archivedKeys.count > 1_024 { archivedKeys.removeAll() }
            archivedKeys.formUnion(identityKeys(binding))
        }
        setBinding(nil, for: record.id)
    }

    private func identityKeys(_ binding: Binding) -> Set<String> {
        var ids = [binding.anchorID]
        ids += [binding.coordinate.storedSessionID, binding.runtimeSessionKey, binding.canonicalRegistryID,
                binding.catalog?.rowID, binding.catalog?.lineageRootID].compactMap { $0 }
        ids += binding.catalog?.lineageIDs ?? []
        return Set(ids.map(DirectHermesSessionIdentity.key))
    }

    func setFlags(_ record: SessionRecord, flags: DirectHermesSessionFlags) async throws {
        let binding = try candidate(for: record)
        guard binding.durability == .persisted else { throw DirectHermesSessionError.sessionNotPersisted }
        let targetID = binding.canonicalRegistryID ?? binding.catalog?.lineageRootID ?? binding.anchorID
        var fields: [String: BighelpJSONValue] = [:]
        if let value = flags.archived { fields["archived"] = .boolean(value) }
        if let value = flags.hidden { fields["hidden"] = .boolean(value) }
        if let value = flags.pinned { fields["pinned"] = .boolean(value) }
        if let value = flags.unread { fields["unread"] = .boolean(value) }
        guard !fields.isEmpty else { throw WorkspaceClientError.invalidRequest }
        let response = try await perform(.sessionUpdate, fields.merging([
            "session_id": .string(targetID),
            "profile": .string(binding.coordinate.profileID),
        ]) { _, new in new })
        guard response["ok"]?.boolean == true,
              fields.allSatisfy({ response[$0.key] == $0.value }) else {
            throw WorkspaceClientError.invalidResponse
        }
        let current = try await detail(profileID: binding.coordinate.profileID, storedID: targetID)
        for (field, expected) in fields {
            if field == "unread" { continue }
            guard try DirectHermesSessionValidation.flag(current[field]) == expected.boolean else {
                throw WorkspaceClientError.conflict
            }
        }
    }

    func delete(_ record: SessionRecord) async throws {
        _ = try candidate(for: record)
        throw DirectHermesSessionError.nativeRowDeletionOnly
    }

    @discardableResult
    func deleteNativeRow(_ record: SessionRecord) async throws -> DirectHermesNativeRowDeletionReceipt {
        let binding = try candidate(for: record)
        let catalog = try await refreshedCatalogCoordinate(for: binding)
        let response = try await perform(.sessionDelete, [
            "session_id": .string(catalog.rowID),
            "profile": .string(binding.coordinate.profileID),
        ])
        guard response["ok"]?.boolean == true,
              response["already_absent"] == nil || response["already_absent"]?.boolean != nil else {
            throw WorkspaceClientError.invalidResponse
        }
        setBinding(nil, for: record.id)
        historyWindows[record.id] = nil
        historyProjections[record.id] = nil
        historyCacheOrder.removeAll { $0 == record.id }
        historyCacheBytes[record.id] = nil
        hydrationTokens[record.id] = nil
        return .init(owner: owner, profileID: binding.coordinate.profileID, rowID: catalog.rowID,
                     alreadyAbsent: response["already_absent"]?.boolean == true)
    }

    private func perform(_ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue]) async throws -> [String: BighelpJSONValue] {
        try requireOwner()
        let response = try await workspace.perform(operation, payload: payload, owner: owner)
        try requireOwner()
        return response
    }

    private func requireOwner() throws {
        try Task.checkCancellation()
        guard !retired, let current = currentOwner(), let transportOwner = workspace.owner,
              current == owner, transportOwner == owner,
              current.cacheScopeID == owner.cacheScopeID, transportOwner.cacheScopeID == owner.cacheScopeID else {
            throw WorkspaceClientError.ownerChanged
        }
    }

    private func loadProfiles() async throws -> [Profile] {
        let response = try await perform(.profilesList, ["include_sessions": .boolean(false)])
        guard let rows = response["profiles"]?.array, rows.count <= 512 else {
            throw WorkspaceClientError.invalidResponse
        }
        var loaded: [Profile] = []
        var map: [String: Profile] = [:]
        for row in rows {
            guard let object = row.object else { throw WorkspaceClientError.invalidResponse }
            let id = try DirectHermesSessionValidation.string(object["name"], maximum: 128)
            let key = DirectHermesSessionIdentity.key(id)
            guard map[key] == nil else { throw WorkspaceClientError.invalidResponse }
            let label = try DirectHermesSessionValidation.optionalText(object["display_name"], maximum: 800)
            let canonical = try registryValue(object["canonical_session"])
            let profile = Profile(id: id, displayName: label.flatMap { $0.isEmpty ? nil : $0 } ?? id, canonical: canonical)
            loaded.append(profile)
            map[key] = profile
            if let canonical { canonicalIDs[key] = canonical }
        }
        profiles = map
        return loaded
    }

    private func requireProfile(_ profileID: String) async throws -> Profile {
        try DirectHermesSessionValidation.coordinate(profileID, maximum: 128)
        let loaded = try await loadProfiles()
        guard let profile = loaded.first(where: { DirectHermesSessionValidation.same($0.id, profileID) }) else {
            throw WorkspaceClientError.invalidRequest
        }
        return profile
    }

    private func registryValue(_ value: BighelpJSONValue?) throws -> Registry? {
        guard let value, value != .null else { return nil }
        guard let row = value.object else { throw WorkspaceClientError.invalidResponse }
        let id = try DirectHermesSessionValidation.string(row["id"])
        let resolved = try DirectHermesSessionValidation.optionalText(row["resolved_id"], maximum: 512)
        if let resolved { try DirectHermesSessionValidation.coordinate(resolved) }
        return Registry(id: id, resolvedID: resolved)
    }

    private func registry(profileID: String) async throws -> Registry? {
        let response = try await perform(.nativeSessionList, [
            "profile": .string(profileID), "title": .string("Bot Chat"),
            "include_hidden": .boolean(true), "limit": .integer(200),
        ])
        guard let rows = response["sessions"]?.array, rows.count <= 1 else {
            throw WorkspaceClientError.invalidResponse
        }
        guard let value = rows.first else { return nil }
        guard value.object?["title"]?.string == "Bot Chat" else { throw WorkspaceClientError.invalidResponse }
        return try registryValue(value)
    }

    /// Hermes finds an agent's Bot Chat by name on resume, as `hermes -c "Bot Chat"` and its
    /// message routes do, wherever the chat started and even when archived. The list
    /// lookup skips archived chats, so a Bot Chat archived elsewhere never opened here.
    /// Nil when the agent has none (4007).
    private func resumeCanonicalByTitle(profile: Profile) async throws -> DirectHermesResolvedSession? {
        let receipt: (response: [String: BighelpJSONValue], epoch: String?)
        do {
            receipt = try await resume(profileID: profile.id, storedID: "Bot Chat")
        } catch WorkspaceClientError.rejected(code: "4007") {
            return nil
        }
        let stored = try DirectHermesSessionValidation.string(receipt.response["session_key"] ?? receipt.response["resumed"])
        try DirectHermesSessionValidation.coordinate(stored)
        let canonical = Registry(id: stored, resolvedID: nil)
        canonicalIDs[DirectHermesSessionIdentity.key(profile.id)] = canonical
        return try await openRegistry(canonical, profile: profile, receipt: receipt)
    }

    private func openRegistry(_ registry: Registry, profile: Profile,
                              receipt resumed: (response: [String: BighelpJSONValue], epoch: String?)? = nil)
        async throws -> DirectHermesResolvedSession {
        let appID = try DirectHermesSessionIdentity.appID(owner: owner, profileID: profile.id, anchorID: registry.id)
        if resumed == nil, let current = bindings[appID], current.coordinate.runtimeSessionID != nil {
            return try await resolveSession(current.record)
        }
        let record = try draftRecord(profile: profile, storedID: registry.id, title: "Bot Chat")
        let candidate = try Binding(
            coordinate: WorkspaceSessionCoordinate(owner: owner, profileID: profile.id, sessionID: appID,
                                                   storedSessionID: registry.resolvedID ?? registry.id, runtimeSessionID: nil),
            anchorID: registry.id, record: record, durability: .persisted, cwd: nil,
            canonicalRegistryID: registry.id
        )
        let receipt: (response: [String: BighelpJSONValue], epoch: String?)
        if let resumed { receipt = resumed } else { receipt = try await resume(profileID: profile.id, storedID: registry.id) }
        let binding = try attachedBinding(receipt.response, original: candidate, profile: profile, receiptEpoch: receipt.epoch)
        setBinding(binding, for: appID)
        return descriptor(binding)
    }

    private func resume(profileID: String, storedID: String) async throws
        -> (response: [String: BighelpJSONValue], epoch: String?) {
        try await performReceipt(.sessionResume, [
            "profile": .string(profileID), "session_id": .string(storedID),
            "defer_history": .boolean(true), "omit_messages": .boolean(true),
            "source": .string(DirectHermesReleaseContract.sessionSource),
        ])
    }

    private func candidate(for record: SessionRecord) throws -> Binding {
        try requireOwner()
        let decoded = try DirectHermesSessionIdentity.decode(record.id, owner: owner)
        guard record.kind == .direct, record.agentIDs.count == 1,
              DirectHermesSessionValidation.same(record.agentIDs[0], decoded.profileID) else {
            throw WorkspaceClientError.invalidRequest
        }
        if var known = bindings[record.id] {
            let nativeSource = known.record.remoteSource
            known.record = record
            known.record.remoteStoredID = known.coordinate.storedSessionID
            known.record.remoteSource = nativeSource
            return hasOwnership(known) ? known : removingLiveBinding(known)
        }
        var record = record
        record.remoteStoredID = decoded.anchorID
        let creation = creations[DirectHermesSessionIdentity.key(decoded.profileID)]
        let knownDraft = creation?.purpose == .ordinary
            && creation?.storedSessionID.map({ DirectHermesSessionValidation.same($0, decoded.anchorID) }) == true
        return try Binding(
            coordinate: WorkspaceSessionCoordinate(owner: owner, profileID: decoded.profileID, sessionID: record.id,
                                                   storedSessionID: decoded.anchorID, runtimeSessionID: nil),
            anchorID: decoded.anchorID, record: record, durability: knownDraft ? .draft : .persisted,
            cwd: nil, canonicalRegistryID: nil,
            isLiveDiscoveryOnly: !knownDraft && record.remoteSource == nil
        )
    }

    private func attachedBinding(_ response: [String: BighelpJSONValue], original: Binding, profile: Profile,
                                 expectedRuntime: String? = nil, receiptEpoch: String?) throws -> Binding {
        let runtime = try DirectHermesSessionValidation.string(response["session_id"])
        if let expectedRuntime, !DirectHermesSessionValidation.same(runtime, expectedRuntime) {
            throw WorkspaceClientError.invalidResponse
        }
        let stored = try DirectHermesSessionValidation.string(response["session_key"] ?? response["stored_session_id"] ?? response["resumed"])
        for key in ["session_key", "stored_session_id", "resumed"] {
            if let value = response[key] {
                let id = try DirectHermesSessionValidation.string(value)
                guard DirectHermesSessionValidation.same(id, stored) else { throw WorkspaceClientError.invalidResponse }
            }
        }
        guard let info = response["info"]?.object else { throw WorkspaceClientError.invalidResponse }
        if let returnedProfile = info["profile_name"] {
            let returned = try DirectHermesSessionValidation.string(returnedProfile, maximum: 128)
            guard DirectHermesSessionValidation.same(returned, profile.id) else { throw WorkspaceClientError.invalidResponse }
        }
        if let infoStored = info["stored_session_id"] {
            guard DirectHermesSessionValidation.same(try DirectHermesSessionValidation.string(infoStored), stored) else {
                throw WorkspaceClientError.invalidResponse
            }
        }
        if expectedRuntime != nil {
            // ID-only activation cannot use REST or an old guessed binding to
            // fill a missing profile echo. Its prior evidence must still match.
            guard hasOwnership(original), original.ownership?.epoch == receiptEpoch,
                  bindings[original.record.id]?.ownership?.revision == original.ownership?.revision,
                  original.runtimeSessionKey.map({ DirectHermesSessionValidation.same($0, stored) }) == true else {
                throw WorkspaceClientError.invalidResponse
            }
        }
        var binding = original
        binding.coordinate = try .init(owner: owner, profileID: profile.id, sessionID: original.record.id,
                                       storedSessionID: stored, runtimeSessionID: runtime)
        binding.runtimeSessionKey = stored
        binding.ownership = .init(runtimeID: runtime, sessionKey: stored, profileID: profile.id,
                                  epoch: receiptEpoch, isReceipt: true)
        binding.record.remoteStoredID = stored
        if let runningValue = response["running"] {
            guard let running = runningValue.boolean else { throw WorkspaceClientError.invalidResponse }
            binding.record.isActive = running
        }
        if info["lazy"]?.boolean != true, let model = info["model"]?.string, !model.isEmpty {
            _ = try DirectHermesSessionValidation.text(model, maximum: 512, allowsEmpty: false)
            let provider = try DirectHermesSessionValidation.optionalText(info["provider"], maximum: 128)
            binding.record.sessionRuntime = .init(model: model, provider: provider, observedAt: now())
        }
        binding.cwd = try DirectHermesSessionValidation.optionalText(info["cwd"], maximum: 4096)
        return binding
    }

    private func catalogBinding(_ value: [String: BighelpJSONValue], profile: Profile) throws -> Binding {
        let id = try DirectHermesSessionValidation.string(value["id"])
        guard let returnedProfile = value["profile"]?.string,
              DirectHermesSessionValidation.same(returnedProfile, profile.id) else {
            throw WorkspaceClientError.invalidResponse
        }
        let lineageRoot = try DirectHermesSessionValidation.optionalText(value["_lineage_root_id"], maximum: 512)
        if let lineageRoot { try DirectHermesSessionValidation.coordinate(lineageRoot) }
        let lineage: [String]?
        if let raw = value["_lineage_ids"], raw != .null {
            guard let values = raw.array, values.count <= 10_000 else { throw WorkspaceClientError.invalidResponse }
            let ids = try values.map { try DirectHermesSessionValidation.string($0) }
            guard Set(ids.map(DirectHermesSessionIdentity.key)).count == ids.count,
                  ids.contains(where: { DirectHermesSessionValidation.same($0, id) }),
                  lineageRoot.map({ root in ids.contains { DirectHermesSessionValidation.same($0, root) } }) ?? true else {
                throw WorkspaceClientError.invalidResponse
            }
            lineage = ids
        } else {
            lineage = nil
        }
        let matchesCanonical = profile.canonical.map { canonical in
            DirectHermesSessionValidation.same(canonical.id, id)
                || canonical.resolvedID.map { DirectHermesSessionValidation.same($0, id) } == true
                || lineageRoot.map { DirectHermesSessionValidation.same($0, canonical.id) } == true
                || lineage?.contains(where: { DirectHermesSessionValidation.same($0, canonical.id) }) == true
        } ?? false
        let anchor = matchesCanonical ? (profile.canonical?.id ?? id) : (lineageRoot ?? id)
        let appID = try DirectHermesSessionIdentity.appID(owner: owner, profileID: profile.id, anchorID: anchor)
        guard let started = try DirectHermesSessionValidation.date(value["started_at"]) else {
            throw WorkspaceClientError.invalidResponse
        }
        let updated = try DirectHermesSessionValidation.date(value["last_active"] ?? value["last_activity_at"]) ?? started
        let source = try DirectHermesSessionValidation.optionalText(value["source"], maximum: 128)
        let title = try DirectHermesSessionValidation.optionalText(value["title"], maximum: 4096) ?? ""
        let preview = HermesUserMessageDisplay.preview(
            try DirectHermesSessionValidation.optionalText(value["preview"], maximum: 64 * 1024) ?? ""
        )
        let count: Int
        if let rawCount = value["message_count"], rawCount != .null {
            guard let parsed = rawCount.integer else { throw WorkspaceClientError.invalidResponse }
            count = parsed
        } else {
            count = 0
        }
        guard count >= 0 else { throw WorkspaceClientError.invalidResponse }
        var record = SessionRecord(
            id: appID, kind: .direct, agentIDs: [profile.id], title: title.isEmpty ? "Untitled" : title,
            remoteStoredID: id, remoteSource: source, isPinned: try DirectHermesSessionValidation.flag(value["pinned"]) ?? false,
            createdAt: started, updatedAt: updated, hasAcceptedMessage: count > 0
        )
        record.catalogPreview = preview
        return try Binding(
            coordinate: WorkspaceSessionCoordinate(owner: owner, profileID: profile.id, sessionID: appID,
                                                   storedSessionID: id, runtimeSessionID: nil),
            anchorID: anchor, record: record, durability: .persisted,
            cwd: DirectHermesSessionValidation.optionalText(value["cwd"], maximum: 4096),
            canonicalRegistryID: matchesCanonical ? anchor : nil,
            catalog: .init(owner: owner, profileID: profile.id, rowID: id, lineageRootID: lineageRoot,
                           lineageIDs: lineage, canonicalRegistryID: matchesCanonical ? profile.canonical?.id : nil)
        )
    }

    private func coalescingSavedBinding(
        _ incoming: Binding,
        claimedRetainedVisibleIDs: inout Set<String>
    ) throws -> Binding {
        let matches = bindings.values.filter { current in
            current.record.id != incoming.record.id
                && DirectHermesSessionValidation.same(
                    current.coordinate.profileID,
                    incoming.coordinate.profileID
                )
                && binding(incoming, containsStoredIdentity: current.anchorID)
        }
        guard matches.count <= 1 else { throw WorkspaceClientError.invalidResponse }
        guard let current = matches.first else { return incoming }
        guard claimedRetainedVisibleIDs.insert(current.record.id).inserted else {
            throw WorkspaceClientError.invalidResponse
        }

        // The app identity is an owner/profile/lineage anchor. When a live-only
        // session first appears in REST under another exact lineage member,
        // retain that already visible identity so mounted drafts and history
        // reconcile into the durable metadata row instead of changing routes.
        var adopted = incoming
        var record = current.record
        record.remoteStoredID = incoming.record.remoteStoredID
        record.remoteSource = incoming.record.remoteSource
        record.workspaceID = incoming.record.workspaceID
        record.workspaceName = incoming.record.workspaceName
        record.title = incoming.record.title
        record.catalogPreview = incoming.record.catalogPreview
        record.isPinned = incoming.record.isPinned
        record.isActive = hasOwnership(current) && current.record.isActive
        // The host's saved last activity, unless a reply is still coming in here.
        record.updatedAt = record.isActive ? max(current.record.updatedAt, incoming.record.updatedAt)
            : incoming.record.updatedAt
        record.hasAcceptedMessage = current.record.hasAcceptedMessage || incoming.record.hasAcceptedMessage
        adopted.record = record
        adopted.coordinate = try .init(
            owner: owner,
            profileID: incoming.coordinate.profileID,
            sessionID: current.record.id,
            storedSessionID: incoming.coordinate.storedSessionID,
            runtimeSessionID: hasOwnership(current) ? current.coordinate.runtimeSessionID : nil
        )
        if hasOwnership(current) {
            adopted.runtimeSessionKey = current.runtimeSessionKey
            adopted.ownership = current.ownership
        }
        return adopted
    }

    private func hasOwnership(_ binding: Binding) -> Bool {
        guard binding.coordinate.owner == owner, let proof = binding.ownership,
              let runtime = binding.coordinate.runtimeSessionID,
              let key = binding.runtimeSessionKey,
              DirectHermesSessionValidation.same(proof.runtimeID, runtime),
              DirectHermesSessionValidation.same(proof.sessionKey, key),
              DirectHermesSessionValidation.same(proof.profileID, binding.coordinate.profileID) else { return false }
        return proof.epoch == replayEpoch && (proof.epoch != nil || proof.isReceipt)
    }

    private func removingLiveBinding(_ original: Binding) -> Binding {
        var value = original
        // All coordinates are validated at construction; removing the optional
        // runtime cannot invalidate any of their unchanged stored fields.
        value.coordinate = try! .init(owner: original.coordinate.owner,
                                      profileID: original.coordinate.profileID,
                                      sessionID: original.coordinate.sessionID,
                                      storedSessionID: original.coordinate.storedSessionID,
                                      runtimeSessionID: nil)
        value.runtimeSessionKey = nil
        value.ownership = nil
        value.record.isActive = false
        return value
    }

    /// Metadata writes do not invalidate discovery; both positive proof changes
    /// and revocations do. The ticket is bounded, with no lifetime tombstones.
    private func setBinding(_ binding: Binding?, for id: String) {
        let current = bindings[id]
        if current?.ownership?.revision != binding?.ownership?.revision
            || current?.coordinate != binding?.coordinate {
            ownershipRevision = UUID()
        }
        bindings[id] = binding
    }

    private func setBindings(_ next: [String: Binding]) {
        if bindings.count != next.count || bindings.contains(where: { id, current in
            current.ownership?.revision != next[id]?.ownership?.revision
                || current.coordinate != next[id]?.coordinate
        }) {
            ownershipRevision = UUID()
        }
        bindings = next
    }

    private func observeReplayEpoch(_ epoch: String) {
        if let prior = replayEpoch, !DirectHermesSessionValidation.same(prior, epoch) {
            ownershipRevision = UUID()
        }
        replayEpoch = epoch
        for (id, binding) in bindings where binding.ownership != nil && binding.ownership?.epoch != epoch {
            setBinding(removingLiveBinding(binding), for: id)
        }
    }

    /// session.events.since accepts the empty session key and returns an empty
    /// ring plus the process epoch. It does not look up/attach/build a session.
    /// Never dispatch this data, its open_requests, or advance chat cursors.
    private func readReplayEpoch(token: UUID? = nil, ownershipTicket: UUID? = nil) async throws -> String {
        let response = try await perform(.sessionEvents, ["session_id": .string(""), "last_seen": .integer(0)])
        if let token, listToken != token { throw CancellationError() }
        if let ownershipTicket, ownershipRevision != ownershipTicket { throw StaleOwnershipDiscovery() }
        guard response["events"]?.array?.isEmpty == true,
              response["count"]?.integer == 0, response["latest_seq"]?.integer == 0,
              response["truncated"]?.boolean == false, response["open_requests"]?.array != nil else {
            throw WorkspaceClientError.invalidResponse
        }
        let epoch = try DirectHermesSessionValidation.string(response["epoch"])
        observeReplayEpoch(epoch)
        return epoch
    }

    private func optionalReplayEpoch() async throws -> String? {
        do { return try await readReplayEpoch() }
        catch is CancellationError { throw CancellationError() }
        catch WorkspaceClientError.ownerChanged { throw WorkspaceClientError.ownerChanged }
        catch { return nil }
    }

    /// Receipts remain explicit operation results, never inferred from a REST
    /// match. Epoch-less receipts are usable for that attachment, but cannot
    /// establish fresh catalog discovery after an epoch becomes known.
    private func performReceipt(_ operation: WorkspaceOperation, _ payload: [String: BighelpJSONValue],
                                expectedOwnership: RuntimeOwnership? = nil) async throws
        -> (response: [String: BighelpJSONValue], epoch: String?) {
        let before = try await optionalReplayEpoch()
        let context = expectedOwnership?.epoch ?? before ?? replayEpoch
        try validateReceiptContext([context, expectedOwnership?.epoch, before, replayEpoch], expectedOwnership)
        let response = try await perform(operation, payload)
        let after = try await optionalReplayEpoch()
        try validateReceiptContext([context, expectedOwnership?.epoch, before, after, replayEpoch], expectedOwnership)
        return (response, after ?? before ?? expectedOwnership?.epoch ?? context)
    }

    private func validateReceiptContext(_ observations: [String?], _ expected: RuntimeOwnership?) throws {
        let known = observations.compactMap { $0 }
        if let first = known.first, !known.allSatisfy({ DirectHermesSessionValidation.same(first, $0) }) {
            throw WorkspaceClientError.invalidResponse
        }
        if let expected, !bindings.values.contains(where: {
            $0.ownership?.revision == expected.revision && hasOwnership($0)
        }) { throw WorkspaceClientError.invalidResponse }
    }

    private func requireDiscovery(_ token: UUID, _ ownershipTicket: UUID) throws {
        try requireOwner()
        guard listToken == token else { throw CancellationError() }
        guard ownershipRevision == ownershipTicket else { throw StaleOwnershipDiscovery() }
    }

    private func discoverActiveSessions(profiles: [Profile], token: UUID,
                                        ownershipTicket: UUID) async throws -> [OwnedActiveSession] {
        try requireDiscovery(token, ownershipTicket)
        let epoch = try await readReplayEpoch(token: token, ownershipTicket: ownershipTicket)
        try requireDiscovery(token, ownershipTicket)
        let active = try DirectHermesActiveSessionsDecoder.decode(try await perform(.nativeSessionActiveList, [:]))
        try requireDiscovery(token, ownershipTicket)
        let allowed = Set(profiles.map { DirectHermesSessionIdentity.key($0.id) })
        var proven: [OwnedActiveSession] = []
        var needsInventoryFence = false
        var replayReads = 0
        for item in active {
            let retained = bindings.values.filter {
                hasOwnership($0) && $0.ownership?.epoch == epoch
                    && $0.coordinate.runtimeSessionID.map { DirectHermesSessionValidation.same($0, item.runtimeID) } == true
            }
            guard retained.count <= 1 else { throw WorkspaceClientError.invalidResponse }
            if let current = retained.first, let proof = current.ownership {
                if DirectHermesSessionValidation.same(proof.sessionKey, item.sessionKey),
                   allowed.contains(DirectHermesSessionIdentity.key(proof.profileID)) {
                    proven.append(.init(item: item, ownership: proof))
                } else {
                    // An observed handle/key replacement invalidates the old
                    // proof. Do not guess a compression/lineage transition.
                    setBinding(removingLiveBinding(current), for: current.record.id)
                    throw StaleOwnershipDiscovery()
                }
                continue
            }
            // Stock replay retains at most 64 rings. Bound optional catalog
            // enrichment even if the process advertises many live handles.
            guard replayReads < 64 else { continue }
            replayReads += 1
            do {
                let response = try await perform(.sessionEvents, [
                    "session_id": .string(item.runtimeID), "last_seen": .integer(0),
                ])
                try requireDiscovery(token, ownershipTicket)
                if let returnedEpoch = response["epoch"]?.string,
                   !DirectHermesSessionValidation.same(returnedEpoch, epoch) {
                    _ = try await readReplayEpoch(token: token, ownershipTicket: ownershipTicket)
                    throw StaleOwnershipDiscovery()
                }
                if let proof = try replayOwnership(response, item: item, epoch: epoch, allowed: allowed) {
                    proven.append(.init(item: item, ownership: proof))
                    needsInventoryFence = true
                }
            } catch is CancellationError { throw CancellationError() }
            catch WorkspaceClientError.ownerChanged { throw WorkspaceClientError.ownerChanged }
            catch is StaleOwnershipDiscovery { throw StaleOwnershipDiscovery() }
            catch WorkspaceClientError.transportUnavailable { throw WorkspaceClientError.transportUnavailable }
            catch { continue } // Missing proof is not missing saved history.
        }
        if needsInventoryFence {
            let final = try DirectHermesActiveSessionsDecoder.decode(try await perform(.nativeSessionActiveList, [:]))
            try requireDiscovery(token, ownershipTicket)
            proven = proven.compactMap { candidate in
                guard let item = final.first(where: {
                    DirectHermesSessionValidation.same($0.runtimeID, candidate.item.runtimeID)
                        && DirectHermesSessionValidation.same($0.sessionKey, candidate.item.sessionKey)
                }) else { return nil }
                return .init(item: item, ownership: candidate.ownership)
            }
        }
        let finalEpoch = try await readReplayEpoch(token: token, ownershipTicket: ownershipTicket)
        try requireDiscovery(token, ownershipTicket)
        guard DirectHermesSessionValidation.same(epoch, finalEpoch) else { return [] }
        return proven
    }

    private func replayOwnership(_ response: [String: BighelpJSONValue], item: DirectHermesActiveSessionItem,
                                 epoch: String, allowed: Set<String>) throws -> RuntimeOwnership? {
        guard response["epoch"]?.string.map({ DirectHermesSessionValidation.same($0, epoch) }) == true,
              response["truncated"]?.boolean == false,
              let events = response["events"]?.array, events.count <= 512,
              response["count"]?.integer == events.count,
              response["latest_seq"]?.integer == events.count,
              let requests = response["open_requests"]?.array, requests.count <= 512 else {
            throw WorkspaceClientError.invalidResponse
        }
        var profile: String?
        for (index, value) in events.enumerated() {
            guard let event = value.object, event["seq"]?.integer == index + 1,
                  event["session_id"]?.string.map({ DirectHermesSessionValidation.same($0, item.runtimeID) }) == true,
                  let type = event["type"]?.string, !type.isEmpty,
                  let payload = event["payload"]?.object else { throw WorkspaceClientError.invalidResponse }
            if type == "session.reclaimed" { return nil }
            guard type == "session.info" else { continue }
            let returnedProfile = try DirectHermesSessionValidation.string(payload["profile_name"], maximum: 128)
            let stored = try DirectHermesSessionValidation.string(payload["stored_session_id"])
            guard allowed.contains(DirectHermesSessionIdentity.key(returnedProfile)),
                  DirectHermesSessionValidation.same(stored, item.sessionKey),
                  profile.map({ DirectHermesSessionValidation.same($0, returnedProfile) }) ?? true else { return nil }
            profile = returnedProfile
        }
        guard let profile else { return nil }
        return .init(runtimeID: item.runtimeID, sessionKey: item.sessionKey,
                     profileID: profile, epoch: epoch, isReceipt: false)
    }

    private func overlayActiveSessions(
        _ active: [OwnedActiveSession],
        profile: Profile,
        bindings profileBindings: inout [Binding]
    ) throws {
        var claimedVisibleIDs = Set<String>()
        for owned in active {
            let item = owned.item
            guard DirectHermesSessionValidation.same(owned.ownership.profileID, profile.id) else {
                throw WorkspaceClientError.invalidResponse
            }
            let savedMatches = profileBindings.indices.filter {
                binding(profileBindings[$0], containsStoredIdentity: item.sessionKey)
            }
            guard savedMatches.count <= 1 else { throw WorkspaceClientError.invalidResponse }
            if savedMatches.isEmpty, archivedKeys.contains(DirectHermesSessionIdentity.key(item.sessionKey)) { continue }

            var index = savedMatches.first
            if index == nil {
                let retainedMatches = bindings.values.filter { current in
                    DirectHermesSessionValidation.same(current.coordinate.profileID, profile.id)
                        && binding(current, containsStoredIdentity: item.sessionKey)
                }
                guard retainedMatches.count <= 1 else { throw WorkspaceClientError.invalidResponse }
                if let retained = retainedMatches.first,
                   item.status.hasActiveWork || (hasOwnership(retained) && retained.ownership?.isReceipt == true) {
                    profileBindings.append(retained)
                    index = profileBindings.indices.last
                }
            }

            if let index {
                var matched = profileBindings[index]
                guard claimedVisibleIDs.insert(matched.record.id).inserted else {
                    throw WorkspaceClientError.invalidResponse
                }
                matched.coordinate = try .init(
                    owner: owner,
                    profileID: profile.id,
                    sessionID: matched.record.id,
                    storedSessionID: matched.coordinate.storedSessionID ?? item.sessionKey,
                    runtimeSessionID: item.runtimeID
                )
                matched.runtimeSessionKey = item.sessionKey
                matched.ownership = owned.ownership
                matched.record.isActive = item.status.hasActiveWork
                // Hermes stamps a session "last active: now" whenever it's resumed, with no new
                // message; only work in progress moves a saved chat up the list.
                if item.status.hasActiveWork {
                    matched.record.updatedAt = max(matched.record.updatedAt, item.lastActive)
                }
                if matched.catalog == nil && !owned.ownership.isReceipt {
                    matched.record.title = item.title.isEmpty ? "Untitled" : item.title
                    matched.record.catalogPreview = item.preview
                    matched.record.hasAcceptedMessage = matched.record.hasAcceptedMessage || item.messageCount > 0
                }
                if !item.model.isEmpty && (item.status.hasActiveWork || matched.record.sessionRuntime == nil || !owned.ownership.isReceipt) {
                    matched.record.sessionRuntime = .init(
                        model: item.model,
                        provider: matched.record.sessionRuntime?.provider,
                        observedAt: item.lastActive
                    )
                }
                profileBindings[index] = matched
                continue
            }

            // Idle, unmatched process objects are neither active work nor a
            // saved chat. Do not invent a durable catalog row for them.
            guard item.status.hasActiveWork else { continue }
            let appID = try DirectHermesSessionIdentity.appID(
                owner: owner,
                profileID: profile.id,
                anchorID: item.sessionKey
            )
            guard !profileBindings.contains(where: { $0.record.id == appID }) else {
                throw WorkspaceClientError.invalidResponse
            }
            var record = SessionRecord(
                id: appID,
                kind: .direct,
                agentIDs: [profile.id],
                title: item.title.isEmpty ? "Untitled" : item.title,
                remoteStoredID: item.sessionKey,
                createdAt: item.startedAt,
                updatedAt: item.lastActive,
                hasAcceptedMessage: item.messageCount > 0
            )
            record.catalogPreview = item.preview
            record.isActive = true
            if !item.model.isEmpty {
                record.sessionRuntime = .init(model: item.model, provider: nil, observedAt: item.lastActive)
            }
            profileBindings.append(try Binding(
                coordinate: .init(
                    owner: owner,
                    profileID: profile.id,
                    sessionID: appID,
                    storedSessionID: item.sessionKey,
                    runtimeSessionID: item.runtimeID
                ),
                anchorID: item.sessionKey,
                record: record,
                durability: .draft,
                cwd: nil,
                canonicalRegistryID: nil,
                runtimeSessionKey: item.sessionKey,
                isLiveDiscoveryOnly: true,
                ownership: owned.ownership
            ))
        }
    }

    private func binding(_ binding: Binding, containsStoredIdentity value: String) -> Bool {
        DirectHermesSessionValidation.same(binding.anchorID, value)
            || binding.coordinate.storedSessionID.map {
                DirectHermesSessionValidation.same($0, value)
            } == true
            || binding.catalog.map {
                DirectHermesSessionValidation.same($0.rowID, value)
            } == true
            || binding.catalog?.lineageRootID.map {
                DirectHermesSessionValidation.same($0, value)
            } == true
            || binding.catalog?.lineageIDs?.contains(where: {
                DirectHermesSessionValidation.same($0, value)
            }) == true
            || binding.catalog?.canonicalRegistryID.map {
                DirectHermesSessionValidation.same($0, value)
            } == true
    }

    /// Resolve the session's persisted cwd through Hermes' project registry.
    /// `project: null` means the session is genuinely unassigned. A host that
    /// predates `projects.for_cwd` can still provide its session catalog, so
    /// only that explicit unsupported-operation result, or a nonmatching cwd
    /// fallback for a stale path, degrades to unassigned; malformed project
    /// payloads and transport responses still fail the authoritative load.
    private func projectAssociation(for cwd: String, profile: Profile) async throws -> ProjectAssociation? {
        let path = try WorkspaceManagementDecoder.path(.string(cwd))
        do {
            let response = try await perform(.projectsForCwd, [
                "profile": .string(profile.id), "cwd": .string(path)
            ])
            // Hermes resolves a deleted/nonexistent stored cwd to its current
            // completion cwd. That fallback is not evidence for a project
            // association: keep this row unassigned while allowing the rest
            // of the authoritative catalog to load.
            guard response["cwd"]?.string == path else { return nil }
            switch response["project"] {
            case .null:
                return nil
            case .object(let row):
                let project = try WorkspaceManagementDecoder.project(row)
                guard !project.isArchived else { return nil }
                return ProjectAssociation(id: project.id, name: project.name)
            default:
                throw WorkspaceClientError.invalidResponse
            }
        } catch WorkspaceClientError.unavailable(.unsupportedOperation) {
            return nil
        }
    }

    private func projectAssociationKey(profile: Profile, cwd: String) -> String {
        "\(profile.id.utf8.count):\(profile.id)\(cwd.utf8.count):\(cwd)"
    }

    private func preservingLiveBinding(_ incoming: Binding) -> Binding {
        let incoming = removingLiveBinding(incoming)
        guard let current = bindings[incoming.record.id],
              hasOwnership(current),
              DirectHermesSessionValidation.same(current.coordinate.profileID, incoming.coordinate.profileID),
              (current.coordinate.storedSessionID.flatMap { stored in
                  incoming.coordinate.storedSessionID.map {
                      DirectHermesSessionValidation.same(stored, $0)
                  }
              } == true || binding(incoming, containsStoredIdentity: current.anchorID)) else {
            return incoming
        }
        var merged = incoming
        guard let coordinate = try? WorkspaceSessionCoordinate(
            owner: incoming.coordinate.owner,
            profileID: incoming.coordinate.profileID,
            sessionID: incoming.coordinate.sessionID,
            storedSessionID: incoming.coordinate.storedSessionID,
            runtimeSessionID: current.coordinate.runtimeSessionID
        ) else { return incoming }
        merged.coordinate = coordinate
        merged.record.isActive = current.record.isActive
        if current.record.isActive { merged.record.updatedAt = max(merged.record.updatedAt, current.record.updatedAt) }
        if let runtime = current.record.sessionRuntime,
           runtime.observedAt > (merged.record.sessionRuntime?.observedAt ?? .distantPast) {
            merged.record.sessionRuntime = runtime
        }
        merged.runtimeSessionKey = current.runtimeSessionKey
        merged.ownership = current.ownership
        return merged
    }

    private func descriptor(_ binding: Binding) -> DirectHermesResolvedSession {
        .init(record: binding.record, coordinate: binding.coordinate, durability: binding.durability,
              canonicalRegistryID: binding.canonicalRegistryID, cwd: binding.cwd, catalog: binding.catalog)
    }

    private func detail(profileID: String, storedID: String) async throws -> [String: BighelpJSONValue] {
        let response = try await perform(.sessionDetail, [
            "session_id": .string(storedID), "profile": .string(profileID),
        ])
        guard let id = response["id"]?.string, DirectHermesSessionValidation.same(id, storedID),
              let profile = response["profile"]?.string,
              DirectHermesSessionValidation.same(profile, profileID) else {
            throw WorkspaceClientError.invalidResponse
        }
        return response
    }

    /// Whether `/api/sessions` has another page. Hermes 0.21.x sends no `has_more` and adds
    /// pinned sessions past the limit, so the row count can't tell; `total` can.
    static func pageHasMore(_ page: [String: BighelpJSONValue], offset: Int, rows: Int) -> Bool {
        if let hasMore = page["has_more"]?.boolean { return hasMore }
        let limit = page["limit"]?.integer ?? 100
        if let total = page["total"]?.integer { return offset + limit < total }
        return rows >= limit
    }

    private func refreshedCatalogCoordinate(for binding: Binding) async throws -> DirectHermesCatalogCoordinate {
        let profile = try await requireProfile(binding.coordinate.profileID)
        var offset = 0
        while offset <= DirectHermesSessionValidation.maximumSessions {
            let page = try await perform(.sessionsList, [
                "profile": .string(profile.id), "limit": .integer(100), "offset": .integer(offset),
                "archived": .string("include"), "order": .string("created"),
            ])
            guard let rows = page["sessions"]?.array,
                  rows.count <= DirectHermesSessionValidation.maximumSessions,
                  page["limit"]?.integer == 100, page["offset"]?.integer == offset else {
                throw WorkspaceClientError.invalidResponse
            }
            for row in rows {
                guard let object = row.object else { throw WorkspaceClientError.invalidResponse }
                let candidate = try catalogBinding(object, profile: profile)
                guard let catalog = candidate.catalog else { throw WorkspaceClientError.invalidResponse }
                let matches = DirectHermesSessionValidation.same(catalog.rowID, binding.anchorID)
                    || catalog.lineageRootID.map { DirectHermesSessionValidation.same($0, binding.anchorID) } == true
                    || catalog.lineageIDs?.contains(where: { DirectHermesSessionValidation.same($0, binding.anchorID) }) == true
                if matches { return catalog }
            }
            let hasMore = Self.pageHasMore(page, offset: offset, rows: rows.count)
            if rows.isEmpty || !hasMore { break }
            offset += page["limit"]?.integer ?? rows.count
        }
        throw WorkspaceClientError.conflict
    }

    private func draftRecord(profile: Profile, storedID: String, title: String) throws -> SessionRecord {
        SessionRecord(id: try DirectHermesSessionIdentity.appID(owner: owner, profileID: profile.id, anchorID: storedID),
                      kind: .direct, agentIDs: [profile.id], title: title, remoteStoredID: storedID, createdAt: now())
    }

    private static func messageText(_ item: TimelineItem) -> String? {
        guard case .message(let text) = item.content else { return nil }
        return text
    }

    private static func historyRowID(_ item: TimelineItem) -> Int? {
        guard let range = item.id.range(of: ":row:", options: .backwards),
              let id = Int(item.id[range.upperBound...]), id > 0 else { return nil }
        return id
    }

    private static func forkTitle(_ source: String) throws -> String {
        let suffix = " · Fork"
        let title = String(source.prefix(max(1, 240 - suffix.count))) + suffix
        return try DirectHermesSessionValidation.text(title, maximum: 240, allowsEmpty: false)
    }

    private func beginCreation(key: String, profileID: String) throws {
        try requireOwner()
        guard onCreationStateChange != nil else { throw DirectHermesSessionError.creationPersistenceRequired }
        guard bindings.count < DirectHermesSessionValidation.maximumSessions else { throw WorkspaceClientError.capacityExceeded }
        guard !creatingProfiles.contains(key) else { throw DirectHermesSessionError.creationInProgress(profileID: profileID) }
        guard creations[key] != nil || creations.count < 128 else { throw WorkspaceClientError.capacityExceeded }
        creatingProfiles.insert(key)
    }

    private func newCreation(profile: Profile, purpose: DirectHermesSessionCreationState.Purpose,
                             inProjectFolder: Bool = true) async throws -> DirectHermesSessionCreationState {
        let cwd = inProjectFolder ? try await selectedFolderPath?(profile.id) : nil
        try requireOwner()
        if let cwd { try DirectHermesSessionValidation.hostPath(cwd) }
        return .init(schemaVersion: 1, intentID: UUID().uuidString, scopeID: owner.cacheScopeID,
                     profileID: profile.id, purpose: purpose, connectionGeneration: owner.connectionGeneration,
                     phase: .createRequested, requestedCWD: cwd,
                     canonicalRegistryID: canonicalIDs[DirectHermesSessionIdentity.key(profile.id)]?.id)
    }

    private func dispatchCreate(_ state: inout DirectHermesSessionCreationState, profile: Profile) async throws -> Binding {
        try persistBeforeDispatch(state)
        var payload: [String: BighelpJSONValue] = [
            "profile": .string(profile.id), "source": .string(DirectHermesReleaseContract.sessionSource),
        ]
        if state.purpose == .firstCanonical {
            payload["title"] = .string("Bot Chat")
            payload["hidden"] = .boolean(true)
            payload["follow_profile_config"] = .boolean(true)
        }
        if let cwd = state.requestedCWD {
            payload["cwd"] = .string(cwd)
            // A deliberate pick. Otherwise Hermes puts an agent's own configured
            // folder first, and the chat would come back outside its project.
            payload["cwd_explicit"] = .boolean(true)
        }
        let receipt: (response: [String: BighelpJSONValue], epoch: String?)
        do {
            receipt = try await performReceipt(.sessionCreate, payload)
        } catch WorkspaceClientError.rejected(code: "invalid_params") where payload["cwd_explicit"] != nil {
            // Released Hermes (0.21.5 and older) refuses fields it doesn't know. It
            // also doesn't put an agent's own folder first, so the plain request is
            // enough there.
            payload["cwd_explicit"] = nil
            receipt = try await performReceipt(.sessionCreate, payload)
        }
        let response = receipt.response
        guard response["message_count"]?.integer == 0, response["messages"]?.array?.isEmpty == true else {
            throw WorkspaceClientError.invalidResponse
        }
        let stored = try DirectHermesSessionValidation.string(response["stored_session_id"])
        let runtime = try DirectHermesSessionValidation.string(response["session_id"])
        guard let returnedProfile = response["info"]?.object?["profile_name"]?.string,
              DirectHermesSessionValidation.same(returnedProfile, profile.id) else {
            throw WorkspaceClientError.invalidResponse
        }
        state.storedSessionID = stored
        state.runtimeSessionID = runtime
        state.phase = .created
        try retain(state)
        let record = try draftRecord(profile: profile, storedID: stored,
                                     title: state.purpose == .firstCanonical ? "Bot Chat" : "New chat")
        let original = try Binding(
            coordinate: WorkspaceSessionCoordinate(owner: owner, profileID: profile.id, sessionID: record.id,
                                                   storedSessionID: stored, runtimeSessionID: runtime),
            anchorID: stored, record: record, durability: .draft, cwd: state.requestedCWD, canonicalRegistryID: nil
        )
        let binding = try attachedBinding(response, original: original, profile: profile, receiptEpoch: receipt.epoch)
        if let requested = state.requestedCWD,
           binding.cwd.map({ DirectHermesSessionValidation.same($0, requested) }) != true {
            throw DirectHermesSessionError.workspaceNotConfirmed
        }
        return binding
    }

    private func persistBeforeDispatch(_ state: DirectHermesSessionCreationState) throws {
        try requireOwner()
        guard let sink = onCreationStateChange else { throw DirectHermesSessionError.creationPersistenceRequired }
        try sink(state)
        try requireOwner()
        creations[DirectHermesSessionIdentity.key(state.profileID)] = state
    }

    private func retain(_ state: DirectHermesSessionCreationState) throws {
        try requireOwner()
        creations[DirectHermesSessionIdentity.key(state.profileID)] = state
        guard let sink = onCreationStateChange else { throw DirectHermesSessionError.creationPersistenceRequired }
        try sink(state)
        try requireOwner()
    }

    private func validate(_ options: DirectHermesSessionListOptions) throws {
        guard options.sources.count <= 32, options.excludedSources.count <= 32 else {
            throw WorkspaceClientError.invalidRequest
        }
        for source in options.sources + options.excludedSources {
            try DirectHermesSessionValidation.coordinate(source, maximum: 128)
            guard !source.contains(",") else { throw WorkspaceClientError.invalidRequest }
        }
        if let path = options.cwdPrefix { try DirectHermesSessionValidation.hostPath(path) }
    }
}
