import Foundation

/// The negotiated Hermes hosted-room capability response. These fields mirror
/// `groups.capabilities`; the Link client owns transport and error mapping.
struct HermesBotModeCapabilities: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let driver: Bool
    let persistentProcess: Bool
    let authorityGatewayID: String
    let roomLink: [String: BighelpJSONValue]
    let features: [String]
    let methods: [String]
    let maxLogLimit: Int

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case driver
        case persistentProcess = "persistent_process"
        case authorityGatewayID = "authority_gateway_id"
        case roomLink = "room_link"
        case features
        case methods
        case maxLogLimit = "max_log_limit"
    }

    func supports(_ operation: String) -> Bool {
        methods.contains(operation)
    }

    var supportsNativeExecution: Bool {
        protocolVersion == 2
            && driver
            && !authorityGatewayID.isEmpty
            && Self.requiredOperations.allSatisfy(supports)
            && Self.requiredFeatures.allSatisfy(features.contains)
    }

    static let requiredOperations: [String] = [
        "groups.capabilities",
        "groups.create",
        "groups.state",
        "groups.send",
        "groups.log",
        "groups.stop",
        "groups.retry",
        "groups.approve",
    ]

    static let requiredFeatures: [String] = [
        "typed_events",
        "idempotent_send",
        "monotonic_log",
        "coordinator_fencing",
    ]
}

/// The exact roster member object accepted by Hermes `groups.create`.
struct HermesBotModeRoomMember: Codable, Equatable, Sendable {
    let memberID: String
    let profile: String
    let handle: String
    let displayName: String?
    let target: [String: BighelpJSONValue]

    private enum CodingKeys: String, CodingKey {
        case memberID = "member_id"
        case profile
        case handle
        case displayName = "display_name"
        case target
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        memberID = try container.decode(String.self, forKey: .memberID)
        profile = try container.decode(String.self, forKey: .profile)
        handle = try container.decode(String.self, forKey: .handle)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        // Hermes reads a member without a target as local to its profile
        // (`_validate_member_target`); rooms saved before it stored targets
        // have none, and one such room must not fail the whole catalog.
        target = try container.decodeIfPresent([String: BighelpJSONValue].self, forKey: .target)
            ?? ["kind": .string("local"), "profile": .string(profile)]
    }

    init(member: BotModeMember) {
        memberID = member.id
        profile = member.profileID
        handle = member.handle
        displayName = nil
        target = [
            "kind": .string("local"),
            "profile": .string(member.profileID),
        ]
    }

    init(
        memberID: String,
        profile: String,
        handle: String,
        displayName: String? = nil,
        target: [String: BighelpJSONValue]
    ) {
        self.memberID = memberID
        self.profile = profile
        self.handle = handle
        self.displayName = displayName
        self.target = target
    }
}

struct HermesBotModeRoomState: Codable, Equatable, Sendable {
    let roomID: String
    let name: String
    let members: [HermesBotModeRoomMember]
    let authorityGatewayID: String
    let authorityEpoch: Int
    let revision: Int
    let createdAt: Double
    let updatedAt: Double
    let latestSequence: Int?
    let disbandedAt: Double?
    let driverStatus: [String: BighelpJSONValue]?

    var persistentMetadata: Self {
        Self(
            roomID: roomID, name: name, members: members,
            authorityGatewayID: authorityGatewayID, authorityEpoch: authorityEpoch,
            revision: revision, createdAt: createdAt, updatedAt: updatedAt,
            latestSequence: latestSequence, disbandedAt: disbandedAt, driverStatus: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case name
        case members
        case authorityGatewayID = "authority_gateway_id"
        case authorityEpoch = "authority_epoch"
        case revision
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case latestSequence = "latest_seq"
        case disbandedAt = "disbanded_at"
        case driverStatus = "driver_status"
    }
}

struct HermesBotModeAuthority: Codable, Equatable, Sendable {
    let gatewayID: String
    let epoch: Int

    private enum CodingKeys: String, CodingKey {
        case gatewayID = "gateway_id"
        case epoch
    }
}

/// One typed, server-authored event from `groups.log`.
struct HermesBotModeEvent: Codable, Equatable, Sendable {
    let roomID: String
    let sequence: Int
    let eventID: String
    let kind: String
    let actor: [String: BighelpJSONValue]
    let authorityEpoch: Int?
    let payload: [String: BighelpJSONValue]
    let createdAt: Double

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case sequence = "seq"
        case eventID = "event_id"
        case kind
        case actor
        case authorityEpoch = "authority_epoch"
        case payload
        case createdAt = "created_at"
    }

