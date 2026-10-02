import Foundation
#if DEBUG
import UIKit
#endif

enum ConversationFixtureError: Error {
    case unavailable
}

@MainActor
class ConversationFixtureClient: AttachmentConversationClient {
    private(set) var receivedAttachments: [ChatAttachment] = []
    private var responseSequence = 1
    private let shouldFail: Bool
    private let canonicalAgentID: String
    private let agentSnapshot: TimelineSenderSnapshot

    init(
        shouldFail: Bool = false,
        canonicalAgentID: String = "default",
        agentDisplayName: String = "Assistant",
        agentAvatarFileName: String? = nil
    ) {
        self.shouldFail = shouldFail
        self.canonicalAgentID = canonicalAgentID
        agentSnapshot = TimelineSenderSnapshot(name: agentDisplayName, avatarFileName: agentAvatarFileName)
    }

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        guard !shouldFail else { throw ConversationFixtureError.unavailable }

        return ConversationResponse(items: [
            assistantItem(
                conversationID: conversationID,
                content: .message("Here’s the latest fixture update. Your priorities are on track, and I’ll keep the plan current as new work arrives.")
            )
        ])
    }

    func send(message: String, attachments: [ChatAttachment], conversationID: String,
              onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        receivedAttachments = attachments
        if let streaming = self as? any StreamingConversationClient {
            return try await streaming.send(message: message, conversationID: conversationID, onDraft: onDraft)
        }
        return try await send(message: message, conversationID: conversationID)
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        guard !shouldFail else { throw ConversationFixtureError.unavailable }

        let content: TimelineContent = switch action {
        case .weatherAndTasks:
            .weatherAndTasks(ConversationFixtures.weatherAndTasks)
        case .budgetAndPlan:
            .budgetSummary(ConversationFixtures.budgetSummary)
        case .vendorApproval:
            .approvalRequest(.vendorFixture)
        }

        return ConversationResponse(items: [
            assistantItem(conversationID: conversationID, content: content)
        ])
    }

    private func assistantItem(
        conversationID: String,
        content: TimelineContent
    ) -> TimelineItem {
        defer { responseSequence += 1 }
        return TimelineItem(
            id: "fixture-\(conversationID)-response-\(responseSequence)",
            role: .assistant,
            sender: .agent(id: canonicalAgentID, snapshot: agentSnapshot),
            content: content,
            metadata: TimelineMetadata(source: "bighelp demo data", freshness: "Updated just now")
        )
    }
}

@MainActor
final class MidSessionConversationFixtureClient: ConversationFixtureClient, MidSessionConversationClient {
    func sendMidSession(
        message: String,
        attachments: [ChatAttachment],
        conversationID: String,
        behavior: MidSessionChatBehavior,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> MidSessionSubmissionOutcome {
        .accepted
    }
}

enum ConversationFixtures {
    /// Explicit simulator preview data, never inserted into an authenticated account.
    static var uiV3Preview: SessionRecord {
        let sessionID = "demo-finance"
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let items = [
            TimelineItem(id: "v3-sample-user-2", role: .human, sender: .user(snapshot: .init(name: "You")),
                         content: .message("A calmer chat, with all of our tools."),
                         metadata: .init(source: "UI preview", sourceOrder: 3)),
            TimelineItem(id: "v3-sample-assistant-2", role: .assistant, sender: agent,
                         content: .message("**Room for the conversation.**\n\nYour model, rich drafts, files, and voice stay close. Project Changes and grouped activity are still right here."),
                         metadata: .init(source: "Sample conversation", sourceOrder: 6))
        ]
        let activity = ["Reviewing layout", "Checking controls"].enumerated().map { index, title in
            ChatActivityEvent(eventID: "v3-sample-tool-\(index)", sessionID: sessionID,
                              turnID: "v3-sample-turn", kind: .tool, lifecycle: .succeeded,
                              title: title, summary: "Sample completed activity", detail: nil,
                              occurredAt: 4 + index, toolCallID: "v3-sample-call-\(index)",
                              toolName: "preview_check", arguments: "{\"sample\":true}",
                              result: "{\"sample\":true}", sourceOrder: 4 + index)
        }
        return SessionRecord(id: sessionID, kind: .direct, agentIDs: ["finance"], title: "UI V3 Preview",
                             workspaceID: "demo-loopdy", workspaceName: "bighelp",
                             sessionRuntime: .init(model: "gpt-5.6", provider: "openai", observedAt: Date()),
                             items: items, activityEvents: activity, hasAcceptedMessage: true)
    }

