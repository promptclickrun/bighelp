import Foundation

enum TimelineRole: String, Codable, Equatable, Sendable {
    case human
    case assistant
}

enum NativeMessageReactionAuthor: String, Equatable, Sendable {
    case user
    case agent
}

struct NativeMessageReaction: Equatable, Sendable {
    let emoji: String
    let author: NativeMessageReactionAuthor
    let occurredAt: Double?
    let isSeen: Bool?
}

enum NativeMessageReactionAvailability: Equatable, Sendable {
    case available
    case canonicalMessageRequired
    case conflictingCanonicalRow
    case foreignSession
    case outcomeUnknown
    case reconnectRequired
    case unsupportedHost

    var allowsMutation: Bool { self == .available }

    var accessibilityDescription: String {
        switch self {
        case .available:
            "Choose a reaction"
        case .canonicalMessageRequired:
            "Reactions become available after Hermes saves this message"
        case .conflictingCanonicalRow:
            "Reactions are unavailable because this message identity is ambiguous"
        case .foreignSession:
            "Reactions are unavailable for a different conversation"
        case .outcomeUnknown:
            "Hermes may have received the previous reaction; reopen this chat to reconcile it"
        case .reconnectRequired:
            "Reconnect to Hermes to change reactions"
        case .unsupportedHost:
            "This Hermes host does not support message reactions"
        }
    }
}

struct NativeMessageReactionPresentation: Equatable, Sendable {
    let rowID: Int?
    let reactions: [NativeMessageReaction]
    let availability: NativeMessageReactionAvailability
    let isUpdating: Bool
    let errorMessage: String?
}

/// A live decorative signal only. It intentionally carries no message ID because
/// Hermes' `reaction` event does not identify a transcript row.
struct NativeAffectionReactionSignal: Equatable, Sendable {
    let revision: UInt64
    let kind: String
}

struct TimelineSenderSnapshot: Codable, Equatable, Sendable {
    let name: String
    let avatarFileName: String?
    /// A picture kept outside this computer's agents folder: an agent on
    /// another computer. Live only and never saved, since the path is this device's.
    var imageURL: URL? = nil

    private enum CodingKeys: String, CodingKey {
        case name, avatarFileName
    }

    init(name: String, avatarFileName: String? = nil, imageURL: URL? = nil) {
        self.name = name
        self.avatarFileName = avatarFileName
        self.imageURL = imageURL
    }
}

struct TimelineSender: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Hashable, Sendable {
        case user
        case agent
        case system
    }

    let id: String
    let kind: Kind
    let snapshot: TimelineSenderSnapshot

    static func user(snapshot: TimelineSenderSnapshot) -> TimelineSender {
        TimelineSender(id: UserIdentity.stableID, kind: .user, snapshot: snapshot)
    }

    static func agent(id: String, snapshot: TimelineSenderSnapshot) -> TimelineSender {
        TimelineSender(id: id, kind: .agent, snapshot: snapshot)
    }

    static func system(
        id: String = "system",
        snapshot: TimelineSenderSnapshot = .init(name: "System")
    ) -> TimelineSender {
        TimelineSender(id: id, kind: .system, snapshot: snapshot)
    }
}

/// Coordinates for an explicitly incomplete canonical row. The row ID is the
/// exact JSON `id` used by the content reader, never a namespaced timeline ID,
/// source-order index, or an identifier reconstructed from visible text.
struct CanonicalContentReference: Codable, Equatable, Sendable {
    let sessionID: String
    let rowID: String

    func routed(to sessionID: String) -> CanonicalContentReference {
        CanonicalContentReference(sessionID: sessionID, rowID: rowID)
    }
}

struct TimelineMetadata: Codable, Equatable, Sendable {
    let source: String?
    let freshness: String?
    let delivery: String?
    let timestamp: Date?
    let turnDurationMilliseconds: Int?
    /// Canonical Hermes history row or the local authenticated arrival
    /// sequence. This is presentation metadata only; it never replaces the
    /// message identity used for reconciliation.
    private(set) var sourceOrder: Int?
    let platformMessageID: String?
    /// Missing in legacy snapshots and complete rows; absence is not a fetch hint.
    private(set) var contentReference: CanonicalContentReference?
    /// Display only, never saved: an agent message written on the way to the
    /// answer (more work followed in the same turn). See ChatInterimReplies.
    var isInterimReply = false