    var text: String? { payload["text"]?.string }
    var memberID: String? { payload["member_id"]?.string }
    var discussionEventID: String? { payload["discussion_event_id"]?.string }
    var taskID: String? { payload["task_id"]?.string }
    var threadID: String? { payload["thread_id"]?.string }
    var turnID: String? { payload["turn_id"]?.string }
    var memberIndex: Int? { payload["member_index"]?.integer }
    var roundIndex: Int? { payload["round_index"]?.integer }
    var seenThroughSequence: Int? { payload["seen_through_seq"]?.integer }
    var executionGeneration: Int? { payload["execution_generation"]?.integer }
    var passed: Bool? { payload["passed"]?.boolean }
    var messageEventID: String? { payload["message_event_id"]?.string }

    func botModeEvent(sourceOrder: Int) -> BotModeEvent? {
        let timestamp = Date(timeIntervalSince1970: createdAt)
        switch kind {
        case "message.user":
            guard let text else { return nil }
            var event = BotModeEvent.human(text: text, id: eventID, timestamp: timestamp, sourceOrder: sourceOrder)
            event.nativeEvent = self
            return event
        case "message.member":
            guard let memberID, let text else { return nil }
            var event = BotModeEvent.agent(memberID: memberID, text: text, id: eventID, timestamp: timestamp, sourceOrder: sourceOrder)
            event.nativeEvent = self
            return event
        default:
            return nil
        }
    }
}

struct HermesBotModeLogPage: Codable, Equatable, Sendable {
    let events: [HermesBotModeEvent]
    let cursor: Int
    let latestSequence: Int
    let hasMore: Bool
    let authority: HermesBotModeAuthority

    private enum CodingKeys: String, CodingKey {
        case events
        case cursor
        case latestSequence = "latest_seq"
        case hasMore = "has_more"
        case authority
    }
}

struct HermesBotModeUserPayload: Codable, Equatable, Sendable {
    let text: String
    let threadID: String

    private enum CodingKeys: String, CodingKey {
        case text
        case threadID = "thread_id"
    }
}

struct HermesBotModeSendResult: Codable, Equatable, Sendable {
    let event: HermesBotModeEvent
    let clientEventID: String
    let accepted: Bool
    let driverStarted: Bool

    private enum CodingKeys: String, CodingKey {
        case event
        case clientEventID = "client_event_id"
        case accepted
        case driverStarted = "driver_started"
    }
}

struct HermesBotModeTaskReceipt: Codable, Equatable, Sendable {
    let roomID: String
    let taskID: String
    let threadID: String
    let turnID: String
    let status: String
    let executionGeneration: Int
    let cancelGeneration: Int

    private enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case taskID = "task_id"
        case threadID = "thread_id"
        case turnID = "turn_id"
        case status
        case executionGeneration = "execution_generation"
        case cancelGeneration = "cancel_generation"
    }
}

struct HermesBotModeRetryResult: Codable, Equatable, Sendable {
    let retried: Bool
    let task: HermesBotModeTaskReceipt
}

@MainActor
protocol HermesBotModeClient: AnyObject {
    func groupsCapabilities() async throws -> HermesBotModeCapabilities
    func groupsCreate(
        roomID: String,
        name: String,
        members: [HermesBotModeRoomMember]
    ) async throws -> HermesBotModeRoomState
    func groupsState(roomID: String, includeDisbanded: Bool) async throws -> HermesBotModeRoomState
    func groupsSend(
        roomID: String,
        eventID: String,
        payload: HermesBotModeUserPayload
    ) async throws -> HermesBotModeSendResult
    func groupsLog(
        roomID: String,
        sinceSequence: Int,
        limit: Int,
        includeDisbanded: Bool
    ) async throws -> HermesBotModeLogPage
    func groupsStop(roomID: String, cancelID: String) async throws
    func groupsRetry(roomID: String, taskID: String) async throws -> HermesBotModeRetryResult
}

enum BotModeRoomError: Error, Equatable {
    case invalidDirectSession
    case invalidMember
    case roomNotFound
    case runAlreadyActive
    case noRetryableFailure
    case persistenceConflict
    case sharedHistoryRequiresBotMode
    case executionUnavailable
    case nativeSendRejected
    case nativeRetryRejected
    case nativeApprovalStale
    case nativeApprovalRejected
    case nativeAuthorityMismatch
    case nativeTurnTimedOut
    case nativeMembershipImmutable
}

enum BotModePersistenceError: Error, Equatable {
    case writeFailed
    case unsupportedNativeSchema
}

struct BotModeRunOwner: Codable, Equatable, Sendable {
    let instanceID: String
    let generation: Int

    var runID: String { "\(instanceID)-\(generation)" }
}

struct BotModeRunActivity: Equatable, Sendable {
    let eventID: String
    let runID: String
    let turnID: String
    let memberID: String
    let memberHandle: String
    let fromMemberID: String?
    let fromMemberHandle: String?
    let lifecycle: ChatActivityLifecycle
    let summary: String
    let detail: String?
    let occurredAt: Int
    let sourceOrder: Int
}

