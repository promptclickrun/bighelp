import Combine
import Foundation
import Observation

@MainActor
@Observable
final class ChatModel {
    // State lives here; responsibility extensions operate on this same MainActor
    // owner. Internal implementation seams are not independent state owners.
    let conversationID: String
    let activityDisclosures = ChatActivityDisclosureStore()
    let nativeSessionResumeProgress = NativeSessionResumeProgressPresentation()

    @ObservationIgnored let responseTextGrowthSubject = PassthroughSubject<ResponseTextGrowth, Never>()
    var responseTextGrowth: AnyPublisher<ResponseTextGrowth, Never> {
        responseTextGrowthSubject.eraseToAnyPublisher()
    }
    @ObservationIgnored var responseHapticsStopped = false
    @ObservationIgnored var responseHapticsRetired = false

    func retireResponseHaptics() {
        responseHapticsRetired = true
        nativeSessionResumeProgress.retire()
    }

    var draft = "" {
        didSet {
            // A sent reply put back after a failure, or a saved draft, comes
            // back as its quote line plus text: show the reply again.
            if !isReplacingReferenceDraft, let reply = ChatReplyQuote.split(draft) {
                draft = reply.body
                replyDraft = reply.quote
            }
            if !isReplacingReferenceDraft, Data(oldValue.utf8) != Data(draft.utf8) {
                referenceCanonicalSource = nil
                referenceDraftID = nil
                referenceDraftRevision = nil
                referenceSelections.removeAll {
                    (try? ReferenceCodec.encode(source: draft, references: [$0.snapshot])) == nil
                }
            }
            if let selectedSlashCommand,
               SlashCommandIndex(commands: [selectedSlashCommand]).selection(for: draft) == nil {
                self.selectedSlashCommand = nil
            }
            if conversationID.hasPrefix("local-draft:") {
                // A pending presentation canvas may be replaced or fail before
                // the normal checkpoint delay. Publish its draft synchronously
                // so allocation never drops text the user already entered.
                persistSession()
                flushPersistence()
            } else {
                persistSession()
            }
        }
    }
    /// The message the draft answers. It is sent, and saved with the draft, as
    /// a quote line before the text (`ChatReplyQuote`).
    var replyDraft: ChatReplyQuote? {
        didSet {
            guard oldValue != replyDraft, !isReplacingReferenceDraft else { return }
            persistSession()
        }
    }
    var slashCommandLoadTrigger: Bool { draft.hasPrefix("/") }
    var items: [TimelineItem]
    var draftAttachments: [ChatAttachment] = []
    /// Ordinary files/images and PDF-page selections in the exact order the
    /// user added them. `draftAttachments` remains the ordinary-file view used
    /// by existing clients and persisted reference drafts.
    var orderedDraftAttachments: [ChatDraftAttachment] = []
    /// Photos or files still being read in; Send waits for them.
    var draftAttachmentImport: DraftAttachmentImportProgress?
    /// Ones that didn't attach, with why and a way to try again; Send waits for these too.
    var draftAttachmentFailures: [DraftAttachmentFailure] = []
    var pdfAttachmentReceipts: [DirectHermesPDFAttachmentReceipt] = []
    var isPDFDraftSendInFlight = false
    var referenceSelections: [ReferenceDraftSelection] = []
    var referenceSnapshots: [ReferenceSnapshot] { referenceSelections.map(\.snapshot) }
    var referenceSubmission: ReferenceCanonicalSubmission?
    var referenceOwner: ReferenceHubOwner?
    var referenceCanonicalSource: String?
    var referenceDraftID: UUID?
    var referenceDraftRevision: UInt64?
    var isReplacingReferenceDraft = false
    var referenceOwnerRetired = false
    var referenceSendInFlight = false
    var referencePersistenceNeeded = false
    @ObservationIgnored var lastReferenceCheckpoint: (draft: Data, state: ReferenceCanonicalState?)?
    let onReferenceStateChange: ((String, ReferenceCanonicalState?) throws -> Void)?
    var hasLocallyPendingPrimaryTurn = false
    var hasExternallyOwnedPrimaryTurn = false
    /// A catalog row may say a turn was active before this presentation binds
    /// its exact native runtime. Only the native snapshot/event owner may
    /// confirm or retire that provisional liveness.
    var hasRestoredPrimaryTurn = false
    // Native lifecycle authority is separate from Link/Voice's human-row and
    // terminal-message contract. A local RPC waiter is not the current run.
    var nativeTurnID: String?
    var pendingIndependentMessageIDs: Set<String> = []
    /// When the last turn here ended: an alert about it while you're reading
    /// this chat is old news (`BighelpVisibleChats`).
    @ObservationIgnored private(set) var lastTurnEndedAt: Date?
    var isSending = false {
        didSet {
            // The runtime controls are the authority for whether a model or
            // reasoning change may be sent, so the active-turn state has to
            // reach them from every path that starts or ends a turn.
            runtimeControls?.setTurnActive(isSending)
            if !isSending {
                hasLocallyPendingPrimaryTurn = false
                hasExternallyOwnedPrimaryTurn = false
                hasRestoredPrimaryTurn = false
                if oldValue {
                    lastTurnEndedAt = Date()
                    flushPersistence()
                }
            }
        }
    }
    var isStopping = false
    var pendingMidSessionSubmissions: [PendingMidSessionSubmission] = []
    var failureMessage: String?
    var isHydratingHistory = false
    /// In-flight reloads from Hermes: returning to the chat, Force Refresh or
    /// reconnect recovery. The header reads "Updating…" while any is running.
    private(set) var hostRefreshCount = 0
    var isRefreshingFromHost: Bool { hostRefreshCount > 0 }
    func requestSessionControls() { sessionControlsRequest += 1 }