    private enum CodingKeys: String, CodingKey {
        case source, freshness, delivery, timestamp, turnDurationMilliseconds, sourceOrder,
             platformMessageID, contentReference
    }

    init(
        source: String? = nil,
        freshness: String? = nil,
        delivery: String? = nil,
        timestamp: Date? = nil,
        sourceOrder: Int? = nil,
        platformMessageID: String? = nil,
        turnDurationMilliseconds: Int? = nil,
        contentReference: CanonicalContentReference? = nil
    ) {
        self.contentReference = contentReference
        self.turnDurationMilliseconds = turnDurationMilliseconds
        self.platformMessageID = platformMessageID
        self.source = source
        self.freshness = freshness
        self.delivery = delivery
        self.timestamp = timestamp
        self.sourceOrder = sourceOrder
    }

    func ordered(_ sourceOrder: Int) -> TimelineMetadata {
        var metadata = self
        metadata.sourceOrder = sourceOrder
        return metadata
    }

    func routed(to sessionID: String) -> TimelineMetadata {
        var metadata = self
        metadata.contentReference = contentReference?.routed(to: sessionID)
        return metadata
    }
}

enum TimelineMetadataPresentation {
    static func timestampLabel(
        for metadata: TimelineMetadata,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String? {
        guard let timestamp = metadata.timestamp else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

struct BudgetSummary: Codable, Equatable, Sendable {
    let period: String
    let spent: String
    let budget: String
    let remaining: String
    let percentUsed: Int
    let plan: [PlanItem]
}

struct PlanItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let time: String
}

struct WeatherAndTasks: Codable, Equatable, Sendable {
    let city: String
    let condition: String
    let currentTemperature: Int
    let highTemperature: Int
    let lowTemperature: Int
    let hourly: [HourlyWeather]
    let tasks: [PrioritizedTask]
}

struct HourlyWeather: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let time: String
    let condition: String
    let temperature: Int
    let systemImage: String
}

struct PrioritizedTask: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let priority: String
    let title: String
    let detail: String
}

struct ApprovalRequest: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let action: String
    let requester: String
    let vendor: String
    let amount: String
    let dueDate: String
    let category: String
    let sourceInvoice: String
    let consequence: String
}

enum TimelineContent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case message
        case budgetSummary
        case weatherAndTasks
        case approvalRequest
        case generativeUI
        case bighelpCard = "loopdyCard"
    }

    case message(String)
    case budgetSummary(BudgetSummary)
    case weatherAndTasks(WeatherAndTasks)
    case approvalRequest(ApprovalRequest)
    case generativeUI(GenerativeUICard)
    case bighelpCard(BighelpCardDocument)

    var kind: Kind {
        switch self {
        case .message: .message
        case .budgetSummary: .budgetSummary
        case .weatherAndTasks: .weatherAndTasks
        case .approvalRequest: .approvalRequest
        case .generativeUI: .generativeUI
        case .bighelpCard: .bighelpCard
        }
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case budgetSummary
        case weatherAndTasks
        case approvalRequest
        case generativeUI
        case bighelpCard = "loopdyCard"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try container.decodeIfPresent(String.self, forKey: .message) {
            self = .message(text)
        } else if let summary = try container.decodeIfPresent(BudgetSummary.self, forKey: .budgetSummary) {
            self = .budgetSummary(summary)
        } else if let weather = try container.decodeIfPresent(WeatherAndTasks.self, forKey: .weatherAndTasks) {
            self = .weatherAndTasks(weather)
        } else if let request = try container.decodeIfPresent(ApprovalRequest.self, forKey: .approvalRequest) {
            self = .approvalRequest(request)
        } else if let card = try container.decodeIfPresent(GenerativeUICard.self, forKey: .generativeUI) {
            self = .generativeUI(card)
        } else if let card = try container.decodeIfPresent(BighelpCardDocument.self, forKey: .bighelpCard) {
            self = .bighelpCard(card)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .message, in: container, debugDescription: "Unknown timeline content")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let text):
            try container.encode(text, forKey: .message)
        case .budgetSummary(let summary):
            try container.encode(summary, forKey: .budgetSummary)
        case .weatherAndTasks(let weather):
            try container.encode(weather, forKey: .weatherAndTasks)
        case .approvalRequest(let request):
            try container.encode(request, forKey: .approvalRequest)
        case .generativeUI(let card):
            try container.encode(card, forKey: .generativeUI)
        case .bighelpCard(let card):
            try container.encode(card, forKey: .bighelpCard)
        }
    }
}