    #if DEBUG
    static var nativeReactionPreview: SessionRecord {
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let items = [
            TimelineItem(id: "native-reaction-fixture:row:101", role: .human,
                         sender: .user(snapshot: .init(name: "You")),
                         content: .message("A calmer chat, with all of our tools."),
                         metadata: .init(source: "UI preview", sourceOrder: 1)),
            TimelineItem(id: "native-reaction-fixture:row:102", role: .assistant,
                         sender: agent,
                         content: .message("**Room for the conversation.**\n\nYour model, rich drafts, files, and voice stay close."),
                         metadata: .init(source: "UI preview", sourceOrder: 2)),
        ]
        return SessionRecord(
            id: "demo-finance",
            kind: .direct,
            agentIDs: ["finance"],
            title: "Reaction interaction preview",
            workspaceID: "demo-loopdy",
            workspaceName: "bighelp",
            sessionRuntime: .init(model: "gpt-5.6", provider: "openai", observedAt: Date()),
            items: items,
            hasAcceptedMessage: true
        )
    }

    static var inlineMentionsPreview: SessionRecord {
        let items = [
            TimelineItem(id: "inline-mentions-human", role: .human,
                sender: .user(snapshot: .init(name: "You")),
                content: .message("Before @avery-park, ask @all about the plan; then @avery-park can review it. After."),
                metadata: .init(sourceOrder: 1)),
            TimelineItem(id: "inline-mentions-agent", role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Avery Park")),
                content: .message("Ask @jordan-lee for a second opinion. Code stays plain: `@all`."),
                metadata: .init(sourceOrder: 2))
        ]
        return SessionRecord(id: "demo-finance", kind: .direct, agentIDs: ["finance"],
            title: "Inline mentions", items: items, hasAcceptedMessage: true)
    }

    static var simpleChatPreview: SessionRecord {
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let now = Date()
        let entries: [(String, TimelineRole, String)] = [
            ("simple-welcome", .assistant, "Hey there! I’m Avery.\nI can help you brainstorm ideas, plan your day, answer questions, and more."),
            ("simple-question", .human, "Can you help me plan a 3-day trip to Kyoto?"),
            ("simple-answer", .assistant, "Absolutely! Here’s a high-level itinerary for a 3-day trip to Kyoto, with a mix of culture, food, and hidden gems."),
            ("simple-followup", .human, "This is perfect! Can you add a few local food spots?")
        ]
        let items = entries.enumerated().map { index, entry in
            TimelineItem(id: entry.0, role: entry.1,
                sender: entry.1 == .assistant ? agent : .user(snapshot: .init(name: "You")),
                content: .message(entry.2),
                metadata: .init(source: "UI preview", timestamp: now.addingTimeInterval(Double(index - 3) * 60), sourceOrder: index))
        }
        return SessionRecord(id: "demo-finance", kind: .direct, agentIDs: ["finance"], title: "Kyoto trip",
            workspaceID: "demo-loopdy", workspaceName: "bighelp",
            sessionContext: .init(sessionId: "demo-finance", model: "gpt-5.6", contextUsed: 29100,
                contextMax: 1000000, contextPercent: 3, compressions: 0, isCompacting: false,
                updatedAt: Int(now.timeIntervalSince1970)),
            sessionRuntime: .init(model: "gpt-5.6", provider: "openai", observedAt: now),
            items: items, hasAcceptedMessage: true)
    }
    #endif

