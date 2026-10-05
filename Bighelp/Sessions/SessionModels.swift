import CryptoKit
import Foundation

enum SessionKind: String, Codable, Equatable, Sendable {
    case direct
    case botMode
}

enum SessionCatalogError: Error, Equatable, Sendable {
    case invalidSession
    case invalidTitle
}

enum SessionTitleRules {
    static let maximumLength = 100

    static func validated(_ value: String) throws -> String {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= maximumLength else {
            throw SessionCatalogError.invalidTitle
        }
        return title
    }
}

enum SessionForkCheckpointRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

struct SessionForkCheckpoint: Codable, Equatable, Sendable {
    let userTurn: Int
    let role: SessionForkCheckpointRole
    let contentDigest: String

    init(userTurn: Int, role: SessionForkCheckpointRole, content: String) {
        self.userTurn = userTurn
        self.role = role
        contentDigest = Self.digest(content)
    }

    func matches(content: String) -> Bool {
        contentDigest == Self.digest(content)
    }

    private static func digest(_ content: String) -> String {
        BighelpLinkBase64URL.encode(Data(SHA256.hash(data: Data(content.utf8))))
    }
}

struct SessionForkRequest: Equatable, Sendable {
    let sourceSessionID: String
    let forkSessionID: String
    let agentID: String
    let checkpoint: SessionForkCheckpoint
    let title: String
}

struct SessionForkReceipt: Equatable, Sendable {
    let forkSessionID: String
    let title: String
}

@MainActor
protocol SessionForkClient: AnyObject {
    func fork(_ request: SessionForkRequest) async throws -> SessionForkReceipt
}

@MainActor
final class LocalSessionForkClient: SessionForkClient {
    func fork(_ request: SessionForkRequest) async throws -> SessionForkReceipt {
        SessionForkReceipt(
            forkSessionID: request.forkSessionID,
            title: request.title
        )
    }
}

/// Where a chat started, from Hermes' session `source`: bighelp, Hermes Desktop, the
/// terminal, a messaging app, a schedule, or a coding agent Hermes imported it from.
enum SessionOrigin {
    /// A short name for the tag on the chat's row, or nil when Hermes didn't say.
    static func label(_ source: String?) -> String? {
        guard let source else { return nil }
        let raw = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty, raw.utf8.count <= 64 else { return nil }
        switch raw {
        case "bighelp", "loopdy": return "bighelp"
        case "desktop", "hermes-desktop", "hermes_desktop": return "Hermes Desktop"
        case "tui": return "TUI"
        case "cli": return "CLI"
        case "acp": return "Editor"
        case "cron": return "Scheduled"
        case "workflow": return "Workflow"
        case "webhook": return "Webhook"
        case "api_server", "api": return "API"
        case "bot_room", HostedRoomSessionProjection.remoteSource: return "Group chat"
        case "claude-code", "claude_code", "claude": return "Claude Code"
        case "codex-cli", "codex_cli", "codex": return "Codex"
        case "telegram": return "Telegram"
        case "discord": return "Discord"
        case "slack": return "Slack"
        case "whatsapp": return "WhatsApp"
        case "signal": return "Signal"
        case "imessage", "bluebubbles": return "iMessage"
        case "sms": return "SMS"
        case "email": return "Email"
        case "matrix": return "Matrix"
        case "mattermost": return "Mattermost"
        default:
            let words = raw.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            guard !words.isEmpty else { return nil }
            return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }
}

struct SessionSummary: Identifiable, Equatable, Sendable {
    let id: String
    let kind: SessionKind
    let agentIDs: [String]
    let title: String
    let preview: String
    let createdAt: Date
    let updatedAt: Date
    let isActive: Bool
    let isPinned: Bool
    let isCronSession: Bool
    let workspaceID: String?
    let workspaceName: String?
    let hostedRoomID: String?
    /// Hermes' `source` for this chat (where it started); see `SessionOrigin`.
    let origin: String?

