import Foundation
import OSLog

@MainActor
/// Owns the sole stream registry, creation journal and lifecycle. Extensions preserve this shared actor boundary.
final class NativeWorkspaceSessionBridge: SessionCatalogClient {
    var canDeleteConversation: Bool { false }
    var allowsLocalAgentReassignment: Bool { false }
    /// The runtime installs the catalog sink after constructing the bridge.
    /// Every callback carries the exact owner that opened the stream so a
    /// late event from another host or connection generation is ignored.
    var onSessionContextChange: (@MainActor (WorkspaceOwner, SessionContextSnapshot) -> Void)?
    var onSessionTodosChange: (@MainActor (WorkspaceOwner, SessionTodoSnapshot) -> Void)?
    var onNativeSubagentRosterChange: (@MainActor (
        WorkspaceOwner, String, DirectHermesConversationClient, [NativeSubagentRailItem]
    ) -> Void)?
    var onSessionRetired: (@MainActor (String) -> Void)?
    /// A refresh found open chats whose runtimes Hermes ended: resume them.
    var onRetainedStreamsNeedResume: (@MainActor () -> Void)?
    var onSessionLivenessChange: (@MainActor (WorkspaceOwner, String, Bool) -> Void)?
    var onUnknownRuntimeEvent: (@MainActor (WorkspaceOwner) -> Void)?

    struct Stream {
        var owner: WorkspaceOwner
        var lease: DirectHermesOwnedRPC
        let client: DirectHermesConversationClient
        var record: SessionRecord
        /// Last exact stream/model verification published by this bridge. A
        /// catalog read that started earlier cannot use snapshot absence to
        /// retire this newer owner.
        var verificationSequence: UInt64
        /// Hermes may omit an empty session from `session.list` until its
        /// first accepted turn. Keep the verified create result available for
        /// the next refresh so the catalog can drive the normal reattach path.
        var retainIfOmitted: Bool
        var recoveredCoordinate: WorkspaceSessionCoordinate? = nil
        var requiresResumeAfterTransportReconnect = false
        weak var boundModel: ChatModel? = nil
    }

    struct CanonicalSessionReentryFlight {
        let id: UUID
        let owner: WorkspaceOwner
        let client: DirectHermesConversationClient
        let modelIdentity: ObjectIdentifier
        let task: Task<SessionRecord, Error>
    }

    struct AuthoritativeRecoveryFlight {
        let id: UUID
        let owner: WorkspaceOwner
        let client: DirectHermesConversationClient
        let modelIdentity: ObjectIdentifier?
        let task: Task<Void, Error>
    }

    let authority: WorkspaceAuthority
    var attachmentResolver: (any AgentAttachmentResolving)?
    /// Where this computer takes files over 8 MB (plugin `native-uploads-v1`).
    var bigFileHost: (any BigFileUploadHost)?
    var speakerNote: (any ChatSpeakerNoting)?
    var agentTalk: (any AgentTalkReading)?
    var selectedFolderPath: (@MainActor (String) async throws -> String?)?
    let connections: WorkspaceConnectionStore
    let drafts: DirectHermesDraftStore
    private let creationRepository: DemoRepository<[String: DirectHermesSessionCreationState]>
    private var creationStates: [String: DirectHermesSessionCreationState]
    var streams: [String: Stream] = [:]
    var canonicalSessionReentryFlights: [String: CanonicalSessionReentryFlight] = [:]
    var authoritativeRecoveryFlights: [String: AuthoritativeRecoveryFlight] = [:]
    var activeMappings: [String: DirectHermesActiveSessionMapping] = [:]
    var streamVerificationSequence: UInt64 = 0
    var retired = false
    private let unavailable = NativeWorkspaceUnavailableClient()
    lazy var box = WorkspaceOwnedClientBox<DirectHermesSessionCatalogClient>(
        connections: connections, authority: authority
    ) { [weak self] workspace, owner, currentOwner in
        guard let self, !self.retired else { throw WorkspaceClientError.ownerChanged }
        let client = DirectHermesSessionCatalogClient(
            workspace: workspace, owner: owner, currentOwner: currentOwner,
            selectedFolderPath: { [weak self] profile in
                guard let self, !self.retired, currentOwner() == owner else {
                    throw WorkspaceClientError.ownerChanged
                }
                return try await self.selectedFolderPath?(profile)
            },
            onCreationStateChange: { [weak self] state in
                guard let self, !self.retired, currentOwner() == owner,
                      state.scopeID == self.authority.cacheScopeID else {
                    throw WorkspaceClientError.ownerChanged
                }
                var states = self.creationStates
                states[Data(state.profileID.utf8).base64EncodedString()] = state
                guard states.count <= 128 else { throw WorkspaceClientError.capacityExceeded }
                try self.creationRepository.save(states)
                self.creationStates = states
            }
        )
        let saved = self.creationStates
        let usable = Self.restorableCreationStates(saved, scopeID: self.authority.cacheScopeID, owner: owner)
        if usable.count != saved.count { self.keepCreationStates(usable, leftOut: saved.count - usable.count) }
        for state in usable.values { try client.restoreCreationState(state) }
        if let previous = self.lastCatalogClient { client.adoptHistory(from: previous) }
        self.lastCatalogClient = client
        return client
    }
    /// The last connection's catalog client, while the box still holds it, for the history it read.
    private weak var lastCatalogClient: DirectHermesSessionCatalogClient?