    func beginHostRefresh() { hostRefreshCount += 1 }
    func endHostRefresh() { hostRefreshCount = max(0, hostRefreshCount - 1) }
    /// Invalidates decorative live-only reactions when canonical history arrives.
    var companionHistoryRevision = 0
    var hasPreviousHistory = false
    var isLoadingPreviousHistory = false
    var previousHistoryErrorMessage: String?
    var previousHistoryRevealID: String?
    var activityLedger: ChatActivityLedger
    var transcriptEntries: [ChatTranscriptEntry] = [] {
        didSet { transcriptRevision &+= 1 }
    }
    var transcriptRevision: UInt64 = 0

    struct NativeMessageReactionSnapshot: Equatable {
        let rowID: Int
        let role: TimelineRole
        let reactions: [NativeMessageReaction]
    }

    var nativeMessageReactionSnapshots: [Int: NativeMessageReactionSnapshot] = [:]
    /// Reactions set on a just-finished message before it had a saved row.
    var newestReactionRowByItemID: [String: Int] = [:]
    var pendingUnsavedReactionItemIDs: Set<String> = []
    var nativeMessageReactionErrors: [Int: String] = [:]
    var pendingNativeMessageReactionRows: Set<Int> = []
    var uncertainNativeMessageReactionRows: Set<Int> = []
    var unsupportedNativeReactionGeneration: UUID?
    var nativeMessageReactionRevision: UInt64 = 0
    var nativeAffectionRevision: UInt64 = 0
    var nativeAffectionReaction: NativeAffectionReactionSignal?

    @ObservationIgnored var defersTranscriptPresentation = false
    /// Messages whose files reached this device, by the saved text that named
    /// them, so a history reload of that same text keeps the files on screen.
    @ObservationIgnored var deliveredFileSources: [String: String] = [:]
    @ObservationIgnored var hasDeferredTranscriptChanges = false

    var transcriptProjectionWorkCount = 0
    var lastTranscriptProjectionWorkCount = 0
    var lastItemMutationWorkCount = 0
    var lastActivityMutationWorkCount = 0
    var itemIndexByID: [String: Int] = [:]
    var transcriptMessageIndexByID: [String: Int] = [:]
    var transcriptActivityIndexByEventID: [String: Int] = [:]
    var transcriptActivityPositionByEventID: [String: Int] = [:]
    var taskDrawer: ChatTaskDrawerState?
    var sessionContext: SessionContextSnapshot?
    var sessionGoal: SessionGoalSnapshot?
    var sessionTitle: String
    var sessionWorkspaceID: String? { sourceSession?.workspaceID }
    var sessionWorkspaceName: String? { sourceSession?.workspaceName }
    var sessionSubagents: [SessionSubagentSnapshot] = []
    /// Native Hermes emits a stable subagent identity before its child session
    /// is guaranteed to exist. Keep that live status separate from the
    /// persisted Link roster so missing child navigation never invents a route.
    var nativeSubagents: [NativeSubagentRailItem] = []
    var activityVisibility: ChatActivityVisibility {
        didSet {
            rebuildTranscript()
            persistSession()
        }
    }