    init(
        id: String,
        kind: SessionKind,
        agentIDs: [String],
        title: String,
        preview: String,
        createdAt: Date? = nil,
        updatedAt: Date,
        isActive: Bool = false,
        isPinned: Bool = false,
        isCronSession: Bool = false,
        workspaceID: String? = nil,
        workspaceName: String? = nil,
        hostedRoomID: String? = nil,
        origin: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.agentIDs = agentIDs
        self.title = title
        self.preview = preview
        self.createdAt = createdAt ?? updatedAt
        self.updatedAt = updatedAt
        self.isActive = isActive
        self.isPinned = isPinned
        self.isCronSession = isCronSession
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.hostedRoomID = hostedRoomID
        self.origin = origin
    }
}

struct SessionRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    /// The Hermes durable coordinate paired with this user-facing session id.
    /// Persisting it lets a cold client hydrate history without an ephemeral
    /// in-memory catalog mapping.
    var remoteStoredID: String?
    var remoteSource: String?
    var workspaceID: String?
    var workspaceName: String?
    var sessionContext: SessionContextSnapshot?
    var sessionRuntime: SessionRuntimeSnapshot?
    var sessionGoal: SessionGoalSnapshot?
    /// Full revisioned todo authority. A present empty snapshot is a durable
    /// tombstone and must remain distinct from a legacy record with no field.
    var sessionTodos: SessionTodoSnapshot?
    /// Independent of parent model generation; never creates a streaming draft.
    var sessionSubagents: SessionSubagentRosterSnapshot?
    var hasActiveWork: Bool { isActive || sessionSubagents?.subagents.isEmpty == false }
    var parentSessionID: String?
    var kind: SessionKind
    var agentIDs: [String]
    var title: String
    var draft: String
    /// Local reference routing/receipt metadata; never serialized into Link text.
    var referenceState: ReferenceCanonicalState?
    /// Explicit per-chat choice. Opaque Keychain record ID, never token bytes.
    var referenceGitHubCredentialID: String?
    var referenceGitHubDisabled: Bool
    var items: [TimelineItem]
    var botModeRoomID: String?
    /// Direct turns accepted before conversion remain private to the original
    /// agent. Bot Mode's canonical shared log lives in `items` after conversion.
    var botModePrivateHistory: [TimelineItem]
    var activityEvents: [ChatActivityEvent]
    var activityVisibility: ChatActivityVisibility
    /// True while Hermes reports this durable session as live, even before
    /// the first user message has been committed.
    var isActive: Bool
    var isPinned: Bool
    let createdAt: Date
    var updatedAt: Date
    var hasAcceptedMessage: Bool

    /// Non-nil only for a metadata projection whose protected payload has not
    /// been restored. Empty arrays in that projection are NOT an empty chat.
    var localContentRevision: UUID? = nil
    var localContentScope: String? = nil
    var catalogPreview: String? = nil
    var hasDeferredReferenceState: Bool = false
    var isContentLoaded: Bool { localContentRevision == nil }

    /// A presentation-only draft used while Hermes allocates the durable
    /// session. It has no remote coordinate and must never be sent or exposed
    /// as an authoritative chat summary.
    var isLocalPresentationDraft: Bool {
        id.hasPrefix("local-draft:")
            && remoteStoredID == nil
            && remoteSource == nil
            && !hasAcceptedMessage
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case remoteStoredID
        case remoteSource
        case workspaceID
        case workspaceName
        case sessionContext
        case sessionRuntime
        case sessionGoal
        case sessionTodos
        case sessionSubagents
        case parentSessionID
        case kind
        case agentIDs
        case title
        case draft
        case referenceState
        case referenceGitHubCredentialID
        case referenceGitHubDisabled
        case items
        case botModeRoomID
        case botModePrivateHistory
        case activityEvents
        case activityVisibility
        case isActive
        case isPinned
        case createdAt
        case updatedAt
        case hasAcceptedMessage
        case localContentRevision
        case localContentScope
        case catalogPreview
        case hasDeferredReferenceState
    }