enum BotModeRunOwnerExpectation: Equatable {
    case noOwner
    case owner(BotModeRunOwner)
}

enum BotModeMemberChange: Equatable {
    case added
    case alreadyMember
    case atCapacity
    case removed
    case wouldBecomeEmpty
}

struct BotModeMember: Identifiable, Codable, Equatable, Sendable {
    let profileID: String
    let handle: String
    let sessionID: String
    var nativeMemberID: String? = nil

    var id: String { nativeMemberID ?? profileID }
}

struct BotModeMemberContext: Codable, Equatable, Sendable {
    let sessionID: String
    var messages: [BotModeEvent]
    var sharedWatermark: String?

    init(sessionID: String, messages: [BotModeEvent], sharedWatermark: String? = nil) {
        self.sessionID = sessionID
        self.messages = messages
        self.sharedWatermark = sharedWatermark
    }
}

struct BotModeMemberFailure: Codable, Equatable, Sendable {
    let memberID: String
    let message: String
    let taskID: String?
    let status: String?
    let discussionEventID: String?
    let threadID: String?
    let turnID: String?
    let executionGeneration: Int?
    let cancelGeneration: Int?

    init(
        memberID: String,
        message: String,
        taskID: String? = nil,
        status: String? = nil,
        discussionEventID: String? = nil,
        threadID: String? = nil,
        turnID: String? = nil,
        executionGeneration: Int? = nil,
        cancelGeneration: Int? = nil
    ) {
        self.memberID = memberID
        self.message = message
        self.taskID = taskID
        self.status = status
        self.discussionEventID = discussionEventID
        self.threadID = threadID
        self.turnID = turnID
        self.executionGeneration = executionGeneration
        self.cancelGeneration = cancelGeneration
    }
}

struct BotModeEvent: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case botModeStarted
        case human
        case agent
    }

    let id: String
    let kind: Kind
    let memberID: String?
    let text: String?
    let timestamp: Date?
    let sourceOrder: Int?
    var nativeEvent: HermesBotModeEvent? = nil

    static func botModeStarted(id: String = UUID().uuidString, sourceOrder: Int? = nil) -> Self {
        Self(id: id, kind: .botModeStarted, memberID: nil, text: nil, timestamp: nil, sourceOrder: sourceOrder)
    }

    static func human(
        text: String,
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        sourceOrder: Int? = nil
    ) -> Self {
        Self(
            id: id,
            kind: .human,
            memberID: UserIdentity.stableID,
            text: text,
            timestamp: timestamp,
            sourceOrder: sourceOrder
        )
    }

    static func agent(
        memberID: String,
        text: String,
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        sourceOrder: Int? = nil
    ) -> Self {
        Self(
            id: id,
            kind: .agent,
            memberID: memberID,
            text: text,
            timestamp: timestamp,
            sourceOrder: sourceOrder
        )
    }

    static func privateContextEvent(from item: TimelineItem) -> Self {
        let text: String? = if case .message(let message) = item.content { message } else { nil }
        switch item.role {
        case .human:
            return Self(
                id: item.id,
                kind: .human,
                memberID: UserIdentity.stableID,
                text: text,
                timestamp: item.metadata.timestamp,
                sourceOrder: item.metadata.sourceOrder
            )
        case .assistant:
            return Self(
                id: item.id,
                kind: .agent,
                memberID: item.sender.id,
                text: text,
                timestamp: item.metadata.timestamp,
                sourceOrder: item.metadata.sourceOrder
            )
        }
    }
}

struct BotModeRoom: Identifiable, Codable, Equatable, Sendable {
    static let maximumMembers = 6
    static let maximumVisibleEvents = 200
    static let maximumContextMessages = 120

    private enum CodingKeys: String, CodingKey {
        case id
        case directSessionID
        case members
        case privateHistory
        case visibleEvents
        case memberContexts
        case retiredHandles
        case memberFailures
        case isRunning
        case runOwner
        case persistenceRevision
        case nativeRoomID
        case nativeLogCursor
        case nativeAuthorityGatewayID
        case nativeAuthorityEpoch
        case nativePendingEventID
        case nativePendingThreadID
        case nativePendingText
        case nativePendingDiscussionEventID
        case nativeCompletedDiscussionEventIDs
        case nativeState
        case nativePendingSenderSnapshot
        case nativeOwnEventSenders
        case nativePendingRename
        case nativePendingCreation
        case nativeRetryJournal
        case nativePendingCancelID
        case nativeFollowUps
        case nativePendingPeerLinks
    }