    var client: any ConversationClient
    let sleeper: any DemoSleeper
    var agentID: String
    var sourceSession: SessionRecord?
    let botModeRoomStore: BotModeRoomStore?
    let agentDirectory: AgentDirectoryStore?
    private(set) var runtimeControls: SessionRuntimeControlModel? {
        didSet {
            runtimeControls?.setTurnActive(isSending)
        }
    }
    private(set) var slashCommandCatalog: SlashCommandCatalogModel?
    /// Bumped to ask the chat screen to open Model & reasoning, from places
    /// that show the current model (Info, the avatar's profile, the context pop-up).
    private(set) var sessionControlsRequest = 0
    var botModeRoomID: String?
    private let userIdentity: UserIdentity
    private let userIdentityStore: UserIdentityStore?
    let onSessionChange: ((String, [TimelineItem], ChatActivityLedger, ChatActivityVisibility) -> Void)?
    let onGoalSnapshotChange: ((SessionGoalSnapshot) -> Void)?
    let onTodoSnapshotChange: ((SessionTodoSnapshot) -> Void)?
    let persistenceCheckpointDelay: Duration
    var persistenceCheckpointTask: Task<Void, Never>?
    var hasDirtyPersistence = false
    let onTurnStopped: (() -> Void)?
    let onBotModeChange: ((String, [String]) -> Bool)?
    let onBotModeChangeWithHistory: ((String, [String], [TimelineItem]) -> Bool)?
    let onBotModeCollapse: ((String, String, [TimelineItem]) -> Bool)?
    var nextHumanSequence = 1
    var retryRequest: RetryRequest?
    var nativeBotModeSendRecovery: NativeBotModeSendRecovery?
    var mentionCursorOffset: Int?
    private var selectedSlashCommand: SlashCommandDescriptor?
    var nextTranscriptOrder = 1
    let midSessionBehavior: @MainActor () -> MidSessionChatBehavior
    var ownerGeneration = 0
    var sessionTodos: SessionTodoSnapshot?
    var sessionSubagentUpdatedAt = 0
    var botModeApprovalSubmissions: Set<String> = []
    var botModeApprovalErrors: [String: String] = [:]
    var botModeRoomObservation: UUID?
    let generatedMediaResolver: (any GeneratedMediaResolving)?
    var generatedMediaResolutionTasks: [String: Task<Void, Never>] = [:]
    var generatedMediaResolutionAttempts: [String: String] = [:]
    var generatedMediaResolutionGeneration: UInt64 = 0

    init(
        conversationID: String,
        client: any ConversationClient,
        sleeper: any DemoSleeper = ImmediateDemoSleeper(),
        userIdentity: UserIdentity = .init(name: "", avatarFileName: nil),
        userIdentityStore: UserIdentityStore? = nil,
        agentID: String = "default",
        initialItems: [TimelineItem]? = nil,
        initialDraft: String = "",
        initialActivityEvents: [ChatActivityEvent] = [],
        initialActivityVisibility: ChatActivityVisibility = .default,
        initialGoalSnapshot: SessionGoalSnapshot? = nil,
        initialTodoSnapshot: SessionTodoSnapshot? = nil,
        persistenceCheckpointDelay: Duration = .seconds(2),
        taskDrawerDismissDelay: Duration = .seconds(4),
        midSessionBehavior: @escaping @MainActor () -> MidSessionChatBehavior = { .steer },
        sourceSession: SessionRecord? = nil,
        botModeRoomStore: BotModeRoomStore? = nil,
        agentDirectory: AgentDirectoryStore? = nil,
        runtimeControls: SessionRuntimeControlModel? = nil,
        slashCommandCatalog: SlashCommandCatalogModel? = nil,
        generatedMediaResolver: (any GeneratedMediaResolving)? = nil,
        botModeRoomID: String? = nil,
        onSessionChange: ((String, [TimelineItem], ChatActivityLedger, ChatActivityVisibility) -> Void)? = nil,
        onGoalSnapshotChange: ((SessionGoalSnapshot) -> Void)? = nil,
        onTodoSnapshotChange: ((SessionTodoSnapshot) -> Void)? = nil,
        onTurnStopped: (() -> Void)? = nil,
        onBotModeChange: ((String, [String]) -> Bool)? = nil,
        onBotModeChangeWithHistory: ((String, [String], [TimelineItem]) -> Bool)? = nil,
        onBotModeCollapse: ((String, String, [TimelineItem]) -> Bool)? = nil,
        onReferenceStateChange: ((String, ReferenceCanonicalState?) throws -> Void)? = nil
    ) {
        self.conversationID = conversationID
        self.client = client
        self.sleeper = sleeper
        self.userIdentity = userIdentity
        self.userIdentityStore = userIdentityStore
        self.agentID = agentID
        self.sourceSession = sourceSession
        let initialSessionTitle = sourceSession?.title
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sessionTitle = initialSessionTitle.isEmpty ? "New chat" : initialSessionTitle
        if let initialGoalSnapshot,
           initialGoalSnapshot.sessionID == conversationID,
           (sourceSession?.remoteStoredID).map({ $0 == initialGoalSnapshot.storedSessionID }) ?? true,
           initialGoalSnapshot.isValid {
            sessionGoal = initialGoalSnapshot
        }
        self.botModeRoomStore = botModeRoomStore
        self.agentDirectory = agentDirectory
        self.runtimeControls = runtimeControls
        self.slashCommandCatalog = slashCommandCatalog
        self.generatedMediaResolver = generatedMediaResolver
        self.botModeRoomID = botModeRoomID
        self.onSessionChange = onSessionChange
        self.onGoalSnapshotChange = onGoalSnapshotChange
        self.onTodoSnapshotChange = onTodoSnapshotChange
        self.onReferenceStateChange = onReferenceStateChange
        self.persistenceCheckpointDelay = persistenceCheckpointDelay
        self.onTurnStopped = onTurnStopped
        self.onBotModeChange = onBotModeChange
        self.onBotModeChangeWithHistory = onBotModeChangeWithHistory
        self.onBotModeCollapse = onBotModeCollapse
        self.midSessionBehavior = midSessionBehavior
        // Keep the source-compatible delay argument for existing fixtures, but
        // todo lifetime is snapshot-owned and no longer timer-owned.
        _ = taskDrawerDismissDelay
        let validInitialTodos = initialTodoSnapshot.flatMap { snapshot in
            snapshot.sessionID == conversationID && snapshot.isValid ? snapshot : nil
        }
        let validSourceTodos = (sourceSession?.sessionTodos).flatMap { snapshot in
            snapshot.sessionID == conversationID && snapshot.isValid ? snapshot : nil
        }
        let restoredTodos = validInitialTodos?.supersedes(validSourceTodos) == true
            ? validInitialTodos : validSourceTodos ?? validInitialTodos
        sessionTodos = restoredTodos
        taskDrawer = restoredTodos?.taskDrawer
        let seedItems = initialItems ?? ConversationFixtures.initialItems(
            conversationID: conversationID,
            agentID: agentID
        )
        let orderedContent = ChatTranscriptProjection.orderedContent(
            items: seedItems, events: initialActivityEvents
        )
        items = orderedContent.items
        let orderedActivityEvents = orderedContent.events
        activityLedger = ChatActivityLedger(
            sessionID: conversationID,
            events: orderedActivityEvents
        )
        if restoredTodos == nil {
            var legacyDrawer: ChatTaskDrawerState?
            for event in orderedActivityEvents {
                legacyDrawer = ChatTodoProjection.applying(event, to: legacyDrawer)
            }
            taskDrawer = legacyDrawer
        }
        nextTranscriptOrder = orderedContent.nextOrder
        botModeRoomStore?.ensurePresentationOrder(atLeast: orderedContent.nextOrder)
        activityVisibility = initialActivityVisibility
        // A saved reply rides before an ordinary draft; reference drafts keep their exact bytes.
        let savedReply = sourceSession?.referenceState == nil ? ChatReplyQuote.split(initialDraft) : nil
        let initialDraft = savedReply?.body ?? initialDraft
        replyDraft = savedReply?.quote
        let restoredReferences = ReferenceCanonicalState.restoredDraft(initialDraft,
            state: sourceSession?.referenceState)
        draft = restoredReferences.source
        referenceSelections = restoredReferences.selections
        referenceCanonicalSource = initialDraft
        referenceSubmission = sourceSession?.referenceState?.submission
        referenceDraftID = sourceSession?.referenceState?.draftID
        referenceDraftRevision = sourceSession?.referenceState?.draftRevision
        referencePersistenceNeeded = sourceSession?.referenceState != nil || !referenceSelections.isEmpty
        if let submission = referenceSubmission,
           referenceDraftID == submission.draftID,
           referenceDraftRevision == submission.revision,
           Data(initialDraft.utf8) == Data(submission.message.text.utf8) {
            draftAttachments = submission.attachments
        }
        orderedDraftAttachments = draftAttachments.map(ChatDraftAttachment.attachment)
        hasRestoredPrimaryTurn = sourceSession?.isActive == true
        isSending = hasRestoredPrimaryTurn
        // Property observers do not run during initialization, so a session
        // that is restored mid-turn has to seed the lockout explicitly.
        runtimeControls?.setTurnActive(isSending)
        rebuildItemIndexes()
        rebuildTranscript()
        observeBotModeRoomIfNeeded()
        #if DEBUG
        (client as? CanvasStreamingFixtureClient)?.model = self
        #endif
        scheduleGeneratedMediaResolutions()
        scheduleNativeGoalControlRefresh()
    }

