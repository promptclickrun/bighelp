import Foundation

/// A Hermes event about who takes a message or a discussion's pause, kept beside the room's
/// messages: `room.assignment` (a lead's pick), `room.routed` (the automatic pick),
/// `room.activity` with `bounded` (a discussion paused at its cap), `room.continued` and
/// `room.stop_requested` (both end a pause's choice). Hermes writes each as the room's gateway.
struct BotModeRoomNotice: Codable, Equatable, Sendable {
    static let kinds: Set<String> = [
        "room.assignment", "room.routed", "room.activity", "room.continued", "room.stop_requested",
    ]
    static let maximumKept = 500

    let event: HermesBotModeEvent
    let sourceOrder: Int

    static func keeps(_ event: HermesBotModeEvent) -> Bool {
        guard kinds.contains(event.kind), event.actor["kind"]?.string == "gateway" else { return false }
        return event.kind != "room.activity" || event.payload["status"]?.string == "bounded"
    }
}

/// A centered line in a group chat: who took a message, or a discussion Hermes paused.
struct BotModeRoomNoticeRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case routing
        /// Continue and Stop show only while nothing has moved the discussion on and it may
        /// still continue.
        case paused(discussionEventID: String, isActionable: Bool)
        case continued
    }

    let id: String
    let text: String
    let kind: Kind

    /// The discussion a pause is about; nil for every other line.
    var pausedDiscussionEventID: String? {
        if case .paused(let discussion, _) = kind { return discussion }
        return nil
    }
}

extension TimelineItem {
    /// A routing line or pause as a transcript row (`ChatCanvasRow.groupNotice`), in the room
    /// log's order between the messages.
    static func groupNotice(_ row: BotModeRoomNoticeRow, sourceOrder: Int, createdAt: Double) -> TimelineItem {
        var metadata = TimelineMetadata(timestamp: Date(timeIntervalSince1970: createdAt), sourceOrder: sourceOrder)
        metadata.groupNotice = row
        return TimelineItem(id: "room-notice:\(row.id)", role: .assistant,
                            sender: .system(id: "hermes-room", snapshot: .init(name: "Hermes")),
                            content: .message(row.text), metadata: metadata)
    }
}

enum BotModeRoomNoticePresentation {
    /// The rows for a room's notices, in log order. `names` maps a member ID to the name the
    /// room shows; a member no longer in it is left out, and a line naming nobody is skipped.
    /// `messages` are the room's messages, which count toward a pause and end its choice.
    /// `allowsContinue` is false where the computer can't continue a discussion.
    static func rows(
        notices: [BotModeRoomNotice], messages: [HermesBotModeEvent], names: [String: String],
        maximumContinues: Int?, allowsContinue: Bool = true
    ) -> [(notice: BotModeRoomNotice, row: BotModeRoomNoticeRow)] {
        let ordered = notices.sorted { $0.event.sequence < $1.event.sequence }
        let pauses = Pauses(notices: ordered, messages: messages)
        return ordered.compactMap { notice in
            let event = notice.event
            let row: BotModeRoomNoticeRow? = switch event.kind {
            case "room.assignment": line(event, assignment(event.payload, names: names))
            case "room.routed": line(event, routed(event.payload, names: names))
            case "room.continued": BotModeRoomNoticeRow(id: event.eventID, text: "Continued", kind: .continued)
            case "room.activity":
                event.discussionEventID.map { discussion in
                    BotModeRoomNoticeRow(
                        id: event.eventID, text: pausedText(pauses.messageCount(before: event)),
                        kind: .paused(discussionEventID: discussion, isActionable: allowsContinue
                            && pauses.isActionable(event, maximumContinues: maximumContinues)))
                }
            default: nil
            }
            return row.map { (notice, $0) }
        }
    }

    private static func line(_ event: HermesBotModeEvent, _ text: String?) -> BotModeRoomNoticeRow? {
        text.map { BotModeRoomNoticeRow(id: event.eventID, text: $0, kind: .routing) }
    }

