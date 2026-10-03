import Foundation

/// Turns the phone's chats, needs and boards into what the Watch shows:
/// plain text, newest first, cut to fit a message.
enum WatchRelayProjection {
    static func needs(_ items: [DashboardAttentionItem], agentNames: [String: String],
                      now: Date = .now) -> [WatchNeed] {
        let needs: [WatchNeed] = items.compactMap { item in
            let agent = WatchWire.bounded(item.agentID.flatMap { agentNames[$0] } ?? "bighelp", bytes: WatchLimits.name)
            switch item.interaction {
            case .approval(let summary):
                guard !summary.isExpired(at: now) else { return nil }
                let offered = Set(summary.allowedDecisions.map(\.rawValue))
                return WatchNeed(
                    id: item.id, kind: .approval,
                    title: WatchWire.bounded(item.title, bytes: WatchLimits.title),
                    detail: WatchWire.bounded(item.detail, bytes: WatchLimits.detail),
                    agentName: agent, sessionID: item.sessionID, createdAt: item.createdAt,
                    decisions: WatchDecision.allCases.filter { offered.contains($0.rawValue) },
                    choices: [], allowsTyping: false, answerOnPhone: false,
                    link: .approval(summary.approvalID, title: WatchWire.bounded(item.title, bytes: WatchLimits.title))
                )
            case .clarification(let request):
                guard !request.isExpired(at: now) else { return nil }
                let simple = isSimple(request)
                return WatchNeed(
                    id: item.id, kind: .question,
                    title: WatchWire.bounded(item.title, bytes: WatchLimits.title),
                    detail: WatchWire.bounded(request.question.isEmpty ? item.detail : request.question,
                                              bytes: WatchLimits.detail),
                    agentName: agent, sessionID: item.sessionID ?? request.sessionID, createdAt: item.createdAt,
                    decisions: [],
                    choices: simple ? request.choices : [],
                    allowsTyping: simple && request.allowsCustomResponse,
                    answerOnPhone: !simple,
                    link: .chat(item.sessionID ?? request.sessionID,
                                title: WatchWire.bounded(item.title, bytes: WatchLimits.title))
                )
            case .none:
                return nil
            }
        }
        return Array(needs.sorted { $0.createdAt > $1.createdAt }.prefix(WatchLimits.needs))
    }

    /// One question with a few short choices; anything more is answered on the phone.
    static func isSimple(_ request: DashboardClarificationRequest) -> Bool {
        request.questions.count == 1 && !request.isMultiSelect
            && request.questions[0].lockedAnswer == nil
            && request.choices.count <= WatchLimits.choices
            && request.choices.allSatisfy { $0.utf8.count <= 500 }
            && (request.allowsCustomResponse || !request.choices.isEmpty)
    }

    static func chats(_ summaries: [SessionSummary], agentNames: [String: String],
                      isSending: (String) -> Bool) -> [WatchChatSummary] {
        summaries
            .filter { $0.kind == .direct }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(WatchLimits.chats)
            .map { summary in
                let agentID = summary.agentIDs.first
                return WatchChatSummary(
                    id: summary.id,
                    title: WatchWire.bounded(summary.title.isEmpty ? "New chat" : summary.title, bytes: WatchLimits.title),
                    agentID: agentID,
                    agentName: WatchWire.bounded(agentID.flatMap { agentNames[$0] } ?? "bighelp", bytes: WatchLimits.name),
                    preview: WatchWire.bounded(summary.preview, bytes: WatchLimits.preview),
                    updatedAt: summary.updatedAt,
                    isWorking: summary.isActive || isSending(summary.id)
                )
            }
    }

    static func chat(_ record: SessionRecord, items: [TimelineItem], isWorking: Bool,
                     activityEvents: [ChatActivityEvent] = [], agentNames: [String: String]) -> WatchChat {
        let agentID = record.agentIDs.first
        let messages: [WatchMessage] = items.compactMap { item in
            guard case .message(let raw) = item.content else { return nil }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Silence markers aren't words for the person.
            guard !text.isEmpty, !(item.role == .assistant && ChatSilentReply.isMarker(text)) else { return nil }
            return WatchMessage(
                id: WatchWire.bounded(item.id, bytes: WatchLimits.id),
                isYou: item.role == .human,
                text: excerpt(text, bytes: WatchLimits.message),
                at: item.metadata.timestamp ?? record.updatedAt
            )
        }
        var seen = Set<String>()
        let unique = messages.reversed().filter { seen.insert($0.id).inserted }.reversed()
        return WatchChat(
            sessionID: record.id,
            title: WatchWire.bounded(record.title.isEmpty ? "New chat" : record.title, bytes: WatchLimits.title),
            agentName: WatchWire.bounded(agentID.flatMap { agentNames[$0] } ?? "bighelp", bytes: WatchLimits.name),
            messages: Array(unique.suffix(WatchLimits.messages)),
            isWorking: isWorking,
            activity: isWorking ? ChatActivityPresentation.liveLabel(for: activityEvents)
                .map { WatchWire.bounded($0, bytes: WatchLimits.name) } : nil
        )
    }

    static func board(_ items: [AgentBoardItem], kind: WatchBoardKind) -> [WatchBoardItem] {
        let wanted: AgentBoardItem.Kind = switch kind {
        case .feed: .feed
        case .ideas: .idea
        case .goals: .goal
        }
        return items
            .filter { $0.kind == wanted && !$0.dismissed }
            // Goals still being worked on come before finished ones.
            .sorted { lhs, rhs in
                if kind == .goals, lhs.isDone != rhs.isDone { return !lhs.isDone }
                return lhs.createdAt > rhs.createdAt
            }
            .prefix(WatchLimits.boardItems)
            .map { item in
                WatchBoardItem(
                    id: WatchWire.bounded(item.id, bytes: WatchLimits.id),
                    title: WatchWire.bounded(item.title.isEmpty ? kind.title : item.title, bytes: WatchLimits.title),
                    body: excerpt(item.body, bytes: WatchLimits.body),
                    icon: WatchWire.bounded(item.icon, bytes: 64),
                    status: WatchWire.bounded(item.status, bytes: 64),
                    note: WatchWire.bounded(item.note, bytes: WatchLimits.preview),
                    createdAt: item.createdAt,
                    isUnread: !item.read
                )
            }
    }

    /// Only bighelp's own links.
    static func openableURL(_ string: String) -> URL? {
        guard let url = URL(string: string), BighelpIncomingURLRoute.parse(url) != nil else { return nil }
        return url
    }

    /// The start of a long text, ending in "…" when it was cut.
    static func excerpt(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        return WatchWire.bounded(text, bytes: bytes - 3).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