    let richDraftRecovery = RichDraftRecoveryStore()

    var directTransportIsReady: Bool {
        guard !(client is NativeWorkspaceUnavailableClient) else { return false }
        return nativeConversationClient?.isReadyForSubmission ?? true
    }

    var canSend: Bool {
        // Hosted groups have their own authenticated client and readiness gates.
        // Their unused direct-chat placeholder must not disable the composer.
        if !isBotMode {
            if isSending, let native = nativeConversationClient {
                guard native.hasAuthoritativeEventCoverage,
                      native.preparingAttachmentID == nil,
                      native.sessionActionsAreRunning else { return false }
            } else if !isSending {
                guard directTransportIsReady else { return false }
            } else {
                guard supportsMidSessionSending else { return false }
            }
        }
        guard !isAwaitingAuthoritativeSessionAllocation else { return false }
        guard !isBotMode || botModeExecutionEnabled else { return false }
        let sendsWhileRoomWorks = acceptsBotModeFollowUp
        if !sendsWhileRoomWorks {
            guard botModeRoom?.isRunning != true else { return false }
            guard botModeRoom?.nativePendingEventID == nil, !hasNativeBotModeRetryActions else { return false }
        }
        guard botModeRoom?.nativeRetryJournal == nil, botModeRoom?.nativePendingCancelID == nil else { return false }
        guard !richDraftRecovery.hasUnexportedChanges else { return false }
        let hasText = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let attachmentsSupported = orderedDraftAttachments.isEmpty || (!isBotMode && orderedDraftAttachments.allSatisfy { value in
            if let selection = value.pdfSelection { return pdfAttachmentTarget == selection.target }
            if case .attachment(let attachment) = value { return supportedAttachmentKinds.contains(attachment.kind) }
            return false
        })
        let hasSendableAttachments = !orderedDraftAttachments.isEmpty && attachmentsSupported
        guard !referenceOwnerRetired, referenceSubmission == nil, !referenceSendInFlight,
              draftAttachmentImport == nil, draftAttachmentFailures.isEmpty,
              !hasExclusiveMidSessionSubmission, !isPDFDraftSendInFlight,
              !hasStalePDFPageSelections,
              attachmentsSupported, hasText || hasSendableAttachments
        else { return false }
        return !isSending || isMidSessionTurnLive || sendsWhileRoomWorks
    }

