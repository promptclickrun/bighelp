import Foundation

@MainActor
final class DemoSessionCatalogClient: SessionCatalogClient {
    private var records: [SessionRecord]

    init(records: [SessionRecord] = DemoSessionCatalogClient.fixtureRecords) {
        self.records = records
    }

    static func canonicalID(profileID: String, records: [SessionRecord]) throws -> String {
        if let canonical = records.first(where: {
            $0.id == "demo-canonical-\(profileID)" && $0.agentIDs == [profileID]
        }) { return canonical.id }
        guard let canonical = records.first(where: {
            $0.id == "demo-\(profileID)" && $0.agentIDs == [profileID]
        }) else { throw SessionCatalogError.invalidSession }
        return canonical.id
    }

    func list() async throws -> [SessionRecord] {
        records
    }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        let record = SessionRecord(
            id: "session_\(UUID().uuidString.lowercased())",
            kind: kind,
            agentIDs: agentIDs,
            title: "New chat"
        )
        records.append(record)
        return record
    }

    func refreshMetadata(_ record: SessionRecord) async throws -> SessionRecord? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-test-held-session-metadata") {
            try await Task.sleep(for: .seconds(15))
        }
        #endif
        return nil
    }

    func hydratePage(
        _ record: SessionRecord,
        offset: Int?,
        turnLimit: Int
    ) async throws -> SessionHydrationPage {
        guard let canonical = records.first(where: { $0.id == record.id }) else {
            throw SessionCatalogError.invalidSession
        }
        #if DEBUG
        if offset == nil,
           ProcessInfo.processInfo.arguments.contains("-test-held-session-history") {
            try await Task.sleep(for: .seconds(60))
        }
        #endif
        guard canonical.id == "demo-tool-folder-anchor" else {
            guard offset == nil else { throw SessionCatalogError.invalidSession }
            return SessionHydrationPage(record: canonical, nextOffset: nil)
        }
        switch offset {
        case nil:
            var recent = canonical
            recent.items = Array(canonical.items.suffix(1))
            return SessionHydrationPage(record: recent, nextOffset: 1)
        case 1:
            var older = canonical
            older.items = Array(canonical.items.dropLast())
            older.activityEvents = []
            return SessionHydrationPage(record: older, nextOffset: nil)
        default:
            throw SessionCatalogError.invalidSession
        }
    }

    static let fixtureRecords: [SessionRecord] = [
        longTranscriptFixture,
        timelineExpansionAnchorFixture,
        SessionRecord(
            id: "demo-finance",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Finance",
            workspaceID: "demo-loopdy",
            workspaceName: "bighelp",
            items: ConversationFixtures.initialItems(conversationID: "demo-finance", agentID: "finance", agentName: "Avery Park"),
            hasAcceptedMessage: true
        ),
        SessionRecord(
            id: "demo-travel",
            kind: .direct,
            agentIDs: ["travel"],
            title: "Travel",
            workspaceID: "demo-travel",
            workspaceName: "Travel Planning",
            items: ConversationFixtures.initialItems(conversationID: "demo-travel", agentID: "travel", agentName: "Mina Shah"),
            hasAcceptedMessage: true
        )
    ] + (1...48).map { index in
        let agentIDs: [String] = switch index % 6 {
        case 0: ["finance", "travel"]
        case 1: ["travel"]
        case 2: ["home"]
        case 3: ["finance"]
        case 4: ["archived-agent"]
        default: ["finance", "home"]
        }
        let kind: SessionKind = agentIDs.count > 1 ? .botMode : .direct
        let updatedAt = Date.now.addingTimeInterval(TimeInterval(-index * 3_600))
        // Where each chat started, as Hermes reports it, for the tags and the Started in filter.
        let sources = ["desktop", "telegram", "tui", "claude-code", "codex-cli", "bighelp"]
        return SessionRecord(
            id: "demo-session-\(index)",
            kind: kind,
            agentIDs: agentIDs,
            title: "\(kind == .botMode ? "Shared" : "Direct") session \(index)",
            remoteSource: kind == .botMode ? nil : sources[index % sources.count],
            items: [
                TimelineItem(
                    id: "demo-session-\(index)-message",
                    role: .assistant,
                    sender: .agent(id: agentIDs[0], snapshot: .init(name: "Assistant")),
                    content: .message(index.isMultiple(of: 4) ? "Budget planning update" : "Saved fixture conversation"),
                    metadata: TimelineMetadata(delivery: "Delivered")
                )
            ],
            createdAt: updatedAt,
            updatedAt: updatedAt,
            hasAcceptedMessage: true
        )
    }

    private static var longTranscriptFixture: SessionRecord {
        let sessionID = "demo-long-transcript"
        var items: [TimelineItem] = []
        var activities: [ChatActivityEvent] = []
        var sourceOrder = 1
        for index in 1...901 {
            items.append(TimelineItem(
                id: "\(sessionID)-message-\(index)",
                role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Avery Park")),
                content: .message(
                    index == 901
                        ? "Long transcript settled sentinel 1000"
                        : "Long transcript settled message \(index)"
                ),
                metadata: .init(delivery: "Delivered", sourceOrder: sourceOrder)
            ))
            sourceOrder += 1
            if index <= 891, index.isMultiple(of: 9) {
                activities.append(ChatActivityEvent(
                    eventID: "\(sessionID)-activity-\(index)",
                    sessionID: sessionID,
                    turnID: "\(sessionID)-turn-\(index)",
                    kind: .tool,
                    lifecycle: .succeeded,
                    title: "Fixture activity \(index / 9)",
                    summary: "Completed synthetic work",
                    detail: nil,
                    occurredAt: sourceOrder,
                    toolCallID: "\(sessionID)-call-\(index)",
                    toolName: "fixture_tool",
                    arguments: #"{"fixture":true}"#,
                    result: #"{"ok":true}"#,
                    sourceOrder: sourceOrder
                ))
                sourceOrder += 1
            }
        }
        return SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["finance"],
            title: "Long transcript efficiency fixture",
            items: items,
            activityEvents: activities,
            hasAcceptedMessage: true
        )
    }

    private static var timelineExpansionAnchorFixture: SessionRecord {
        let sessionID = "demo-tool-folder-anchor"
        let turnID = "demo-tool-folder-anchor-turn"
        let sender = TimelineSender.agent(
            id: "finance",
            snapshot: .init(name: "Avery Park")
        )
        let earlierMessages = (1...20).map { (index: Int) in
            TimelineItem(
                id: "\(sessionID)-earlier-\(index)",
                role: .assistant,
                sender: sender,
                content: .message(
                    "Earlier fixture update \(index) keeps this restored conversation taller than one screen."
                ),
                metadata: .init(delivery: "Delivered", sourceOrder: index)
            )
        }
        let finalAnswer = TimelineItem(
            id: "\(sessionID)-final",
            role: .assistant,
            sender: sender,
            content: .message("Anchor sentinel stays visible."),
            metadata: .init(delivery: "Delivered", sourceOrder: 40)
        )
        let toolEvents = (1...9).map { (index: Int) in
            ChatActivityEvent(
                eventID: "\(sessionID)-tool-event-\(index)",
                sessionID: sessionID,
                turnID: turnID,
                kind: .tool,
                lifecycle: .succeeded,
                title: "Tool activity",
                summary: "Completed fixture tool call \(index)",
                detail: nil,
                occurredAt: 20 + index,
                toolCallID: "\(sessionID)-tool-call-\(index)",
                toolName: "fixture_tool_\(index)",
                arguments: #"{"fixture":true}"#,
                result: #"{"ok":true}"#,
                sourceOrder: 20 + index
            )
        }
        return SessionRecord(
            id: sessionID,
            kind: .direct,
            agentIDs: ["finance"],
            title: "Tool folder anchor regression",
            items: earlierMessages + [finalAnswer],
            activityEvents: toolEvents,
            hasAcceptedMessage: true
        )
    }
}