    /// "Pixel gave this to Scout", or "Pixel is taking this" when the lead keeps it (it picked
    /// itself, or its pick named nobody and Hermes gave it the message).
    private static func assignment(_ payload: [String: BighelpJSONValue], names: [String: String]) -> String? {
        let leadID = payload["lead_member_id"]?.string
        let lead = leadID.flatMap { names[$0] } ?? "The lead"
        let ids = memberIDs(payload)
        if payload["fallback"]?.boolean == true || (leadID != nil && ids == [leadID]) {
            return names[leadID ?? ""] == nil ? nil : "\(lead) is taking this"
        }
        return joined(ids, names: names).map { "\(lead) gave this to \($0)" }
    }

    /// "Assigned to Scout and Echo", "Assigned to everyone", or the fallback to everyone.
    private static func routed(_ payload: [String: BighelpJSONValue], names: [String: String]) -> String? {
        if payload["fallback"]?.boolean == true { return "Couldn’t choose who answers, so everyone will" }
        if payload["everyone"]?.boolean == true { return "Assigned to everyone" }
        return joined(memberIDs(payload), names: names).map { "Assigned to \($0)" }
    }

    private static func memberIDs(_ payload: [String: BighelpJSONValue]) -> [String] {
        payload["member_ids"]?.array?.prefix(128).compactMap(\.string) ?? []
    }

    private static func joined(_ ids: [String], names: [String: String]) -> String? {
        let known = ids.compactMap { names[$0] }
        return known.isEmpty ? nil : ListFormatter.localizedString(byJoining: known)
    }

    private static func pausedText(_ count: Int) -> String {
        switch count {
        case 0: "Paused."
        case 1: "Paused after 1 message."
        default: "Paused after \(count) messages."
        }
    }

    /// What decides each pause: the messages its discussion had before it, and whatever came
    /// after it. Mirrors Hermes' `paused_discussion`.
    private struct Pauses {
        private var memberMessages: [String: [Int]] = [:]
        private var sources: [String: Int] = [:]
        private var latestUserMessage: [String: Int] = [:]
        private var latestStop = 0
        private var latestMove: [String: Int] = [:]
        private var continues: [String: Int] = [:]

        init(notices: [BotModeRoomNotice], messages: [HermesBotModeEvent]) {
            for message in messages {
                switch message.kind {
                case "message.member":
                    if let discussion = message.discussionEventID {
                        memberMessages[discussion, default: []].append(message.sequence)
                    }
                case "message.user":
                    sources[message.eventID] = message.sequence
                    if let thread = message.threadID {
                        latestUserMessage[thread] = max(latestUserMessage[thread] ?? 0, message.sequence)
                    }
                default: break
                }
            }
            for notice in notices {
                let event = notice.event
                switch event.kind {
                case "room.stop_requested": latestStop = max(latestStop, event.sequence)
                case "room.continued", "room.activity":
                    guard let discussion = event.discussionEventID else { continue }
                    latestMove[discussion] = max(latestMove[discussion] ?? 0, event.sequence)
                    if event.kind == "room.continued" { continues[discussion, default: 0] += 1 }
                default: break
                }
            }
        }

        func messageCount(before pause: HermesBotModeEvent) -> Int {
            guard let discussion = pause.discussionEventID else { return 0 }
            return memberMessages[discussion]?.filter { $0 < pause.sequence }.count ?? 0
        }

        /// Continue and Stop still mean something: no later pause or Continue for this
        /// discussion, no Stop after its message, no newer message in its thread, and a
        /// Continue left.
        func isActionable(_ pause: HermesBotModeEvent, maximumContinues: Int?) -> Bool {
            guard let discussion = pause.discussionEventID else { return false }
            let source = sources[discussion] ?? pause.sequence
            return (latestMove[discussion] ?? 0) <= pause.sequence
                && latestStop <= source
                && pause.threadID.map { (latestUserMessage[$0] ?? 0) <= pause.sequence } ?? true
                && maximumContinues.map { (continues[discussion] ?? 0) < $0 } ?? true
        }
    }
}