    /// Why Send is unavailable, in plain words, for VoiceOver and diagnostics.
    /// Mirrors the gates in `canSend`; nil when sending is possible or idle.
    var sendUnavailableReason: String? {
        guard !canSend else { return nil }
        if !isBotMode, let native = nativeConversationClient {
            if !native.connected { return "not connected to host" }
            if native.isHydratingForReason { return "loading chat history" }
            if native.needsRecoveryForReason { return "recovering the last message" }
            if native.requiresDurableReattachmentForReason { return "reattaching to the host session" }
            if native.preparingAttachmentID != nil { return "preparing an attachment" }
            if native.hasPendingSubmissionForReason { return "a message is still being sent" }
        }
        if isAwaitingAuthoritativeSessionAllocation { return "starting the chat on the host" }
        if richDraftRecovery.hasUnexportedChanges { return "saving the draft" }
        if referenceSubmission != nil || referenceSendInFlight { return "a message is still being sent" }
        if draftAttachmentImport != nil { return "attachments are still being added" }
        if !draftAttachmentFailures.isEmpty { return "an attachment didn't attach" }
        if orderedDraftAttachments.isEmpty && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        if isSending { return "the agent is still replying" }
        return "this attachment can't be sent here"
    }

    var allowedMidSessionBehaviors: [MidSessionChatBehavior] {
        nativeConversationClient != nil && !orderedDraftAttachments.isEmpty
            ? [.queued] : [.steer, .queued, .interruptAndSend]
    }

    var defaultMidSessionBehavior: MidSessionChatBehavior {
        // File context uses the supported queue path. This does not rewrite the
        // saved preference or turn an explicitly selected Steer into a queue.
        let preferred = midSessionBehavior()
        return allowedMidSessionBehaviors.contains(preferred) ? preferred : .queued
    }

    var supportsMidSessionSending: Bool {
        botModeRoomID == nil && client is any MidSessionConversationClient
    }

    var supportsStopping: Bool {
        if isBotMode { return botModeRoomStore?.nativeExecutionAvailable == true }
        return client is any StoppableConversationClient
    }

    var canStop: Bool {
        !referenceOwnerRetired && (isSending || botModeRoom?.isRunning == true || botModeRoom?.nativePendingEventID != nil
            || botModeRoom?.nativeFollowUps.isEmpty == false
            || botModeRoom?.nativeRetryJournal != nil || botModeRoom?.nativePendingCancelID != nil)
            && !isStopping
            && !hasExclusiveMidSessionSubmission
            && supportsStopping
    }

    var isMidSessionTurnLive: Bool {
        guard isSending && supportsMidSessionSending else { return false }
        // A restored catalog flag is not steer authority. Native steering is
        // exposed only after the bound adapter has observed the live turn.
        return nativeConversationClient?.sessionActionsAreRunning ?? true
    }

    var isComposerInputDisabled: Bool {
        isStopping
            || isPDFDraftSendInFlight
            || hasExclusiveMidSessionSubmission
            // A group chat keeps taking messages while its agents work.
            || (isSending && !supportsMidSessionSending && !isBotMode)
    }

    var isComposerAttachmentInputDisabled: Bool {
        isAwaitingAuthoritativeSessionAllocation || isPDFDraftSendInFlight || isComposerInputDisabled
    }

    var midSessionSubmissionState: MidSessionSubmissionState {
        guard let submission = pendingMidSessionSubmissions.last else { return .idle }
        return .submitting(submission.behavior)
    }

    var hasExclusiveMidSessionSubmission: Bool {
        pendingMidSessionSubmissions.contains { $0.behavior == .interruptAndSend }
    }

    func pendingMidSessionBehavior(for itemID: String) -> MidSessionChatBehavior? {
        pendingMidSessionSubmissions.first { $0.id == itemID }?.behavior
    }

    var canPerformQuickAction: Bool {
        !isBotMode && directTransportIsReady && !isSending && !isAwaitingAuthoritativeSessionAllocation
            && !referenceOwnerRetired && referenceSubmission == nil && !referenceSendInFlight
            && !richDraftRecovery.hasUnexportedChanges && !hasExclusiveMidSessionSubmission
            && !isPDFDraftSendInFlight && !hasStalePDFPageSelections
    }

