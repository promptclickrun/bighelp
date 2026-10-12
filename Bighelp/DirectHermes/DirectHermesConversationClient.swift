import Foundation
import Observation

@MainActor
@Observable
/// Owns observable state and transport lifetime. Responsibility extensions operate on this same actor and journal.
final class DirectHermesConversationClient: StreamingConversationClient, StoppableConversationClient, CompactingConversationClient,
    MidSessionConversationClient, AttachmentConversationClient {
    typealias SessionContextObserver = @MainActor (SessionContextSnapshot) -> Void
    typealias NativeSubagentObserver = @MainActor ([NativeSubagentRailItem]) -> Void
    typealias SessionTodoObserver = @MainActor (SessionTodoSnapshot) -> Void
    typealias SessionLivenessObserver = @MainActor (Bool) -> Void

    /// The native command router explicitly refused execution before admission.
    struct RejectedCommand: Error {}

    var supportedAttachmentKinds: Set<ChatAttachment.Kind> { [.file, .image] }
    var allowsLocalAgentReassignment: Bool { false }
    let nativeWorkspaceAuthority: WorkspaceAuthority?
    let conversationID: String
    let profile: String
    internal(set) var scope: String
    let hostIdentity: String
    let promptHostIdentity: String
    let usesCatalogHistory: Bool
    internal(set) var runtimeID: String
    internal(set) var storedID: String
    internal(set) var title: String
    internal(set) var modelName = ""
    internal(set) var status = "Ready"
    var latestSpinnerActivity: String?
    var spinnerActivityText: String? {
        guard connected, !isHydrating, projection.running else { return nil }
        return latestSpinnerActivity
    }
    internal(set) var connected = true
    internal(set) var needsRecovery = false
    /// A definite stale-runtime refusal revokes this attachment, not the
    /// certainty of the refused prompt. Only verified reattachment clears it.
    internal(set) var requiresDurableReattachment = false
    var hasPendingSubmission: Bool {
        preparingAttachmentID != nil || pendingID != nil || waiter != nil
    }
    // Read-only views of readiness gates, for explaining a disabled Send.
    var isHydratingForReason: Bool { isHydrating }
    var needsRecoveryForReason: Bool { needsRecovery }
    var requiresDurableReattachmentForReason: Bool { requiresDurableReattachment }
    var hasPendingSubmissionForReason: Bool { hasPendingSubmission }

    var isReadyForSubmission: Bool {
        hasAuthoritativeEventCoverage && !hasPendingSubmission
    }
    /// A pending local submission blocks another admission without weakening
    /// the already-recovered transport's sequence coverage.
    var hasAuthoritativeEventCoverage: Bool {
        connected && !isHydrating && !needsRecovery && !requiresDurableReattachment
    }
    var canSetMessageReaction: Bool { hasAuthoritativeEventCoverage }
    var sessionActionsConnectionGeneration: UUID { generation }
    var sessionActionsAreRunning: Bool { projection.running }
    var currentPDFAttachmentTarget: DirectHermesPDFAttachmentTarget? {
        guard hasAuthoritativeEventCoverage else { return nil }
        return try? DirectHermesPDFAttachmentTarget(
            runtimeID: runtimeID,
            profileID: profile,
            owner: generation
        )
    }
    var prompts: [DirectHermesPrompt] {
        guard promptContract != .unknown else { return [] }
        return promptStore?.prompts(
            hostIdentity: promptHostIdentity,
            profile: profile,
            runtimeID: runtimeID,
            visibleSessionID: conversationID
        ) ?? legacyPrompts.values.sorted {
            ($0.createdAt, $0.id) < ($1.createdAt, $1.id)
        }
    }
    internal(set) var journal: DirectHermesDraftStore.Record
    internal(set) var projection: DirectHermesProjection
    var sideTaskResults: [DirectHermesSideTaskResult] { projection.sideTaskResults }
    var reviewSummaries: [DirectHermesReviewSummary] { projection.reviewSummaries }
    var notices: [DirectHermesNotice] { projection.notices }
    var latestStatusUpdate: DirectHermesStatusUpdate? { projection.latestStatusUpdate }
    var toolOutputRisks: [DirectHermesToolOutputRisk] { projection.toolOutputRisks }
    var messageReactions: [Int: DirectHermesMessageReaction] { retainedMessageReactions }
    var latestAffectionReaction: DirectHermesAffectionReaction? { projection.latestAffectionReaction }
    var controlSnapshot: DirectHermesSessionControlSnapshot? { projection.controlSnapshot }
    var reclaim: DirectHermesSessionReclaim? { projection.reclaim }
    var sessionActions: DirectHermesSessionActions {
        let owner = generation
        return DirectHermesSessionActions(profile: profile, authority: { [weak self] in
            guard let self, self.connected, self.generation == owner else { return nil }
            return DirectHermesSessionActions.Connection(
                rpc: self.rpc,
                runtimeSessionID: self.runtimeID,
                storedSessionID: self.storedID,
                isRunning: self.projection.running,
                canMutate: self.hasAuthoritativeEventCoverage,
                isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.connected && self.generation == owner
                }
            )
        }, onSideTaskAccepted: { [weak self] acceptance in
            guard let self, self.connected, self.generation == owner else { return }
            self.acceptSideTask(acceptance)
        })
    }
    internal(set) var sessionContext: SessionContextSnapshot?
    @ObservationIgnored var onSessionContextChange: SessionContextObserver?
    @ObservationIgnored var onNativeSubagentsChange: NativeSubagentObserver?
    @ObservationIgnored var onSessionTodosChange: SessionTodoObserver?
    @ObservationIgnored var onSessionLivenessChange: SessionLivenessObserver?
    internal(set) var nativeSubagents: [NativeSubagentRailItem] = []
    weak var model: ChatModel? {
        didSet {
            if let sessionContext { model?.reconcileSessionContext(sessionContext) }
            if let todoSnapshot = projection.todoSnapshot { model?.reconcileTodos(todoSnapshot) }
            if let controlSnapshot {
                model?.reconcileNativeGoalControl(controlSnapshot, from: self,
                    connectionGeneration: sessionActionsConnectionGeneration)
            }
            model?.reconcileNativeSubagents(nativeSubagents)
            publishNativeMessageReactions()
            scheduleMessageMedia()
        }
    }
    @ObservationIgnored var rpc: any DirectHermesRPC
    @ObservationIgnored weak var promptStore: DirectHermesPromptStore?
    @ObservationIgnored var openRequestRecovery: DirectHermesOpenRequestRecovery?
    var promptContract = DirectHermesPromptContract.unknown
    var legacyPrompts: [DirectHermesLegacyPromptKey: DirectHermesPrompt] = [:]
    @ObservationIgnored var legacyMutations: [DirectHermesLegacyPromptKey: UUID] = [:]
    /// Unsent answers in the question pop-up, so closing it and coming back
    /// keeps what you picked and typed. Kept only while the request waits.
    @ObservationIgnored var promptAnswerDrafts: [String: DirectHermesPromptAnswerDraft] = [:]
    @ObservationIgnored let drafts: DirectHermesDraftStore
    @ObservationIgnored let attachmentResolver: (any AgentAttachmentResolving)?
    /// Says who is sending before each new turn (hosts several people share).
    @ObservationIgnored var speakerNote: (any ChatSpeakerNoting)?
    @ObservationIgnored var attachmentTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var attachmentAttempts: [String: String] = [:]
    /// Waits before asking again for a finished message's files. A first read
    /// can lose to Hermes saving the turn, a reload, or a network hand-off.
    @ObservationIgnored var mediaRetryDelays: [Duration] = [.seconds(2), .seconds(6), .seconds(15)]
    @ObservationIgnored var mediaRetryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var mediaFailures: [String: Int] = [:]
    var retainedMessageReactions: [Int: DirectHermesMessageReaction] = [:]
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored var waiter: CheckedContinuation<ConversationResponse, Error>?
    @ObservationIgnored var pendingID: UUID?
    @ObservationIgnored var pendingTurnID: String?
    @ObservationIgnored var admissionOverlapped = false
    @ObservationIgnored var submissionTurns: [String] = []
    @ObservationIgnored var settledSubmissionTurns: [String: Bool] = [:]
    @ObservationIgnored var admitted = false
    @ObservationIgnored var terminalSeen = false
    @ObservationIgnored var turnFailed = false
    @ObservationIgnored var pendingTurnFailed = false
    @ObservationIgnored var acceptedRecovery: (submissionID: UUID, turnID: String, epoch: String)?
    @ObservationIgnored var draftSink: ((TimelineItem) -> Void)?
    @ObservationIgnored var recoveryTask: Task<Void, Error>?
    var isHydrating = false
    @ObservationIgnored var rosterTask: Task<Void, Never>?
    @ObservationIgnored var reactionHydrationTask: Task<Void, Never>?
    @ObservationIgnored var heldEvents: [DirectHermesEvent] = []
    @ObservationIgnored var heldEventsOverflowed = false
    @ObservationIgnored var hydrationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    @ObservationIgnored var onAdmittedActivity: ((DirectHermesProjection.Change, String, Bool) -> Void)?
    @ObservationIgnored var isReplayingActivity = false
    @ObservationIgnored var workspaceRecord: SessionRecord?
    /// Saved history was held back because a reply still looked unfinished.
    @ObservationIgnored var workspaceHistoryDeferred = false
    /// That reply ended while away and its missed events could not be
    /// replayed, so only a fresh saved-history read has the finished text.
    @ObservationIgnored var needsCatalogHistoryReseed = false
    var preparingAttachmentID: UUID?
    @ObservationIgnored var returnsVoiceReply = false
    @ObservationIgnored var voiceReplyItems: [TimelineItem] = []
    @ObservationIgnored var voiceReplyUnavailable = false
    @ObservationIgnored let monotonicNow: @MainActor () -> UInt64
    @ObservationIgnored var liveTurnStart: (epoch: String, turnID: String, nanoseconds: UInt64)?
    /// A queued voice receipt has admitted the prompt, but Hermes does not
    /// include the eventual turn identity in that receipt. Keep the waiter
    /// until the first native `message.start` for this submission establishes
    /// the turn that may settle it.
    @ObservationIgnored var queuedVoiceAwaitingTurn = false
    @ObservationIgnored var nativeSubagentsByID: [String: NativeSubagentRailItem] = [:]
    @ObservationIgnored var terminalNativeSubagentIDs: Set<String> = []
    @ObservationIgnored var nativeSubagentEventRevision: UInt64 = 0

    init(rpc: any DirectHermesRPC, hostIdentity: String, promptHostIdentity: String? = nil,
         profile: String, runtimeID: String,
         storedID: String, title: String, epoch: String, drafts: DirectHermesDraftStore,
         workspaceSession: WorkspaceSessionCoordinate? = nil,
         onSessionContextChange: SessionContextObserver? = nil,
         attachmentResolver: (any AgentAttachmentResolving)? = nil,
         promptStore: DirectHermesPromptStore? = nil,
         openRequestRecovery: DirectHermesOpenRequestRecovery? = nil,
         monotonicNow: @escaping @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) throws {
        if let workspaceSession {
            guard workspaceSession.owner.authority.kind == .direct,
                  DirectHermesIdentity.matches(workspaceSession.owner.cacheScopeID, hostIdentity),
                  DirectHermesIdentity.matches(workspaceSession.profileID, profile),
                  DirectHermesIdentity.matches(workspaceSession.runtimeSessionID, runtimeID),
                  DirectHermesIdentity.matches(workspaceSession.storedSessionID, storedID) else {
                throw WorkspaceClientError.ownerChanged
            }
        }
        self.nativeWorkspaceAuthority = workspaceSession?.owner.authority
        self.rpc = rpc
        self.hostIdentity = hostIdentity
        self.promptHostIdentity = promptHostIdentity ?? hostIdentity
        usesCatalogHistory = workspaceSession != nil
        self.profile = profile
        self.runtimeID = runtimeID
        self.storedID = storedID
        self.title = title
        self.drafts = drafts
        self.attachmentResolver = attachmentResolver
        self.promptStore = promptStore
        self.openRequestRecovery = openRequestRecovery
        self.onSessionContextChange = onSessionContextChange
        self.monotonicNow = monotonicNow
        // JSON array encoding is an unambiguous scope even with separators in names.
        let scope = String(data: try JSONEncoder().encode([hostIdentity, profile, storedID]), encoding: .utf8)!
        // The catalog owns presentation identity; native RPCs still use the
        // separately verified live runtime and durable session coordinates.
        let conversationID = workspaceSession?.sessionID ?? "direct-hermes:" + scope
        var journal = try drafts.load(scope: scope)
        journal.owner = .init(hostIdentity: hostIdentity, profile: profile, storedID: storedID, title: title)
        self.scope = scope
        self.conversationID = conversationID
        self.journal = journal
        projection = DirectHermesProjection(conversationID: conversationID, profile: profile,
            storedID: storedID, epoch: epoch)
        needsRecovery = journal.unresolved.contains { $0.rejectionCode == nil }
    }

    func saveDraft(_ text: String) {
        journal.draft = text
        do { try drafts.save(journal, scope: scope) }
        catch { status = "Draft could not be saved on this device. Keep this chat open." }
    }

    /// Metadata-only promotion after the bridge proves the exact live/durable
    /// mapping. Both retained projections must adopt together before another delta.
    func adoptVerifiedCatalogSource(previous: SessionRecord, next: SessionRecord) throws {
        guard usesCatalogHistory, let current = workspaceRecord,
              previous.remoteSource == nil, current.remoteSource == nil, next.remoteSource != nil,
              DirectHermesIdentity.matches(previous.id, conversationID),
              DirectHermesIdentity.matches(next.id, conversationID),
              DirectHermesIdentity.matches(current.id, conversationID),
              next.kind == .direct, next.agentIDs.count == 1,
              next.agentIDs == previous.agentIDs,
              DirectHermesIdentity.matches(next.agentIDs.first, profile),
              DirectHermesIdentity.matches(previous.remoteStoredID, storedID),
              DirectHermesIdentity.matches(next.remoteStoredID, storedID),
              DirectHermesIdentity.matches(current.remoteStoredID, storedID) else {
            throw WorkspaceClientError.ownerChanged
        }
        if let model, !model.adoptNativeCatalogSource(from: self, previous: previous, next: next) {
            throw WorkspaceClientError.ownerChanged
        }
        workspaceRecord?.remoteSource = next.remoteSource
    }

    func seedWorkspaceHistory(_ record: SessionRecord) throws {
        guard usesCatalogHistory, DirectHermesIdentity.matches(record.id, conversationID),
              record.kind == .direct, record.agentIDs.count == 1,
              DirectHermesIdentity.matches(record.agentIDs.first, profile),
              DirectHermesIdentity.matches(record.remoteStoredID, storedID) else {
            throw WorkspaceClientError.ownerChanged
        }
        workspaceRecord = record
        if let context = record.sessionContext,
           context.sessionId == conversationID,
           DirectHermesIdentity.matches(record.remoteStoredID, storedID) {
            sessionContext = context
        }
        if let todos = record.sessionTodos {
            _ = projection.adoptTodoSnapshot(todos)
        }
        // A consumed event cursor belongs to these rows. Replacing a live or
        // offscreen projection with an older disk page would lose events that
        // exact replay will correctly not send again. Recovery still validates
        // the native snapshot and owner; this is only a display seed guard.
        if projection.hasLiveEvents, projection.running || model == nil {
            workspaceHistoryDeferred = model != nil
            return
        }
        if let model {
            model.reconcileHydratedSession(record)
            // A pending reply keeps its partial row until its end is observed.
            workspaceHistoryDeferred = model.isSending
            projection.retainVisible(items: model.items, activities: model.activityLedger.allEvents)
        } else {
            projection.retainVisible(items: record.items, activities: record.activityEvents)
        }
    }

    /// Applies a saved-history read taken after recovery confirmed the turn
    /// ended, replacing the partial reply left from before the app went away.
    func reseedFinishedTurn(_ record: SessionRecord) throws {
        guard needsCatalogHistoryReseed else { return }
        needsCatalogHistoryReseed = false
        guard !projection.running else { return }
        try seedWorkspaceHistory(record)
    }

    func adoptWorkspaceCoordinate(_ coordinate: WorkspaceSessionCoordinate) throws {
        guard usesCatalogHistory, coordinate.owner.authority.kind == .direct,
              DirectHermesIdentity.matches(coordinate.owner.cacheScopeID, hostIdentity),
              DirectHermesIdentity.matches(coordinate.sessionID, conversationID),
              DirectHermesIdentity.matches(coordinate.profileID, profile),
              let runtime = coordinate.runtimeSessionID, let stored = coordinate.storedSessionID else {
            throw WorkspaceClientError.ownerChanged
        }
        if runtime != runtimeID { resetLiveTiming(); projection.resetCheckpoint(); runtimeID = runtime }
        adoptStoredID(stored)
        requiresDurableReattachment = false
    }

    func markReviewed(_ id: UUID) {
        let previous = journal
        journal.unresolved.removeAll { $0.id == id }
        do {
            try drafts.save(journal, scope: scope)
            needsRecovery = journal.unresolved.contains { $0.rejectionCode == nil }
        } catch {
            journal = previous
            status = "Could not save your review. The original text is still retained."
        }
    }

    func adoptStandaloneRuntimeID(_ value: String) throws {
        guard !usesCatalogHistory, !value.isEmpty, value.utf8.count <= 4_096 else {
            throw WorkspaceClientError.ownerChanged
        }
        guard !runtimeID.utf8.elementsEqual(value.utf8) else { return }
        resetLiveTiming()
        projection.resetCheckpoint()
        runtimeID = value
    }

    func rebind(_ rpc: any DirectHermesRPC) {
        if !connected { isHydrating = true }
        self.rpc = rpc
        connected = true
        model?.reconcileNativeReactionConnectionState(from: self)
    }

    func rebind(_ rpc: any DirectHermesRPC,
                openRequestRecovery: @escaping DirectHermesOpenRequestRecovery) {
        self.openRequestRecovery = openRequestRecovery
        rebind(rpc)
    }

    func suspend() {
        latestSpinnerActivity = nil
        resetLiveTiming()
        attachmentTasks.values.forEach { $0.cancel() }
        attachmentTasks.removeAll()
        attachmentAttempts.removeAll()
        resetMediaRetries()
        // Suspension revokes transport authority, not the last visible roster.
        // Only a valid replacement snapshot or exact terminal event clears it.
        if let id = pendingID, admitted, !admissionOverlapped, let turnID = pendingTurnID {
            // A local waiter ending does not erase an already-confirmed native
            // admission. Exact same-epoch terminal replay can settle it later.
            acceptedRecovery = (id, turnID, projection.epoch)
        }
        generation = UUID()
        rosterTask?.cancel()
        rosterTask = nil
        reactionHydrationTask?.cancel()
        reactionHydrationTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        isHydrating = false
        heldEvents = []
        heldEventsOverflowed = false
        settleHydrationWaiters(throwing: DirectHermesError.notConnected)
        resetPromptContract()
        model?.suspendNativeTurn(from: self)
        connected = false
        model?.reconcileNativeReactionConnectionState(from: self)
        status = "Disconnected · reopen to recover from Hermes"
        let uncertain = pendingID != nil || preparingAttachmentID != nil
        if uncertain { needsRecovery = true }
        // The journal retains any uncertain upload, but its process-local
        // preparation owner cannot survive this transport generation. Retiring
        // only that latch lets exact-owner recovery admit a new instruction;
        // the old operation's generation checks still prevent replay or cleanup.
        preparingAttachmentID = nil
        finish(throwing: DirectHermesError.disconnected(outcomeUnknown: uncertain))
    }

    func commandCatalog() async throws -> [(name: String, detail: String)] {
        let owner = generation
        let result = try await rpc.request("commands.catalog", params: sessionParams)
        guard connected, owner == generation else { throw DirectHermesError.notConnected }
        return (result.object?["pairs"]?.array ?? []).compactMap { row in
            guard let fields = row.array, fields.count == 2,
                  let name = fields[0].string, let detail = fields[1].string else { return nil }
            return (name, detail)
        }
    }

    func setSessionModel(_ identifier: String) async throws {
        try validate(conversationID)
        guard model?.isSending != true, !projection.running, !needsRecovery else {
            throw DirectHermesWorkspaceError.reviewRequired
        }
        // The model input is one literal identifier, never an injectable flag list.
        guard !identifier.isEmpty, !identifier.hasPrefix("-"),
              !identifier.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw DirectHermesError.invalidResponse
        }
        let owner = generation
        var params = sessionParams
        params["key"] = .string("model")
        params["value"] = .string(identifier + " --session")
        params["confirm_expensive_model"] = .boolean(false)
        let result = try await rpc.request("config.set", params: params)
        guard owner == generation, connected else { throw DirectHermesError.disconnected(outcomeUnknown: true) }
        guard result.object?["confirm_required"]?.boolean != true else {
            throw DirectHermesWorkspaceError.modelConfirmationRequired
        }
        guard result.object?["scope"]?.string == "session", let value = result.object?["value"]?.string else {
            throw DirectHermesError.invalidResponse
        }
        // Read back the exact runtime, rather than treating an RPC ack as UI authority.
        let snapshot = try await rpc.request("session.activate", params: sessionParams)
        guard owner == generation, connected else { throw DirectHermesError.notConnected }
        let activation = try validatedActivationSnapshot(snapshot)
        modelName = activation["info"]?.object?["model"]?.string ?? value
    }

    var sessionParams: [String: BighelpJSONValue] {
        ["session_id": .string(runtimeID), "profile": .string(profile)]
    }

    func adoptStoredID(_ value: String) {
        guard !value.isEmpty else { return }
        projection.storedID = value
        guard value != storedID else { return }
        storedID = value
        do {
            let newScope = String(decoding: try JSONEncoder().encode([hostIdentity, profile, value]), as: UTF8.self)
            var next = try drafts.load(scope: newScope)
            next.draft = journal.draft
            next.owner = .init(hostIdentity: hostIdentity, profile: profile, storedID: value, title: title)
            let retainedIDs = Set(next.unresolved.map(\.id))
            next.unresolved += journal.unresolved.filter { !retainedIDs.contains($0.id) }
            try drafts.save(next, scope: newScope)
            // Preserve the former scoped file as a recovery copy. Compression is
            // not authority to erase an unresolved submission's original owner.
            scope = newScope
            journal = next
        } catch {
            needsRecovery = true
            status = "Hermes rotated the stored session. The original draft remains retained; its new local scope could not be saved."
        }
    }

    func validate(_ id: String) throws {
        guard id == conversationID, connected, !isHydrating, !requiresDurableReattachment else {
            throw DirectHermesError.notConnected
        }
    }

    static func safeMessage(_ error: Error) -> String {
        if error as? ChatAttachmentError == .unsupportedKind { return DirectHermesFileAttachments.imagesUnavailable }
        if let error = error as? DirectHermesError { return error.localizedDescription }
        if let error = error as? DirectHermesWorkspaceError { return error.localizedDescription }
        return "The operation could not be completed. Your retained text has not been resent."
    }
}