    let id: String
    let directSessionID: String?
    private(set) var members: [BotModeMember]
    private(set) var privateHistory: [TimelineItem]
    private(set) var visibleEvents: [BotModeEvent]
    private(set) var memberContexts: [String: BotModeMemberContext]
    // This is the sole departed-member registry: it preserves the room-assigned
    // alias required for a later re-add, without retaining a hidden session,
    // context, watermark, failure, or private member history.
    private var retiredHandles: [String: String]
    private(set) var memberFailures: [BotModeMemberFailure]
    var isRunning: Bool
    private(set) var runOwner: BotModeRunOwner?
    private(set) var persistenceRevision: Int
    /// Hermes owns the room after the first successful `groups.create`.
    /// `nil` means the local roster is still a pre-send staging roster.
    private(set) var nativeRoomID: String?
    private(set) var nativeLogCursor: Int
    private(set) var nativeAuthorityGatewayID: String?
    private(set) var nativeAuthorityEpoch: Int?
    /// A durable idempotency reservation for a send interrupted after local
    /// persistence but before the Link response is received.
    private(set) var nativePendingEventID: String?
    private(set) var nativePendingThreadID: String?
    private(set) var nativePendingText: String?
    /// The server event ID returned by `groups.send`. Hermes room.activity
    /// correlates against this canonical discussion ID, while
    /// `nativePendingEventID` remains the client idempotency key.
    private(set) var nativePendingDiscussionEventID: String?
    /// Durable completion evidence retained across a receipt/log race. Hermes
    /// room.activity IDs are authoritative; this list lets a later receipt
    /// reconciliation settle a discussion whose terminal event was replayed
    /// before its canonical send receipt was persisted.
    private(set) var nativeCompletedDiscussionEventIDs: [String]
    private(set) var nativeState: HermesBotModeRoomState?
    private(set) var nativePendingSenderSnapshot: TimelineSenderSnapshot?
    private(set) var nativeOwnEventSenders: [String: TimelineSenderSnapshot]
    private(set) var nativePendingRename: HermesBotModeRenameIntent?
    private(set) var nativePendingCreation: HermesBotModeCreationIntent?
    private(set) var nativeRetryJournal: HermesBotModeRetryJournal?
    private(set) var nativePendingCancelID: String?
    /// Messages sent while the room was already working. Hermes queues each
    /// behind the active drive; each keeps its own idempotency key until its
    /// discussion settles.
    private(set) var nativeFollowUps: [HermesBotModeFollowUp]
    /// Agents on other computers this room still has to link (RoomLink). Kept
    /// until each is registered, so setup can continue after a relaunch.
    private(set) var nativePendingPeerLinks: [HermesBotModePeerLink]