    #if DEBUG
    static var toolDisclosureScrollPreview: SessionRecord {
        var session = uiV3Preview
        session.items += (0..<8).map { index in
            TimelineItem(id: "tool-review-history-\(index)", role: .assistant,
                sender: .agent(id: "finance", snapshot: .init(name: "Avery Park")),
                content: .message(String(repeating: "History \(index) after the completed tool.\n", count: 4)),
                metadata: .init(source: "UI fixture", sourceOrder: 10 + index))
        }
        return session
    }

    static var completedTurnContextPreview: SessionRecord {
        let sessionID = "demo-finance"
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let messages: [(String, String, Int)] = [
            ("fold-preamble", "I checked the release options.", 2),
            ("fold-context", "TestFlight keeps this build private. Public release makes it available to everyone.", 4),
            ("fold-answer", "The compatibility flag must stay enabled for existing clients.", 6),
            ("fold-verification", "Verification confirmed that recommendation.", 8),
        ]
        let items = [TimelineItem(id: "fold-user", role: .human, sender: .user(snapshot: .init(name: "You")),
                                  content: .message("Review the release options."), metadata: .init(sourceOrder: 1))]
            + messages.map { id, text, order in
                TimelineItem(id: id, role: .assistant, sender: agent, content: .message(text),
                             metadata: .init(sourceOrder: order, turnDurationMilliseconds: order == 8 ? 10_000 : nil))
            }
        let activity = [("fold-inspection", "Inspecting release", 3), ("fold-verifier", "Verifying compatibility", 7)].map { id, title, order in
            ChatActivityEvent(eventID: id, sessionID: sessionID, turnID: "fold-preview-turn",
                              kind: .tool, lifecycle: .succeeded, title: title, summary: "Completed", detail: nil,
                              occurredAt: order, toolCallID: "call-\(id)", toolName: "preview_check",
                              arguments: "{\"preview\":true}", result: "Verified preview", sourceOrder: order)
        }
        return SessionRecord(id: sessionID, kind: .direct, agentIDs: ["finance"], title: "Completed Turn Context",
                             items: items, activityEvents: activity,
                             activityVisibility: .init(showReasoning: true, showToolCalls: true), hasAcceptedMessage: true)
    }

