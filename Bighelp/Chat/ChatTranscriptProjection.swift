import Foundation
import Observation

@Observable
final class ChatActivityTurn: Identifiable, Equatable {
    let id: String
    private(set) var events: [ChatActivityEvent]
    private var maximumSourceOrder: Int?
    var upperSourceOrder: Int { maximumSourceOrder ?? .max }

    @MainActor
    init(id: String, events: [ChatActivityEvent]) {
        self.id = id
        self.events = events
        maximumSourceOrder = events.compactMap(\.sourceOrder).max()
    }

    @MainActor
    func append(_ event: ChatActivityEvent) {
        events.append(event)
        if let order = event.sourceOrder {
            maximumSourceOrder = maximumSourceOrder.map { max($0, order) } ?? order
        }
    }

    @MainActor
    func update(_ event: ChatActivityEvent, at index: Int) {
        let previousOrder = events[index].sourceOrder
        events[index] = event
        guard previousOrder != event.sourceOrder else { return }
        if let order = event.sourceOrder, maximumSourceOrder.map({ order >= $0 }) ?? true {
            maximumSourceOrder = order
        } else if previousOrder == maximumSourceOrder {
            maximumSourceOrder = events.compactMap(\.sourceOrder).max()
        }
    }

    static func == (lhs: ChatActivityTurn, rhs: ChatActivityTurn) -> Bool {
        lhs.id == rhs.id && lhs.events == rhs.events
    }
}


/// One row in the visible transcript. Adjacent activity emitted by the same
/// Hermes turn may share a compact expandable card, but a message always
/// breaks that group so compaction can never reorder the conversation.
enum ChatTranscriptEntry: Identifiable, Equatable {
    case message(TimelineItem)
    case activity(ChatActivityTurn)

    var id: String {
        switch self {
        case .message(let item):
            "message:\(item.id)"
        case .activity(let turn):
            "activity:\(turn.id)"
        }
    }
}

/// Canonical source-ordered transcript projection shared by the active chat,
/// restored sessions, and child-session drawers. Keeping this pure prevents a
/// secondary surface from regrouping Hermes activity differently than chat.
@MainActor
enum ChatTranscriptProjection {
    /// Fill missing presentation positions after all supplied canonical orders.
    /// Messages precede activity only for those missing positions, as on restore.
    static func orderedContent(
        items: [TimelineItem],
        events: [ChatActivityEvent]
    ) -> (items: [TimelineItem], events: [ChatActivityEvent], nextOrder: Int) {
        var nextOrder = max(
            items.compactMap(\.metadata.sourceOrder).max() ?? 0,
            events.compactMap(\.sourceOrder).max() ?? 0
        ) + 1
        let items = items.map { item in
            guard item.metadata.sourceOrder == nil else { return item }
            defer { nextOrder += 1 }
            return item.ordered(nextOrder)
        }
        let events = events.map { event in
            guard event.sourceOrder == nil else { return event }
            defer { nextOrder += 1 }
            return event.ordered(nextOrder)
        }
        return (items, events, nextOrder)
    }

    private enum Node {
        case message(TimelineItem)
        case activity(ChatActivityEvent)

        var order: Int {
            switch self {
            case .message(let item): item.metadata.sourceOrder ?? .max
            case .activity(let event): event.sourceOrder ?? .max
            }
        }

        var tieBreak: String {
            switch self {
            case .message(let item): "1:\(item.id)"
            case .activity(let event): "0:\(event.eventID)"
            }
        }
    }