    init(
        id: String,
        directSessionID: String? = nil,
        members: [BotModeMember],
        privateHistory: [TimelineItem] = [],
        visibleEvents: [BotModeEvent] = [.botModeStarted()],
        memberContexts: [String: BotModeMemberContext]? = nil,
        retiredHandles: [String: String] = [:],
        memberFailures: [BotModeMemberFailure] = [],
        isRunning: Bool = false,
        runOwner: BotModeRunOwner? = nil,
        persistenceRevision: Int = 0,
        nativeRoomID: String? = nil,
        nativeLogCursor: Int = 0,
        nativeAuthorityGatewayID: String? = nil,
        nativeAuthorityEpoch: Int? = nil,
        nativePendingEventID: String? = nil,
        nativePendingThreadID: String? = nil,
        nativePendingText: String? = nil,
        nativePendingDiscussionEventID: String? = nil,
        nativeCompletedDiscussionEventIDs: [String] = [],
        nativeState: HermesBotModeRoomState? = nil,
        nativePendingSenderSnapshot: TimelineSenderSnapshot? = nil,
        nativeOwnEventSenders: [String: TimelineSenderSnapshot] = [:],
        nativePendingRename: HermesBotModeRenameIntent? = nil,
        nativePendingCreation: HermesBotModeCreationIntent? = nil,
        nativeRetryJournal: HermesBotModeRetryJournal? = nil,
        nativePendingCancelID: String? = nil,
        nativeFollowUps: [HermesBotModeFollowUp] = [],
        nativePendingPeerLinks: [HermesBotModePeerLink] = []
    ) throws {
        let memberIDs = members.map(\.id)
        guard !id.isEmpty, !memberIDs.isEmpty,
              nativeRoomID.map({ $0 == id }) ?? true,
              nativeState.map({ $0.roomID == id && nativeRoomID == id }) ?? true,
              memberIDs.count <= (nativeRoomID == nil ? Self.maximumMembers : 128),
              Set(memberIDs).count == memberIDs.count,
              members.allSatisfy({
                  !$0.handle.isEmpty && (nativeRoomID != nil || nativePendingCreation != nil || !$0.sessionID.isEmpty)
              }) else {
            throw BotModeRoomError.invalidMember
        }
        self.id = id
        self.directSessionID = directSessionID
        self.members = members
        self.privateHistory = privateHistory
        let validMemberIDs = Set(memberIDs)
        // Hermes owns the complete native log. Keep the decoded cache intact so
        // a persisted cursor can still replay and render older native messages,
        // including those of members who have since left the room: the cursor
        // is already past them, so a dropped one never comes back. The local
        // fixture harness retains its roster-bound, bounded transcript contract.
        self.visibleEvents = nativeRoomID != nil ? visibleEvents : Self.boundedVisibleEvents(visibleEvents.filter { event in
            event.kind != .agent || (event.memberID.map(validMemberIDs.contains) ?? false)
        })
        let contexts = memberContexts ?? Dictionary(
            uniqueKeysWithValues: members.map { ($0.id, BotModeMemberContext(sessionID: $0.sessionID, messages: [])) }
        )
        self.memberContexts = Dictionary(uniqueKeysWithValues: members.map { member in
            let context = contexts[member.id] ?? BotModeMemberContext(sessionID: member.sessionID, messages: [])
            return (
                member.id,
                BotModeMemberContext(
                    sessionID: context.sessionID,
                    messages: Self.bounded(context.messages.filter { event in
                        event.kind != .agent || (event.memberID.map(validMemberIDs.contains) ?? false)
                    }, limit: Self.maximumContextMessages),
                    sharedWatermark: context.sharedWatermark
                )
            )
        })
        if nativeRoomID != nil { self.memberContexts = [:] }
        self.retiredHandles = retiredHandles
        self.memberFailures = memberFailures
        let hasConsistentRun = isRunning && runOwner != nil
        self.isRunning = hasConsistentRun
        self.runOwner = hasConsistentRun ? runOwner : nil
        self.persistenceRevision = persistenceRevision
        self.nativeRoomID = nativeRoomID
        self.nativeLogCursor = max(0, nativeLogCursor)
        self.nativeAuthorityGatewayID = nativeAuthorityGatewayID
        self.nativeAuthorityEpoch = nativeAuthorityEpoch
        self.nativePendingEventID = nativePendingEventID
        self.nativePendingThreadID = nativePendingThreadID
        self.nativePendingText = nativePendingText
        self.nativePendingDiscussionEventID = nativePendingDiscussionEventID
        self.nativeCompletedDiscussionEventIDs = Array(nativeCompletedDiscussionEventIDs.suffix(128))
        self.nativeState = nativeState?.persistentMetadata
        self.nativePendingSenderSnapshot = nativePendingSenderSnapshot
        self.nativeOwnEventSenders = nativeOwnEventSenders
        self.nativePendingRename = nativePendingRename
        self.nativePendingCreation = nativePendingCreation
        self.nativeRetryJournal = nativeRetryJournal
        self.nativePendingCancelID = nativePendingCancelID
        self.nativeFollowUps = nativeRoomID == nil ? [] : Array(nativeFollowUps.prefix(HermesBotModeFollowUp.maximumPending))
        self.nativePendingPeerLinks = Array(nativePendingPeerLinks.prefix(Self.maximumMembers))
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let members = try container.decode([BotModeMember].self, forKey: .members)
        let runOwner = try container.decodeIfPresent(BotModeRunOwner.self, forKey: .runOwner)
        let isRunning = try container.decodeIfPresent(Bool.self, forKey: .isRunning) ?? (runOwner != nil)

        try self.init(
            id: id,
            directSessionID: try container.decodeIfPresent(String.self, forKey: .directSessionID),
            members: members,
            privateHistory: try container.decodeIfPresent([TimelineItem].self, forKey: .privateHistory) ?? [],
            visibleEvents: try container.decodeIfPresent([BotModeEvent].self, forKey: .visibleEvents)
                ?? [.botModeStarted(id: "bot-mode-started-\(id)")],
            memberContexts: try container.decodeIfPresent(
                [String: BotModeMemberContext].self,
                forKey: .memberContexts
            ),
            retiredHandles: try container.decodeIfPresent(
                [String: String].self,
                forKey: .retiredHandles
            ) ?? [:],
            memberFailures: try container.decodeIfPresent(
                [BotModeMemberFailure].self,
                forKey: .memberFailures
            ) ?? [],
            isRunning: isRunning,
            runOwner: runOwner,
            persistenceRevision: try container.decodeIfPresent(Int.self, forKey: .persistenceRevision) ?? 0,
            nativeRoomID: try container.decodeIfPresent(String.self, forKey: .nativeRoomID),
            nativeLogCursor: try container.decodeIfPresent(Int.self, forKey: .nativeLogCursor) ?? 0,
            nativeAuthorityGatewayID: try container.decodeIfPresent(String.self, forKey: .nativeAuthorityGatewayID),
            nativeAuthorityEpoch: try container.decodeIfPresent(Int.self, forKey: .nativeAuthorityEpoch),
            nativePendingEventID: try container.decodeIfPresent(String.self, forKey: .nativePendingEventID),
            nativePendingThreadID: try container.decodeIfPresent(String.self, forKey: .nativePendingThreadID),
            nativePendingText: try container.decodeIfPresent(String.self, forKey: .nativePendingText),
            nativePendingDiscussionEventID: try container.decodeIfPresent(
                String.self,
                forKey: .nativePendingDiscussionEventID
            ),
            nativeCompletedDiscussionEventIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .nativeCompletedDiscussionEventIDs
            ) ?? [],
            nativeState: try container.decodeIfPresent(HermesBotModeRoomState.self, forKey: .nativeState),
            nativePendingSenderSnapshot: try container.decodeIfPresent(TimelineSenderSnapshot.self, forKey: .nativePendingSenderSnapshot),
            nativeOwnEventSenders: try container.decodeIfPresent([String: TimelineSenderSnapshot].self, forKey: .nativeOwnEventSenders) ?? [:],
            nativePendingRename: try container.decodeIfPresent(HermesBotModeRenameIntent.self, forKey: .nativePendingRename),
            nativePendingCreation: try container.decodeIfPresent(HermesBotModeCreationIntent.self, forKey: .nativePendingCreation),
            nativeRetryJournal: try container.decodeIfPresent(HermesBotModeRetryJournal.self, forKey: .nativeRetryJournal),
            nativePendingCancelID: try container.decodeIfPresent(String.self, forKey: .nativePendingCancelID),
            nativeFollowUps: try container.decodeIfPresent([HermesBotModeFollowUp].self, forKey: .nativeFollowUps) ?? [],
            nativePendingPeerLinks: try container.decodeIfPresent(
                [HermesBotModePeerLink].self, forKey: .nativePendingPeerLinks
            ) ?? []
        )
    }

    var memberIDs: [String] { members.map(\.id) }
    var profileIDs: [String] {
        members.reduce(into: [String]()) { ids, member in
            if !ids.contains(member.profileID) { ids.append(member.profileID) }
        }
    }
    var title: String { nativeState?.name ?? nativePendingCreation?.name ?? "Group chat" }

    var hasSharedConversation: Bool {
        visibleEvents.contains { $0.kind == .human || $0.kind == .agent }
    }

    var hasNativeRoom: Bool { nativeRoomID != nil }

    /// Hermes' current groups contract has no roster mutation operation. The
    /// local roster is editable only until the first remote room is created.
    var canEditMembership: Bool { nativeRoomID == nil && nativePendingCreation == nil }

    mutating func setNativeRenameIntent(_ intent: HermesBotModeRenameIntent?) {
        nativePendingRename = intent
    }

    mutating func setNativeCreationIntent(_ intent: HermesBotModeCreationIntent?) {
        nativePendingCreation = intent
    }

    mutating func setNativePendingPeerLinks(_ links: [HermesBotModePeerLink]) {
        nativePendingPeerLinks = Array(links.prefix(Self.maximumMembers))
    }

    mutating func setNativeRetryJournal(_ journal: HermesBotModeRetryJournal?) {
        nativeRetryJournal = journal
    }

    mutating func setNativeCancelIntent(_ cancelID: String?) {
        nativePendingCancelID = cancelID
    }

    func member(id: String) -> BotModeMember? {
        members.first(where: { $0.id == id })
    }

    func handle(for profile: AgentProfile, nativeHandles: Bool = false) -> String {
        member(id: profile.id)?.handle ?? nextHandle(base: nativeHandles
            ? NativeBotModeHandles.preferred(profileID: profile.id, name: profile.name)
            : AgentHandle.normalized(profile.name))
    }

    static func fromDirect(session: SessionRecord, adding memberID: String) throws -> Self {
        try fromDirect(session: session, adding: memberID, profiles: [])
    }

    static func fromDirect(
        session: SessionRecord,
        adding memberID: String,
        profiles: [AgentProfile],
        nativeHandles: Bool = false
    ) throws -> Self {
        guard session.kind == .direct, session.agentIDs.count == 1,
              let originalID = session.agentIDs.first, !memberID.isEmpty, memberID != originalID else {
            throw BotModeRoomError.invalidDirectSession
        }
        let handles = nativeHandles ? NativeBotModeHandles.directory(for: profiles) : AgentHandle.directory(for: profiles)
        let original = makeMember(
            id: originalID,
            handle: handles.first(where: { $0.profileID == originalID })?.handle,
            sessionID: session.id
        )
        let added = makeMember(
            id: memberID,
            handle: handles.first(where: { $0.profileID == memberID })?.handle,
            sessionID: "\(session.id)-\(memberID)"
        )
        return try Self(
            id: "bot-\(session.id)",
            directSessionID: session.id,
            members: [original, added],
            privateHistory: session.items,
            visibleEvents: [.botModeStarted(id: "bot-mode-started-\(session.id)")],
            memberContexts: [
                originalID: BotModeMemberContext(
                    sessionID: original.sessionID,
                    messages: session.items.map(BotModeEvent.privateContextEvent)
                ),
                memberID: BotModeMemberContext(sessionID: added.sessionID, messages: [])
            ]
        )
    }

    static func fixture(id: String = "room-fixture", memberIDs: [String]) -> Self {
        try! Self(
            id: id,
            members: memberIDs.map { makeMember(id: $0, sessionID: "hidden-\($0)") },
            visibleEvents: [.botModeStarted(id: "bot-mode-started-\(id)")]
        )
    }

    mutating func add(memberID: String) throws -> BotModeMemberChange {
        try add(memberID: memberID, preferredHandle: AgentHandle.normalized(memberID))
    }

    mutating func add(profile: AgentProfile, nativeHandles: Bool = false) throws -> BotModeMemberChange {
        try add(
            memberID: profile.id,
            preferredHandle: nativeHandles
                ? NativeBotModeHandles.preferred(profileID: profile.id, name: profile.name)
                : AgentHandle.normalized(profile.name),
            nativeHandles: nativeHandles
        )
    }

    private mutating func add(memberID: String, preferredHandle: String, nativeHandles: Bool = false) throws -> BotModeMemberChange {
        guard !memberID.isEmpty else { throw BotModeRoomError.invalidMember }
        guard !memberIDs.contains(memberID) else { return .alreadyMember }
        guard members.count < Self.maximumMembers else { return .atCapacity }

        let member = Self.makeMember(
            id: memberID,
            handle: retiredHandles[memberID].flatMap {
                isHandleAvailable($0) && (!nativeHandles || (HermesBotModeWireCodec.identifier($0)
                    && !["all", "everyone"].contains($0))) ? $0 : nil
            }
                ?? nextHandle(base: preferredHandle),
            sessionID: "\(id)-\(memberID)"
        )
        members.append(member)
        memberContexts[memberID] = BotModeMemberContext(
            sessionID: member.sessionID,
            messages: Self.bounded(visibleEvents, limit: Self.maximumContextMessages)
        )
        return .added
    }

    mutating func remove(memberID: String) throws -> BotModeMemberChange {
        guard let index = members.firstIndex(where: { $0.profileID == memberID }) else { return .removed }
        guard members.count > 1 else { return .wouldBecomeEmpty }
        let removed = members.remove(at: index)
        retiredHandles[memberID] = removed.handle
        memberContexts[memberID] = nil
        memberFailures.removeAll { $0.memberID == memberID }
        return .removed
    }

    mutating func appendVisible(_ event: BotModeEvent) {
        visibleEvents = Self.boundedVisibleEvents(visibleEvents + [event])
    }

    mutating func appendShared(_ event: BotModeEvent) {
        appendVisible(event)
        for member in members {
            var context = memberContexts[member.profileID] ?? BotModeMemberContext(sessionID: member.sessionID, messages: [])
            context.messages = Self.bounded(context.messages + [event], limit: Self.maximumContextMessages)
            context.sharedWatermark = event.id
            memberContexts[member.profileID] = context
        }
    }

    /// Appends a server-authored Hermes event without applying the local
    /// fixture transcript cap. `nativeLogCursor` is the authoritative bound
    /// for replay, so truncating this cache would make persisted rooms lose
    /// history after relaunch.
    mutating func appendNativeShared(_ event: BotModeEvent) {
        guard !visibleEvents.contains(where: { $0.id == event.id }) else { return }
        visibleEvents.append(event)
    }

    mutating func replaceFailures(with failures: [BotModeMemberFailure]) {
        memberFailures = failures
    }

    mutating func recoverFromPersistedRun() {
        isRunning = false
        runOwner = nil
    }

    mutating func beginRun(owner: BotModeRunOwner?) {
        runOwner = owner
        isRunning = owner != nil
    }

    mutating func settleRun() {
        isRunning = false
        runOwner = nil
    }

    mutating func markPersisted(revision: Int) {
        persistenceRevision = revision
    }

    mutating func markNativeRoom(_ state: HermesBotModeRoomState) {
        nativeRoomID = state.roomID
        nativeAuthorityGatewayID = state.authorityGatewayID
        nativeAuthorityEpoch = state.authorityEpoch
        nativeState = state.persistentMetadata
        memberContexts = [:]
        if !state.members.isEmpty {
            members = state.members.map {
                BotModeMember(profileID: $0.profile, handle: $0.handle, sessionID: "", nativeMemberID: $0.memberID)
            }
        }
    }

    mutating func advanceNativeLog(to cursor: Int) {
        nativeLogCursor = max(nativeLogCursor, cursor)
    }

    mutating func prepareNativeTurn(
        eventID: String, threadID: String, text: String, owner: BotModeRunOwner,
        senderSnapshot: TimelineSenderSnapshot? = nil
    ) {
        nativePendingEventID = eventID
        nativePendingThreadID = threadID
        nativePendingText = text
        nativePendingDiscussionEventID = nil
        nativePendingSenderSnapshot = senderSnapshot ?? nativePendingSenderSnapshot
        beginRun(owner: owner)
    }

    mutating func markNativeDiscussion(eventID: String) {
        nativePendingDiscussionEventID = eventID
        if let nativePendingSenderSnapshot {
            nativeOwnEventSenders[eventID] = nativePendingSenderSnapshot
        }
    }

    mutating func markNativeDiscussionCompleted(eventID: String) {
        guard !eventID.isEmpty, !nativeCompletedDiscussionEventIDs.contains(eventID) else { return }
        nativeCompletedDiscussionEventIDs.append(eventID)
        if nativeCompletedDiscussionEventIDs.count > 128 {
            nativeCompletedDiscussionEventIDs.removeFirst(nativeCompletedDiscussionEventIDs.count - 128)
        }
    }

    mutating func queueNativeFollowUp(_ followUp: HermesBotModeFollowUp) {
        guard !nativeFollowUps.contains(where: { $0.eventID == followUp.eventID }) else { return }
        nativeFollowUps.append(followUp)
    }

    /// Records Hermes' receipt. A discussion that already settled needs no tracking.
    mutating func markNativeFollowUpReceipt(eventID: String, discussionEventID: String) {
        guard let index = nativeFollowUps.firstIndex(where: { $0.eventID == eventID }) else { return }
        if let snapshot = nativeFollowUps[index].senderSnapshot {
            nativeOwnEventSenders[discussionEventID] = snapshot
        }
        nativeFollowUps[index].discussionEventID = discussionEventID
        if nativeCompletedDiscussionEventIDs.contains(discussionEventID) {
            settleNativeFollowUps(completedDiscussionID: discussionEventID)
        }
    }

    /// A settled follow-up also ends every message sent before it: Hermes
    /// supersedes older discussions in the thread. One still waiting for its
    /// receipt keeps its key for recovery. False when it isn't a follow-up.
    @discardableResult
    mutating func settleNativeFollowUps(completedDiscussionID: String) -> Bool {
        guard let index = nativeFollowUps.firstIndex(where: { $0.discussionEventID == completedDiscussionID }) else {
            return false
        }
        nativeFollowUps = nativeFollowUps[...index].filter { $0.discussionEventID == nil }
            + nativeFollowUps[(index + 1)...]
        return true
    }

    @discardableResult
    mutating func removeNativeFollowUp(eventID: String) -> Bool {
        let before = nativeFollowUps.count
        nativeFollowUps.removeAll { $0.eventID == eventID }
        return nativeFollowUps.count != before
    }

    /// Hermes is still working on something this phone sent: a running
    /// turn, or messages sent while it ran.
    var isNativeWorking: Bool {
        hasNativeRoom && (isRunning || !nativeFollowUps.isEmpty)
    }

    mutating func clearNativeFollowUps() {
        nativeFollowUps.removeAll()
    }

    /// Follow-ups Hermes accepted whose discussions are still running.
    var hasUnsettledNativeFollowUps: Bool {
        nativeFollowUps.contains { $0.discussionEventID != nil }
    }

    mutating func clearNativeTurn() {
        nativePendingEventID = nil
        nativePendingThreadID = nil
        nativePendingText = nil
        nativePendingDiscussionEventID = nil
        nativePendingSenderSnapshot = nil
    }

    private func nextHandle(base: String) -> String {
        let occupied = Set(
            members.map { $0.handle.lowercased() }
                + retiredHandles.values.map { $0.lowercased() }
        )
        var candidate = base
        var suffix = 2
        while occupied.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func isHandleAvailable(_ handle: String) -> Bool {
        !members.contains { $0.handle.caseInsensitiveCompare(handle) == .orderedSame }
    }

    private static func makeMember(id: String, handle: String? = nil, sessionID: String) -> BotModeMember {
        BotModeMember(profileID: id, handle: handle ?? AgentHandle.normalized(id), sessionID: sessionID)
    }

    private static func bounded<T>(_ values: [T], limit: Int) -> [T] {
        Array(values.suffix(limit))
    }

    private static func boundedVisibleEvents(_ events: [BotModeEvent]) -> [BotModeEvent] {
        guard events.count > maximumVisibleEvents else { return events }
        guard let boundary = events.first(where: { $0.kind == .botModeStarted }) else {
            return Array(events.suffix(maximumVisibleEvents))
        }
        return [boundary] + events.filter { $0.id != boundary.id }.suffix(maximumVisibleEvents - 1)
    }
}