    var canRetry: Bool {
        // Recovery may permit independent new input while retaining an uncertain
        // original submission. That is not permission to replay the old action.
        guard isBotMode || (directTransportIsReady && nativeConversationClient?.journal.unresolved.isEmpty != false)
        else { return false }
        return !isAwaitingAuthoritativeSessionAllocation
            && !referenceOwnerRetired && !isSending && (retryRequest != nil || hasNativeBotModeRetryActions)
            && referenceSubmission == nil && !referenceSendInFlight
    }

    var canReassignDirectAgent: Bool {
        client.allowsLocalAgentReassignment && !referenceOwnerRetired && !isBotMode && !isSending && items.isEmpty
            && referenceSubmission == nil && !referenceSendInFlight
    }

    var nativeConversationClient: DirectHermesConversationClient? { client as? DirectHermesConversationClient }

    func attachPreparedNativeClient(_ native: DirectHermesConversationClient) -> Bool {
        guard !referenceOwnerRetired, native.conversationID == conversationID,
              memberIDs == [native.profile], native.nativeWorkspaceAuthority != nil else { return false }
        guard client is NativeWorkspaceUnavailableClient || nativeConversationClient === native else { return false }
        client = native
        native.model = self
        if let context = native.sessionContext { reconcileSessionContext(context) }
        scheduleNativeGoalControlRefresh()
        return true
    }

    var slashCommandSuggestions: [SlashCommandDescriptor] {
        slashCommandCatalog?.index.suggestions(for: draft) ?? []
    }

    /// Refreshes the mounted session's typed command catalog after the live
    /// Hermes skill registry changes. This does not touch transcript rows or
    /// schedule a catalog polling loop.
    func reloadSlashCommandCatalogAfterSkillsChange() async -> Int? {
        guard !referenceOwnerRetired, let catalog = slashCommandCatalog else { return nil }
        await catalog.load()
        guard !referenceOwnerRetired, slashCommandCatalog === catalog,
              catalog.errorMessage == nil else { return nil }
        return catalog.commands.count
    }

    var activeSlashCommand: SlashCommandSelection? {
        if let selection = slashCommandCatalog?.index.selection(for: draft) {
            return selection
        }
        guard let selectedSlashCommand else { return nil }
        return SlashCommandIndex(commands: [selectedSlashCommand]).selection(for: draft)
    }

    func selectSlashCommand(_ command: SlashCommandDescriptor) {
        selectedSlashCommand = command
        draft = SlashCommandIndex(commands: [command]).draft(selecting: command)
        setMentionCursor(offset: draft.count)
    }

    func setSlashCommandArguments(_ arguments: String) {
        guard let selection = activeSlashCommand else { return }

        // The command chip is a convenience, not a separate editing mode.
        // If the user starts a new slash command from its argument field,
        // hand the complete draft back to the catalog so the chip is removed
        // and the dynamic command menu can filter the new token.
        if arguments.hasPrefix("/") {
            selectedSlashCommand = nil
            draft = arguments
            setMentionCursor(offset: draft.count)
            return
        }
        draft = SlashCommandIndex(commands: [selection.command])
            .replacingArguments(in: selection, with: arguments)
        setMentionCursor(offset: draft.count)
    }

    func clearSlashCommand() {
        selectedSlashCommand = nil
        draft = ""
        setMentionCursor(offset: nil)
    }

    var workingAgentName: String? {
        for item in items.reversed() {
            if let name = agentName(from: item) {
                return name
            }
        }
        guard let profileName = agentDirectory?.profiles
            .first(where: { $0.id == agentID })?
            .name
        else { return nil }
        return normalizedAgentName(profileName)
    }

    func updateNativeMetadata(_ item: TimelineItem, from owner: DirectHermesConversationClient) {
        guard (client as? DirectHermesConversationClient) === owner,
              !isBotMode, senderBelongsToThisSession(item),
              let index = itemIndexByID[item.id] else { return }
        let existing = items[index]
        guard existing.role == item.role,
              existing.sender.kind == item.sender.kind,
              existing.sender.id == item.sender.id else { return }
        items[index] = TimelineItem(id: existing.id, role: existing.role, sender: existing.sender,
            content: existing.content,
            metadata: TimelineMetadata(source: existing.metadata.source, freshness: existing.metadata.freshness,
                delivery: existing.metadata.delivery,
                timestamp: item.metadata.timestamp ?? existing.metadata.timestamp,
                sourceOrder: existing.metadata.sourceOrder,
                platformMessageID: existing.metadata.platformMessageID,
                turnDurationMilliseconds: item.metadata.turnDurationMilliseconds ?? existing.metadata.turnDurationMilliseconds,
                contentReference: existing.metadata.contentReference), attachments: existing.attachments)
        updateProjectedMessage(items[index])
        persistSession()
    }

