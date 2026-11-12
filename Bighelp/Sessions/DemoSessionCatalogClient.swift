import Foundation

@MainActor
final class DemoSessionCatalogClient: SessionCatalogClient {
    private var records: [SessionRecord]
    private var archived = DemoSessionCatalogClient.archivedFixtures

    var canDeleteArchivedChats: Bool { true }

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

    func archivedChats() async throws -> [SessionArchivedChat] { archived }

    func restoreArchivedChat(_ chat: SessionArchivedChat) async throws {
        archived.removeAll { $0.id == chat.id }
    }

    /// The Telegram row is still open on its gateway, so Hermes refuses it.
    func deleteArchivedChat(_ chat: SessionArchivedChat) async throws {
        guard chat.storedID != "demo-archived-garage" else {
            throw WorkspaceClientError.rejected(code: "4023", message: HermesRefusalMessage("cannot delete an active session"))
        }
        archived.removeAll { $0.id == chat.id }
    }

    func create(kind: SessionKind, agentIDs: [String]) async throws -> SessionRecord {
        #if DEBUG
        // A real computer can take seconds to make a chat; the blank canvas shows meanwhile.
        if ProcessInfo.processInfo.arguments.contains("-test-slow-new-chat") {
            try await Task.sleep(for: .seconds(4))
        }
        #endif
        let record = SessionRecord(
            id: "session_\(UUID().uuidString.lowercased())",
            kind: kind,
            agentIDs: agentIDs,
            title: "New chat"
        )
        records.append(record)
        return record
    }

    func createSession(agentID: String, folder: String, title: String,
                       runtime: SessionStartRuntime) async throws -> SessionRecord {
        let record = SessionRecord(
            id: "session_\(UUID().uuidString.lowercased())",
            kind: .direct,
            agentIDs: [agentID],
            title: title
        )
        records.append(record)
        return record
    }

    /// Read state as Hermes keeps it, on the demo's own rows.
    func setUnread(_ record: SessionRecord, unread: Bool) async throws {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else {
            throw SessionCatalogError.invalidSession
        }
        records[index].isUnread = unread
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
            // A chat started in the demo keeps what was sent in it, as a host saves it.
            if canonical.items.isEmpty, !record.items.isEmpty {
                return SessionHydrationPage(record: record, nextOffset: nil)
            }
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

    static let archivedFixtures: [SessionArchivedChat] = [
        .init(profileID: "travel", storedID: "demo-archived-lisbon", title: "Packing list for the Lisbon trip",
              source: "imessage", preview: nil, lastActive: Date(timeIntervalSinceNow: -86_400)),
        .init(profileID: "finance", storedID: "demo-archived-garage", title: "Fix the garage door opener",
              source: "telegram", preview: nil, lastActive: Date(timeIntervalSinceNow: -259_200)),
        .init(profileID: "travel", storedID: "demo-archived-book-club", title: "Book club notes",
              source: "bighelp", preview: nil, lastActive: Date(timeIntervalSinceNow: -691_200)),
    ]

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
            isUnread: false,
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
            // A reply nobody has read yet, as Hermes lists one.
            isUnread: true,
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
        // Group chats get everyday names: the onboarding previews and store screenshots show them.
        let groupNames = ["Weekend trip", "Family budget", "Home projects", "Dinner plans",
                          "Gift ideas", "Moving day", "Garden plans", "Party planning"]
        let previews = ["Here's the plan for Saturday.", "Booked! The details are in your email.",
                        "I moved your 3 PM to Thursday.", "The shopping list is ready.",
                        "Your flight is on time.", "I found three good options."]
        return SessionRecord(
            id: "demo-session-\(index)",
            kind: kind,
            agentIDs: agentIDs,
            title: kind == .botMode ? groupNames[(index / 3) % groupNames.count] : "Direct session \(index)",
            remoteSource: kind == .botMode ? nil : sources[index % sources.count],
            // A half-written message waits in one chat's message box.
            draft: index == 2 ? "Can you add oat milk and" : "",
            items: [
                TimelineItem(
                    id: "demo-session-\(index)-message",
                    role: .assistant,
                    sender: .agent(id: agentIDs[0], snapshot: .init(name: "Assistant")),
                    content: .message(index.isMultiple(of: 4) ? "Budget planning update" : previews[(index / 3) % previews.count]),
                    metadata: TimelineMetadata(delivery: "Delivered")
                )
            ],
            isUnread: index == 7 || index == 5,
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
