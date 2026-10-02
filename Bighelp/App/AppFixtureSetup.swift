import Foundation

@MainActor
enum AppFixtureSetup {
    static func sessions(arguments: [String], usesFixtures: Bool) -> [SessionRecord] {
        var initialSessions = usesFixtures ? DemoSessionCatalogClient.fixtureRecords : []
        #if DEBUG
        if usesFixtures, arguments.contains(AppStoreScreenshotFixture.launchArgument) {
            return AppStoreScreenshotFixture.sessions
        }
        if usesFixtures, arguments.contains("-test-idle-replay") {
            initialSessions = IdleReplayAcceptanceFixture.records
        }
        if usesFixtures, arguments.contains("-test-session-organization") {
            initialSessions = SessionOrganizationAcceptanceFixture.records
        }
        #endif
        if usesFixtures, arguments.contains("-preview-ui-v3"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            initialSessions[index] = ConversationFixtures.uiV3Preview
        }
        #if DEBUG
        if usesFixtures, arguments.contains("-test-native-reaction-ui"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            initialSessions[index] = ConversationFixtures.nativeReactionPreview
        }
        if usesFixtures, arguments.contains("-test-inline-mentions"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            initialSessions[index] = ConversationFixtures.inlineMentionsPreview
        }
        if usesFixtures, arguments.contains("-preview-simple-chat"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            initialSessions[index] = ConversationFixtures.simpleChatPreview
        }
        if usesFixtures, arguments.contains("-test-tool-disclosure-scroll"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            initialSessions[index] = ConversationFixtures.toolDisclosureScrollPreview
        }
        if usesFixtures, arguments.contains("-test-thinking-style"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            initialSessions[index] = ConversationFixtures.thinkingStylePreview
            if arguments.contains("-test-hide-tool-calls") {
                initialSessions[index].activityVisibility.showToolCalls = false
            }
        }
        if usesFixtures, arguments.contains("-test-loader-chat"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            initialSessions[index] = ConversationFixtures.loaderChatPreview(
                waiting: arguments.contains("-test-loader-chat-waiting"))
        }
        if usesFixtures, arguments.contains("-test-card-replies"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            initialSessions[index] = ConversationFixtures.cardRepliesPreview
        }
        if usesFixtures, arguments.contains("-test-completed-turn-context"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            initialSessions[index] = ConversationFixtures.completedTurnContextPreview
        }
        if usesFixtures, let flag = arguments.firstIndex(of: "-test-generated-media"),
           arguments.indices.contains(flag + 1),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }),
           let preview = try? GeneratedMediaAcceptanceFixture.session(mode: arguments[flag + 1]) {
            initialSessions[index] = preview
        }
        if usesFixtures, arguments.contains("-test-session-model"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            initialSessions[index].sessionRuntime = .init(
                model: "session-chosen-model", provider: "anthropic", observedAt: Date()
            )
        }
        if usesFixtures, arguments.contains("-preview-ui-v3"), arguments.contains("-test-v3-header-context"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            initialSessions[index].sessionContext = .init(
                sessionId: "demo-finance", model: "gpt-5.6",
                contextUsed: 25_000, contextMax: 100_000, contextPercent: 25,
                compressions: 0, isCompacting: false, updatedAt: 1_788_000_100,
                inputTokens: 18_000, outputTokens: 2_000, cachedTokens: 12_000,
                totalTokens: 20_000, sessionInputTokens: 54_000,
                sessionOutputTokens: 6_000, sessionCachedTokens: 36_000,
                sessionTotalTokens: 60_000, sessionIncludesSubagents: true
            )
        }
        if usesFixtures, arguments.contains("-preview-ui-v3"),
           arguments.contains("-test-reasoning-activity"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            let completed = arguments.contains("-test-reasoning-completed")
            initialSessions[index].activityEvents.append(ChatActivityEvent(
                eventID: "reasoning-fixture-event",
                sessionID: "demo-finance",
                turnID: "reasoning-fixture-turn",
                kind: .reasoning,
                lifecycle: completed ? .succeeded : .running,
                title: "Reasoning",
                summary: completed ? "Response ready" : "Reviewing the request",
                detail: completed ? "The reasoning phase finished." : "Using the current session context.",
                occurredAt: 6
            ))
            initialSessions[index].isActive = !completed
            initialSessions[index].activityVisibility.showReasoning = true
        }
        if usesFixtures, arguments.contains("-test-live-reasoning-card"),
           let index = initialSessions.firstIndex(where: { $0.id == "demo-finance" }) {
            var projection = DirectHermesProjection(
                conversationID: "demo-finance", profile: "finance", storedID: "thinking-fixture", epoch: "thinking-ui"
            )
            projection.reserveOrder(1)
            _ = projection.accept(.init(type: "message.start", sessionID: "thinking-fixture", payload: [:], sequence: 1))
            _ = projection.accept(.init(type: "reasoning.delta", sessionID: "thinking-fixture",
                                        payload: ["text": .string("Visible ")], sequence: 2))
            _ = projection.accept(.init(type: "reasoning.delta", sessionID: "thinking-fixture",
                                        payload: ["text": .string("reasoning token")], sequence: 3))
            _ = projection.accept(.init(type: "tool.start", sessionID: "thinking-fixture",
                                        payload: ["tool_id": .string("tool-1"), "name": .string("read_file")], sequence: 4))
            initialSessions[index] = SessionRecord(
                id: "demo-finance", kind: .direct, agentIDs: ["finance"], title: "Thinking preview",
                items: [TimelineItem(id: "thinking-question", role: .human,
                    sender: .user(snapshot: .init(name: "You")), content: .message("Review the source"),
                    metadata: .init(sourceOrder: 1))],
                activityEvents: projection.activities,
                activityVisibility: .init(showReasoning: true, showToolCalls: true),
                isActive: true, hasAcceptedMessage: true
            )
        }
        #endif
        #if DEBUG
        if usesFixtures, arguments.contains("-preview-agent-groups") {
            initialSessions.append(SessionRecord(id: "demo-agent-group", kind: .botMode,
                agentIDs: ["finance", "home"], title: "Household team"))
        }
        #endif
        let midSessionFixtureID = "demo-finance-mid-session"
        if usesFixtures, arguments.contains("-start-chat-mid-session"),
           let finance = initialSessions.first(where: { $0.id == "demo-finance" }) {
            initialSessions.append(SessionRecord(
                id: midSessionFixtureID,
                kind: finance.kind,
                agentIDs: finance.agentIDs,
                title: finance.title,
                draft: "Review the latest finance update",
                items: finance.items,
                activityEvents: finance.activityEvents,
                activityVisibility: finance.activityVisibility,
                isActive: true,
                createdAt: finance.createdAt,
                updatedAt: finance.updatedAt,
                hasAcceptedMessage: finance.hasAcceptedMessage
            ))
        }
        #if DEBUG
        if usesFixtures, arguments.contains("-demo-collaboration") {
            initialSessions.insert(
                SessionRecord(
                    id: "demo-collaboration",
                    kind: .direct,
                    agentIDs: ["finance"],
                    title: "Agent collaboration",
                    items: [
                        TimelineItem(
                            id: "demo-collaboration-message",
                            role: .human,
                            sender: .user(snapshot: .init(name: "You")),
                            content: .message("Ask Mina to review the launch plan."),
                            metadata: .init(sourceOrder: 1)
                        ),
                    ],
                    activityEvents: [
                        ChatActivityEvent(
                            eventID: "demo-agent-collaboration",
                            sessionID: "demo-collaboration",
                            turnID: "demo-agent-collaboration-turn",
                            kind: .botHandoff,
                            lifecycle: .running,
                            title: "Contacting Mina",
                            summary: "Mina is reviewing the launch plan",
                            detail: nil,
                            occurredAt: 1_788_000_100,
                            arguments: "Please **review** the launch plan and flag any travel risks.",
                            botRunID: "demo-agent-collaboration-run",
                            memberID: "travel",
                            fromMemberID: "finance",
                            sourceOrder: 2
                        ),
                    ],
                    hasAcceptedMessage: true
                ),
                at: 0
            )
        }
        #endif
        return initialSessions
    }
}