    /// `-test-card-replies`: the agent asks with a selection card and a form;
    /// answering either sends the answer as the person's next message.
    static var cardRepliesPreview: SessionRecord {
        let sessionID = "demo-finance"
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        // Hosts deliver cards as a fenced block in the reply's text.
        func card(_ document: [String: Any]) -> String {
            let json = try! JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            return "```\(ChatCardMessageProjection.fenceLanguage)\n" + String(decoding: json, as: UTF8.self) + "\n```"
        }
        let common: [String: Any] = [
            "schema": "loopdy.generative_ui", "version": 2, "created_at": "2026-09-30T18:00:00Z", "origin": "live",
        ]
        let selection = card(common.merging([
            "component": "selection", "title": "Where to this weekend?",
            "card_id": "5e1ec7105e1ec7105e1ec7105e1ec710",
            "content_hash": String(repeating: "a", count: 64),
            "provenance": ["source_name": "Trip ideas"],
            "data": [
                "description": "Pick one and I'll plan the rest.",
                "mode": "single", "submit_label": "Send",
                "options": [
                    ["id": "coast", "label": "The coast", "detail": "2 hours, ocean views", "enabled": true,
                     "stage_text": "Let's go to the coast."],
                    ["id": "mountains", "label": "The mountains", "detail": "3 hours, hiking and a cabin",
                     "enabled": true, "stage_text": "Let's go to the mountains."],
                    ["id": "city", "label": "A city weekend", "detail": "Museums and food", "enabled": true,
                     "stage_text": "Let's do a city weekend."],
                ],
            ],
        ]) { $1 })
        let form = card(common.merging([
            "component": "form", "title": "Trip details",
            "card_id": "f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0",
            "content_hash": String(repeating: "b", count: 64),
            "action": [
                "kind": "submit_form", "request_id": "f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0",
                "owner": ["profile": "finance", "session_id": "demo-finance-stored"],
                "expires_at": "2026-10-07T18:00:00Z",
            ],
            "data": [
                "description": "A few details so I can book the right things.",
                "submit_label": "Send",
                "fields": [
                    ["id": "travelers", "kind": "integer", "label": "Travelers", "required": true, "default": 2],
                    ["id": "pace", "kind": "select", "label": "Pace", "required": true,
                     "options": [["id": "slow", "label": "Slow and easy"], ["id": "packed", "label": "Packed"]]],
                    ["id": "pet", "kind": "toggle", "label": "Bringing the dog", "required": false],
                    ["id": "notes", "kind": "textarea", "label": "Anything else", "required": false],
                ],
            ],
        ]) { $1 })
        let items = [
            TimelineItem(id: "cards-q", role: .human, sender: .user(snapshot: .init(name: "You")),
                         content: .message("Can you help me plan a weekend trip?"), metadata: .init(sourceOrder: 10)),
            TimelineItem(id: "cards-intro", role: .assistant, sender: agent,
                         content: .message("Happy to. Pick a place, then fill in the details."),
                         metadata: .init(sourceOrder: 20)),
            TimelineItem(id: "cards-selection", role: .assistant, sender: agent, content: .message(selection),
                         metadata: .init(sourceOrder: 30)),
            TimelineItem(id: "cards-form", role: .assistant, sender: agent, content: .message(form),
                         metadata: .init(sourceOrder: 40)),
        ]
        return SessionRecord(id: sessionID, kind: .direct, agentIDs: ["finance"], title: "Weekend trip",
                             items: items, hasAcceptedMessage: true)
    }