    init(
        id: String,
        kind: SessionKind,
        agentIDs: [String],
        title: String,
        remoteStoredID: String? = nil,
        remoteSource: String? = nil,
        workspaceID: String? = nil,
        workspaceName: String? = nil,
        sessionContext: SessionContextSnapshot? = nil,
        sessionRuntime: SessionRuntimeSnapshot? = nil,
        sessionGoal: SessionGoalSnapshot? = nil,
        sessionTodos: SessionTodoSnapshot? = nil,
        sessionSubagents: SessionSubagentRosterSnapshot? = nil,
        parentSessionID: String? = nil,
        draft: String = "",
        items: [TimelineItem] = [],
        botModeRoomID: String? = nil,
        botModePrivateHistory: [TimelineItem] = [],
        activityEvents: [ChatActivityEvent] = [],
        activityVisibility: ChatActivityVisibility = .default,
        isActive: Bool = false,
        isPinned: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date? = nil,
        hasAcceptedMessage: Bool = false,
        referenceState: ReferenceCanonicalState? = nil,
        referenceGitHubCredentialID: String? = nil,
        referenceGitHubDisabled: Bool = false
    ) {
        self.id = id
        self.remoteStoredID = remoteStoredID
        self.remoteSource = remoteSource
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.sessionContext = sessionContext
        self.sessionRuntime = sessionRuntime
        self.sessionGoal = sessionGoal
        self.sessionTodos = sessionTodos
        self.sessionSubagents = sessionSubagents
        self.parentSessionID = parentSessionID
        self.kind = kind
        self.agentIDs = agentIDs
        self.title = title
        self.draft = draft
        self.referenceState = referenceState
        self.referenceGitHubCredentialID = referenceGitHubCredentialID
        self.referenceGitHubDisabled = referenceGitHubDisabled
        self.items = items
        self.botModeRoomID = botModeRoomID
        self.botModePrivateHistory = botModePrivateHistory
        self.activityEvents = activityEvents
        self.activityVisibility = activityVisibility
        self.isActive = isActive
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.hasAcceptedMessage = hasAcceptedMessage
    }

    var summary: SessionSummary {
        SessionSummary(
            id: id,
            kind: kind,
            agentIDs: agentIDs,
            title: title,
            preview: items.last.flatMap { item in
                guard case .message(let text) = item.content else { return nil }
                return HermesUserMessageDisplay.preview(text, attachments: item.attachments)
            } ?? catalogPreview ?? (kind == .botMode ? "Group chat" : ""),
            createdAt: createdAt,
            updatedAt: updatedAt,
            isActive: hasActiveWork,
            isPinned: isPinned,
            isCronSession: isCronSession,
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            hostedRoomID: remoteSource == HostedRoomSessionProjection.remoteSource
                ? botModeRoomID : nil,
            origin: remoteSource
        )
    }

    var isSubagentSession: Bool {
        parentSessionID != nil
    }

    var isCronSession: Bool {
        remoteSource?.caseInsensitiveCompare("cron") == .orderedSame
    }

    /// A workflow stage's own session. It belongs to its run, not to the chat
    /// lists: Sessions, recents and widgets leave it out.
    var isWorkflowSession: Bool {
        remoteSource?.caseInsensitiveCompare(Self.workflowSource) == .orderedSame
    }