    /// Only the actual native client can adopt this model. No synthetic human
    /// row, Link pending-message correlation, or assistant-segment terminal.
    func adoptNativeTurn(from owner: DirectHermesConversationClient, turnID: String, running: Bool) {
        guard (client as? DirectHermesConversationClient) === owner, !isBotMode else { return }
        if running {
            guard nativeTurnID != turnID || !isSending else { return }
            if let previous = nativeTurnID, previous != turnID {
                // A queued/server turn can start before an earlier send task
                // resumes. Retire that task's presentation authority, not its RPC.
                _ = beginOwnerGeneration()
            } else if nativeTurnID == nil {
                _ = beginOwnerGeneration()
            }
            nativeTurnID = turnID
            hasRestoredPrimaryTurn = false
            isSending = true
            failureMessage = nil
            retryRequest = nil
        } else {
            // A finished turn normally matches the adopted ID. If the IDs drift
            // (replayed message.start, reconnect), an authoritative idle owner with
            // no pending submission still ends the turn; otherwise isSending stays
            // latched and Send is disabled until relaunch.
            guard nativeTurnID == turnID
                    || (isSending && !owner.hasPendingSubmission && owner.hasAuthoritativeEventCoverage
                        && !owner.sessionActionsAreRunning) else { return }
            nativeTurnID = nil
            settleNativeActivityLiveness()
            _ = beginOwnerGeneration()
            isStopping = false
            isSending = false
            pendingMidSessionSubmissions = []
            retryRequest = nil
            settleTaskDrawerAfterTurn()
        }
        persistSession()
    }

    /// Exact native idle authority ends parent activity even when a tool's
    /// completion was lost. Unknown tool outcomes stay neutral; independently
    /// running subagents stay live. Generic history merges cannot do this.
    private func settleNativeActivityLiveness() {
        let current = activityLedger.allEvents
        guard current.contains(where: { $0.kind != .subagent && $0.lifecycle == .running }) else { return }
        let settled = current.map { event in
            guard event.kind != .subagent, event.lifecycle == .running else { return event }
            return event.updating(lifecycle: event.kind == .tool ? .recorded : .succeeded,
                summary: event.summary, detail: event.detail, occurredAt: event.occurredAt)
        }
        activityLedger = ChatActivityLedger(sessionID: conversationID, events: settled)
        rebuildTranscript()
    }

    /// A disconnect can cancel a local waiter before its first native start.
    /// Only a later idle readback, with no client submission left, may settle it.
    func reconcileNativeIdle(from owner: DirectHermesConversationClient) {
        guard (client as? DirectHermesConversationClient) === owner,
              !owner.hasPendingSubmission,
              nativeTurnID == nil,
              hasLocallyPendingPrimaryTurn || hasRestoredPrimaryTurn else { return }
        _ = beginOwnerGeneration()
        isStopping = false
        isSending = false
        pendingMidSessionSubmissions = []
        retryRequest = nil
        settleTaskDrawerAfterTurn()
    }

    func suspendNativeTurn(from owner: DirectHermesConversationClient) {
        guard (client as? DirectHermesConversationClient) === owner else { return }
        // The run may still exist on the host. Keep its visible state, but a
        // cancelled local waiter must never finish it after reconnect adoption.
        _ = beginOwnerGeneration()
        isStopping = false
    }

    /// The adapter has already reconciled native identities and retained rows.
    /// Bypass Link hydration's inactive pending-message correlation entirely.
    func adoptNativeSnapshot(from owner: DirectHermesConversationClient, session: SessionRecord) {
        guard (client as? DirectHermesConversationClient) === owner,
              session.id == conversationID else { return }
        let hasSameContextOwner = sourceSession?.remoteStoredID == session.remoteStoredID
            && sourceSession?.remoteSource == session.remoteSource
            && sourceSession?.agentIDs == session.agentIDs
        if sourceSession != nil, !hasSameContextOwner {
            sessionTodos = nil
            taskDrawer = nil
        }
        sourceSession = session
        if let snapshot = session.sessionTodos { reconcileTodos(snapshot) }
        companionHistoryRevision &+= 1
        items = keepingDeliveredFiles(session.items)
        rebuildItemIndexes()
        activityLedger = ChatActivityLedger(sessionID: conversationID, events: session.activityEvents)
        if sessionTodos == nil, taskDrawer == nil {
            for event in activityLedger.allEvents {
                taskDrawer = ChatTodoProjection.applying(event, to: taskDrawer)
            }
        }
        if !session.isActive { settleNativeActivityLiveness() }
        nextTranscriptOrder = max(items.compactMap(\.metadata.sourceOrder).max() ?? 0,
            session.activityEvents.compactMap(\.sourceOrder).max() ?? 0) + 1
        nextHumanSequence = items.filter { $0.role == .human }.count + 1
        rebuildTranscript()
        scheduleGeneratedMediaResolutions()
    }

    /// Projects a Hermes turn started by another presentation surface, such as
    /// Voice, into the route-owned chat model. The chat then remains the shared
    /// owner of Stop/thinking presentation if that surface is dismissed.
    func beginExternallyOwnedTurn(with human: TimelineItem) {
        guard !isBotMode,
              !isSending,
              human.role == .human,
              senderBelongsToThisSession(human)
        else { return }
        _ = beginOwnerGeneration()
        hasLocallyPendingPrimaryTurn = true
        hasExternallyOwnedPrimaryTurn = true
        isSending = true
        failureMessage = nil
        retryRequest = nil
        if itemIndexByID[human.id] == nil {
            appendItem(ordered(human))
        }
        rebuildTranscript(from: human.metadata.sourceOrder)
        persistSession()
    }