    static func entries(
        items allItems: [TimelineItem],
        activityEvents: [ChatActivityEvent],
        visibility: ChatActivityVisibility,
        isBotMode: Bool,
        isScheduled: Bool = false,
        after previous: TimelineItem? = nil,
        reactedTo: (TimelineItem) -> Bool = { _ in false }
    ) -> [ChatTranscriptEntry] {
        // An agent that chose not to answer an off-screen note leaves no bubble.
        let items = ChatSilentReply.presented(
            allItems, lane: isBotMode ? .room : isScheduled ? .scheduled : .chat, after: previous,
            reactedTo: reactedTo)
        // A room exposes participant messages, not the members' private work.
        // Retain recorded activity in its store without projecting tool or
        // agent-to-agent cards into either live or reopened room transcripts.
        let visibleActivity = isBotMode ? [] : activityEvents.filter {
            $0.isVisible(using: visibility)
        }
        let nodes: [Node]
        if isBotMode, items.contains(where: { $0.metadata.sourceOrder == nil }) {
            // Builds before Bot Mode carried a shared event sequence but no
            // cross-stream source order. Recover the only defensible ordering:
            // the human turn, authenticated activity for a member, then that
            // member's persisted reply. Generic turn activity is placed before
            // the first reply rather than incorrectly trailing every final.
            var pendingActivity = visibleActivity.sorted { left, right in
                let leftOrder = left.sourceOrder ?? left.occurredAt
                let rightOrder = right.sourceOrder ?? right.occurredAt
                if leftOrder == rightOrder { return left.id < right.id }
                return leftOrder < rightOrder
            }
            var recovered: [Node] = []
            var currentTurnID: String?

            func appendPending(where predicate: (ChatActivityEvent) -> Bool) {
                let selected = pendingActivity.filter(predicate)
                guard !selected.isEmpty else { return }
                recovered.append(contentsOf: selected.map(Node.activity))
                let selectedIDs = Set(selected.map(\.id))
                pendingActivity.removeAll { selectedIDs.contains($0.id) }
            }

            for item in items {
                if item.role == .human {
                    if let currentTurnID {
                        appendPending { $0.turnID == currentTurnID }
                    }
                    currentTurnID = item.id
                    recovered.append(.message(item))
                    continue
                }

                if let currentTurnID {
                    let matchingMember = pendingActivity.filter {
                        $0.turnID == currentTurnID && $0.memberID == item.sender.id
                    }
                    if let threshold = matchingMember.compactMap(\.sourceOrder).max() {
                        appendPending {
                            $0.turnID == currentTurnID
                                && (($0.sourceOrder ?? .min) <= threshold || $0.memberID == nil)
                        }
                    } else {
                        appendPending {
                            $0.turnID == currentTurnID
                                && ($0.memberID == item.sender.id || $0.memberID == nil)
                        }
                    }
                }
                recovered.append(.message(item))
            }
            if let currentTurnID {
                appendPending { $0.turnID == currentTurnID }
            }
            recovered.append(contentsOf: pendingActivity.map(Node.activity))
            nodes = recovered
        } else {
            nodes = (items.map(Node.message) + visibleActivity.map(Node.activity)).sorted { left, right in
                if left.order == right.order { return left.tieBreak < right.tieBreak }
                return left.order < right.order
            }
        }

        var result: [ChatTranscriptEntry] = []
        for node in nodes {
            switch node {
            case .message(let item):
                result.append(.message(item))
            case .activity(let event):
                if case .activity(let previous)? = result.last,
                   previous.events.last?.turnID == event.turnID {
                    result[result.count - 1] = .activity(ChatActivityTurn(
                        id: previous.id,
                        events: previous.events + [event]
                    ))
                } else {
                    result.append(.activity(ChatActivityTurn(
                        id: "\(event.turnID):\(event.eventID)",
                        events: [event]
                    )))
                }
            }
        }
        return result
    }
}

/// The content that can change the layout at the tail of an open chat.
///
/// The rendered projection owns invalidation, including same-ID edits and
/// visibility changes. Do not retain or compare the entire transcript merely
/// to decide whether the scroll position needs reconciliation.
struct ChatTimelineScrollKey: Equatable {
    let revision: UInt64
    let isSending: Bool
    let clarificationIDs: [String]
}

enum ChatClarificationProjection {
    static func items(
        for conversationID: String,
        in snapshot: DashboardSnapshot?
    ) -> [DashboardAttentionItem] {
        guard !conversationID.isEmpty, let snapshot else { return [] }
        return snapshot.attentionItems.filter { item in
            guard case .clarification(let request) = item.interaction else { return false }
            guard request.sessionID == conversationID else { return false }
            return item.sessionID == nil || item.sessionID == conversationID
        }
    }
}

struct ChatTimelineFollowState: Equatable, Sendable {
    static let nearBottomThreshold: CGFloat = 72

    private(set) var shouldFollowNewContent = true

    mutating func updateDistanceFromBottom(
        _ distance: CGFloat,
        isUserInitiated: Bool = true
    ) {
        guard distance.isFinite else { return }
        // Content growth, dynamic composer height, and lazy-row reconciliation
        // all change this geometry without the reader moving the timeline.
        // Only an intentional scroll may release the live bottom anchor.
        guard isUserInitiated else { return }
        shouldFollowNewContent = max(0, distance) <= Self.nearBottomThreshold
    }

    mutating func resetForConversationChange() {
        shouldFollowNewContent = true
    }

    mutating func resumeFollowingLatest() {
        shouldFollowNewContent = true
    }

    mutating func beginUserReview() {
        shouldFollowNewContent = false
    }

    mutating func beginDisclosureReview() {
        shouldFollowNewContent = false
    }

    var shouldScrollForNewContent: Bool {
        shouldFollowNewContent
    }
}