    init(connections: WorkspaceConnectionStore, authority: WorkspaceAuthority, directory: URL,
         protectedData: any BighelpProtectedDataAvailabilityProviding = BighelpSystemProtectedDataAvailability()) throws {
        self.connections = connections
        self.authority = authority
        drafts = DirectHermesDraftStore(root: directory.appending(path: "submission-journals", directoryHint: .isDirectory))
        creationRepository = DemoRepository(directory: directory, name: "native-session-creation", seed: [:],
                                            protectedDataAvailability: protectedData)
        let saved = try creationRepository.loadExistingPreservingSource() ?? [:]
        creationStates = Self.restorableCreationStates(saved, scopeID: authority.cacheScopeID, owner: nil)
        guard creationStates.count <= 128 else { throw WorkspaceClientError.invalidResponse }
        if creationStates.count != saved.count {
            keepCreationStates(creationStates, leftOut: saved.count - creationStates.count)
        }
    }

    /// The saved creation records this computer (and, given one, this connection) can use. A record is
    /// only a retry breadcrumb for a chat being made, so one that doesn't fit is left out rather than
    /// thrown: thrown, one bad record (2.6.30 saved one for each plugin-made Bot Chat) stopped opening
    /// and starting every chat on that computer, also after a restart.
    static func restorableCreationStates(
        _ states: [String: DirectHermesSessionCreationState], scopeID: String, owner: WorkspaceOwner?
    ) -> [String: DirectHermesSessionCreationState] {
        states.filter { key, state in
            state.scopeID == scopeID && key == Data(state.profileID.utf8).base64EncodedString()
                && (owner.map { (try? state.validated(for: $0)) != nil } ?? true)
        }
    }

    private func keepCreationStates(_ states: [String: DirectHermesSessionCreationState], leftOut: Int) {
        creationStates = states
        let saved = (try? creationRepository.save(states)) != nil
        Self.log.error(
            "Left out \(leftOut, privacy: .public) bad chat creation record(s); saved: \(saved, privacy: .public)")
    }
    private static let log = Logger(subsystem: "app.loopdy.mobile", category: "SessionCreation")

    func currentCoordinate(for id: String) -> WorkspaceSessionCoordinate? {
        guard !retired, let owner = connections.owner, owner.authority == authority else { return nil }
        if let stream = streams[id], stream.owner == owner {
            return try? WorkspaceSessionCoordinate(
                owner: owner, profileID: stream.client.profile, sessionID: id,
                storedSessionID: stream.client.storedID, runtimeSessionID: stream.client.runtimeID
            )
        }
        return try? box.value().coordinate(for: id)
    }

    /// A retained stream is eligible for durable resume only within the same
    /// authenticated authority. Its visible ID keeps the original durable
    /// anchor while `storedID` may be a server-confirmed compaction successor.
    static func canRebindRetainedStream(
        streamOwner: WorkspaceOwner,
        owner: WorkspaceOwner,
        record: SessionRecord,
        profileID: String,
        storedID: String,
        runtimeID: String
    ) -> Bool {
        guard streamOwner.authority == owner.authority,
              streamOwner.authenticationGeneration == owner.authenticationGeneration,
              record.kind == .direct, record.agentIDs.count == 1,
              DirectHermesSessionValidation.same(record.agentIDs[0], profileID),
              !storedID.isEmpty, !runtimeID.isEmpty else {
            return false
        }
        guard let decoded = try? DirectHermesSessionIdentity.decode(record.id, owner: owner) else {
            return false
        }
        return DirectHermesSessionValidation.same(decoded.profileID, profileID)
    }

    static func sameOrAdoptingSource(_ previous: String?, _ current: String?) -> Bool {
        DirectHermesIdentity.sameSessionSource(previous, current) || (previous == nil && current != nil)
    }

    func conversationClient(for record: SessionRecord) -> any ConversationClient {
        guard !retired, let stream = streams[record.id] else { return unavailable }
        return stream.client
    }

    func currentOwner() throws -> WorkspaceOwner {
        guard !retired, let owner = connections.owner, owner.authority == authority else {
            throw WorkspaceClientError.ownerChanged
        }
        return owner
    }

    var retainedSessionIDs: [String] {
        streams.compactMap { id, stream in
            stream.client.model != nil || !stream.client.journal.unresolved.isEmpty ? id : nil
        }.sorted()
    }

    func suspend() {
        let reentryTasks = canonicalSessionReentryFlights.values.map(\.task)
        canonicalSessionReentryFlights.removeAll()
        reentryTasks.forEach { $0.cancel() }
        let recoveryTasks = authoritativeRecoveryFlights.values.map(\.task)
        authoritativeRecoveryFlights.removeAll()
        recoveryTasks.forEach { $0.cancel() }
        for id in Array(streams.keys) {
            if let stream = streams[id] { unbindPromptSession(stream, visibleSessionID: id) }
            streams[id]?.recoveredCoordinate = nil
            streams[id]?.client.model?.flushPersistence()
            streams[id]?.client.suspend()
        }
        activeMappings.removeAll()
    }

    func resetForAccountBoundary() {
        retired = true
        suspend()
        box.reset()
        streams.removeAll()
        activeMappings.removeAll()
    }

}