    /// A final assistant message is Hermes' authoritative terminal signal for
    /// an externally owned turn. Merely dismissing its originating surface is
    /// deliberately not sufficient to retire the chat's running state.
    func acceptAuthoritativeTerminalForExternallyOwnedTurn(_ newItems: [TimelineItem]) {
        guard hasExternallyOwnedPrimaryTurn else { return }
        let hasTerminalAssistant = newItems.contains { item in
            item.role == .assistant
                && item.metadata.delivery != "Streaming"
                && senderBelongsToThisSession(item)
        }
        guard hasTerminalAssistant else { return }
        acceptExternal(newItems)
        _ = beginOwnerGeneration()
        pendingMidSessionSubmissions = []
        retryRequest = nil
        failureMessage = nil
        settleTaskDrawerAfterTurn()
        isStopping = false
        isSending = false
    }

    func finishExternallyOwnedTurnWithoutReply() {
        guard hasExternallyOwnedPrimaryTurn else { return }
        _ = beginOwnerGeneration()
        pendingMidSessionSubmissions = []
        settleTaskDrawerAfterTurn()
        isStopping = false
        isSending = false
    }

    func ownsReferenceSession(_ session: SessionRecord) -> Bool {
        !referenceOwnerRetired && session.id == conversationID
            && session.agentIDs == memberIDs
            && session.remoteStoredID == sourceSession?.remoteStoredID
            && session.remoteSource == sourceSession?.remoteSource
    }

    /// The native bridge verified the first durable catalog row against the
    /// exact live runtime. Adopt its previously absent source without treating
    /// that metadata enrichment as a new owner or replacing live state.
    func adoptNativeCatalogSource(
        from owner: DirectHermesConversationClient,
        previous: SessionRecord,
        next: SessionRecord
    ) -> Bool {
        guard nativeConversationClient === owner,
              previous.remoteSource == nil, next.remoteSource != nil,
              Data(previous.id.utf8) == Data(next.id.utf8),
              previous.agentIDs.map({ Data($0.utf8) }) == next.agentIDs.map({ Data($0.utf8) }),
              previous.remoteStoredID.map({ Data($0.utf8) }) == next.remoteStoredID.map({ Data($0.utf8) }),
              ownsReferenceSession(previous) else { return false }
        sourceSession?.remoteSource = next.remoteSource
        return true
    }

    func reassignDirectAgent(
        to agentID: String,
        client: any ConversationClient,
        runtimeControls: SessionRuntimeControlModel?,
        slashCommandCatalog: SlashCommandCatalogModel?
    ) {
        guard canReassignDirectAgent, !agentID.isEmpty else { return }
        if self.agentID != agentID {
            // This model deliberately survives an empty-chat agent selection.
            // Rebind reference review to the new recipient without retiring
            // the composer or discarding the user's unsent text.
            referenceOwner = nil
            referenceDraftID = nil
            referenceDraftRevision = nil
            referencePersistenceNeeded = true
        }
        self.agentID = agentID
        self.client = client
        self.runtimeControls = runtimeControls
        self.slashCommandCatalog = slashCommandCatalog
        if var sourceSession {
            sourceSession.agentIDs = [agentID]
            sourceSession.remoteStoredID = nil
            sourceSession.remoteSource = nil
            self.sourceSession = sourceSession
        }
        persistSession()
    }

    var currentUserSnapshot: TimelineSenderSnapshot {
        let identity = userIdentityStore?.identity ?? userIdentity
        return TimelineSenderSnapshot(name: identity.displayName, avatarFileName: identity.avatarFileName)
    }

    private func agentName(from item: TimelineItem?) -> String? {
        guard let item,
              item.role == .assistant,
              item.sender.kind == .agent
        else { return nil }

        // A restored timeline snapshot can be stale while the agent
        // directory is still loading. Resolve by the sender's exact id first
        // and retain the snapshot as the offline fallback.
        if let profileName = agentDirectory?.profiles
            .first(where: { $0.id == item.sender.id })?
            .name,
           let normalizedProfileName = normalizedAgentName(profileName) {
            return normalizedProfileName
        }
        return normalizedAgentName(item.sender.snapshot.name)
    }

    private func normalizedAgentName(_ value: String) -> String? {
        let normalized = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }


    struct NativeBotModeSendRecovery {
        let roomID: String
        let eventID: String
        let message: String
        let ownerGeneration: Int
        let nativeOwnerID: String
        let failureMessage: String?
    }

    enum RetryRequest {
        case send(String, [ChatAttachment])
        case botModeSend(String, String)
        case botModeRetry(String)
        case action(QuickAction)
    }

    enum ResponseIdentityError: Error {
        case collision
    }
}

enum ChatQueuedSubmissionError: Error, Equatable {
    case busy
    case invalidMessage
    case unavailable
}