    static let workflowSource = "workflow"

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        remoteStoredID = try container.decodeIfPresent(String.self, forKey: .remoteStoredID)
        remoteSource = try container.decodeIfPresent(String.self, forKey: .remoteSource)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        workspaceName = try container.decodeIfPresent(String.self, forKey: .workspaceName)
        sessionContext = try container.decodeIfPresent(SessionContextSnapshot.self, forKey: .sessionContext)
        sessionRuntime = try container.decodeIfPresent(SessionRuntimeSnapshot.self, forKey: .sessionRuntime)
        let decodedGoal = try container.decodeIfPresent(SessionGoalSnapshot.self, forKey: .sessionGoal)
        if let goal = decodedGoal, goal.isValid, goal.sessionID == id,
           remoteStoredID == nil || remoteStoredID == goal.storedSessionID {
            sessionGoal = goal
        } else {
            sessionGoal = nil
        }
        // Older records have no key and migrate to unknown (`nil`), never to an
        // empty todo list. This preserves the difference between missing state
        // and a newer explicit empty tombstone.
        let todoSnapshot = try container.decodeIfPresent(SessionTodoSnapshot.self, forKey: .sessionTodos)
        sessionTodos = todoSnapshot?.sessionID == id && todoSnapshot?.isValid == true
            ? todoSnapshot : nil
        let roster = try container.decodeIfPresent(SessionSubagentRosterSnapshot.self, forKey: .sessionSubagents)
        sessionSubagents = roster?.sessionID == id && (roster?.updatedAt ?? 0) > 0
            && (roster?.subagents.count ?? 0) <= 256 ? roster : nil
        parentSessionID = try container.decodeIfPresent(String.self, forKey: .parentSessionID)
        kind = try container.decode(SessionKind.self, forKey: .kind)
        agentIDs = try container.decode([String].self, forKey: .agentIDs)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New chat"
        draft = try container.decodeIfPresent(String.self, forKey: .draft) ?? ""
        referenceState = try container.decodeIfPresent(ReferenceCanonicalState.self, forKey: .referenceState)
        referenceGitHubCredentialID = try container.decodeIfPresent(String.self, forKey: .referenceGitHubCredentialID)
        referenceGitHubDisabled = try container.decodeIfPresent(Bool.self, forKey: .referenceGitHubDisabled) ?? false
        let legacyItems = try container.decodeIfPresent(
            [LegacyTimelineItem].self,
            forKey: .items
        ) ?? []
        let canonicalAgentID = kind == .direct && agentIDs.count == 1 ? agentIDs[0] : nil
        items = legacyItems.map { $0.migrated(canonicalAgentID: canonicalAgentID) }
        botModeRoomID = try container.decodeIfPresent(String.self, forKey: .botModeRoomID)
        botModePrivateHistory = try container.decodeIfPresent([LegacyTimelineItem].self, forKey: .botModePrivateHistory)?.map {
            $0.migrated(canonicalAgentID: canonicalAgentID)
        } ?? []
        activityEvents = try container.decodeIfPresent(
            [ChatActivityEvent].self,
            forKey: .activityEvents
        ) ?? []
        activityVisibility = try container.decodeIfPresent(
            ChatActivityVisibility.self,
            forKey: .activityVisibility
        ) ?? .default
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        hasAcceptedMessage = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasAcceptedMessage
        ) ?? items.contains(where: { $0.role == .human })
        localContentRevision = try container.decodeIfPresent(UUID.self, forKey: .localContentRevision)
        localContentScope = try container.decodeIfPresent(String.self, forKey: .localContentScope)
        catalogPreview = try container.decodeIfPresent(String.self, forKey: .catalogPreview)
        hasDeferredReferenceState = try container.decodeIfPresent(Bool.self, forKey: .hasDeferredReferenceState) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(remoteStoredID, forKey: .remoteStoredID)
        try container.encodeIfPresent(remoteSource, forKey: .remoteSource)
        try container.encodeIfPresent(workspaceID, forKey: .workspaceID)
        try container.encodeIfPresent(workspaceName, forKey: .workspaceName)
        try container.encodeIfPresent(sessionContext, forKey: .sessionContext)
        try container.encodeIfPresent(sessionRuntime, forKey: .sessionRuntime)
        try container.encodeIfPresent(sessionGoal, forKey: .sessionGoal)
        try container.encodeIfPresent(sessionTodos, forKey: .sessionTodos)
        try container.encodeIfPresent(sessionSubagents, forKey: .sessionSubagents)
        try container.encodeIfPresent(parentSessionID, forKey: .parentSessionID)
        try container.encode(kind, forKey: .kind)
        try container.encode(agentIDs, forKey: .agentIDs)
        try container.encode(title, forKey: .title)
        try container.encode(draft, forKey: .draft)
        try container.encodeIfPresent(referenceState, forKey: .referenceState)
        try container.encodeIfPresent(referenceGitHubCredentialID, forKey: .referenceGitHubCredentialID)
        try container.encode(referenceGitHubDisabled, forKey: .referenceGitHubDisabled)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(botModeRoomID, forKey: .botModeRoomID)
        try container.encode(botModePrivateHistory, forKey: .botModePrivateHistory)
        try container.encode(activityEvents, forKey: .activityEvents)
        try container.encode(activityVisibility, forKey: .activityVisibility)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(hasAcceptedMessage, forKey: .hasAcceptedMessage)
        try container.encodeIfPresent(localContentRevision, forKey: .localContentRevision)
        try container.encodeIfPresent(localContentScope, forKey: .localContentScope)
        try container.encodeIfPresent(catalogPreview, forKey: .catalogPreview)
        if hasDeferredReferenceState {
            try container.encode(true, forKey: .hasDeferredReferenceState)
        }
    }
}