    /// `-test-thinking-style`: a finished turn (thinking, two interim messages,
    /// tools, answer) and a turn still in progress with visible thinking.
    /// `-test-loader-chat`: every chat loader with made-up data. A finished
    /// turn (folds into "Worked for 14s · 3 steps") with two files still on
    /// their way, then a live one: thinking
    /// done, a run of browser steps still going, a picture being made and a
    /// forecast card streaming in. With `waiting`, the live run is paused on a
    /// secure input request instead.
    static func loaderChatPreview(waiting: Bool = false) -> SessionRecord {
        let sessionID = "demo-finance"
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        func human(_ id: String, _ text: String, _ order: Int) -> TimelineItem {
            TimelineItem(id: id, role: .human, sender: .user(snapshot: .init(name: "You")),
                         content: .message(text), metadata: .init(sourceOrder: order))
        }
        func tool(_ id: String, _ turn: String, _ name: String, _ arguments: String, _ order: Int,
                  ms: Int? = nil, running: Bool = false) -> ChatActivityEvent {
            ChatActivityEvent(eventID: id, sessionID: sessionID, turnID: turn, kind: .tool,
                              lifecycle: running ? .running : .succeeded, title: name,
                              summary: nil, detail: nil, occurredAt: order, durationMilliseconds: ms,
                              toolCallID: "call-\(id)", toolName: name, arguments: arguments,
                              result: running ? nil : "Done", sourceOrder: order)
        }
        func thought(_ id: String, _ turn: String, _ text: String, _ order: Int, ms: Int) -> ChatActivityEvent {
            ChatActivityEvent(eventID: id, sessionID: sessionID, turnID: turn, kind: .reasoning,
                              lifecycle: .succeeded, title: "Reasoning", summary: nil, detail: text,
                              occurredAt: order, durationMilliseconds: ms, sourceOrder: order)
        }
        let card = #"{"card_id":"0f1e2d3c4b5a69788796a5b4c3d2e1f0","component":"weather_forecast","content_hash":"#
        // A made-up photo the person sent, for touch-and-hold Copy and Save.
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).pngData { context in
            let colors = [UIColor(red: 0.98, green: 0.72, blue: 0.55, alpha: 1).cgColor,
                          UIColor(red: 0.45, green: 0.36, blue: 0.75, alpha: 1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 300), options: [])
            }
            UIColor(red: 1, green: 0.9, blue: 0.7, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 250, y: 80, width: 70, height: 70))
        }
        let photoAttachment = (try? ChatAttachment(id: "loader-photo-attachment", fileName: "gion-street.png",
                                                   mimeType: "image/png", data: photo)).map { [$0] } ?? []
        let items = [
            TimelineItem(id: "loader-photo", role: .human, sender: .user(snapshot: .init(name: "You")),
                         content: .message(""), metadata: .init(sourceOrder: 5), attachments: photoAttachment),
            human("loader-q1", "Find me a ryokan near Gion for the October trip?", 10),
            // Files still on their way to the phone show as loading tiles.
            TimelineItem(id: "loader-files", role: .assistant, sender: agent,
                         content: .message("Here's the room and your plan.\nMEDIA:/demo/.hermes/cache/images/"
                                           + "hatanaka-room.png\nMEDIA:/demo/Documents/Kyoto plan.pdf"),
                         metadata: .init(sourceOrder: 55)),
            TimelineItem(id: "loader-a1", role: .assistant, sender: agent,
                         content: .message("Found three near Gion under $400 a night. Hatanaka has your "
                                           + "October 9 check-in open. Want me to hold it?"),
                         metadata: .init(sourceOrder: 60, turnDurationMilliseconds: 14_000)),
            human("loader-q2", "Yes, hold it. Then paint Gion at dusk and add a forecast card.", 70),
            TimelineItem(id: "loader-a2", role: .assistant, sender: agent,
                         content: .message("Here's the week in Kyoto:\n\n```loopdy-card\n" + card),
                         metadata: .init(delivery: "Streaming", sourceOrder: 130)),
        ]
        var activity = [
            thought("loader-r1", "loader-turn-1", "Two nights near Gion, under $400 a night, "
                    + "checking in after the 4 PM landing.", 20, ms: 2_500),
            tool("loader-t1", "loader-turn-1", "web_search", #"{"query":"ryokan near Gion"}"#, 30, ms: 1_900),
            tool("loader-t2", "loader-turn-1", "browser_navigate", #"{"url":"https://stays.example/gion"}"#, 40,
                 ms: 1_200),
            tool("loader-t3", "loader-turn-1", "write_file", #"{"path":"Kyoto plan.md"}"#, 50, ms: 600),
            thought("loader-r2", "loader-turn-2", "Hold the room first, then the picture and the forecast.", 80,
                    ms: 3_000),
            tool("loader-t4", "loader-turn-2", "browser_navigate", #"{"url":"https://stays.example/hold"}"#, 90,
                 ms: 1_400),
            tool("loader-t5", "loader-turn-2", "browser_click", #"{"element":"Hold room"}"#, 100,
                 running: !waiting),
            tool("loader-img", "loader-turn-2", "image_generate", #"{"prompt":"Gion at dusk, watercolor"}"#, 120,
                 running: true),
        ]
        if waiting {
            activity.insert(tool("loader-t6", "loader-turn-2", "bighelp_request_secure_input",
                                 #"{"label":"Booking site password"}"#, 110, running: true), at: 7)
        }
        return SessionRecord(id: sessionID, kind: .direct, agentIDs: ["finance"], title: "Kyoto trip",
                             items: items, activityEvents: activity,
                             activityVisibility: .init(showReasoning: true, showToolCalls: true),
                             isActive: true, hasAcceptedMessage: true)
    }

    static var thinkingStylePreview: SessionRecord {
        let sessionID = "demo-finance"
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        func human(_ id: String, _ text: String, _ order: Int) -> TimelineItem {
            TimelineItem(id: id, role: .human, sender: .user(snapshot: .init(name: "You")),
                         content: .message(text), metadata: .init(sourceOrder: order))
        }
        func reply(_ id: String, _ text: String, _ order: Int, duration: Int? = nil) -> TimelineItem {
            TimelineItem(id: id, role: .assistant, sender: agent, content: .message(text),
                         metadata: .init(sourceOrder: order, turnDurationMilliseconds: duration))
        }
        func tool(_ id: String, _ turn: String, _ title: String, _ name: String, _ order: Int,
                  running: Bool = false) -> ChatActivityEvent {
            ChatActivityEvent(eventID: id, sessionID: sessionID, turnID: turn, kind: .tool,
                              lifecycle: running ? .running : .succeeded, title: title,
                              summary: running ? nil : "Completed", detail: nil, occurredAt: order,
                              toolCallID: "call-\(id)", toolName: name, arguments: "{\"path\":\"budget.csv\"}",
                              result: running ? nil : "Read 42 rows", sourceOrder: order)
        }
        func thought(_ id: String, _ turn: String, _ text: String, _ order: Int, running: Bool = false) -> ChatActivityEvent {
            ChatActivityEvent(eventID: id, sessionID: sessionID, turnID: turn, kind: .reasoning,
                              lifecycle: running ? .running : .succeeded, title: "Reasoning",
                              summary: nil, detail: text, occurredAt: order,
                              durationMilliseconds: running ? nil : 4_000, sourceOrder: order)
        }
        // Back-to-back thinking in both turns, and work on both sides of the
        // interim messages, so one fold and grouped thinking are both visible.
        let items = [
            human("thinking-q1", "Am I on track with my grocery budget this month?", 10),
            reply("thinking-interim-1", "Let me pull up your budget file first.", 30),
            reply("thinking-interim-2", "Found it. Now adding up this month's grocery receipts.", 50),
            reply("thinking-answer", "You're on track. You've spent **$412** of your **$600** grocery budget, "
                  + "with 9 days left. At your usual pace you'll finish around $540.", 70, duration: 12_000),
            human("thinking-q2", "And dining out?", 80),
            reply("thinking-interim-3", "Checking restaurant charges now.", 100),
        ]
        let activity = [
            thought("thinking-r1", "turn-1", "They want a budget check. Read budget.csv for the grocery limit, "
                    + "then total September grocery receipts and compare.", 20),
            thought("thinking-r1b", "turn-1", "Budget file first, receipts after.", 21),
            tool("thinking-t1", "turn-1", "Reading budget.csv", "read_file", 40),
            thought("thinking-r1c", "turn-1", "Receipts so far total $412.", 55),
            thought("thinking-r1d", "turn-1", "Compare with the $600 limit and project to month end.", 56),
            tool("thinking-t2", "turn-1", "Totaling receipts", "execute_code", 60),
            thought("thinking-r2", "turn-2", "Dining out is its own category.", 90),
            thought("thinking-r2b", "turn-2", "Filter card charges by restaurant merchant codes for this month",
                    91, running: true),
            tool("thinking-t3", "turn-2", "Searching charges", "search_files", 110, running: true),
        ]
        return SessionRecord(id: sessionID, kind: .direct, agentIDs: ["finance"], title: "Budget check",
                             items: items, activityEvents: activity,
                             activityVisibility: .init(showReasoning: true, showToolCalls: true),
                             isActive: true, hasAcceptedMessage: true)
    }
    #endif

    static func initialItems(
        conversationID: String,
        agentID: String = "default",
        agentName: String = "Assistant",
        agentAvatarFileName: String? = nil
    ) -> [TimelineItem] {
        let sender = TimelineSender.agent(
            id: agentID,
            snapshot: .init(name: agentName, avatarFileName: agentAvatarFileName)
        )
        return [
            TimelineItem(
                id: "fixture-\(conversationID)-welcome",
                role: .assistant,
                sender: sender,
                content: .message("Good morning. I’ve gathered your fixture priorities, spending, and schedule in one place."),
                metadata: TimelineMetadata(source: "bighelp demo data", freshness: "Updated 2 min ago")
            ),
            TimelineItem(
                id: "fixture-\(conversationID)-budget",
                role: .assistant,
                sender: sender,
                content: .budgetSummary(budgetSummary),
                metadata: TimelineMetadata(source: "Demo finance workspace", freshness: "Updated 2 min ago")
            )
        ]
    }

    static func weatherFixture(senderID: String) -> TimelineItem {
        TimelineItem(
            id: "fixture-weather-\(senderID)",
            role: .assistant,
            sender: .agent(id: senderID, snapshot: .init(name: "Assistant")),
            content: .weatherAndTasks(weatherAndTasks),
            metadata: .init(source: "bighelp demo data", freshness: "Updated just now")
        )
    }

    static let budgetSummary = BudgetSummary(
        period: "August 2026",
        spent: "$6,320",
        budget: "$9,500",
        remaining: "$3,180 remaining",
        percentUsed: 67,
        plan: [
            PlanItem(
                id: "plan-finance-review",
                title: "Review vendor payment",
                detail: "Confirm the Acme Software invoice before its due date.",
                time: "9:30 AM"
            ),
            PlanItem(
                id: "plan-focus-block",
                title: "Protect focus time",
                detail: "Keep the afternoon clear for the quarterly brief.",
                time: "1:00 PM"
            ),
            PlanItem(
                id: "plan-weekly-wrap",
                title: "Weekly wrap-up",
                detail: "Send the completed-items summary to your team.",
                time: "4:30 PM"
            )
        ]
    )

    static let weatherAndTasks = WeatherAndTasks(
        city: "San Francisco",
        condition: "Sunny",
        currentTemperature: 61,
        highTemperature: 65,
        lowTemperature: 52,
        hourly: [
            HourlyWeather(id: "weather-now", time: "Now", condition: "Sunny", temperature: 61, systemImage: "sun.max.fill"),
            HourlyWeather(id: "weather-10", time: "10 AM", condition: "Sunny", temperature: 62, systemImage: "sun.max.fill"),
            HourlyWeather(id: "weather-12", time: "12 PM", condition: "Sunny", temperature: 64, systemImage: "sun.max.fill"),
            HourlyWeather(id: "weather-2", time: "2 PM", condition: "Sunny", temperature: 65, systemImage: "sun.max.fill")
        ],
        tasks: [
            PrioritizedTask(
                id: "task-payment",
                priority: "Important",
                title: "Review Acme Software payment",
                detail: "Invoice #INV-04521 is ready for your decision."
            ),
            PrioritizedTask(
                id: "task-brief",
                priority: "Next",
                title: "Finish quarterly brief",
                detail: "Your protected focus block begins at 1:00 PM."
            ),
            PrioritizedTask(
                id: "task-follow-up",
                priority: "Later",
                title: "Send team follow-up",
                detail: "Share the completed-items summary before 5:00 PM."
            )
        ]
    )
}

extension ApprovalRequest {
    static let vendorFixture = ApprovalRequest(
        id: "approval-acme-inv-04521",
        action: "Pay vendor invoice",
        requester: "Finance Agent",
        vendor: "Acme Software",
        amount: "$4,850.00 USD",
        dueDate: "May 15, 2025",
        category: "Software & Tools",
        sourceInvoice: "#INV-04521",
        consequence: "Approving schedules the payment and records it against the Software & Tools budget."
    )
}