struct TimelineItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let role: TimelineRole
    let sender: TimelineSender
    let content: TimelineContent
    private(set) var metadata: TimelineMetadata
    let attachments: [ChatAttachment]

    init(
        id: String,
        role: TimelineRole,
        sender: TimelineSender,
        content: TimelineContent,
        metadata: TimelineMetadata,
        attachments: [ChatAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.sender = sender
        self.content = content
        self.metadata = metadata
        self.attachments = attachments
    }

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
        self.init(
            id: try container.decode(String.self, forKey: .id),
            role: try container.decode(TimelineRole.self, forKey: .role),
            sender: try container.decode(TimelineSender.self, forKey: .sender),
            content: try container.decode(TimelineContent.self, forKey: .content),
            metadata: try container.decode(TimelineMetadata.self, forKey: .metadata),
            attachments: try container.decodeIfPresent([ChatAttachment].self, forKey: .attachments) ?? []
        )
    }

    /// The same message marked as written on the way to the answer (display only).
    func markedInterim() -> TimelineItem {
        var item = self
        item.metadata.isInterimReply = true
        return item
    }

    func ordered(_ sourceOrder: Int) -> TimelineItem {
        var item = self
        item.metadata = metadata.ordered(sourceOrder)
        return item
    }

    /// Re-home only the reader's visible session coordinate; row identity and
    /// all retained content/metadata remain exact across catalog alias changes.
    func routed(to sessionID: String) -> TimelineItem {
        var item = self
        item.metadata = metadata.routed(to: sessionID)
        return item
    }
}

enum QuickAction: String, CaseIterable, Identifiable, Equatable, Sendable {
    case weatherAndTasks
    case budgetAndPlan
    case vendorApproval

    var id: Self { self }

    var title: String {
        switch self {
        case .weatherAndTasks: "Catch me up"
        case .budgetAndPlan: "Plan my day"
        case .vendorApproval: "Start a task"
        }
    }

    var intent: String {
        switch self {
        case .weatherAndTasks: "Show me today's weather and priority tasks."
        case .budgetAndPlan: "Show my budget and today's plan."
        case .vendorApproval: "Show the vendor payment that needs review."
        }
    }

    var systemImage: String {
        switch self {
        case .weatherAndTasks: "checklist"
        case .budgetAndPlan: "calendar"
        case .vendorApproval: "checkmark.circle"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .weatherAndTasks: "quick.weather"
        case .budgetAndPlan: "quick.budget"
        case .vendorApproval: "quick.approval"
        }
    }
}

struct ConversationResponse: Equatable, Sendable {
    let items: [TimelineItem]
}

enum MidSessionSubmissionOutcome: Equatable, Sendable {
    case accepted
    case replacement(ConversationResponse)
}

enum MidSessionSubmissionState: Equatable, Sendable {
    case idle
    case submitting(MidSessionChatBehavior)
}

struct PendingMidSessionSubmission: Identifiable, Equatable, Sendable {
    let id: String
    let behavior: MidSessionChatBehavior
}

enum PendingMidSessionPresentation {
    static func label(for behavior: MidSessionChatBehavior) -> String {
        switch behavior {
        case .steer: "Steering…"
        case .queued: "Queued…"
        case .interruptAndSend: "Interrupting…"
        }
    }
}

enum ChatComposerInteractionPolicy {
    static let sendOptionsLongPressDuration = 1.0
}

enum ChatComposerPrimaryAction: Equatable, Sendable {
    case voice
    case send
    case stop

    static func resolve(
        draft: String,
        isTurnActive: Bool = false,
        hasAttachments: Bool = false
    ) -> ChatComposerPrimaryAction {
        if hasAttachments || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .send
        }
        return isTurnActive ? .stop : .voice
    }
}


/// Pure classification shared by catalog merge and mounted history hydration.
enum ChatHistoryProjection {
    static func isSummaryProjection(_ items: [TimelineItem]) -> Bool {
        guard items.count == 1 else { return false }
        return items[0].id.hasSuffix(":summary-preview")
    }

    static func isCanonicalTranscript(_ items: [TimelineItem]) -> Bool {
        !items.isEmpty && !isSummaryProjection(items)
    }
}