private struct LegacyTimelineItem: Codable {
    let id: String
    let role: TimelineRole
    let sender: TimelineSender?
    let content: TimelineContent
    let metadata: TimelineMetadata
    let attachments: [ChatAttachment]

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case sender
        case content
        case metadata
        case attachments
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(TimelineRole.self, forKey: .role)
        sender = try container.decodeIfPresent(TimelineSender.self, forKey: .sender)
        content = try container.decode(TimelineContent.self, forKey: .content)
        metadata = try container.decodeIfPresent(
            TimelineMetadata.self,
            forKey: .metadata
        ) ?? TimelineMetadata()
        attachments = try container.decodeIfPresent(
            [ChatAttachment].self,
            forKey: .attachments
        ) ?? []
    }

    func migrated(canonicalAgentID: String?) -> TimelineItem {
        TimelineItem(
            id: id,
            role: role,
            sender: sender ?? legacySender(canonicalAgentID: canonicalAgentID),
            content: content,
            metadata: metadata,
            attachments: attachments
        )
    }

    private func legacySender(canonicalAgentID: String?) -> TimelineSender {
        switch role {
        case .human:
            return .user(snapshot: .init(name: "You"))
        case .assistant:
            if let canonicalAgentID, !canonicalAgentID.isEmpty {
                return .agent(id: canonicalAgentID, snapshot: .init(name: "Assistant"))
            }
            return .system(id: "unknown-sender", snapshot: .init(name: "Unknown sender"))
        }
    }
}

typealias SessionHydrationProgress = @MainActor (SessionRecord) throws -> Void

struct SessionHydrationPage: Equatable, Sendable {
    let record: SessionRecord
    let nextOffset: Int?
    var livePresentation: [String: BighelpJSONValue]? = nil
    var presentationOwner: String? = nil
}

@MainActor
protocol SessionCatalogClient {
    var canDeleteConversation: Bool { get }
    var allowsLocalAgentReassignment: Bool { get }
    func list() async throws -> [SessionRecord]
    func refreshMetadata(_ record: SessionRecord) async throws -> SessionRecord?
    func canonicalToolCallIDs(for record: SessionRecord) -> Set<String>
    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord
    func hydrate(_ record: SessionRecord) async throws -> SessionRecord
    func hydrate(
        _ record: SessionRecord,
        onProgress: @escaping SessionHydrationProgress
    ) async throws -> SessionRecord
    func hydratePage(
        _ record: SessionRecord,
        offset: Int?,
        turnLimit: Int
    ) async throws -> SessionHydrationPage
    func rename(_ record: SessionRecord, title: String) async throws
    func setPinned(_ record: SessionRecord, pinned: Bool) async throws
    func archive(_ record: SessionRecord) async throws
    func delete(_ record: SessionRecord) async throws
    func resetForAccountBoundary()
}

@MainActor
extension SessionCatalogClient {
    var canDeleteConversation: Bool { true }
    var allowsLocalAgentReassignment: Bool { true }

    /// Native hosts can verify one saved session without enumerating every profile.
    /// Clients without that operation keep the existing catalog-refresh behavior.
    func refreshMetadata(_ record: SessionRecord) async throws -> SessionRecord? { nil }

    /// IDs covered by this client's verified canonical history, including
    /// repeated/conflicting stored variants that cannot share one activity ID.
    func canonicalToolCallIDs(for record: SessionRecord) -> Set<String> { [] }

    func hydrate(_ record: SessionRecord) async throws -> SessionRecord { record }

    func rename(_ record: SessionRecord, title: String) async throws {
        throw SessionCatalogError.invalidSession
    }

    func setPinned(_ record: SessionRecord, pinned: Bool) async throws {
        throw SessionCatalogError.invalidSession
    }

    func archive(_ record: SessionRecord) async throws {
        throw SessionCatalogError.invalidSession
    }

    func delete(_ record: SessionRecord) async throws {
        throw SessionCatalogError.invalidSession
    }

    func hydrate(
        _ record: SessionRecord,
        onProgress: @escaping SessionHydrationProgress
    ) async throws -> SessionRecord {
        let hydrated = try await hydrate(record)
        try onProgress(hydrated)
        return hydrated
    }

    func hydratePage(
        _ record: SessionRecord,
        offset: Int?,
        turnLimit: Int
    ) async throws -> SessionHydrationPage {
        guard offset == nil else { throw SessionCatalogError.invalidSession }
        return SessionHydrationPage(
            record: try await hydrate(record),
            nextOffset: nil
        )
    }

    func resetForAccountBoundary() {}
}

extension SessionRecord {
    /// The saved one-agent chat a notification names by `ManagedNotificationValidation.sessionReference`.
    static func matching(reference: String, profileID: String, in records: [SessionRecord]) -> SessionRecord? {
        let matches = records.filter { record in
            record.kind == .direct && record.agentIDs == [profileID]
                && record.remoteStoredID.map {
                    ManagedNotificationValidation.sessionReference(profile: profileID, session: $0) == reference
                } == true
        }
        return matches.count == 1 ? matches[0] : nil
    }
}
