import Combine
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Bighelp

private extension ChatTranscriptEntry {
    var messageText: String? {
        guard case .message(let item) = self, case .message(let text) = item.content else {
            return nil
        }
        return text
    }
}

private final class ObservationInvalidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

@MainActor
struct ChatModelTests {
    @Test func responseHapticsFollowLiveGrowthWithoutReplayOrDuplicatePulses() async {
        let client = ControlledStreamingConversationClient()
        let model = ChatModel(conversationID: "haptic-stream", client: client, initialItems: [])
        var events: [ResponseTextGrowth] = []
        let subscription = model.responseTextGrowth.sink { events.append($0) }
        model.draft = "Please answer"
        let send = Task { await model.send() }
        await client.waitUntilStarted()
        client.yieldDraft(id: "answer", text: "Hello")
        #expect(events.count == 1)
        client.yieldDraft(id: "answer", text: "Hello")
        #expect(events.count == 1)
        client.yieldDraft(id: "answer", text: "Hello there")
        #expect(events.count == 2)
        client.yieldDraft(id: "answer", text: "Short")
        client.yieldDraft(id: "answer", text: "A longer replacement")
        #expect(events.count == 2)
        model.setTranscriptPresentationDeferred(true)
        client.yieldDraft(id: "answer", text: "A longer replacement during catchup")
        #expect(events.count == 2)
        model.setTranscriptPresentationDeferred(false)
        #expect(events.count == 2)
        client.yieldDraft(id: "answer", text: "A longer replacement during catchup, now live")
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.conversationID == "haptic-stream" && $0.messageID == "answer" })
        client.finish(id: "answer", text: "A longer replacement during catchup, now live")
        await send.value
        #expect(events.count == 3)
        var replayed = 0
        let laterSubscription = model.responseTextGrowth.sink { _ in replayed += 1 }
        #expect(replayed == 0)
        withExtendedLifetime((subscription, laterSubscription)) {}
    }

    @Test func responseHapticsIncludeFinalOnlyAndGrowingFinalFrames() async {
        let finalOnlyClient = ControlledStreamingConversationClient()
        let finalOnlyModel = ChatModel(
            conversationID: "haptic-final-only",
            client: finalOnlyClient,
            initialItems: []
        )
        var finalOnlyEvents: [ResponseTextGrowth] = []
        let finalOnlySubscription = finalOnlyModel.responseTextGrowth.sink {
            finalOnlyEvents.append($0)
        }
        finalOnlyModel.draft = "Answer directly"
        let finalOnlySend = Task { await finalOnlyModel.send() }
        await finalOnlyClient.waitUntilStarted()
        finalOnlyClient.finish(id: "final-only-answer", text: "Final answer")
        await finalOnlySend.value
        #expect(finalOnlyEvents.map(\.messageID) == ["final-only-answer"])

        let streamedClient = ControlledStreamingConversationClient()
        let streamedModel = ChatModel(
            conversationID: "haptic-final-growth",
            client: streamedClient,
            initialItems: []
        )
        var streamedEvents: [ResponseTextGrowth] = []
        let streamedSubscription = streamedModel.responseTextGrowth.sink {
            streamedEvents.append($0)
        }
        streamedModel.draft = "Finish the answer"
        let streamedSend = Task { await streamedModel.send() }
        await streamedClient.waitUntilStarted()
        streamedClient.yieldDraft(id: "growing-answer", text: "Partial")
        streamedClient.finish(id: "growing-answer", text: "Partial final answer")
        await streamedSend.value
        #expect(streamedEvents.map(\.messageID) == ["growing-answer", "growing-answer"])

        withExtendedLifetime((finalOnlySubscription, streamedSubscription)) {}
    }

    @Test func responseHapticsIgnoreHistoryAndRetiredModels() {
        let model = ChatModel(conversationID: "haptic-external", client: ConversationFixtureClient(), initialItems: [])
        var events: [ResponseTextGrowth] = []
        let subscription = model.responseTextGrowth.sink { events.append($0) }
        func item(_ id: String, _ text: String) -> TimelineItem {
            TimelineItem(id: id, role: .assistant, sender: .agent(id: "default", snapshot: .init(name: "Assistant")), content: .message(text), metadata: .init(delivery: "Streaming"))
        }
        model.acceptExternal([item("history", "Restored streaming-looking history")])
        #expect(events.isEmpty)
        model.acceptExternal([item("commentary", "Let me check")], isLiveAssistantText: true)
        #expect(events.map(\.messageID) == ["commentary"])
        model.acceptExternal([item("placeholder", "Preparing attachment…")], isLiveAssistantText: true)
        #expect(events.count == 1)
        model.retireResponseHaptics()
        model.acceptExternal([item("retired", "A late event")], isLiveAssistantText: true)
        #expect(events.count == 1)
        withExtendedLifetime(subscription) {}
    }

    @Test func persistedTranscriptProjectionInterleavesAndConsolidatesActivityLikeTheLiveChat() {
        let sessionID = "child-session-projection"
        let user = TimelineItem(
            id: "child-user",
            role: .human,
            sender: .user(snapshot: .init(name: "You")),
            content: .message("Inspect the project"),
            metadata: .init(sourceOrder: 1)
        )
        let answer = TimelineItem(
            id: "child-answer",
            role: .assistant,
            sender: .agent(id: "child-agent", snapshot: .init(name: "Reviewer")),
            content: .message("The review is complete."),
            metadata: .init(sourceOrder: 4)
        )
        let events = [
            ChatActivityEvent(
                eventID: "child-tool-1",
                sessionID: sessionID,
                turnID: user.id,
                kind: .tool,
                lifecycle: .succeeded,
                title: "Read files",
                summary: nil,
                detail: nil,
                occurredAt: 2,
                toolCallID: "child-call-1",
                sourceOrder: 2
            ),
            ChatActivityEvent(
                eventID: "child-tool-2",
                sessionID: sessionID,
                turnID: user.id,
                kind: .tool,
                lifecycle: .succeeded,
                title: "Run tests",
                summary: nil,
                detail: nil,
                occurredAt: 3,
                toolCallID: "child-call-2",
                sourceOrder: 3
            ),
        ]

        let entries = ChatTranscriptProjection.entries(
            items: [user, answer],
            activityEvents: events,
            visibility: .default,
            isBotMode: false
        )

        #expect(entries.count == 3)
        guard case .message(let projectedUser) = entries[0] else {
            Issue.record("Expected the user message before child activity")
            return
        }
        guard case .activity(let activity) = entries[1] else {
            Issue.record("Expected one consolidated child work trail")
            return
        }
        guard case .message(let projectedAnswer) = entries[2] else {
            Issue.record("Expected the child answer after its activity")
            return
        }
        #expect(projectedUser.id == user.id)
        #expect(activity.events.map(\.id) == events.map(\.id))
        #expect(projectedAnswer.id == answer.id)
    }


    @Test func authoritativeGoalCompletionClearsRailAndSurvivesReopen() throws {
        let active = SessionGoalSnapshot(sessionID: "goal-visible", storedSessionID: "goal-stored", status: .active, summary: "Finish the work", updatedAt: 10)
        let model = ChatModel(conversationID: "goal-visible", client: ConversationFixtureClient(), initialItems: [], initialGoalSnapshot: active)
        #expect(model.goalRailState?.summary == "Finish the work")
        let completed = SessionGoalSnapshot(sessionID: "goal-visible", storedSessionID: "goal-stored", status: .done, summary: nil, updatedAt: 11)
        model.reconcileGoal(completed)
        model.reconcileGoal(active)
        #expect(model.goalRailState == nil)
        let record = SessionRecord(id: "goal-visible", kind: .direct, agentIDs: ["default"], title: "Goal", remoteStoredID: "goal-stored", sessionGoal: completed)
        let restored = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))
        let reopened = ChatModel(conversationID: restored.id, client: ConversationFixtureClient(), initialItems: [], initialGoalSnapshot: restored.sessionGoal, sourceSession: restored)
        #expect(reopened.goalRailState == nil)
        #expect(reopened.sessionGoal == completed)
    }

    @Test func ordinaryAssistantProseCannotCompleteAnActiveGoal() {
        let active = SessionGoalSnapshot(sessionID: "goal-prose", storedSessionID: "stored-prose", status: .active, summary: "Standing goal", updatedAt: 10)
        let model = ChatModel(conversationID: "goal-prose", client: ConversationFixtureClient(), initialItems: [], initialGoalSnapshot: active)
        model.acceptExternal([TimelineItem(id: "answer", role: .assistant, sender: .agent(id: "default", snapshot: .init(name: "Agent")), content: .message("Goal achieved. There is no active goal."), metadata: .init(delivery: "Delivered"))])
        #expect(model.goalRailState != nil)
        model.reconcileGoal(SessionGoalSnapshot(sessionID: "foreign", storedSessionID: "stored-prose", status: .none, summary: nil, updatedAt: 11))
        #expect(model.goalRailState != nil)
        model.reconcileGoal(SessionGoalSnapshot(sessionID: "goal-prose", storedSessionID: "stored-prose", status: .none, summary: nil, updatedAt: 12))
        #expect(model.goalRailState == nil)
    }

    @Test func goalRailProjectionUsesOnlyCanonicalGoalCommands() {
        var state: ChatGoalRailState?

        state = ChatGoalProjection.applying(
            "/goal Ship the reconnect fix without losing queued work",
            to: state
        )
        #expect(state == ChatGoalRailState(
            summary: "Ship the reconnect fix without losing queued work",
            lifecycle: .active
        ))

        state = ChatGoalProjection.applying("/goal pause", to: state)
        #expect(state?.lifecycle == .paused)

        state = ChatGoalProjection.applying("ordinary follow up", to: state)
        #expect(state?.lifecycle == .paused)

        for observationalCommand in [
            "/goal status",
            "/goal show",
            "/goal wait 123 build",
            "/goal unwait",
            "/goal gate list",
        ] {
            #expect(ChatGoalProjection.applying(observationalCommand, to: state) == state)
        }

        state = ChatGoalProjection.applying("/goal resume", to: state)
        #expect(state?.lifecycle == .active)

        state = ChatGoalProjection.applying("/goal draft Verify this release", to: state)
        #expect(state?.summary == "Verify this release")

        state = ChatGoalProjection.applying("/goal done", to: state)
        #expect(state == nil)
    }

    @Test func goalRailProjectionRejectsBareAndLookalikeCommands() {
        let existing = ChatGoalRailState(summary: "Keep this", lifecycle: .active)

        #expect(ChatGoalProjection.applying("/goal", to: existing) == existing)
        #expect(ChatGoalProjection.applying(" /goal replace", to: existing) == existing)
        #expect(ChatGoalProjection.applying("/goalkeeper replace", to: existing) == existing)
        #expect(ChatGoalProjection.applying("/goal pause now", to: existing)?.summary == "pause now")
    }

    @Test func goalRailActionPreservesAnExistingComposerDraft() async {
        let client = RecordingSlashConversationClient()
        let model = ChatModel(
            conversationID: "session-goal-action",
            client: client,
            initialItems: [TimelineItem(
                id: "goal-command",
                role: .human,
                sender: .user(snapshot: .init(name: "You")),
                content: .message("/goal Ship the release"),
                metadata: .init(delivery: "Sent")
            )],
            initialGoalSnapshot: .init(sessionID: "session-goal-action", storedSessionID: "stored-goal", status: .active, summary: "Ship the release", updatedAt: 1)
        )
        model.draft = "Keep this unsent draft"

        await model.submitGoalCommand("pause")

        #expect(client.messages == ["/goal pause"])
        #expect(model.draft == "Keep this unsent draft")
        #expect(model.goalRailState?.lifecycle == .active)
        model.reconcileGoal(.init(sessionID: "session-goal-action", storedSessionID: "stored-goal", status: .paused, summary: "Ship the release", updatedAt: 2))
        #expect(model.goalRailState?.lifecycle == .paused)
    }

    @Test func idleGoalCommandProjectsItsHumanRowBeforeSending() async {
        let sleeper = ControlledDemoSleeper()
        let model = ChatModel(
            conversationID: "goal-human-projection",
            client: ConversationFixtureClient(),
            sleeper: sleeper,
            initialItems: []
        )

        let submission = Task { await model.submitGoalCommand("Ship safely") }
        await sleeper.waitUntilSleepStarts()

        #expect(model.transcriptEntries.compactMap(\.messageText) == ["/goal Ship safely"])

        sleeper.resume()
        await submission.value
    }

    @Test(arguments: ["pause", "resume", "clear", "A replacement goal"])
    func liveGoalCommandsNeverFallBackToGenericMidSessionSteering(argument: String) async {
        // Native goal controls use session.control, never chat steering. A
        // non-native fixture cannot promise that a generic send changes a goal.
        let client = ControlledMidSessionConversationClient()
        let goal = TimelineItem(
            id: "existing-goal",
            role: .human,
            sender: .user(snapshot: .init(name: "You")),
            content: .message("/goal Ship safely"),
            metadata: .init(sourceOrder: 1)
        )
        let model = ChatModel(
            conversationID: "goal-mid-human-projection",
            client: client,
            initialItems: [goal],
            initialGoalSnapshot: .init(sessionID: "goal-mid-human-projection", storedSessionID: "stored-goal", status: .active, summary: "Ship safely", updatedAt: 1)
        )
        model.draft = "Start"
        let owner = Task { await model.send() }
        await client.waitUntilInitialStarted()
        model.draft = "Keep my draft"

        await model.submitGoalCommand(argument)

        #expect(client.midSessionBehaviors.isEmpty)
        #expect(model.transcriptEntries.compactMap(\.messageText) == ["/goal Ship safely", "Start"])
        #expect(model.draft == "Keep my draft")
        #expect(model.goalRailState?.lifecycle == .active)
        #expect(model.failureMessage != nil)
        #expect(model.isSending)

        client.finishInitial(text: "Done")
        await owner.value
        #expect(model.transcriptEntries.compactMap(\.messageText).last == "Done")
        #expect(!model.isSending)
    }

    @Test func queuedShortcutProjectsAcceptedHumanRowImmediately() async throws {
        let model = ChatModel(
            conversationID: "queued-human-projection",
            client: QueuedConversationClientFixture(),
            initialItems: []
        )

        try await model.submitWithoutWaiting(message: "Queue this", attachments: [])

        #expect(model.transcriptEntries.compactMap(\.messageText) == ["Queue this"])
    }

    @Test func midSessionSendProjectsItsHumanRowBeforeAcceptance() async {
        let client = ControlledMidSessionConversationClient()
        let model = ChatModel(
            conversationID: "mid-human-projection",
            client: client,
            initialItems: []
        )
        model.draft = "Start"
        let owner = Task { await model.send() }
        await client.waitUntilInitialStarted()
        model.draft = "Steer now"

        let steering = Task { await model.sendMidSession(using: .steer) }
        await client.waitUntilMidSessionStarted()

        #expect(model.transcriptEntries.compactMap(\.messageText).suffix(2) == ["Start", "Steer now"])

        client.resolveMidSession(.accepted)
        await steering.value
        client.finishInitial(text: "Done")
        await owner.value
    }

    // A card's answer (a form, a picked option) goes to the agent as the
    // person's next message. Before, picks were only put in the composer and
    // form answers waited on the host where nothing told the agent.
    @Test func cardReplySendsItsOwnMessageAndKeepsTheDraft() async {
        let client = RecordingSlashConversationClient()
        let model = ChatModel(conversationID: "card-reply-idle", client: client, initialItems: [])
        model.draft = "Half-typed note"

        let sent = await model.sendCardReply("My answers to “Trip”:\n- Days: 3")

        #expect(sent)
        #expect(client.messages == ["My answers to “Trip”:\n- Days: 3"])
        #expect(model.transcriptEntries.compactMap(\.messageText) == ["My answers to “Trip”:\n- Days: 3"])
        #expect(model.draft == "Half-typed note")
    }

    @Test func cardReplyDuringATurnSteersItAndKeepsTheDraft() async {
        let client = ControlledMidSessionConversationClient()
        let model = ChatModel(conversationID: "card-reply-steer", client: client, initialItems: [])
        model.draft = "Start"
        let owner = Task { await model.send() }
        await client.waitUntilInitialStarted()
        model.draft = "Keep my draft"

        let reply = Task { await model.sendCardReply("Book the 9:40 flight") }
        await client.waitUntilMidSessionStarted()

        #expect(client.midSessionBehaviors == [.steer])
        #expect(model.transcriptEntries.compactMap(\.messageText).suffix(2) == ["Start", "Book the 9:40 flight"])
        #expect(model.draft == "Keep my draft")

        client.resolveMidSession(.accepted)
        #expect(await reply.value)
        client.finishInitial(text: "Done")
        await owner.value
        #expect(model.draft == "Keep my draft")
    }

    @Test func aRefusedCardReplyNeverReplacesTheDraft() async {
        let client = ControlledMidSessionConversationClient()
        let model = ChatModel(conversationID: "card-reply-refused", client: client, initialItems: [])
        model.draft = "Start"
        let owner = Task { await model.send() }
        await client.waitUntilInitialStarted()
        model.draft = "Keep my draft"

        let reply = Task { await model.sendCardReply("Option B") }
        await client.waitUntilMidSessionStarted()
        client.rejectMidSession()
        _ = await reply.value

        #expect(model.draft == "Keep my draft")
        #expect(!model.transcriptEntries.compactMap(\.messageText).contains("Option B"))
        #expect(model.failureMessage != nil)
        client.finishInitial(text: "Done")
        await owner.value
    }

    @Test func cardRepliesNeverRunCommands() async {
        let client = RecordingSlashConversationClient()
        let model = ChatModel(conversationID: "card-reply-command", client: client, initialItems: [])

        #expect(!model.acceptsCardReply("/goal ship it"))
        #expect(await model.sendCardReply("/goal ship it") == false)
        #expect(await model.sendCardReply("   ") == false)
        #expect(client.messages.isEmpty)
    }

    @Test func quickActionProjectsItsHumanIntentBeforePerforming() async {
        let sleeper = ControlledDemoSleeper()
        let model = ChatModel(
            conversationID: "action-human-projection",
            client: ConversationFixtureClient(),
            sleeper: sleeper,
            initialItems: []
        )

        let action = Task { await model.perform(.weatherAndTasks) }
        await sleeper.waitUntilSleepStarts()

        #expect(model.transcriptEntries.compactMap(\.messageText) == [QuickAction.weatherAndTasks.intent])

        sleeper.resume()
        await action.value
    }

    @Test func chatModelReconcilesOnlyNewerTodoAndSubagentSnapshotsForItsSession() {
        let model = ChatModel(
            conversationID: "session-status-current",
            client: ConversationFixtureClient(),
            initialItems: []
        )
        let currentTodos = SessionTodoSnapshot(
            sessionID: model.conversationID,
            revision: 4,
            todos: [
                ChatTaskItem(id: "todo-1", content: "Fix reconnect", status: .inProgress),
            ],
            updatedAt: 1_788_154_004
        )
        let staleTodos = SessionTodoSnapshot(
            sessionID: model.conversationID,
            revision: 3,
            todos: [
                ChatTaskItem(id: "todo-stale", content: "Stale", status: .pending),
            ],
            updatedAt: 1_788_154_003
        )
        let roster = SessionSubagentRosterSnapshot(
            sessionID: model.conversationID,
            subagents: [
                SessionSubagentSnapshot(
                    id: "child-1",
                    sessionID: "child-session-1",
                    parentID: nil,
                    role: "reviewer",
                    goal: "Review reconnect ordering",
                    startedAt: 1_788_154_000
                ),
            ],
            updatedAt: 1_788_154_005
        )

        model.reconcileTodos(currentTodos)
        model.reconcileTodos(staleTodos)
        model.reconcileSubagents(roster)
        model.reconcileSubagents(SessionSubagentRosterSnapshot(
            sessionID: "another-session",
            subagents: [],
            updatedAt: 1_788_154_006
        ))

        #expect(model.taskDrawer?.items == currentTodos.todos)
        #expect(model.sessionSubagents == roster.subagents)
    }

    @Test func statusRailPresentationHasStableOrderAndNeverShowsScrollIndicators() {
        let goal = ChatGoalRailState(summary: "Finish the app", lifecycle: .active)
        let tasks = ChatTaskDrawerState(
            turnID: "turn-status",
            items: [ChatTaskItem(id: "task-1", content: "Verify", status: .pending)]
        )
        let subagent = SessionSubagentSnapshot(
            id: "child-1",
            sessionID: "child-session-1",
            parentID: nil,
            role: "worker",
            goal: "Implement rail",
            startedAt: 1
        )

        #expect(SessionStatusRailPresentation.showsScrollIndicators == false)
        #expect(SessionStatusRailPresentation.items(
            goal: goal,
            subagents: [subagent],
            tasks: tasks
        ).map(\.kind) == [.goal, .subagents, .tasks])
    }

    @Test func sessionContextSnapshotDecodesThePluginEnvelope() throws {
        let data = Data(#"""
        {
            "version": 1,
            "type": "session.context",
            "sessionId": "session-context-0001",
            "title": "Live session title",
            "model": "gpt-5.6-sol",
            "contextUsed": 166000,
            "contextMax": 258000,
            "contextPercent": 64,
            "compressions": 2,
            "isCompacting": true,
            "updatedAt": 1788153001
        }
        """#.utf8)

        let snapshot = try JSONDecoder().decode(SessionContextSnapshot.self, from: data)

        #expect(snapshot == SessionContextSnapshot(
            sessionId: "session-context-0001",
            title: "Live session title",
            model: "gpt-5.6-sol",
            contextUsed: 166_000,
            contextMax: 258_000,
            contextPercent: 64,
            compressions: 2,
            isCompacting: true,
            updatedAt: 1_788_153_001
        ))
    }

    @Test func chatModelAppliesAStreamingTitleForItsOpenSession() {
        let model = ChatModel(
            conversationID: "session-title-current",
            client: ConversationFixtureClient(),
            initialItems: [],
            sourceSession: SessionRecord(
                id: "session-title-current",
                kind: .direct,
                agentIDs: ["default"],
                title: "Original title"
            )
        )
        let update = SessionContextSnapshot(
            sessionId: model.conversationID,
            title: "Renamed while open",
            model: "gpt-5.6-sol",
            contextUsed: 12_000,
            contextMax: 258_000,
            contextPercent: 5,
            compressions: 0,
            isCompacting: false,
            updatedAt: 1_788_153_002
        )

        #expect(model.sessionTitle == "Original title")
        model.reconcileSessionContext(update)
        #expect(model.sessionTitle == "Renamed while open")
    }

    @Test func chatSessionTitleStaysOnOneTruncatingLineAndSitsAboveTheRowCenter() {
        #expect(ChatSessionTitlePresentation.lineLimit == 1)
        #expect(ChatSessionTitlePresentation.minimumHeight == 36)
        #expect(ChatSessionTitlePresentation.verticalOffset == -4)
    }

    @Test func sessionContextPresentationShowsRemainingAndUsedWindow() {
        let snapshot = SessionContextSnapshot(
            sessionId: "session-context-0002",
            model: "gpt-5.6-sol",
            contextUsed: 166_000,
            contextMax: 258_000,
            contextPercent: 64,
            compressions: 0,
            isCompacting: false,
            updatedAt: 1_788_153_002
        )

        #expect(
            SessionContextPresentation.summary(for: snapshot)
                == "36% left (166K used / 258K)"
        )
    }

    @Test func contextRingTintProgressesThroughThemeAwareInterpolatedAnchors() {
        let lightNeutral = SessionContextRingPresentation.RGBA(
            red: 0.36,
            green: 0.36,
            blue: 0.38
        )
        let darkNeutral = SessionContextRingPresentation.RGBA(
            red: 0.78,
            green: 0.78,
            blue: 0.80
        )
        let lightYellow = SessionContextRingPresentation.RGBA(
            red: 0.78,
            green: 0.58,
            blue: 0
        )
        let lightOrange = SessionContextRingPresentation.RGBA(
            red: 0.88,
            green: 0.32,
            blue: 0
        )
        let lightRed = SessionContextRingPresentation.RGBA(
            red: 0.80,
            green: 0.08,
            blue: 0.10
        )
        let darkRed = SessionContextRingPresentation.RGBA(
            red: 1,
            green: 0.12,
            blue: 0.10
        )

        #expect(SessionContextRingPresentation.tint(usedPercent: 25, theme: .light) == lightNeutral)
        #expect(SessionContextRingPresentation.tint(usedPercent: 25, theme: .dark) == darkNeutral)
        #expect(SessionContextRingPresentation.tint(usedPercent: 50, theme: .light) == lightYellow)
        #expect(SessionContextRingPresentation.tint(usedPercent: 80, theme: .light) == lightOrange)
        #expect(SessionContextRingPresentation.tint(usedPercent: 98, theme: .light) == lightRed)
        #expect(SessionContextRingPresentation.tint(usedPercent: 100, theme: .light) == lightRed)
        #expect(SessionContextRingPresentation.tint(usedPercent: 98, theme: .dark) == darkRed)

        let yellowOrangeBlend = SessionContextRingPresentation.tint(
            usedPercent: 65,
            theme: .light
        )
        #expect(abs(yellowOrangeBlend.red - 0.83) < 0.000_001)
        #expect(abs(yellowOrangeBlend.green - 0.45) < 0.000_001)
        #expect(abs(yellowOrangeBlend.blue) < 0.000_001)

        let orangeRedBlend = SessionContextRingPresentation.tint(
            usedPercent: 89,
            theme: .light
        )
        #expect(abs(orangeRedBlend.red - 0.84) < 0.000_001)
        #expect(abs(orangeRedBlend.green - 0.20) < 0.000_001)
        #expect(abs(orangeRedBlend.blue - 0.05) < 0.000_001)
        #expect(SessionContextRingPresentation.tint(usedPercent: -20, theme: .light) == lightNeutral)
    }

    @Test func contextRingFillAndLabelClampToTheWindow() {
        #expect(SessionContextRingPresentation.fill(usedPercent: 64) == 0.64)
        #expect(SessionContextRingPresentation.fill(usedPercent: 320) == 1)
        #expect(SessionContextRingPresentation.fill(usedPercent: -5) == 0)
        #expect(SessionContextRingPresentation.remainingLabel(usedPercent: 64) == "36%")
        #expect(SessionContextRingPresentation.remainingLabel(usedPercent: 320) == "0%")
    }

    @Test func contextTokenRowsOmitMetricsHermesDidNotPublish() {
        let snapshot = SessionContextSnapshot(
            sessionId: "session-context-tokens",
            model: "gpt-5.6-sol",
            contextUsed: 166_000,
            contextMax: 258_000,
            contextPercent: 64,
            compressions: 0,
            isCompacting: false,
            updatedAt: 1_788_153_004
        )

        #expect(SessionContextPresentation.tokenRows(for: snapshot).map(\.id) == ["context"])
    }

    @Test func contextTokenRowsShowTrueCachedZeroWithoutInventingUnknownSessionCache() {
        let snapshot = SessionContextSnapshot(
            sessionId: "session-context-zero-cache",
            model: "gpt-5.6-sol",
            contextUsed: 27_903,
            contextMax: 922_000,
            contextPercent: 3,
            compressions: 0,
            isCompacting: false,
            updatedAt: 1_788_153_004,
            cachedTokens: 0,
            sessionTotalTokens: 155_664
        )

        let rows = SessionContextPresentation.tokenRows(for: snapshot)
        #expect(rows.first(where: { $0.id == "latest-cached" })?.value == "0")
        #expect(rows.contains(where: { $0.id == "session-cached" }) == false)
        #expect(rows.first(where: { $0.id == "session-total" })?.title == "Session total")
        #expect(rows.first(where: { $0.id == "session-total" })?.value
            == SessionContextPresentation.exactCount(155_664))
    }

    @Test func contextTokenRowsListEveryPublishedMetricInReadingOrder() {
        let snapshot = SessionContextSnapshot(
            sessionId: "session-context-tokens",
            model: "gpt-5.6-sol",
            contextUsed: 166_000,
            contextMax: 258_000,
            contextPercent: 64,
            compressions: 2,
            isCompacting: false,
            updatedAt: 1_788_153_005,
            inputTokens: 120_400,
            outputTokens: 8_200,
            cachedTokens: 96_000,
            totalTokens: 128_600,
            sessionInputTokens: 410_400,
            sessionOutputTokens: 18_200,
            sessionCachedTokens: 296_000,
            sessionTotalTokens: 428_600,
            sessionIncludesSubagents: true
        )

        let rows = SessionContextPresentation.tokenRows(for: snapshot)

        #expect(rows.map(\.id) == [
            "latest-input", "latest-output", "latest-cached", "latest-total",
            "context", "session-input", "session-output", "session-cached",
            "session-total", "compressions",
        ])
        #expect(rows.first(where: { $0.id == "latest-input" })?.title == "Latest input")
        #expect(rows.first(where: { $0.id == "latest-cached" })?.title == "Latest cached")
        #expect(rows.first(where: { $0.id == "session-total" })?.title == "Session total (incl. subagents)")
        #expect(
            rows.first(where: { $0.id == "latest-input" })?.value
                == SessionContextPresentation.exactCount(120_400)
        )
        #expect(
            rows.first(where: { $0.id == "context" })?.value
                == "\(SessionContextPresentation.exactCount(166_000)) / \(SessionContextPresentation.exactCount(258_000))"
        )
        #expect(SessionContextPresentation.exactCount(120_400).contains("400"))
    }

    @Test func chatModelAcceptsContextOnlyForItsOwnSession() {
        let model = ChatModel(
            conversationID: "session-context-current",
            client: ConversationFixtureClient(),
            initialItems: []
        )
        let otherSession = SessionContextSnapshot(
            sessionId: "session-context-other",
            model: "gpt-5.6-sol",
            contextUsed: 12_000,
            contextMax: 258_000,
            contextPercent: 5,
            compressions: 0,
            isCompacting: false,
            updatedAt: 1_788_153_003
        )

        model.reconcileSessionContext(otherSession)

        #expect(model.sessionContext == nil)
    }

    @Test func chatModelIgnoresAnOlderContextSnapshot() {
        let model = ChatModel(
            conversationID: "session-context-current",
            client: ConversationFixtureClient(),
            initialItems: []
        )
        let latest = SessionContextSnapshot(
            sessionId: model.conversationID,
            model: "gpt-5.6-sol",
            contextUsed: 166_000,
            contextMax: 258_000,
            contextPercent: 64,
            compressions: 1,
            isCompacting: true,
            updatedAt: 1_788_153_010
        )
        let stale = SessionContextSnapshot(
            sessionId: model.conversationID,
            model: "gpt-5.6-sol",
            contextUsed: 220_000,
            contextMax: 258_000,
            contextPercent: 85,
            compressions: 0,
            isCompacting: false,
            updatedAt: 1_788_153_009
        )

        model.reconcileSessionContext(latest)
        model.reconcileSessionContext(stale)

        #expect(model.sessionContext == latest)
    }

    @Test func authoritativeContextSnapshotDismissesCompactionAndRefreshesUsage() {
        let model = ChatModel(
            conversationID: "session-context-current",
            client: ConversationFixtureClient(),
            initialItems: []
        )
        let compacting = SessionContextSnapshot(
            sessionId: model.conversationID,
            model: "gpt-5.6-sol",
            contextUsed: 166_000,
            contextMax: 258_000,
            contextPercent: 64,
            compressions: 0,
            isCompacting: true,
            updatedAt: 1_788_153_011
        )
        let compacted = SessionContextSnapshot(
            sessionId: model.conversationID,
            model: "gpt-5.6-sol",
            contextUsed: 64_000,
            contextMax: 258_000,
            contextPercent: 25,
            compressions: 1,
            isCompacting: false,
            updatedAt: 1_788_153_012
        )

        model.reconcileSessionContext(compacting)
        #expect(model.sessionContext?.isCompacting == true)

        model.reconcileSessionContext(compacted)

        #expect(model.sessionContext == compacted)
        #expect(
            model.sessionContext.map(SessionContextPresentation.summary(for:))
                == "75% left (64K used / 258K)"
        )
    }

    @Test func condensedDraftFieldStopsGrowingAtFourRenderedLines() {
        #expect(DraftFieldSizing.height(measuredHeight: 8, lineHeight: 20) == 20)
        #expect(DraftFieldSizing.height(measuredHeight: 42, lineHeight: 20) == 42)
        #expect(DraftFieldSizing.height(measuredHeight: 80, lineHeight: 20) == 80)
        #expect(DraftFieldSizing.height(measuredHeight: 100, lineHeight: 20) == 80)
        #expect(DraftFieldSizing.height(measuredHeight: 400, lineHeight: 20) == 80)
    }

    @Test func draftFieldOffersExpandedEditorOnlyBeyondFourRenderedLines() {
        #expect(!DraftFieldSizing.shouldOfferExpandedEditor(
            hasText: false,
            measuredHeight: 400,
            lineHeight: 20
        ))
        #expect(!DraftFieldSizing.shouldOfferExpandedEditor(
            hasText: true,
            measuredHeight: 80,
            lineHeight: 20
        ))
        #expect(DraftFieldSizing.shouldOfferExpandedEditor(
            hasText: true,
            measuredHeight: 81,
            lineHeight: 20
        ))
    }

    @Test func unchangedUIKitDraftUpdatePreservesTheUsersManualScrollPosition() {
        #expect(
            !DraftFieldUpdatePolicy.shouldKeepCaretVisible(
                currentText: "A long draft the user has scrolled away from the caret to review.",
                incomingText: "A long draft the user has scrolled away from the caret to review."
            )
        )
    }

    @Test func programmaticUIKitDraftReplacementKeepsTheNewCaretVisible() {
        #expect(
            DraftFieldUpdatePolicy.shouldKeepCaretVisible(
                currentText: "Previous draft",
                incomingText: "Replacement draft"
            )
        )
    }

    @Test func caretScrollRequestsCoalesceSoOnlyTheNewestSelectionCanMoveTheViewport() {
        var generation = DraftCaretScrollGeneration()
        let staleRequest = generation.beginRequest()
        let newestRequest = generation.beginRequest()

        #expect(!generation.isCurrent(staleRequest))
        #expect(generation.isCurrent(newestRequest))
    }

    @Test func regularWidthDraftUsesTheSameFourLineViewportAndExpansionThreshold() {
        #expect(
            DraftFieldSizing.height(
                measuredHeight: 400,
                lineHeight: 20
            ) == 80
        )
        #expect(
            !DraftFieldSizing.shouldOfferExpandedEditor(
                hasText: true,
                measuredHeight: 80,
                lineHeight: 20
            )
        )
        #expect(
            DraftFieldSizing.shouldOfferExpandedEditor(
                hasText: true,
                measuredHeight: 81,
                lineHeight: 20
            )
        )
    }

    @Test func draftCaretSelectionClampsSelectionRetainedFromAnOlderTextValue() {
        let currentText = "hi"

        #expect(
            DraftCaretSelection.characterOffset(
                in: currentText,
                selectedRange: NSRange(location: 4, length: 0)
            ) == currentText.count
        )
    }

    @Test func draftCaretSelectionClampsStaleUTF16RangeAfterDraftIsReplacedWithShorterUnicodeText() {
        let previousText = "weather 😀 forecast"
        let currentText = "Hi 😀"
        let staleRange = NSRange(location: previousText.utf16.count, length: 0)

        #expect(
            DraftCaretSelection.characterOffset(
                in: currentText,
                selectedRange: staleRange
            ) == currentText.count
        )
    }

    @Test func slashCommandIndexFiltersAndPromotesAnExactCommandIntoAComposerToken() throws {
        let index = SlashCommandIndex(commands: [
            SlashCommandDescriptor(
                name: "help",
                description: "Show available commands",
                category: "Help",
                argsHint: "[query]",
                aliases: ["commands"],
                argumentMode: .text,
                source: .core,
                requiresArguments: false
            ),
            SlashCommandDescriptor(
                name: "reasoning",
                description: "Show or change reasoning effort",
                category: "Configuration",
                argsHint: "[level]",
                aliases: [],
                argumentMode: .options,
                source: .core,
                requiresArguments: false
            ),
            SlashCommandDescriptor(
                name: "review",
                description: "Spawn an independent reviewer",
                category: "Session",
                argsHint: "<instructions>",
                aliases: [],
                argumentMode: .text,
                source: .core,
                requiresArguments: true
            ),
        ])

        #expect(index.suggestions(for: "/").map(\.name) == ["help", "reasoning", "review"])
        #expect(index.suggestions(for: "/re").map(\.name) == ["reasoning", "review"])
        #expect(index.suggestions(for: "/commands").isEmpty)
        let selection = try #require(index.selection(for: "/commands status"))
        #expect(selection.command.name == "help")
        #expect(selection.invocation == "/commands")
        #expect(selection.arguments == "status")
        #expect(index.replacingArguments(in: selection, with: "skills") == "/commands skills")
        #expect(index.draft(selecting: index.commands[2]) == "/review ")
    }

    @Test func slashCommandCatalogLoadsOnlyAfterTheUserStartsACommand() async {
        let client = SlashCommandCatalogClientFixture()
        let catalog = SlashCommandCatalogModel(
            sessionID: "session_commands_fixture_0001",
            agentID: "juno",
            client: client
        )

        await catalog.loadIfNeeded(for: "What is the weather?")
        #expect(client.requests.isEmpty)

        await catalog.loadIfNeeded(for: "/")
        #expect(client.requests == [
            .init(sessionID: "session_commands_fixture_0001", agentID: "juno"),
        ])

        await catalog.loadIfNeeded(for: "/help")
        #expect(client.requests.count == 1)
    }

    @Test func slashCommandCatalogLoadTriggerRemainsStableWhileFilteringTheCommand() {
        let model = ChatModel(
            conversationID: "session_commands_fixture_0001",
            client: ConversationFixtureClient()
        )

        model.draft = "/"
        let initialTrigger = model.slashCommandLoadTrigger
        model.draft = "/he"

        #expect(initialTrigger == true)
        #expect(model.slashCommandLoadTrigger == initialTrigger)
    }

    @Test func slashCommandCatalogCanRetryATransientLoadFailureWithoutLeavingSlashMode() async throws {
        let client = TransientSlashCommandCatalogClient()
        let catalog = SlashCommandCatalogModel(
            sessionID: "session_commands_fixture_0001",
            agentID: "juno",
            client: client
        )

        await catalog.loadIfNeeded(for: "/")

        #expect(catalog.commands.isEmpty)
        #expect(catalog.errorMessage == "Commands could not be loaded from Hermes.")

        await catalog.retry()

        #expect(client.requests.count == 2)
        #expect(catalog.commands.map(\.name) == ["help"])
        #expect(catalog.errorMessage == nil)
    }

    @Test func slashCommandCatalogRetriesTransientTimeoutAndDisconnectBeforeShowingAnError() async throws {
        let client = TransientLinkSlashCommandCatalogClient()
        let catalog = SlashCommandCatalogModel(
            sessionID: "session_commands_fixture_0003",
            agentID: "juno",
            client: client
        )

        await catalog.loadIfNeeded(for: "/")

        #expect(client.requests == 3)
        #expect(catalog.commands.map(\.name) == ["help"])
        #expect(catalog.errorMessage == nil)
    }

    @Test func cancelledSlashCommandLoadDoesNotBecomeAStaleVisibleError() async throws {
        let client = CancelledThenSuccessfulSlashCommandCatalogClient()
        let catalog = SlashCommandCatalogModel(
            sessionID: "session_commands_fixture_0001",
            agentID: "juno",
            client: client
        )

        await catalog.loadIfNeeded(for: "/")

        #expect(catalog.errorMessage == nil)
        #expect(catalog.commands.isEmpty)

        await catalog.retry()

        #expect(catalog.commands.map(\.name) == ["help"])
        #expect(catalog.errorMessage == nil)
    }

    @Test func chatModelPromotesSelectedSlashCommandsAndKeepsArgumentsInTheCanonicalDraft() {
        let command = SlashCommandDescriptor(
            name: "review",
            description: "Spawn an independent reviewer",
            category: "Session",
            argsHint: "<instructions>",
            aliases: [],
            argumentMode: .text,
            source: .core,
            requiresArguments: true
        )
        let model = ChatModel(
            conversationID: "session_fixture_0001",
            client: ConversationFixtureClient(),
            initialItems: []
        )

        model.selectSlashCommand(command)
        #expect(model.draft == "/review ")
        #expect(model.activeSlashCommand?.command.name == "review")

        model.setSlashCommandArguments("check the tests")
        #expect(model.draft == "/review check the tests")

        model.clearSlashCommand()
        #expect(model.draft.isEmpty)
        #expect(model.activeSlashCommand == nil)
    }

    @Test func chatModelSendsTheSelectedSlashCommandAndArgumentsAsTheExactHermesInvocation() async {
        let client = RecordingSlashConversationClient()
        let command = SlashCommandDescriptor(
            name: "help",
            description: "Show available commands",
            category: "Help",
            argsHint: "[query]",
            aliases: ["commands"],
            argumentMode: .text,
            source: .core,
            requiresArguments: false
        )
        let model = ChatModel(
            conversationID: "session_commands_fixture_0004",
            client: client,
            initialItems: []
        )

        model.selectSlashCommand(command)
        model.setSlashCommandArguments("weather")
        await model.send()

        #expect(client.messages == ["/help weather"])
        #expect(model.draft.isEmpty)
    }

    @Test func typingANewSlashAfterAPromotedCommandReentersCommandSearch() {
        let command = SlashCommandDescriptor(
            name: "help",
            description: "Show available commands",
            category: "Help",
            argsHint: "[query]",
            aliases: [],
            argumentMode: .text,
            source: .core,
            requiresArguments: false
        )
        let model = ChatModel(
            conversationID: "session_commands_fixture_0002",
            client: ConversationFixtureClient(),
            initialItems: []
        )

        model.selectSlashCommand(command)
        model.setSlashCommandArguments("/")

        #expect(model.draft == "/")
        #expect(model.activeSlashCommand == nil)
        #expect(model.slashCommandSuggestions.isEmpty)
    }

    @Test func sessionRuntimeControlsLoadCanonicalHermesChoices() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker()
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )

        await controls.loadModelPicker()
        await controls.loadReasoningPicker()

        #expect(controls.currentProvider == "nous")
        #expect(controls.currentModel == "Hermes-4-405B")
        #expect(controls.modelProviders.map(\.id) == ["nous", "openai"])
        #expect(controls.reasoningOptions.map(\.value) == ["reset", "none", "low", "high"])
        #expect(controls.reasoningOptions.map(\.label) == ["Auto", "Off", "Low", "High"])
        #expect(controls.currentReasoningLabel == "Auto")
        #expect(controls.errorMessage == nil)
    }

    /// The chat's model and reasoning show in the context pop-up, Info and the
    /// avatar's profile. Showing them reads the reasoning once, never mid-turn,
    /// and never opens the (slow) model list.
    @Test func modelSummaryReadsReasoningOnceAndNotDuringATurn() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker(current: "high")
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )
        controls.reconcileSessionRuntime(SessionRuntimeSnapshot(
            model: "Hermes-4-405B", provider: "nous", observedAt: Date()
        ))
        #expect(ChatModelSummaryPresentation(controls: controls).reasoning == "Reasoning: unknown")

        controls.setTurnActive(true)
        await controls.loadSummaryIfNeeded()
        #expect(messaging.opened.isEmpty, "Nothing is read while the agent is replying")

        controls.setTurnActive(false)
        await controls.loadSummaryIfNeeded()
        await controls.loadSummaryIfNeeded()
        #expect(messaging.opened.map(\.kind) == [.reasoning])
        let summary = ChatModelSummaryPresentation(controls: controls)
        #expect(summary.modelName == ModelNameCatalogStore.shared.displayName(for: "Hermes-4-405B"))
        #expect(summary.reasoning == "Reasoning: High")
        #expect(summary.providerID == "nous")
    }

    /// Hermes' session info carries the chat's reasoning. Live info is the newest
    /// word; replayed info only fills in an unknown level and never undoes a
    /// read or a choice made since.
    @Test func sessionInfoReasoningKeepsTheNewestLevel() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker(current: "high")
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            allowsAgentDefaults: false,
            now: { 1_788_000_000 }
        )
        controls.reconcileSessionReasoning("", observedAt: .distantPast)
        #expect(ChatModelSummaryPresentation(controls: controls).reasoning == "Reasoning: Auto")
        controls.reconcileSessionReasoning("louder", observedAt: Date())
        #expect(controls.currentReasoningValue == "reset", "Unknown levels are ignored")

        await controls.loadReasoningPicker()
        #expect(controls.currentReasoningValue == "high")
        controls.reconcileSessionReasoning("low", observedAt: .distantPast)
        #expect(controls.currentReasoningValue == "high", "Replayed info never undoes a newer read")

        controls.setTurnActive(true)
        controls.reconcileSessionReasoning("medium", observedAt: Date())
        #expect(ChatModelSummaryPresentation(controls: controls).reasoning == "Reasoning: Medium")
    }

    /// A new chat already knows its agent's defaults, so nothing is read.
    @Test func modelSummaryUsesAgentDefaultsForANewChat() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker()
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )
        controls.seedAgentDefaults(AgentRuntimeSelection(providerID: "openai", modelID: "gpt-5.6-sol", reasoningEffort: ""))
        await controls.loadSummaryIfNeeded()
        #expect(messaging.opened.isEmpty)
        let summary = ChatModelSummaryPresentation(controls: controls)
        #expect(summary.reasoning == "Reasoning: Auto")
        #expect(summary.providerID == "openai")
    }

    @Test func activeTurnLocksModelAndReasoningSelection() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker()
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )
        await controls.loadPickersIfNeeded()
        let selectedBeforeLock = messaging.selections.count

        controls.setTurnActive(true)
        await controls.selectModel(providerID: "openai", modelID: "gpt-5.6-sol")
        await controls.selectReasoning(value: "high")

        #expect(controls.isTurnActive)
        #expect(messaging.selections.count == selectedBeforeLock)
        #expect(controls.errorMessage == ChatRuntimeSelectionLockout.message)
        #expect(controls.currentModel == "Hermes-4-405B")
    }

    @Test func endingTheTurnClearsOnlyTheLockoutMessage() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker()
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )
        await controls.loadPickersIfNeeded()

        controls.setTurnActive(true)
        await controls.selectReasoning(value: "high")
        #expect(controls.errorMessage == ChatRuntimeSelectionLockout.message)

        controls.setTurnActive(false)

        #expect(controls.isTurnActive == false)
        #expect(controls.errorMessage == nil)
    }

    @Test func chatModelMirrorsItsActiveTurnIntoTheRuntimeControls() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker()
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session-lockout-restore",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )
        let model = ChatModel(
            conversationID: "session-lockout-restore",
            client: ConversationFixtureClient(),
            initialItems: [],
            sourceSession: SessionRecord(
                id: "session-lockout-restore",
                kind: .direct,
                agentIDs: ["juno"],
                title: "Restored mid-turn",
                isActive: true
            ),
            runtimeControls: controls
        )

        #expect(model.isSending)
        #expect(controls.isTurnActive)
    }

    @Test func lockoutHintReplacesThePickerHintOnlyWhileATurnRuns() {
        #expect(ChatRuntimeSelectionLockout.isLocked(isTurnActive: true))
        #expect(ChatRuntimeSelectionLockout.isLocked(isTurnActive: false) == false)
        #expect(
            ChatRuntimeSelectionLockout.accessibilityHint(isTurnActive: true)
                == ChatRuntimeSelectionLockout.accessibilityHint
        )
        #expect(
            ChatRuntimeSelectionLockout.accessibilityHint(isTurnActive: false)
                == "Opens settings for this session."
        )
    }

    @Test func sessionRuntimeControlsStaySilentUntilThePickerIsRequested() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker()
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )

        #expect(messaging.opened.isEmpty)

        await controls.loadPickersIfNeeded()

        #expect(Set(messaging.opened.map(\.kind)) == Set([.model, .reasoning]))
    }

    @Test func restoredChatLoadsCurrentReasoningWithoutPresentingThePicker() async throws {
        let session = SessionRecord(
            id: "session_runtime_fixture_0001",
            kind: .direct,
            agentIDs: ["juno"],
            title: "Restored reasoning",
            remoteStoredID: "stored-restored-reasoning",
            remoteSource: "loopdy",
            hasAcceptedMessage: true
        )
        let catalog = SessionCatalogStore(
            client: SessionCatalogFixtureClient(records: [session]),
            records: [session]
        )
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker(current: "high")
        )
        let features = ShellFeatureStore(
            timing: .immediate,
            catalog: catalog,
            sessionControlMessaging: messaging
        )

        #expect(features.prepare(.chat(conversationID: session.id)))
        try await Task.sleep(for: .milliseconds(50))
        guard case .chat(let model)? = features.preparedModel(
            for: .chat(conversationID: session.id)
        ) else {
            Issue.record("Restored chat was not prepared")
            return
        }

        #expect(messaging.opened.map(\.kind) == [.reasoning])
        #expect(model.runtimeControls?.currentReasoningValue == "high")
        #expect(model.runtimeControls?.currentReasoningLabel == "High")
    }

    @Test func reasoningPickerStillLoadsWhenTheModelPickerFails() async throws {
        let messaging = TransientPickerRuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker(),
            modelFailures: [.pickerOpenFailed(message: "Models unavailable")]
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )

        await controls.loadPickersIfNeeded()

        #expect(controls.modelPicker == nil)
        #expect(controls.reasoningOptions.map(\.value) == ["reset", "none", "low", "high"])
        #expect(Set(messaging.opened.map(\.kind)) == Set([.model, .reasoning]))
    }

    @Test func allModelsPresentationLoadsTheModelCatalogBeforeShowingTheSheet() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker()
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )

        await controls.loadModelPickerIfNeeded()

        #expect(messaging.opened.map(\.kind) == [.model])
        #expect(controls.modelProviders.map(\.id) == ["nous", "openai"])

        await controls.loadModelPickerIfNeeded()
        #expect(messaging.opened.map(\.kind) == [.model])
    }

    @Test func cachedProvidersNeverReuseAPickerIdentityForSessionSelection() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker()
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )
        controls.seedCachedModelProviders(try decodeModelPicker().providers)

        #expect(controls.modelProviders.map(\.id) == ["nous", "openai"])
        #expect(messaging.opened.isEmpty)

        await controls.selectModel(providerID: "openai", modelID: "gpt-5.6")

        #expect(messaging.opened.map(\.kind) == [.model])
        #expect(messaging.selections.count == 1)
        #expect(messaging.selections.first?.pickerID == controls.modelPicker?.pickerID)
    }

    @Test func transientModelPickerTimeoutIsRetriedBeforeShowingAnEmptyCatalog() async throws {
        let messaging = TransientPickerRuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker(),
            modelFailures: [.timedOut]
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )

        await controls.loadModelPicker()

        #expect(messaging.opened.map(\.kind) == [.model, .model])
        #expect(controls.modelProviders.map(\.id) == ["nous", "openai"])
        #expect(controls.errorMessage == nil)
    }

    @Test func transientReasoningPickerDisconnectIsRetriedBeforeShowingAnEmptyCatalog() async throws {
        let messaging = TransientPickerRuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker(),
            reasoningFailures: [.disconnected]
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )

        await controls.loadReasoningPicker()

        #expect(messaging.opened.map(\.kind) == [.reasoning, .reasoning])
        #expect(controls.reasoningOptions.map(\.value) == ["reset", "none", "low", "high"])
        #expect(controls.errorMessage == nil)
    }

    @Test func concurrentTransientModelPickerLoadsShareOneSerialRecoverySequence() async throws {
        let messaging = TransientPickerRuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker(),
            modelFailures: [.timedOut]
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )

        let firstLoad = Task { await controls.loadModelPicker() }
        while messaging.opened.isEmpty {
            await Task.yield()
        }
        let secondLoad = Task { await controls.loadModelPicker() }

        await firstLoad.value
        await secondLoad.value

        #expect(messaging.opened.map(\.kind) == [.model, .model])
        #expect(controls.modelProviders.map(\.id) == ["nous", "openai"])
        #expect(controls.isLoadingModel == false)
    }

    @Test func concurrentReasoningPickerLoadsShareOneRequestAndSettleLoadingState() async throws {
        let messaging = DeferredRuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker()
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )

        let firstLoad = Task { await controls.loadReasoningPicker() }
        while messaging.opened.isEmpty {
            await Task.yield()
        }
        let secondLoad = Task { await controls.loadReasoningPicker() }

        await firstLoad.value
        await secondLoad.value

        #expect(messaging.opened.map(\.kind) == [.reasoning])
        #expect(controls.reasoningPicker != nil)
        #expect(controls.isLoadingReasoning == false)
    }

    @Test func concurrentPickerPresentationsWaitForTheInFlightModelCatalog() async throws {
        let messaging = DeferredRuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker()
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )

        let firstPresentation = Task { await controls.loadPickersIfNeeded() }
        while messaging.opened.isEmpty {
            await Task.yield()
        }
        while !controls.isLoadingModel {
            await Task.yield()
        }

        let secondPresentation = Task { await controls.loadModelPickerIfNeeded() }
        await secondPresentation.value

        #expect(controls.modelProviders.map(\.id) == ["nous", "openai"])
        #expect(controls.isLoadingModel == false)

        await firstPresentation.value
    }

    @Test func newerRuntimeObservationDoesNotDiscardPickerChoices() async throws {
        let messaging = RuntimeControlMessagingFixture(modelPicker: try decodeModelPicker(), reasoningPicker: try decodeReasoningPicker())
        let controls = SessionRuntimeControlModel(sessionID: "session_runtime_fixture_0001", agentID: "juno", messaging: messaging)
        messaging.onOpen = {
            controls.reconcileSessionRuntime(.init(model: "gpt-5.6", provider: "openai", observedAt: Date()))
        }
        await controls.loadModelPicker()
        #expect(controls.currentModel == "gpt-5.6")
        #expect(controls.modelProviders.contains(where: { $0.id == "openai" }))
        messaging.onOpen = nil
    }

    @Test func olderHistoryCannotReplaceAnAcceptedPickerSelection() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(), reasoningPicker: try decodeReasoningPicker())
        let controls = SessionRuntimeControlModel(sessionID: "session_runtime_fixture_0001",
            agentID: "juno", messaging: messaging)
        let pendingRead = SessionRuntimeSnapshot(model: "old-model", provider: "nous", observedAt: Date())
        await controls.loadModelPicker()
        await controls.selectModel(providerID: "openai", modelID: "gpt-5.6")
        controls.reconcileSessionRuntime(pendingRead)
        #expect(controls.currentModel == "gpt-5.6")
        #expect(controls.currentProvider == "openai")
        controls.reconcileSessionRuntime(.init(model: "new-host-selection", provider: nil, observedAt: Date()))
        #expect(controls.currentModel == "new-host-selection")
        #expect(controls.currentProvider == nil)
    }

    @Test func sessionRuntimeControlsCanShowTheAgentMainChatDefaultsBeforePickerLoads() {
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: RuntimeControlMessagingFixture(
                modelPicker: try! decodeModelPicker(),
                reasoningPicker: try! decodeReasoningPicker()
            )
        )

        controls.seedAgentDefaults(
            AgentRuntimeSelection(
                providerID: "openai",
                modelID: "gpt-5.6",
                reasoningEffort: "high"
            )
        )

        #expect(controls.currentProvider == "openai")
        #expect(controls.currentModel == "gpt-5.6")
        #expect(controls.currentReasoningValue == "high")
        #expect(controls.currentReasoningLabel == "High")
    }

    @Test func reasoningReadRejectsVisibilityCommandsAsEffectiveEffort() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(), reasoningPicker: try decodeReasoningPicker(current: "show"))
        let controls = SessionRuntimeControlModel(sessionID: "session_runtime_fixture_0001",
            agentID: "juno", messaging: messaging, allowsAgentDefaults: false)
        await controls.loadReasoningPicker()
        #expect(controls.currentReasoningValue == nil)
        #expect(controls.reasoningDisplayLabel == "Unknown")
    }

    @Test func olderReasoningReadCannotReplaceAnAcceptedSelection() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(), reasoningPicker: try decodeReasoningPicker(current: "low"))
        let controls = SessionRuntimeControlModel(sessionID: "session_runtime_fixture_0001",
            agentID: "juno", messaging: messaging)
        await controls.loadReasoningPicker()
        messaging.onOpenAsync = { await controls.selectReasoning(value: "high") }
        await controls.loadReasoningPicker()
        #expect(controls.currentReasoningValue == "high")
        #expect(controls.currentReasoningLabel == "High")
        #expect(messaging.selections.count == 1)
    }

    @Test func unknownReasoningNeverMasqueradesAsAutomatic() {
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: RuntimeControlMessagingFixture(
                modelPicker: try! decodeModelPicker(),
                reasoningPicker: try! decodeReasoningPicker()
            ),
            allowsAgentDefaults: false
        )

        #expect(controls.currentReasoningValue == nil)
        #expect(controls.reasoningDisplayLabel == "Unknown")
    }

    @Test func openingPickersReconcilesTheCurrentSessionReasoningOverTheProfileDefault() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker(current: "medium")
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )
        controls.seedAgentDefaults(
            AgentRuntimeSelection(
                providerID: "openai",
                modelID: "gpt-5.6",
                reasoningEffort: "high"
            )
        )

        await controls.loadPickersIfNeeded()

        #expect(Set(messaging.opened.map(\.kind)) == Set([.model, .reasoning]))
        #expect(controls.currentReasoningValue == "medium")
        #expect(controls.currentReasoningLabel == "Medium")
        #expect(controls.reasoningOptions.first(where: { $0.value == "medium" })?.isCurrent == true)
    }

    @Test func completedRuntimeSelectionsUpdateOnlyTheBoundSessionState() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker()
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )
        await controls.loadModelPicker()
        await controls.loadReasoningPicker()

        await controls.selectModel(providerID: "openai", modelID: "gpt-5.6")
        await controls.selectReasoning(value: "high")

        #expect(controls.currentProvider == "openai")
        #expect(controls.currentModel == "gpt-5.6")
        #expect(controls.currentReasoningLabel == "High")
        #expect(messaging.selections.map(\.sessionID) == [
            "session_runtime_fixture_0001",
            "session_runtime_fixture_0001",
        ])
        #expect(messaging.selections.map(\.kind) == [.model, .reasoning])
    }

    @Test func reasoningSelectionStepTargetsTheTopOfItsViewport() {
        #expect(
            SessionRuntimeSelectionStep.reasoning.scrollAnchorID
                == "chat.session-controls.reasoning-top"
        )
    }

    @Test func modelAndReasoningAreStagedUntilExplicitApply() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker(current: "medium")
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )
        await controls.loadPickersIfNeeded()
        var draft = SessionRuntimeSelectionDraft(
            providerID: controls.currentProvider,
            modelID: controls.currentModel,
            reasoningValue: controls.currentReasoningValue
        )

        #expect(draft.step == .models)

        draft.selectModel(providerID: "openai", modelID: "gpt-5.6")

        #expect(draft.step == .reasoning)
        #expect(messaging.selections.isEmpty)

        draft.selectReasoning("high")

        #expect(draft.step == .models)
        #expect(draft.hasChanges)
        #expect(messaging.selections.isEmpty)

        await controls.apply(draft)

        #expect(messaging.selections.map(\.kind) == [.model, .reasoning])
        #expect(controls.currentProvider == "openai")
        #expect(controls.currentModel == "gpt-5.6")
        #expect(controls.currentReasoningValue == "high")
    }

    @Test func arrivingHostDefaultsRebaseAnUntouchedSelectionDraftWithoutCreatingChanges() {
        var draft = SessionRuntimeSelectionDraft(
            providerID: nil,
            modelID: nil,
            reasoningValue: nil
        )

        draft.reconcile(providerID: "openai", modelID: "gpt-5.6", reasoningValue: "high")

        #expect(draft.providerID == "openai")
        #expect(draft.modelID == "gpt-5.6")
        #expect(draft.reasoningValue == "high")
        #expect(draft.originalProviderID == "openai")
        #expect(draft.originalModelID == "gpt-5.6")
        #expect(draft.originalReasoningValue == "high")
        #expect(!draft.hasChanges)
    }

    @Test func hostRebasePreservesStagedModelAndReasoningIndependently() {
        var stagedModel = SessionRuntimeSelectionDraft(
            providerID: "nous",
            modelID: "Hermes-4-405B",
            reasoningValue: "reset"
        )
        stagedModel.selectModel(providerID: "openai", modelID: "gpt-5.6")
        stagedModel.reconcile(providerID: "anthropic", modelID: "claude-sonnet", reasoningValue: "high")

        #expect(stagedModel.providerID == "openai")
        #expect(stagedModel.modelID == "gpt-5.6")
        #expect(stagedModel.originalProviderID == "anthropic")
        #expect(stagedModel.originalModelID == "claude-sonnet")
        #expect(stagedModel.reasoningValue == "high")
        #expect(stagedModel.originalReasoningValue == "high")
        #expect(stagedModel.hasChanges)

        var stagedReasoning = SessionRuntimeSelectionDraft(
            providerID: "nous",
            modelID: "Hermes-4-405B",
            reasoningValue: "reset"
        )
        stagedReasoning.selectReasoning("low")
        stagedReasoning.reconcile(providerID: "anthropic", modelID: "claude-sonnet", reasoningValue: "high")

        #expect(stagedReasoning.providerID == "anthropic")
        #expect(stagedReasoning.modelID == "claude-sonnet")
        #expect(stagedReasoning.originalProviderID == "anthropic")
        #expect(stagedReasoning.originalModelID == "claude-sonnet")
        #expect(stagedReasoning.reasoningValue == "low")
        #expect(stagedReasoning.originalReasoningValue == "high")
        #expect(stagedReasoning.hasChanges)
    }

    @Test func cancelledOrPartialHostRebaseDoesNotMutateTheSelectionDraft() {
        var draft = SessionRuntimeSelectionDraft(
            providerID: "openai",
            modelID: "gpt-5.6",
            reasoningValue: "high"
        )
        draft.selectModel(providerID: "nous", modelID: "Hermes-4-405B")
        let beforeCancellation = draft

        draft.reconcile(providerID: nil, modelID: nil, reasoningValue: nil)
        #expect(draft == beforeCancellation)

        draft.reconcile(providerID: "anthropic", modelID: nil, reasoningValue: nil)
        #expect(draft == beforeCancellation)
    }

    @Test func friendlyCurrentModelLabelPreservesExactIdentifierBeforePickerOpens() throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker()
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001", agentID: "juno", messaging: messaging
        )
        controls.seedAgentDefaults(.init(providerID: "copilot", modelID: "gpt-6-astra", reasoningEffort: "high"))
        #expect(controls.modelDisplayName == "GPT-6 Astra")
        #expect(controls.currentModel == "gpt-6-astra")
        #expect(messaging.opened.isEmpty)
    }

    @Test func largeModelPickerProvidersStartCollapsedAndToggleIndependently() {
        var disclosure = BighelpModelPickerDisclosureState()

        #expect(!disclosure.isExpanded("openai"))
        #expect(!disclosure.isExpanded("anthropic"))

        disclosure.toggle("anthropic")

        #expect(!disclosure.isExpanded("openai"))
        #expect(disclosure.isExpanded("anthropic"))
    }

    @Test func quickModelChoicesPutCurrentProviderFirstThenValidRecentModels() async throws {
        let suiteName = #function
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let history = RecentModelHistoryStore(defaults: defaults)
        history.record(providerID: "missing", modelID: "removed-model")
        history.record(providerID: "openai", modelID: "gpt-5.6")
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: RuntimeControlMessagingFixture(
                modelPicker: try decodeModelPicker(),
                reasoningPicker: try decodeReasoningPicker()
            ),
            modelHistory: history,
            now: { 1_788_000_000 }
        )

        await controls.loadModelPicker()

        #expect(controls.quickModelChoices.map(\.providerID) == ["nous", "openai"])
        #expect(controls.quickModelChoices.map(\.modelID) == ["Hermes-4-405B", "gpt-5.6"])
        #expect(controls.quickModelChoices.first?.isCurrent == true)
    }

    @Test func failedRuntimeSelectionPreservesTheCanonicalChoiceAndSurfacesFailure() async throws {
        let messaging = RuntimeControlMessagingFixture(
            modelPicker: try decodeModelPicker(),
            reasoningPicker: try decodeReasoningPicker(),
            resultStatus: .failed
        )
        let controls = SessionRuntimeControlModel(
            sessionID: "session_runtime_fixture_0001",
            agentID: "juno",
            messaging: messaging,
            now: { 1_788_000_000 }
        )
        await controls.loadModelPicker()

        await controls.selectModel(providerID: "openai", modelID: "gpt-5.6")

        #expect(controls.currentProvider == "nous")
        #expect(controls.currentModel == "Hermes-4-405B")
        #expect(controls.errorMessage == "Hermes could not apply that model.")
    }

    @Test func providerBrandRegistryRecognizesADeepCrossProviderCatalog() {
        #expect(AIProviderBrandRegistry.indexedProviderIDs.count >= 24)
        // Subscriptions have their own marks; the APIs keep the company marks.
        #expect(AIProviderBrandRegistry.resolve(id: "openai-codex", name: "OpenAI Codex") == .codex)
        #expect(AIProviderBrandRegistry.resolve(id: "openai-api", name: "OpenAI API") == .openAI)
        #expect(AIProviderBrandRegistry.resolve(id: "claude", name: "Claude") == .claude)
        #expect(AIProviderBrandRegistry.resolve(id: "anthropic", name: "Anthropic") == .anthropic)
        #expect(
            AIProviderBrandRegistry.resolve(
                id: "github-copilot",
                name: "GitHub Copilot"
            ).logoAssetName == "ProviderLogoGitHubCopilot"
        )
        #expect(
            AIProviderBrandRegistry.resolve(
                id: "copilot",
                name: "GitHub Copilot"
            ).logoAssetName == "ProviderLogoGitHubCopilot"
        )
        #expect(AIProviderBrandRegistry.resolve(id: "google", name: "Google Gemini") == .google)
        #expect(AIProviderBrandRegistry.resolve(id: "aws-bedrock", name: "Amazon Bedrock") == .bedrock)
        #expect(AIProviderBrandRegistry.resolve(id: "local", name: "LM Studio") == .lmStudio)
        #expect(AIProviderBrandRegistry.resolve(id: "private-endpoint", name: "My Provider") == .custom)
        #expect(AIProviderBrand.openAI.logoAssetName == "ProviderLogoOpenAI")
        #expect(AIProviderBrand.openRouter.logoAssetName == "ProviderLogoOpenRouter")
        #expect(AIProviderBrand.mistral.logoAssetName == "ProviderLogoMistral")
        #expect(AIProviderBrand.lmStudio.logoAssetName == "ProviderLogoLMStudio")
        #expect(AIProviderBrand.huggingFace.logoAssetName == "ProviderLogoHuggingFace")
        #expect(AIProviderBrand.venice.logoAssetName == "ProviderLogoVenice")
        #expect(AIProviderBrand.anthropic.logoAssetName == "ProviderLogoAnthropic")
        #expect(AIProviderBrand.google.logoAssetName == "ProviderLogoGoogle")
        #expect(AIProviderBrand.xAI.logoAssetName == nil)
        #expect(AIProviderBrand.custom.logoAssetName == nil)
    }

    @Test func providerArtworkDistinguishesOfficialMarksFromNeutralFallbacks() {
        #expect(
            AIProviderBrand.openAI.artwork
                == .official(assetName: "ProviderLogoOpenAI")
        )
        #expect(
            AIProviderBrand.githubCopilot.artwork
                == .official(assetName: "ProviderLogoGitHubCopilot")
        )
        #expect(
            AIProviderBrand.anthropic.artwork
                == .official(assetName: "ProviderLogoAnthropic")
        )
        #expect(
            AIProviderBrand.google.artwork
                == .official(assetName: "ProviderLogoGoogle")
        )
        #expect(AIProviderBrand.custom.artwork == .fallback)
    }

    @Test func modelPickerGroupsKeepCurrentProviderFirstAndSearchAcrossProviderAndModel() {
        let providers = [
            BighelpLinkModelProvider(
                id: "anthropic",
                name: "Anthropic",
                isCurrent: false,
                isCustom: false,
                models: ["claude-opus-4.6", "claude-sonnet-4.5"]
            ),
            BighelpLinkModelProvider(
                id: "openai",
                name: "OpenAI",
                isCurrent: true,
                isCustom: false,
                models: ["gpt-5.6", "gpt-5.5"]
            ),
        ]

        let currentFirst = BighelpModelPickerFiltering.groups(
            providers: providers,
            currentProviderID: "openai",
            query: ""
        )
        #expect(currentFirst.map(\.provider.id) == ["openai", "anthropic"])
        #expect(currentFirst.first?.models == ["gpt-5.6", "gpt-5.5"])

        let modelMatch = BighelpModelPickerFiltering.groups(
            providers: providers,
            currentProviderID: "openai",
            query: "opus"
        )
        #expect(modelMatch.map(\.provider.id) == ["anthropic"])
        #expect(modelMatch.first?.models == ["claude-opus-4.6"])

        let providerMatch = BighelpModelPickerFiltering.groups(
            providers: providers,
            currentProviderID: "openai",
            query: "OPEN"
        )
        #expect(providerMatch.map(\.provider.id) == ["openai"])
        #expect(providerMatch.first?.models == ["gpt-5.6", "gpt-5.5"])
    }

    @Test func composerUsesOneAdaptiveVoiceOrSendAction() {
        #expect(ChatComposerPrimaryAction.resolve(draft: "") == .voice)
        #expect(ChatComposerPrimaryAction.resolve(draft: "   \n") == .voice)
        #expect(ChatComposerPrimaryAction.resolve(draft: "Ask Juno") == .send)
    }

    @Test func sendOptionsRequireExactlyOneSecondOfHolding() {
        #expect(ChatComposerInteractionPolicy.sendOptionsLongPressDuration == 1.0)
    }

    @Test func activeTurnComposerStopsOnlyWhileItsDraftIsEmpty() {
        #expect(ChatComposerPrimaryAction.resolve(draft: "", isTurnActive: true) == .stop)
        #expect(ChatComposerPrimaryAction.resolve(draft: "   \n", isTurnActive: true) == .stop)
        #expect(ChatComposerPrimaryAction.resolve(draft: "Steer this", isTurnActive: true) == .send)
        #expect(ChatComposerPrimaryAction.resolve(draft: "", isTurnActive: true) == .stop)
    }

    @Test func draftAttachmentsCanBeRemovedAndSendWithTheirVisibleThumbnailMetadata() async throws {
        let client = AttachmentConversationClientFixture()
        let model = ChatModel(
            conversationID: "session_fixture_0001",
            client: client,
            initialItems: []
        )
        let image = try ChatAttachment(
            id: "attachment_image_fixture_0001",
            fileName: "forecast.png",
            mimeType: "image/png",
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )
        let file = try ChatAttachment(
            id: "attachment_file_fixture_0001",
            fileName: "brief.pdf",
            mimeType: "application/pdf",
            data: Data("PDF".utf8)
        )

        try model.addDraftAttachment(image)
        try model.addDraftAttachment(file)
        model.removeDraftAttachment(id: image.id)
        model.draft = "Review the brief"
        await model.send()

        #expect(client.attachments == [[file]])
        #expect(model.draftAttachments.isEmpty)
        #expect(model.items.first?.attachments == [file])
    }

    @Test func emptyChatPromptsUseTheApprovedActionLanguage() {
        #expect(QuickAction.allCases.map(\.title) == [
            "Catch me up",
            "Plan my day",
            "Start a task",
        ])
    }

    @Test func pendingPresentationUsesTheSelectedAgentsName() {
        let presentation = PendingMessagePresentation(agentName: "  Juno  ")

        #expect(presentation.visibleText == "Juno is working…")
        #expect(presentation.accessibilityLabel == "Sending. Juno is working.")
    }

    @Test func pendingPresentationNeverUsesTheBighelpBrandAsAnAgentName() {
        let presentation = PendingMessagePresentation(agentName: "bighelp")

        #expect(presentation.visibleText == "Your agent is working…")
        #expect(presentation.accessibilityLabel == "Sending. Your agent is working.")
    }

    @Test func workingAgentNamePrefersTheLiveHermesDraftIdentity() async {
        let client = ControlledStreamingConversationClient()
        let model = ChatModel(
            conversationID: "session_fixture_0001",
            client: client,
            initialItems: []
        )
        model.draft = "Who is working?"

        let send = Task { await model.send() }
        await client.waitUntilStarted()
        client.yieldDraft(agentName: "Juno")

        #expect(model.workingAgentName == "Juno")

        client.finish()
        await send.value
    }

    @Test func stoppingALiveTurnUsesTheConversationStopContractAndClearsWorkingState() async {
        let client = ControlledStoppableConversationClient()
        var acceptedStops = 0
        let model = ChatModel(
            conversationID: "session_stop_active_turn_0001",
            client: client,
            initialItems: [],
            onTurnStopped: { acceptedStops += 1 }
        )
        model.draft = "Start the long task"
        let turn = Task { await model.send() }
        await client.waitUntilStarted()

        #expect(model.isSending)
        #expect(model.canStop)
        await model.stop()
        await turn.value

        #expect(client.stoppedConversationIDs == ["session_stop_active_turn_0001"])
        #expect(client.reconciledConversationIDs == ["session_stop_active_turn_0001"])
        #expect(acceptedStops == 1)
        #expect(!model.isSending)
        #expect(!model.canStop)
    }

    @Test func liveDirectTurnUsesTheCurrentDefaultForAnAcceptedMidSessionSend() async throws {
        let client = ControlledMidSessionConversationClient()
        let defaultBehavior = MidSessionBehaviorBox(.steer)
        let model = ChatModel(
            conversationID: "session_mid_session_default_0001",
            client: client,
            initialItems: [],
            midSessionBehavior: { defaultBehavior.value }
        )
        model.draft = "Start the analysis"
        let owner = Task { await model.send() }
        await client.waitUntilInitialStarted()

        defaultBehavior.value = .queued
        model.draft = "Also compare last quarter"
        let submission = Task { await model.send() }
        await client.waitUntilMidSessionStarted()

        #expect(model.midSessionSubmissionState == .submitting(.queued))
        #expect(model.isSending)
        #expect(client.midSessionBehaviors == [.queued])
        client.resolveMidSession(.accepted)
        await submission.value

        #expect(model.midSessionSubmissionState == .idle)
        #expect(model.draft.isEmpty)
        #expect(model.items.compactMap { item -> String? in
            guard case .message(let text) = item.content else { return nil }
            return text
        } == [
            "Start the analysis",
            "Also compare last quarter",
        ])

        client.finishInitial(text: "Initial answer")
        await owner.value
    }

    @Test func liveDirectTurnAcceptsMultipleSteeringMessagesWithoutWaitingForEarlierSteers() async {
        let client = ControlledConcurrentMidSessionConversationClient()
        let model = ChatModel(
            conversationID: "session_mid_session_multiple_steers_0001",
            client: client,
            initialItems: []
        )
        model.draft = "Start the analysis"
        let owner = Task { await model.send() }
        await client.waitUntilInitialStarted()

        model.draft = "First steering message"
        let firstSteer = Task { await model.sendMidSession(using: .steer) }
        await client.waitForMidSessionRequestCount(1)

        model.draft = "Second steering message"
        let secondSteer = Task { await model.sendMidSession(using: .steer) }
        for _ in 0..<20 where client.midSessionMessages.count < 2 {
            await Task.yield()
        }

        #expect(client.midSessionMessages == [
            "First steering message",
            "Second steering message",
        ])
        guard client.midSessionMessages.count == 2 else {
            client.resolveMidSession(at: 0, with: .accepted)
            await firstSteer.value
            await secondSteer.value
            client.finishInitial(text: "Initial answer")
            await owner.value
            return
        }

        let pendingHumanIDs = Array(model.items.filter { $0.role == .human }.suffix(2).map(\.id))
        #expect(model.pendingMidSessionSubmissions.map(\.id) == pendingHumanIDs)
        #expect(model.pendingMidSessionSubmissions.map(\.behavior) == [.steer, .steer])
        #expect(!model.isComposerInputDisabled)

        client.resolveMidSession(at: 1, with: .accepted)
        await secondSteer.value
        #expect(model.pendingMidSessionSubmissions.map(\.id) == [pendingHumanIDs[0]])
        client.resolveMidSession(at: 0, with: .accepted)
        await firstSteer.value
        #expect(model.pendingMidSessionSubmissions.isEmpty)
        #expect(model.midSessionSubmissionState == .idle)

        client.finishInitial(text: "Initial answer")
        await owner.value
    }

    @Test func pendingMidSessionPresentationUsesSpecificLiveSubmissionLabels() {
        #expect(PendingMidSessionPresentation.label(for: .steer) == "Steering…")
        #expect(PendingMidSessionPresentation.label(for: .queued) == "Queued…")
        #expect(PendingMidSessionPresentation.label(for: .interruptAndSend) == "Interrupting…")
    }

    @Test func rejectedMidSessionSendRestoresTheExactDraftAndAttachmentsWithoutDuplicatingHistory() async throws {
        let client = ControlledMidSessionConversationClient()
        let model = ChatModel(
            conversationID: "session_mid_session_rejected_0001",
            client: client,
            initialItems: []
        )
        model.draft = "Start"
        let owner = Task { await model.send() }
        await client.waitUntilInitialStarted()

        let attachment = try ChatAttachment(
            id: "mid_session_attachment_0001",
            fileName: "context.txt",
            mimeType: "text/plain",
            data: Data("context".utf8)
        )
        model.draft = "Do not lose this"
        try model.addDraftAttachment(attachment)
        let submission = Task { await model.sendMidSession(using: .steer) }
        await client.waitUntilMidSessionStarted()
        client.rejectMidSession()
        await submission.value

        #expect(model.draft == "Do not lose this")
        #expect(model.draftAttachments == [attachment])
        #expect(model.items.filter { $0.role == .human }.count == 1)
        #expect(model.transcriptEntries.compactMap(\.messageText) == ["Start"])
        #expect(model.isSending)
        #expect(model.midSessionSubmissionState == .idle)

        client.finishInitial(text: "Initial answer")
        await owner.value
    }

    @Test func interruptAndSendInvalidatesTheOldOwnerBeforeReplacementDraftsAndFinalizersArrive() async {
        let client = ControlledMidSessionConversationClient()
        let model = ChatModel(
            conversationID: "session_mid_session_interrupt_0001",
            client: client,
            initialItems: []
        )
        model.draft = "Old turn"
        let owner = Task { await model.send() }
        await client.waitUntilInitialStarted()

        model.draft = "Replace it now"
        let replacement = Task { await model.sendMidSession(using: .interruptAndSend) }
        await client.waitUntilMidSessionStarted()
        client.yieldMidSessionDraft(id: "replacement-stream", text: "Replacement working")
        client.resolveMidSession(.replacement(ConversationResponse(items: [
            TimelineItem(
                id: "replacement-final",
                role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
                content: .message("Replacement final"),
                metadata: .init(delivery: "Delivered")
            ),
        ])))
        await replacement.value

        client.yieldInitialDraft(id: "stale-old-draft", text: "Stale old draft")
        client.failInitial()
        await owner.value

        #expect(model.items.map(\.id).contains("replacement-stream"))
        #expect(model.items.map(\.id).contains("replacement-final"))
        #expect(!model.items.map(\.id).contains("stale-old-draft"))
        #expect(model.failureMessage == nil)
        #expect(!model.isSending)
    }

    @Test func acceptedInterruptUnlocksTheComposerWhileTheReplacementTurnRemainsLive() async {
        let client = ControlledMidSessionConversationClient()
        let model = ChatModel(
            conversationID: "session_interrupt_acceptance_0001",
            client: client,
            initialItems: []
        )
        model.draft = "Old turn"
        let owner = Task { await model.send() }
        await client.waitUntilInitialStarted()

        model.draft = "Replace it now"
        let replacement = Task { await model.sendMidSession(using: .interruptAndSend) }
        await client.waitUntilMidSessionStarted()

        #expect(model.hasExclusiveMidSessionSubmission)
        #expect(model.isComposerInputDisabled)
        client.resolveMidSession(.accepted)
        await replacement.value

        #expect(!model.hasExclusiveMidSessionSubmission)
        #expect(!model.isComposerInputDisabled)
        #expect(model.isSending)
        model.draft = "Steer the replacement"
        #expect(model.canSend)

        client.failInitial()
        await owner.value
    }

    @Test func sendButtonAlternativesContainOnlyTheTwoNonDefaultOneShotModes() {
        #expect(MidSessionSendPresentation.alternatives(defaultBehavior: .steer) == [
            .queued,
            .interruptAndSend,
        ])
        #expect(MidSessionSendPresentation.alternatives(defaultBehavior: .queued) == [
            .steer,
            .interruptAndSend,
        ])
        #expect(MidSessionSendPresentation.alternatives(defaultBehavior: .interruptAndSend) == [
            .steer,
            .queued,
        ])
        #expect(MidSessionChatBehavior.allCases.allSatisfy { !$0.detail.isEmpty })
    }

    @Test func sendButtonRequiresAOneSecondHoldToUnlockAlternatives() {
        #expect(MidSessionSendPresentation.unlockHoldDuration == 1.0)
    }

    @Test func sendButtonUnlockProgressIsClampedAndProportionalToElapsedHoldTime() {
        #expect(MidSessionSendPresentation.unlockProgress(elapsed: 0) == 0)
        #expect(MidSessionSendPresentation.unlockProgress(elapsed: -1) == 0)
        #expect(MidSessionSendPresentation.unlockProgress(elapsed: 0.5) == 0.5)
        #expect(MidSessionSendPresentation.unlockProgress(elapsed: 1.0) == 1)
        #expect(MidSessionSendPresentation.unlockProgress(elapsed: 10) == 1)
    }

    @Test func workingAgentNameUsesTheMostRecentCanonicalAssistantIdentity() {
        let older = TimelineItem(
            id: "older-assistant",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Avery")),
            content: .message("Older answer"),
            metadata: TimelineMetadata(delivery: "Delivered")
        )
        let latest = TimelineItem(
            id: "latest-assistant",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Juno")),
            content: .message("Latest answer"),
            metadata: TimelineMetadata(delivery: "Delivered")
        )
        let model = ChatModel(
            conversationID: "restored-agent-name",
            client: ConversationFixtureClient(),
            initialItems: [older, latest]
        )

        #expect(model.workingAgentName == "Juno")
    }

    @Test func lateLoadedAgentDirectoryReplacesAnOlderAssistantSnapshotIdentity() async throws {
        let directoryClient = AgentDirectoryFixtureClient(profiles: [
            AgentProfile(
                id: "default",
                name: "Juno",
                role: "Default agent",
                summary: "The default Hermes agent.",
                instructions: "Be helpful.",
                avatarFileName: nil,
                isDefault: true
            ),
        ])
        let directory = AgentDirectoryStore(client: directoryClient, profiles: [])
        let item = TimelineItem(
            id: "assistant-before-directory-load",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
            content: .message("Saved answer"),
            metadata: .init(delivery: "Saved")
        )
        let model = ChatModel(
            conversationID: "late-agent-directory",
            client: ConversationFixtureClient(),
            initialItems: [item],
            agentDirectory: directory
        )

        #expect(model.workingAgentName == "Assistant")

        try await directory.load()

        #expect(model.workingAgentName == "Juno")
    }

    @Test func oldCanonicalAnswerCannotReplaceAnInFlightNewUserTurn() async {
        let sleeper = ControlledDemoSleeper()
        let prior = TimelineItem(id: "local-old-answer", role: .assistant,
                                 sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                                 content: .message("Prior answer"), metadata: .init(delivery: "Saved", sourceOrder: 1))
        let model = ChatModel(conversationID: "idle-send", client: ConversationFixtureClient(), sleeper: sleeper, initialItems: [prior])
        model.draft = "New question after being idle"
        let submission = Task { await model.send() }
        await sleeper.waitUntilSleepStarts()
        let canonicalOld = TimelineItem(id: "hermes:stored:900", role: prior.role, sender: prior.sender,
                                        content: prior.content, metadata: .init(delivery: "Saved", sourceOrder: 900))
        model.reconcileHydratedSession(SessionRecord(id: "idle-send", kind: .direct, agentIDs: ["default"], title: "Existing chat", items: [canonicalOld]))
        #expect(model.isSending)
        #expect(model.transcriptEntries.compactMap(\.messageText).last == "New question after being idle")
        sleeper.resume()
        await submission.value
    }

    @Test func authoritativeHydrationReplacesRenderedLocalRowsWithoutCollapsingEqualTextTurns() {
        let sessionID = "canonical-render-replacement"
        let local = (0..<4).map { index in
            TimelineItem(
                id: "local-\(index)", role: index.isMultiple(of: 2) ? .human : .assistant,
                sender: index.isMultiple(of: 2) ? .user(snapshot: .init(name: "You")) : .agent(id: "default", snapshot: .init(name: "Juno")),
                content: .message(index.isMultiple(of: 2) ? "/plan repeat this" : "Completed"),
                metadata: .init(delivery: "Saved", sourceOrder: index + 1)
            )
        }
        let canonical = local.enumerated().map { index, item in
            TimelineItem(
                id: "hermes:stored:\(1001 + index)", role: item.role, sender: item.sender, content: item.content,
                metadata: .init(source: "Hermes · loopdy", delivery: "Saved", sourceOrder: 1001 + index)
            )
        }
        let model = ChatModel(conversationID: sessionID, client: ConversationFixtureClient(), initialItems: local)
        let snapshot = SessionRecord(id: sessionID, kind: .direct, agentIDs: ["default"], title: "Repeated turns", items: canonical, hasAcceptedMessage: true)
        model.reconcileHydratedSession(snapshot)
        let rendered = model.transcriptEntries.compactMap { entry -> String? in
            guard case .message(let item) = entry else { return nil }
            return item.id
        }
        #expect(model.items.map(\.id) == canonical.map(\.id))
        #expect(rendered == canonical.map(\.id))
        model.reconcileHydratedSession(snapshot)
        #expect(model.transcriptEntries.count == 4)
    }

    @Test func hydratedSessionWithSameItemCountReplacesTheSummaryWithCanonicalHistory() {
        let summaryItem = TimelineItem(
            id: "hermes:stored-summary:summary-preview",
            role: .human,
            sender: .user(snapshot: .init(name: "You")),
            content: .message("Weather preview"),
            metadata: .init(source: "Hermes · loopdy", delivery: "Saved")
        )
        let canonicalItem = TimelineItem(
            id: "hermes:stored-summary:message-1",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Juno")),
            content: .message("The full weather answer"),
            metadata: .init(source: "Hermes · loopdy", delivery: "Saved")
        )
        let model = ChatModel(
            conversationID: "session-summary-correction",
            client: ConversationFixtureClient(),
            initialItems: [summaryItem]
        )
        let canonical = SessionRecord(
            id: "session-summary-correction",
            kind: .direct,
            agentIDs: ["default"],
            title: "Weather",
            items: [canonicalItem],
            hasAcceptedMessage: true
        )

        model.reconcileHydratedSession(canonical)

        #expect(model.items.map(\.id) == [canonicalItem.id])
        #expect(model.items.map(\.content) == [canonicalItem.content])
        #expect(model.items.first?.metadata.sourceOrder == 1)
    }

    @Test func historyHydrationClearsThePreviewPublishesBatchesAndKeepsLoadingUntilFinished() {
        let preview = TimelineItem(
            id: "hermes:stored-progressive:summary-preview",
            role: .human,
            sender: .user(snapshot: .init(name: "You")),
            content: .message("Stale preview"),
            metadata: .init(source: "Hermes · loopdy", delivery: "Saved")
        )
        let model = ChatModel(
            conversationID: "session-progressive-chat",
            client: ConversationFixtureClient(),
            initialItems: [preview]
        )
        var authoritative = SessionRecord(
            id: "session-progressive-chat",
            kind: .direct,
            agentIDs: ["default"],
            title: "Long conversation",
            items: [preview],
            hasAcceptedMessage: true
        )

        model.beginHistoryHydration(from: authoritative)

        #expect(model.isHydratingHistory)
        #expect(model.items.isEmpty)

        authoritative.items = [TimelineItem(
            id: "hermes:stored-progressive:latest-answer",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Juno")),
            content: .message("Latest answer"),
            metadata: .init(source: "Hermes · loopdy", delivery: "Saved", sourceOrder: 20)
        )]
        model.reconcileHydratedSession(authoritative)

        #expect(model.items.map(\.id) == ["hermes:stored-progressive:latest-answer"])
        #expect(model.isHydratingHistory)

        model.finishHistoryHydration()

        #expect(!model.isHydratingHistory)
    }

    @Test func historyHydrationKeepsCanonicalTranscriptVisibleWhileRefreshing() {
        let canonicalItem = TimelineItem(
            id: "hermes:stored-session:answer",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Juno")),
            content: .message("Durable answer"),
            metadata: .init(source: "Hermes · loopdy", delivery: "Saved")
        )
        let session = SessionRecord(
            id: "session-reopen",
            kind: .direct,
            agentIDs: ["default"],
            title: "Reopened session",
            items: [canonicalItem],
            hasAcceptedMessage: true
        )
        let model = ChatModel(
            conversationID: session.id,
            client: ConversationFixtureClient(),
            initialItems: session.items
        )

        model.beginHistoryHydration(from: session)

        #expect(model.isHydratingHistory)
        #expect(model.items.map(\.id) == [canonicalItem.id])
        #expect(model.items.map(\.content) == [canonicalItem.content])
    }

    @Test func activeSessionAcceptsAnOlderHistoryPageWhileItIsLoading() {
        let session = SessionRecord(
            id: "active-history-page",
            kind: .direct,
            agentIDs: ["default"],
            title: "Active session",
            isActive: true,
            hasAcceptedMessage: true
        )
        let model = ChatModel(
            conversationID: session.id,
            client: ConversationFixtureClient(),
            initialItems: [],
            sourceSession: session
        )
        model.beginHistoryHydration(from: session)
        model.finishHistoryHydration(hasPreviousHistory: true)
        model.beginLoadingPreviousHistory()
        var hydrated = session
        hydrated.items = [TimelineItem(
            id: "older-answer",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Juno")),
            content: .message("Earlier work remains visible."),
            metadata: .init(source: "Hermes · loopdy", delivery: "Saved")
        )]

        model.reconcileHydratedSession(hydrated)

        #expect(model.items.map(\.id) == ["older-answer"])
        #expect(model.isSending)
    }

    @Test func onlyTrulyNewBlankChatsShowTheWelcomeState() {
        let newChat = ChatModel(
            conversationID: "new-blank-chat",
            client: ConversationFixtureClient(),
            initialItems: []
        )
        #expect(newChat.shouldShowNewConversationWelcome)

        let restored = SessionRecord(
            id: "restored-empty-chat",
            kind: .direct,
            agentIDs: ["default"],
            title: "Restored session",
            hasAcceptedMessage: true
        )
        let restoredModel = ChatModel(
            conversationID: restored.id,
            client: ConversationFixtureClient(),
            initialItems: [],
            sourceSession: restored
        )
        #expect(!restoredModel.shouldShowNewConversationWelcome)

        var active = restored
        active.isActive = true
        let activeModel = ChatModel(
            conversationID: active.id,
            client: ConversationFixtureClient(),
            initialItems: [],
            sourceSession: active
        )
        #expect(!activeModel.shouldShowNewConversationWelcome)
    }

    @Test func streamingDraftRevisionsAndCanonicalFinalUpdateOneMessageInPlace() async {
        let client = ControlledStreamingConversationClient()
        let model = ChatModel(
            conversationID: "session_fixture_0001",
            client: client,
            initialItems: []
        )
        model.draft = "Stream this"

        let send = Task { await model.send() }
        await client.waitUntilStarted()
        client.yieldDraft(id: "message_streaming_0001", text: "Working")

        #expect(model.presentedItems.map(\.content) == [
            .message("Stream this"),
            .message("Working"),
        ])
        let sourceOrder = model.presentedItems.last?.metadata.sourceOrder

        client.yieldDraft(id: "message_streaming_0001", text: "Working draft")

        #expect(model.presentedItems.map(\.content) == [
            .message("Stream this"),
            .message("Working draft"),
        ])
        #expect(model.presentedItems.last?.metadata.sourceOrder == sourceOrder)

        client.finish(id: "message_streaming_0001", text: "Final answer")
        await send.value

        #expect(model.presentedItems.map(\.content) == [
            .message("Stream this"),
            .message("Final answer"),
        ])
        #expect(model.presentedItems.last?.metadata.delivery == "Delivered")
        #expect(model.presentedItems.last?.metadata.sourceOrder == sourceOrder)
    }

    @Test func submittedHumanRowProjectsBeforeTheFirstStreamingDraftArrives() async {
        let client = ControlledStreamingConversationClient()
        let model = ChatModel(
            conversationID: "immediate-human-projection",
            client: client,
            initialItems: []
        )
        model.draft = "Start now"

        let send = Task { await model.send() }
        await client.waitUntilStarted()

        #expect(model.transcriptEntries.map(\.id) == [
            "message:immediate-human-projection-human-1",
        ])

        client.finish(id: "answer", text: "Done")
        await send.value
    }

    @Test func liveTailProjectionWorkIsIndependentOfSettledPrefixLength() async {
        func projectionWork(settledCount: Int) async -> Int {
            let settled = (1...settledCount).map { (index: Int) in
                TimelineItem(
                    id: "settled-\(index)",
                    role: .assistant,
                    sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                    content: .message("Settled \(index)"),
                    metadata: .init(delivery: "Delivered", sourceOrder: index)
                )
            }
            let client = ControlledStreamingConversationClient()
            let model = ChatModel(
                conversationID: "bounded-stream-projection-\(settledCount)",
                client: client,
                initialItems: settled
            )
            model.draft = "Continue"
            let send = Task { await model.send() }
            await client.waitUntilStarted()
            client.yieldDraft(id: "live-tail", text: "Revision")
            let work = model.lastTranscriptProjectionWorkCount
            client.finish(id: "live-tail", text: "Final")
            await send.value
            return work
        }

        let shortWork = await projectionWork(settledCount: 10)
        let longWork = await projectionWork(settledCount: 1_000)

        #expect(longWork <= shortWork + 2)
        #expect(longWork <= 4)
    }

    @Test func localStreamingCallbackItemMutationWorkIsIndependentOfSettledPrefixLength() async {
        func mutationWork(settledCount: Int) async -> Int {
            let settled = (1...settledCount).map { index in
                TimelineItem(
                    id: "local-item-settled-\(index)",
                    role: .assistant,
                    sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                    content: .message("Settled \(index)"),
                    metadata: .init(delivery: "Delivered", sourceOrder: index)
                )
            }
            let client = ControlledStreamingConversationClient()
            let model = ChatModel(
                conversationID: "local-item-scaling-\(settledCount)",
                client: client,
                initialItems: settled
            )
            model.draft = "Continue"
            let send = Task { await model.send() }
            await client.waitUntilStarted()
            client.yieldDraft(id: "local-live-tail", text: "First")
            client.yieldDraft(id: "local-live-tail", text: "Revision")
            let work = model.lastItemMutationWorkCount
            client.finish(id: "local-live-tail", text: "Final")
            await send.value
            return work
        }

        let shortWork = await mutationWork(settledCount: 10)
        let longWork = await mutationWork(settledCount: 1_000)

        #expect(shortWork == 2)
        #expect(longWork == 2)
    }

    @Test func firstLocalStreamingDraftItemMutationWorkIsIndependentOfSettledPrefixLength() async {
        func mutationWork(settledCount: Int) async -> Int {
            let settled = (1...settledCount).map { index in
                TimelineItem(
                    id: "first-local-settled-\(index)",
                    role: .assistant,
                    sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                    content: .message("Settled \(index)"),
                    metadata: .init(delivery: "Delivered", sourceOrder: index)
                )
            }
            let client = ControlledStreamingConversationClient()
            let model = ChatModel(
                conversationID: "first-local-scaling-\(settledCount)",
                client: client,
                initialItems: settled
            )
            model.draft = "Continue"
            let send = Task { await model.send() }
            await client.waitUntilStarted()
            client.yieldDraft(id: "first-local-live-tail", text: "First")
            let work = model.lastItemMutationWorkCount
            client.finish(id: "first-local-live-tail", text: "Final")
            await send.value
            return work
        }

        let shortWork = await mutationWork(settledCount: 10)
        let longWork = await mutationWork(settledCount: 1_000)

        #expect(longWork <= shortWork + 2)
        #expect(longWork <= 4)
    }

    @Test func repeatedStreamingTailProjectionUpdatesOnlyTheMutableTail() async {
        let settled = (1...1_000).map { (index: Int) in
            TimelineItem(
                id: "settled-\(index)",
                role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                content: .message("Settled \(index)"),
                metadata: .init(delivery: "Delivered", sourceOrder: index)
            )
        }
        let client = ControlledStreamingConversationClient()
        let model = ChatModel(
            conversationID: "bounded-stream-projection",
            client: client,
            initialItems: settled
        )
        model.draft = "Continue"
        let send = Task { await model.send() }
        await client.waitUntilStarted()

        for revision in 1...20 {
            client.yieldDraft(id: "live-tail", text: "Revision \(revision)")
            #expect(model.lastTranscriptProjectionWorkCount <= 2)
        }

        #expect(model.transcriptEntries.count == 1_002)

        client.finish(id: "live-tail", text: "Final")
        await send.value
    }

    @Test func externalStreamingRevisionWorkIsIndependentOfSettledPrefixLength() {
        func revisionWork(settledCount: Int) -> Int {
            let settled = (1...settledCount).map { index in
                TimelineItem(
                    id: "external-settled-\(index)",
                    role: .assistant,
                    sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                    content: .message("Settled \(index)"),
                    metadata: .init(delivery: "Delivered", sourceOrder: index)
                )
            }
            let model = ChatModel(
                conversationID: "external-scaling-\(settledCount)",
                client: ConversationFixtureClient(),
                initialItems: settled
            )
            let draft = TimelineItem(
                id: "external-live-tail",
                role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                content: .message("First"),
                metadata: .init(delivery: "Streaming")
            )
            model.acceptExternal([draft])
            model.acceptExternal([TimelineItem(
                id: draft.id,
                role: draft.role,
                sender: draft.sender,
                content: .message("Revision"),
                metadata: draft.metadata
            )])
            return model.lastTranscriptProjectionWorkCount
        }

        let shortWork = revisionWork(settledCount: 10)
        let longWork = revisionWork(settledCount: 1_000)
        #expect(longWork <= shortWork + 1)
        #expect(longWork <= 2)
    }

    @Test func liveTailActivityInsertionAndUpdateWorkIsIndependentOfSettledPrefixLength() {
        func activityWork(settledCount: Int) -> (insert: Int, update: Int, entryID: String?) {
            let settled = (1...settledCount).map { index in
                TimelineItem(
                    id: "activity-settled-\(index)",
                    role: .assistant,
                    sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                    content: .message("Settled \(index)"),
                    metadata: .init(delivery: "Delivered", sourceOrder: index)
                )
            }
            let model = ChatModel(
                conversationID: "activity-scaling-\(settledCount)",
                client: ConversationFixtureClient(),
                initialItems: settled
            )
            let running = ChatActivityEvent(
                eventID: "live-tool",
                sessionID: model.conversationID,
                turnID: "live-turn",
                kind: .tool,
                lifecycle: .running,
                title: "Live tool",
                summary: nil,
                detail: nil,
                occurredAt: 10_000,
                toolCallID: "live-call"
            )
            _ = model.acceptActivity(running)
            let insertWork = model.lastTranscriptProjectionWorkCount
            _ = model.acceptActivity(running.updating(
                lifecycle: .succeeded,
                summary: "Done",
                detail: nil,
                occurredAt: 10_001
            ))
            return (
                insertWork,
                model.lastTranscriptProjectionWorkCount,
                model.transcriptEntries.last?.id
            )
        }

        let short = activityWork(settledCount: 10)
        let long = activityWork(settledCount: 1_000)
        #expect(long.insert <= short.insert + 1)
        #expect(long.update <= short.update + 1)
        #expect(long.insert <= 3)
        #expect(long.update <= 3)
        #expect(short.entryID == "activity:live-turn:live-tool")
        #expect(long.entryID == short.entryID)
    }

    @Test func chatModelActivityRevisionWorkIsIndependentOfStoredLedgerSize() {
        func revisionWork(eventCount: Int) -> Int {
            let events = (1...eventCount).map { index in
                ChatActivityEvent(
                    eventID: "stored-event-\(index)",
                    sessionID: "activity-cow-\(eventCount)",
                    turnID: "stored-turn-\(index)",
                    kind: .tool,
                    lifecycle: .running,
                    title: "Stored \(index)",
                    summary: nil,
                    detail: nil,
                    occurredAt: index,
                    toolCallID: "stored-call-\(index)",
                    sourceOrder: index
                )
            }
            let model = ChatModel(
                conversationID: "activity-cow-\(eventCount)",
                client: ConversationFixtureClient(),
                initialItems: [],
                initialActivityEvents: events
            )
            let revised = events[eventCount - 1].updating(
                lifecycle: .succeeded,
                summary: "Done",
                detail: nil,
                occurredAt: eventCount + 1
            )

            #expect(model.acceptActivity(revised) == .updated)
            return model.lastActivityMutationWorkCount
        }

        let shortWork = revisionWork(eventCount: 10)
        let longWork = revisionWork(eventCount: 1_000)

        #expect(shortWork == 1)
        #expect(longWork == 1)
    }

    @Test func activityGroupOrderCacheMatchesEventsAfterAppendAndReplacement() {
        func event(_ id: String, _ order: Int?) -> ChatActivityEvent {
            ChatActivityEvent(eventID: id, sessionID: "order-cache", turnID: "turn",
                kind: .tool, lifecycle: .running, title: id, summary: nil, detail: nil,
                occurredAt: 1, toolCallID: id, sourceOrder: order)
        }
        let group = ChatActivityTurn(id: "turn", events: [event("a", nil)])
        #expect(group.upperSourceOrder == .max)
        for item in [event("b", 20), event("c", 10), event("d", nil)] {
            group.append(item)
            #expect(group.upperSourceOrder == group.events.compactMap(\.sourceOrder).max())
        }
        for (index, item) in [(1, event("b", 5)), (2, event("c", nil)), (1, event("b", nil))] {
            group.update(item, at: index)
            #expect(group.upperSourceOrder == (group.events.compactMap(\.sourceOrder).max() ?? .max))
        }
    }

    @Test func sameTurnActivityTailAppendWorkIsIndependentOfExistingGroupSize() {
        func appendWork(eventCount: Int) -> (work: Int, ids: [String], reopenedIDs: [String]) {
            let sessionID = "same-turn-append-\(eventCount)"
            let events = (1...eventCount).map { index in
                ChatActivityEvent(
                    eventID: "same-turn-event-\(index)",
                    sessionID: sessionID,
                    turnID: "one-turn",
                    kind: .tool,
                    lifecycle: .running,
                    title: "Tool \(index)",
                    summary: nil,
                    detail: nil,
                    occurredAt: index,
                    toolCallID: "same-turn-call-\(index)",
                    sourceOrder: index
                )
            }
            let model = ChatModel(
                conversationID: sessionID,
                client: ConversationFixtureClient(),
                initialItems: [],
                initialActivityEvents: events
            )
            let next = ChatActivityEvent(
                eventID: "same-turn-event-next",
                sessionID: sessionID,
                turnID: "one-turn",
                kind: .tool,
                lifecycle: .running,
                title: "Next tool",
                summary: nil,
                detail: nil,
                occurredAt: eventCount + 1,
                toolCallID: "same-turn-call-next",
                sourceOrder: eventCount + 1
            )

            #expect(model.acceptActivity(next) == .inserted)
            let turns = model.transcriptEntries.compactMap { entry -> ChatActivityTurn? in
                guard case .activity(let turn) = entry else { return nil }
                return turn
            }
            #expect(turns.count == 1)
            let reopened = ChatModel(
                conversationID: sessionID,
                client: ConversationFixtureClient(),
                initialItems: [],
                initialActivityEvents: model.activityLedger.allEvents
            )
            let reopenedTurns = reopened.transcriptEntries.compactMap { entry -> ChatActivityTurn? in
                guard case .activity(let turn) = entry else { return nil }
                return turn
            }
            #expect(reopenedTurns.count == 1)
            return (
                model.lastActivityMutationWorkCount + model.lastTranscriptProjectionWorkCount,
                turns.first?.events.map(\.id) ?? [],
                reopenedTurns.first?.events.map(\.id) ?? []
            )
        }

        let short = appendWork(eventCount: 10)
        let long = appendWork(eventCount: 1_000)

        #expect(long.work <= short.work + 2)
        #expect(long.ids.first == "same-turn-append-1000:one-turn:tool:same-turn-call-1")
        #expect(long.ids.last == "same-turn-append-1000:one-turn:tool:same-turn-call-next")
        #expect(long.ids.count == 1_001)
        #expect(long.reopenedIDs == long.ids)
    }

    @Test func sameTurnActivityEarlyRevisionWorkIsIndependentOfExistingGroupSize() {
        func updateWork(eventCount: Int) -> (work: Int, ids: [String], summary: String?) {
            let sessionID = "same-turn-update-\(eventCount)"
            let events = (1...eventCount).map { index in
                ChatActivityEvent(
                    eventID: "same-turn-update-event-\(index)",
                    sessionID: sessionID,
                    turnID: "one-turn",
                    kind: .tool,
                    lifecycle: .running,
                    title: "Tool \(index)",
                    summary: nil,
                    detail: nil,
                    occurredAt: index,
                    toolCallID: "same-turn-update-call-\(index)",
                    sourceOrder: index
                )
            }
            let model = ChatModel(
                conversationID: sessionID,
                client: ConversationFixtureClient(),
                initialItems: [],
                initialActivityEvents: events
            )
            let revisedIndex = eventCount / 2
            let revised = events[revisedIndex].updating(
                lifecycle: .succeeded,
                summary: "Updated",
                detail: nil,
                occurredAt: eventCount + 1
            )

            #expect(model.acceptActivity(revised) == .updated)
            let turn = model.transcriptEntries.compactMap { entry -> ChatActivityTurn? in
                guard case .activity(let turn) = entry else { return nil }
                return turn
            }.first
            return (
                model.lastActivityMutationWorkCount + model.lastTranscriptProjectionWorkCount,
                turn?.events.map(\.id) ?? [],
                turn?.events[revisedIndex].summary
            )
        }

        let short = updateWork(eventCount: 10)
        let long = updateWork(eventCount: 1_000)

        #expect(long.work <= short.work + 2)
        #expect(long.ids.first == "same-turn-update-1000:one-turn:tool:same-turn-update-call-1")
        #expect(long.ids.last == "same-turn-update-1000:one-turn:tool:same-turn-update-call-1000")
        #expect(long.ids.count == 1_000)
        #expect(long.summary == "Updated")
    }

    @Test func projectedActivityTurnObservationInvalidatesForAppendAndUpdateWithCoherentReferenceState() {
        let sessionID = "observable-activity-turn"
        let first = ChatActivityEvent(
            eventID: "observable-first",
            sessionID: sessionID,
            turnID: "observable-turn",
            kind: .tool,
            lifecycle: .running,
            title: "First",
            summary: nil,
            detail: nil,
            occurredAt: 1,
            toolCallID: "observable-call-first",
            sourceOrder: 1
        )
        let model = ChatModel(
            conversationID: sessionID,
            client: ConversationFixtureClient(),
            initialItems: [],
            initialActivityEvents: [first]
        )
        guard case .activity(let heldTurn) = model.transcriptEntries.first else {
            Issue.record("Expected projected activity turn")
            return
        }
        let appendInvalidations = ObservationInvalidationCounter()
        withObservationTracking {
            _ = heldTurn.events
        } onChange: {
            appendInvalidations.increment()
        }
        let second = ChatActivityEvent(
            eventID: "observable-second",
            sessionID: sessionID,
            turnID: first.turnID,
            kind: .tool,
            lifecycle: .running,
            title: "Second",
            summary: nil,
            detail: nil,
            occurredAt: 2,
            toolCallID: "observable-call-second",
            sourceOrder: 2
        )

        #expect(model.acceptActivity(second) == .inserted)
        #expect(appendInvalidations.value == 1)
        #expect(heldTurn.events.map(\.id) == [first.id, second.id])

        let updateInvalidations = ObservationInvalidationCounter()
        withObservationTracking {
            _ = heldTurn.events
        } onChange: {
            updateInvalidations.increment()
        }
        #expect(model.acceptActivity(first.updating(
            lifecycle: .succeeded,
            summary: "Updated",
            detail: nil,
            occurredAt: 3
        )) == .updated)
        #expect(updateInvalidations.value == 1)
        #expect(heldTurn.events.first?.summary == "Updated")
    }

    @Test func draftTypingAndStreamingRevisionsCoalesceUntilCheckpointOrTerminalFlush() async {
        let client = ControlledStreamingConversationClient()
        var persisted: [(String, [TimelineItem])] = []
        let model = ChatModel(
            conversationID: "coalesced-persistence",
            client: client,
            initialItems: [],
            persistenceCheckpointDelay: .milliseconds(20),
            onSessionChange: { draft, items, _, _ in persisted.append((draft, items)) }
        )

        model.draft = "H"
        model.draft = "He"
        model.draft = "Hello"
        #expect(persisted.isEmpty)

        try? await Task.sleep(for: .milliseconds(40))
        #expect(persisted.count == 1)
        #expect(persisted.last?.0 == "Hello")

        let send = Task { await model.send() }
        await client.waitUntilStarted()
        client.yieldDraft(id: "stream", text: "A")
        client.yieldDraft(id: "stream", text: "AB")
        client.yieldDraft(id: "stream", text: "ABC")
        #expect(persisted.count == 1)

        client.finish(id: "stream", text: "Final")
        await send.value
        #expect(persisted.count == 2)
        #expect(persisted.last?.1.last?.content == .message("Final"))
    }

    @Test func backgroundAndNavigationFlushDirtySessionStateImmediately() {
        var persisted: [(String, [TimelineItem])] = []
        let model = ChatModel(
            conversationID: "lifecycle-flush",
            client: ConversationFixtureClient(),
            initialItems: [],
            persistenceCheckpointDelay: .seconds(60),
            onSessionChange: { draft, items, _, _ in persisted.append((draft, items)) }
        )
        model.draft = "Recoverable draft"

        model.flushPersistence()
        #expect(persisted.map(\.0) == ["Recoverable draft"])

        model.draft = "Navigation draft"
        model.flushPersistence()
        #expect(persisted.map(\.0) == ["Recoverable draft", "Navigation draft"])
    }

    @Test func activityAndVisibilityChangesInvalidateFromTheAffectedCanonicalGroup() {
        let sessionID = "projection-invalidation"
        let items = (1...100).map { (index: Int) in
            TimelineItem(
                id: "message-\(index)",
                role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                content: .message("Message \(index)"),
                metadata: .init(delivery: "Delivered", sourceOrder: index * 10)
            )
        }
        let event = ChatActivityEvent(
            eventID: "middle-tool",
            sessionID: sessionID,
            turnID: "turn-middle",
            kind: .tool,
            lifecycle: .running,
            title: "Middle tool",
            summary: nil,
            detail: nil,
            occurredAt: 505,
            toolCallID: "middle-call",
            sourceOrder: 505
        )
        let model = ChatModel(
            conversationID: sessionID,
            client: ConversationFixtureClient(),
            initialItems: items,
            initialActivityEvents: [event]
        )
        let initialIDs = model.transcriptEntries.map(\.id)
        let initialWork = model.transcriptProjectionWorkCount

        _ = model.acceptActivity(event.updating(
            lifecycle: .succeeded,
            summary: "Complete",
            detail: nil,
            occurredAt: 2_000
        ))

        #expect(model.transcriptEntries.map(\.id) == initialIDs)
        #expect(model.transcriptProjectionWorkCount - initialWork < 60)

        model.setToolCallsVisible(false)
        #expect(!model.transcriptEntries.contains { $0.id == "activity:turn-middle:middle-tool" })
    }

    @Test func transcriptPreservesHermesArrivalOrderAcrossInterimActivityAndFinalRows() async {
        let client = ControlledStreamingConversationClient()
        let model = ChatModel(
            conversationID: "session_fixture_0001",
            client: client,
            initialItems: []
        )
        model.draft = "Check the forecast"

        let send = Task { await model.send() }
        await client.waitUntilStarted()
        client.yieldDraft(id: "message_streaming_draft_0001", text: "I’ll check that now.")
        _ = model.acceptActivity(ChatActivityEvent(
            eventID: "reasoning_event_order_0001",
            sessionID: model.conversationID,
            turnID: "turn_order_0001",
            kind: .reasoning,
            lifecycle: .running,
            title: "Thinking",
            summary: "Planning the lookup",
            detail: nil,
            occurredAt: 100
        ))
        _ = model.acceptActivity(ChatActivityEvent(
            eventID: "tool_event_order_0001",
            sessionID: model.conversationID,
            turnID: "turn_order_0001",
            kind: .tool,
            lifecycle: .running,
            title: "Checking weather",
            summary: "Fetching current conditions",
            detail: nil,
            occurredAt: 101,
            toolCallID: "call_weather_order_0001"
        ))
        client.yieldDraft(id: "message_streaming_final_0001", text: "Tomorrow will be sunny.")
        client.finish(id: "message_streaming_final_0001", text: "Tomorrow will be sunny and hot.")
        await send.value

        let rows = model.transcriptEntries.map { entry -> String in
            switch entry {
            case .message(let item):
                return "message:\(item.id)"
            case .activity(let turn):
                return "activity:\(turn.events.map(\.eventID).joined(separator: ","))"
            }
        }
        #expect(rows == [
            "message:session_fixture_0001-human-1",
            "message:message_streaming_draft_0001",
            "activity:tool_event_order_0001",
            "message:message_streaming_final_0001",
        ])
    }

    @Test @MainActor func timelineScrollOwnershipRejectsStaleWorkAcrossConversationChanges() {
        var ownership = ChatTimelineTaskOwnership()
        let firstA = ownership.claim(conversationID: "conversation-a")
        #expect(ownership.owns(firstA, conversationID: "conversation-a"))

        ownership.invalidate()
        let conversationB = ownership.claim(conversationID: "conversation-b")
        #expect(!ownership.owns(firstA, conversationID: "conversation-a"))
        #expect(ownership.owns(conversationB, conversationID: "conversation-b"))

        let secondA = ownership.claim(conversationID: "conversation-a")
        #expect(!ownership.owns(firstA, conversationID: "conversation-a"))
        #expect(!ownership.owns(conversationB, conversationID: "conversation-b"))
        #expect(ownership.owns(secondA, conversationID: "conversation-a"))
    }

    @Test @MainActor func delayedTimelineSettlementStopsAfterConversationInvalidation() async {
        let ownership = ChatTimelineTaskOwnership()
        let token = ownership.claim(conversationID: "conversation-a")
        let delayedCheck = Task { @MainActor in
            await ownership.remainsOwned(
                token,
                conversationID: "conversation-a",
                after: .milliseconds(50)
            )
        }

        await Task.yield()
        ownership.invalidate()

        #expect(await delayedCheck.value == false)
    }

    @Test func timelineScrollObservationCostDoesNotGrowWithSettledHistory() async {
        func samples(count: Int) async -> [Double] {
            let settled = (0..<count).map { index in
                TimelineItem(id: "scroll-\(index)", role: .assistant,
                    sender: .agent(id: "default", snapshot: .init(name: "Juno")),
                    content: .message(String(repeating: "Settled history ", count: 20)),
                    metadata: .init(delivery: "Delivered", sourceOrder: index))
            }
            let client = ControlledStreamingConversationClient()
            let model = ChatModel(conversationID: "scroll-cost-\(count)", client: client,
                                  initialItems: settled)
            func key() -> ChatTimelineScrollKey {
                model.timelineScrollKey()
            }
            model.draft = "Continue"
            let send = Task { await model.send() }
            await client.waitUntilStarted()
            client.yieldDraft(id: "scroll-tail", text: "First")
            let before = key()
            client.yieldDraft(id: "scroll-tail", text: "Second")
            var values: [Double] = []
            var differences = 0
            for sample in 0..<6 {
                let start = ContinuousClock.now
                for _ in 0..<200 { if before != key() { differences += 1 } }
                let elapsed = start.duration(to: .now).components
                if sample > 0 {
                    values.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                }
            }
            #expect(differences == 1_200)
            client.finish(id: "scroll-tail", text: "Done")
            await send.value
            print("SCROLL_OBSERVATION count=\(count) milliseconds=\(values)")
            return values.sorted()
        }
        let short = await samples(count: 100)
        let long = await samples(count: 1_000)
        #expect(long[2] <= short[2] * 4)
    }

    @Test func timelineScrollKeyChangesWhenSameIDStreamingContentChanges() async {
        let client = ControlledStreamingConversationClient()
        let model = ChatModel(conversationID: "scroll-invalidation", client: client, initialItems: [])
        model.draft = "Start"
        let send = Task { await model.send() }
        await client.waitUntilStarted()
        client.yieldDraft(id: "same-id", text: "First")
        let initial = model.timelineScrollKey()
        client.yieldDraft(id: "same-id", text: "Second")
        #expect(initial != model.timelineScrollKey())
        #expect(model.transcriptEntries.last?.messageText == "Second")
        let updated = model.timelineScrollKey()
        model.draft = "Unsent draft"
        #expect(updated == model.timelineScrollKey())
        client.finish(id: "same-id", text: "Final")
        await send.value
        #expect(updated != model.timelineScrollKey())
    }

    @Test func timelineScrollKeyChangesWhenActivityEventUpdatesInPlace() {
        let model = ChatModel(conversationID: "scroll-activity", client: ConversationFixtureClient(),
                              initialItems: [])
        let running = ChatActivityEvent(eventID: "tool", sessionID: model.conversationID,
            turnID: "turn", kind: .tool, lifecycle: .running, title: "Checking",
            summary: nil, detail: nil, occurredAt: 1)
        _ = model.acceptActivity(running)
        let initial = model.timelineScrollKey()
        _ = model.acceptActivity(running.updating(lifecycle: .succeeded, summary: "Done",
                                                detail: nil, occurredAt: 2))
        #expect(initial != model.timelineScrollKey())
        let updated = model.timelineScrollKey()
        model.setTranscriptPresentationDeferred(true)
        _ = model.acceptActivity(running.updating(lifecycle: .succeeded, summary: "Late detail",
                                                detail: "Received", occurredAt: 3))
        #expect(updated == model.timelineScrollKey())
        model.setTranscriptPresentationDeferred(false)
        #expect(updated != model.timelineScrollKey())
        #expect(model.timelineScrollKey() != model.timelineScrollKey(clarificationIDs: ["question"]))
    }

    @Test func chatClarificationProjectionKeepsOnlyTypedRequestsForTheOpenSession() {
        let currentRequest = DashboardClarificationRequest(
            eventID: "clarify-current",
            requestID: "request-current",
            sessionID: "session-current",
            question: "Which release channel?",
            choices: ["TestFlight", "App Store"],
            allowsCustomResponse: true,
            isMultiSelect: false,
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )
        let otherRequest = DashboardClarificationRequest(
            eventID: "clarify-other",
            requestID: "request-other",
            sessionID: "session-other",
            question: "Which branch?",
            choices: ["main"],
            allowsCustomResponse: true,
            isMultiSelect: false,
            expiresAt: nil
        )
        let snapshot = DashboardSnapshot(
            inbox: [],
            attentionItems: [
                DashboardAttentionItem(
                    id: currentRequest.eventID,
                    title: "Clarification needed",
                    detail: currentRequest.question,
                    urgency: .important,
                    sessionID: currentRequest.sessionID,
                    interaction: .clarification(currentRequest)
                ),
                DashboardAttentionItem(
                    id: otherRequest.eventID,
                    title: "Clarification needed",
                    detail: otherRequest.question,
                    urgency: .important,
                    sessionID: otherRequest.sessionID,
                    interaction: .clarification(otherRequest)
                ),
                DashboardAttentionItem(
                    id: "generic-current",
                    title: "Needs review",
                    detail: "Not a Clarify request",
                    urgency: .needsReview,
                    sessionID: currentRequest.sessionID
                ),
            ],
            completedItems: [],
            agents: []
        )

        let projected = ChatClarificationProjection.items(
            for: currentRequest.sessionID,
            in: snapshot
        )

        #expect(projected.map(\.id) == [currentRequest.eventID])
    }

    @Test func clarificationComposerUsesSymmetricControlsToCenterItsPlaceholder() {
        #expect(
            ClarificationComposerLayout.leadingBalanceWidth(
                trailingControlWidth: BighelpTokens.hitTarget
            ) == BighelpTokens.hitTarget
        )
        #expect(ClarificationComposerLayout.inputMinimumHeight == BighelpTokens.hitTarget)
    }

    @Test func timelineFollowStatePausesNewContentWhileReaderIsReviewingOlderMessages() {
        var state = ChatTimelineFollowState()

        #expect(state.shouldFollowNewContent)

        state.updateDistanceFromBottom(180)

        #expect(!state.shouldFollowNewContent)
        #expect(!state.shouldScrollForNewContent)
    }

    @Test func timelineFollowStateResumesAfterReaderReturnsNearTheLatestMessage() {
        var state = ChatTimelineFollowState()
        state.updateDistanceFromBottom(180)

        state.updateDistanceFromBottom(48)

        #expect(state.shouldFollowNewContent)
        #expect(state.shouldScrollForNewContent)
    }

    @Test func idleOverscrollRequiresCorrectionRatherThanBeingTreatedAsTheTail() {
        #expect(ChatTimelineBottomPinning.requiresCorrection(
            signedDistanceFromBottom: -900, shouldFollowNewContent: true, isUserInitiated: false))
        #expect(!ChatTimelineBottomPinning.requiresCorrection(
            signedDistanceFromBottom: -900, shouldFollowNewContent: true, isUserInitiated: true))
    }

    @Test func failedReturnCannotClaimAnOffscreenAnchorIsVisible() {
        var state = ChatReturnToLatestState()
        state.update(isBottomAnchorVisible: false)
        state.beginReturn()
        state.completeReturn()
        #expect(state.isVisible)
        #expect(!state.lastKnownBottomAnchorVisible)
    }

    @Test func returnToLatestVisibilityMatchesBottomAnchorVisibility() {
        var state = ChatReturnToLatestState()

        state.update(isBottomAnchorVisible: true)
        #expect(!state.isVisible)

        state.update(isBottomAnchorVisible: false)
        #expect(state.isVisible)
    }

    @Test func latestMessageSitsJustAboveTheComposer() {
        #expect(ChatBottomAnchorVisibility.contentBottomPadding == 20)
        #expect(ChatCanvasLayout.composerInsetSpacing == BighelpTokens.space4)
    }

    @Test func automaticTailSettlementDoesNotAnimateMutatingLazyContent() {
        #expect(!ChatTimelineScrollAnimationPolicy.shouldAnimate(
            reason: .automaticContentMutation,
            reduceMotion: false
        ))
        #expect(!ChatTimelineScrollAnimationPolicy.shouldAnimate(
            reason: .initialPosition,
            reduceMotion: false
        ))
        #expect(ChatTimelineScrollAnimationPolicy.shouldAnimate(
            reason: .returnToLatest,
            reduceMotion: false
        ))
        #expect(!ChatTimelineScrollAnimationPolicy.shouldAnimate(
            reason: .returnToLatest,
            reduceMotion: true
        ))
    }

    @Test func bottomAnchorBecomingVisibleClearsReturnToLatest() {
        var state = ChatReturnToLatestState()

        state.update(isBottomAnchorVisible: false)
        #expect(state.isVisible)

        state.update(isBottomAnchorVisible: true)

        #expect(!state.isVisible)
    }

    @Test func returnToLatestResetClearsVisibilityUntilGeometryRefreshes() {
        var state = ChatReturnToLatestState()
        state.update(isBottomAnchorVisible: false)
        #expect(state.isVisible)

        state.reset()

        #expect(!state.isVisible)
        #expect(!state.isReturning)
    }

    @Test func tappingReturnToLatestWaitsForTheObservedAnchor() {
        var state = ChatReturnToLatestState()
        state.update(isBottomAnchorVisible: false)
        #expect(state.isVisible)

        state.beginReturn()

        #expect(state.isVisible)
        #expect(state.isReturning)

        // A requested scroll is not proof that the tail reached the viewport.
        state.update(isBottomAnchorVisible: false)
        #expect(state.isVisible)
        #expect(state.isReturning)

        state.update(isBottomAnchorVisible: true)
        #expect(!state.isVisible)
        #expect(!state.isReturning)
    }

    @Test func aReaderCancellingAReturnRestoresTheControlFromTheLastObservation() {
        var state = ChatReturnToLatestState()
        state.update(isBottomAnchorVisible: false)
        state.beginReturn()
        state.update(isBottomAnchorVisible: false)

        state.cancelReturn()

        #expect(state.isVisible)
        #expect(!state.isReturning)
    }

    @Test func completingAReturnPreservesTheLastObservedAnchor() {
        var state = ChatReturnToLatestState()
        state.update(isBottomAnchorVisible: false)
        state.beginReturn()
        state.completeReturn()

        #expect(state.isVisible)
        #expect(!state.isReturning)

        // Only a real observation of the anchor clears the control.
        state.update(isBottomAnchorVisible: true)
        #expect(!state.isVisible)
    }

    @Test func settlingWithoutAReturnInFlightDoesNotChangeVisibility() {
        var state = ChatReturnToLatestState()
        state.update(isBottomAnchorVisible: false)

        state.cancelReturn()
        state.completeReturn()

        #expect(state.isVisible)
    }

    @Test func scrollGeometryUsesTheAnchorIntersectionInsteadOfFollowProximity() {
        #expect(ChatBottomAnchorVisibility.isVisible(signedDistanceFromBottom: 0, viewportHeight: 800))
        #expect(ChatBottomAnchorVisibility.isVisible(signedDistanceFromBottom: -40, viewportHeight: 800))
        #expect(!ChatBottomAnchorVisibility.isVisible(signedDistanceFromBottom: 1, viewportHeight: 800))
        #expect(!ChatBottomAnchorVisibility.isVisible(signedDistanceFromBottom: 72, viewportHeight: 800))
        #expect(!ChatBottomAnchorVisibility.isVisible(signedDistanceFromBottom: -900, viewportHeight: 800))
        #expect(!ChatBottomAnchorVisibility.isVisible(signedDistanceFromBottom: .nan, viewportHeight: 800))
        #expect(!ChatBottomAnchorVisibility.isVisible(signedDistanceFromBottom: .infinity, viewportHeight: 800))
        #expect(!ChatBottomAnchorVisibility.isVisible(signedDistanceFromBottom: 0, viewportHeight: 0))
    }

    @Test func bottomAnchorFallbackMatchesTheNativeHalfVisibleThreshold() {
        #expect(ChatBottomAnchorVisibility.isVisible(
            anchorBottomY: 0.51,
            viewportHeight: 800
        ))
        #expect(ChatBottomAnchorVisibility.isVisible(
            anchorBottomY: 800.49,
            viewportHeight: 800
        ))
        #expect(!ChatBottomAnchorVisibility.isVisible(
            anchorBottomY: 0.49,
            viewportHeight: 800
        ))
        #expect(!ChatBottomAnchorVisibility.isVisible(
            anchorBottomY: 800.51,
            viewportHeight: 800
        ))
    }

    @Test func bottomAnchorFallbackRejectsInvalidGeometry() {
        #expect(!ChatBottomAnchorVisibility.isVisible(
            anchorBottomY: .nan,
            viewportHeight: 800
        ))
        #expect(!ChatBottomAnchorVisibility.isVisible(
            anchorBottomY: 400,
            viewportHeight: .infinity
        ))
        #expect(!ChatBottomAnchorVisibility.isVisible(
            anchorBottomY: 400,
            viewportHeight: 0
        ))
    }

    @Test func completedTimelineDragMarksExactlyTheNextGeometryDeliveryAsUserInitiated() {
        var intent = ChatTimelineUserIntent()

        intent.beginDrag()
        #expect(intent.isGeometryUserInitiated)

        intent.endDrag()
        #expect(intent.isGeometryUserInitiated)

        let didConsumeCompletedDrag = intent.consumeCompletedDrag()
        #expect(didConsumeCompletedDrag)
        #expect(!intent.isGeometryUserInitiated)
        let didConsumeAgain = intent.consumeCompletedDrag()
        #expect(!didConsumeAgain)
    }

    @Test(arguments: [0.4, 1.4]) @MainActor
    func visibleCanvasRepairsAnIdleOffsetBeyondItsContent(overscrollFraction: Double) async throws {
        let model = ChatModel(conversationID: "canvas-overscroll-proof", client: ConversationFixtureClient())
        model.acceptExternal((0..<24).map { index in
            TimelineItem(id: "history-\(index)", role: .assistant,
                         sender: .agent(id: "default", snapshot: .init(name: "Avery")),
                         content: .message("History \(index). A readable paragraph in the chat canvas."),
                         metadata: .init(delivery: "Delivered"))
        })
        let controller = UIHostingController(rootView: ChatView(model: model))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        controller.view.frame = window.bounds
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        try await Task.sleep(for: .milliseconds(900))
        controller.view.layoutIfNeeded()
        let scroll = try #require(scrollViews(controller.view).max(by: { $0.bounds.height < $1.bounds.height }))
        // Exercise both a tail stranded inside the viewport and one entirely
        // above it. Neither is a user drag or rubber-band gesture.
        let maximum = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
        scroll.setContentOffset(CGPoint(x: 0, y: maximum + scroll.bounds.height * overscrollFraction), animated: false)
        try await Task.sleep(for: .milliseconds(650))
        controller.view.layoutIfNeeded()
        let distance = scroll.contentSize.height + scroll.adjustedContentInset.bottom
            - scroll.bounds.height - scroll.contentOffset.y
        #expect(abs(distance) <= 1, "An idle offset beyond the transcript must settle back to its visible bottom.")
    }

    @Test @MainActor func tallActivityUpdatesAndSegmentMigrationDoNotOverscrollHandsOff() async throws {
        let client = ControlledStreamingConversationClient()
        let model = ChatModel(conversationID: "tall-activity-replay", client: client)
        model.acceptExternal((0..<24).map { index in
            TimelineItem(id: "history-\(index)", role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Avery")),
                content: .message(String(repeating: "History \(index). A readable mixed-height paragraph.\n", count: 1 + index % 5)),
                metadata: .init(delivery: "Delivered"))
        })
        model.draft = "Investigate the interface behavior."
        let send = Task { await model.send() }
        await client.waitUntilStarted()
        defer {
            client.finish(id: "segment-b", text: "Replay complete.")
            send.cancel()
        }
        client.yieldDraft(id: "segment-a", text: String(repeating: "Inspecting **the real interface** with stable row identities.\n", count: 12))
        for index in 0..<5 {
            _ = model.acceptActivity(ChatActivityEvent(eventID: "tool-\(index)", sessionID: model.conversationID,
                turnID: "replay-turn", kind: .tool, lifecycle: .running,
                title: "Tool \(index)", summary: "Inspecting source", detail: nil,
                occurredAt: index + 1, toolCallID: "call-\(index)", toolName: "read_file",
                arguments: "{\"context\":\"" + String(repeating: "Synthetic source context. ", count: 150) + "\"}"))
        }
        let child = ChatActivityEvent(eventID: "child-0", sessionID: model.conversationID,
            turnID: "replay-turn", kind: .subagent, lifecycle: .running,
            title: "Research", summary: String(repeating: "A long delegated task describing concrete observations and remaining uncertainty.\n", count: 28),
            detail: nil, occurredAt: 6)
        _ = model.acceptActivity(child)
        _ = model.acceptActivity(ChatActivityEvent(eventID: "child-1", sessionID: model.conversationID,
            turnID: "replay-turn", kind: .subagent, lifecycle: .running,
            title: "Investigation", summary: child.summary, detail: nil, occurredAt: 7))
        for entry in model.transcriptEntries {
            if case .activity(let group) = entry {
                model.activityDisclosures.setExpanded(true, for: group)
            }
        }
        let controller = UIHostingController(rootView: ChatView(model: model)
            .environment(\.bighelpUIV3Enabled, true))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        controller.view.frame = window.bounds
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        try await Task.sleep(for: .milliseconds(1000))
        let scroll = try #require(scrollViews(controller.view).max(by: { $0.bounds.height < $1.bounds.height }))
        func distance() -> CGFloat {
            scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height - scroll.contentOffset.y
        }
        #expect(abs(distance()) <= 1, "The replay must begin at the valid tail without injecting an offset.")
        for stage in ["same-event-update", "segment-migration", "same-message-growth"] {
            let count = model.transcriptEntries.count
            switch stage {
            case "same-event-update":
                _ = model.acceptActivity(child.updating(lifecycle: .succeeded,
                    summary: String(repeating: "Verified a smaller completed summary.\n", count: 14), detail: nil, occurredAt: 8))
                #expect(model.transcriptEntries.count == count)
            case "segment-migration":
                client.yieldDraft(id: "segment-b", text: "A new assistant segment begins.")
            default:
                client.yieldDraft(id: "segment-b", text: String(repeating: "The same segment grows with **formatted details**.\n", count: 18))
            }
            var samples: [CGFloat] = []
            for _ in 0..<60 {
                try await Task.sleep(for: .milliseconds(16))
                samples.append(distance())
            }
            let minimum = try #require(samples.min())
            #expect(minimum >= -1, "Hands-off \(stage) must not place the tail above its valid bottom even transiently.")
            #expect((samples.max() ?? 0) <= 1, "Hands-off \(stage) must keep the visible tail pinned during layout, not jump to it afterward.")
            #expect(abs(distance()) <= 1, "Hands-off \(stage) must settle at the tail.")
        }
        client.finish(id: "segment-b", text: "Replay complete.")
        await send.value
    }

    @Test @MainActor func visibleCanvasFollowsSameRowGrowthAndIdleIncomingMessages() async throws {
        let model = ChatModel(conversationID: "canvas-growth-proof", client: ConversationFixtureClient())
        func message(_ id: String, _ text: String) -> TimelineItem {
            TimelineItem(id: id, role: .assistant, sender: .agent(id: "default", snapshot: .init(name: "Avery")), content: .message(text), metadata: .init(delivery: "Delivered"))
        }
        model.acceptExternal((0..<24).map { message("history-\($0)", "History \($0). A readable paragraph in the chat canvas.") })
        model.acceptExternal([message("growing-tail", "The reply begins.")])
        let controller = UIHostingController(rootView: ChatView(model: model))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        controller.view.frame = window.bounds
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        try await Task.sleep(for: .milliseconds(650))
        controller.view.layoutIfNeeded()
        let scroll = try #require(scrollViews(controller.view).max(by: { $0.bounds.height < $1.bounds.height }))
        func distance() -> CGFloat {
            scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height - scroll.contentOffset.y
        }
        #expect(abs(distance()) < 120)
        for index in 1...4 {
            let text = Array(repeating: "Streaming paragraph grows in place without moving the reader away from the live bottom.", count: index * 8).joined(separator: "\n\n")
            model.acceptExternal([message("growing-tail", text)])
            try await Task.sleep(for: .milliseconds(350))
            controller.view.layoutIfNeeded()
            #expect(abs(distance()) < 120, "In-place growth must remain anchored after layout settles.")
        }
        model.acceptExternal([message("idle-incoming", "A new message arrives while no local turn is active.")])
        try await Task.sleep(for: .milliseconds(400))
        controller.view.layoutIfNeeded()
        #expect(abs(distance()) < 120, "Idle incoming content must still follow the bottom.")
    }

    @Test func catchUpKeepsAllToolDetailsAndTheirGroupAfterReopen() {
        var savedItems: [TimelineItem] = []
        var savedEvents: [ChatActivityEvent] = []
        let model = ChatModel(conversationID: "tool-catchup", client: ConversationFixtureClient(), initialItems: [],
            onSessionChange: { _, items, ledger, _ in savedItems = items; savedEvents = ledger.allEvents })
        model.setTranscriptPresentationDeferred(true)
        for index in 0..<75 {
            _ = model.acceptActivity(ChatActivityEvent(eventID: "tool-\(index)", sessionID: "tool-catchup", turnID: "one-turn",
                kind: .tool, lifecycle: .succeeded, title: "Tool \(index)", summary: "Done",
                detail: "Retained output \(index)", occurredAt: index + 1, toolCallID: "call-\(index)", toolName: "terminal"))
        }
        #expect(model.transcriptEntries.isEmpty)
        #expect(model.activityLedger.allEvents.count == 75)
        #expect(savedEvents.isEmpty)
        // A background/lifecycle checkpoint saves the complete batch while
        // presentation remains deferred; individual tools must not flush it.
        model.flushPersistence()
        #expect(savedEvents.count == 75)
        model.setTranscriptPresentationDeferred(false)
        let reopened = ChatModel(conversationID: "tool-catchup", client: ConversationFixtureClient(),
            initialItems: savedItems, initialActivityEvents: savedEvents)
        #expect(model.transcriptEntries.count == 1)
        #expect(reopened.transcriptEntries.count == 1)
        #expect(reopened.activityLedger.allEvents.map(\.detail) == savedEvents.map(\.detail))
    }

    @Test func backgroundCatchUpPersistsEveryEventButPublishesTheTranscriptTogether() {
        var persistedItems: [TimelineItem] = []
        let model = ChatModel(conversationID: "catch-up", client: ConversationFixtureClient(),
                              onSessionChange: { _, items, _, _ in persistedItems = items })
        let initialEntries = model.transcriptEntries.count
        model.setTranscriptPresentationDeferred(true)
        model.setTranscriptPresentationDeferred(true)
        for index in 0..<75 {
            model.acceptExternal([TimelineItem(id: "catch-up-\(index)", role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Avery")),
                content: .message("Historical content \(index)"), metadata: .init(delivery: "Delivered"))])
        }
        #expect(model.transcriptEntries.count == initialEntries)
        #expect(model.items.filter { $0.id.hasPrefix("catch-up-") }.count == 75)
        #expect(persistedItems.filter { $0.id.hasPrefix("catch-up-") }.isEmpty)
        model.flushPersistence()
        #expect(persistedItems.filter { $0.id.hasPrefix("catch-up-") }.count == 75)
        model.setTranscriptPresentationDeferred(false)
        #expect(model.transcriptEntries.count == initialEntries + 75)
        model.setTranscriptPresentationDeferred(false)
        #expect(model.transcriptEntries.count == initialEntries + 75)
    }

    @Test func nonUserGeometryCannotStealDeliberateReadingPosition() {
        var state = ChatTimelineFollowState()
        state.updateDistanceFromBottom(420, isUserInitiated: true)
        #expect(!state.shouldFollowNewContent)
        // Grouping tools or late layout may temporarily put the tail near the
        // reader. Only deliberate user movement may resume following.
        state.updateDistanceFromBottom(0, isUserInitiated: false)
        #expect(!state.shouldFollowNewContent)
        #expect(!state.shouldScrollForNewContent)
    }

    @Test func timelineLayoutGrowthCannotReleaseBottomFollowWithoutAUserScroll() {
        var state = ChatTimelineFollowState()

        state.updateDistanceFromBottom(420, isUserInitiated: false)

        #expect(state.shouldFollowNewContent)
        #expect(state.shouldScrollForNewContent)

        state.updateDistanceFromBottom(420, isUserInitiated: true)

        #expect(!state.shouldFollowNewContent)
    }

    @Test func directReadingInteractionPausesTailFollowingBeforeGeometryCatchesUp() {
        var state = ChatTimelineFollowState()

        state.beginUserReview()

        #expect(!state.shouldFollowNewContent)
        #expect(!state.shouldScrollForNewContent)
    }

    @Test func expandingWorkDetailsKeepsTheCurrentReadingAnchor() {
        var state = ChatTimelineFollowState()

        state.beginDisclosureReview()

        #expect(!state.shouldFollowNewContent)
        #expect(!state.shouldScrollForNewContent)
    }

    @Test func changingConversationsRestoresBottomFollowForTheNewCanvas() {
        var state = ChatTimelineFollowState()
        state.updateDistanceFromBottom(420, isUserInitiated: true)
        #expect(!state.shouldFollowNewContent)

        state.resetForConversationChange()

        #expect(state.shouldFollowNewContent)
        #expect(state.shouldScrollForNewContent)
    }

    @Test func returnToLatestResumesBottomFollowAfterTheReaderScrolledAway() {
        var state = ChatTimelineFollowState()
        state.updateDistanceFromBottom(420, isUserInitiated: true)
        #expect(!state.shouldScrollForNewContent)

        state.resumeFollowingLatest()

        #expect(state.shouldFollowNewContent)
        #expect(state.shouldScrollForNewContent)
    }

    @Test func workTrailShimmersOnlyWhileAToolCallIsRunning() {
        let runningTool = ChatActivityEvent(
            eventID: "running-tool",
            sessionID: "session",
            turnID: "turn",
            kind: .tool,
            lifecycle: .running,
            title: "Command: terminal",
            summary: nil,
            detail: nil,
            occurredAt: 1
        )
        let completedTool = ChatActivityEvent(
            eventID: "completed-tool",
            sessionID: "session",
            turnID: "turn",
            kind: .tool,
            lifecycle: .succeeded,
            title: "Command: terminal",
            summary: nil,
            detail: nil,
            occurredAt: 2
        )
        let runningReasoning = ChatActivityEvent(
            eventID: "running-reasoning",
            sessionID: "session",
            turnID: "turn",
            kind: .reasoning,
            lifecycle: .running,
            title: "Reasoning",
            summary: nil,
            detail: nil,
            occurredAt: 3
        )

        #expect(ChatActivityPresentation.trailPhase(for: [runningTool]).isLive)
        #expect(!ChatActivityPresentation.trailPhase(for: [completedTool]).isLive)
        // A finished folder says what it did (an unnamed tool here), never a bare "Done".
        #expect(ChatActivityPresentation.trailPhase(for: [completedTool]) == .finished("Called a tool"))
        #expect(ChatActivityPresentation.stepCount(of: [runningReasoning]) == 0)
    }

    @Test func toolStepsAreNeutralExceptForFailuresAndSpinOnlyWhileRunning() {
        func step(_ lifecycle: ChatActivityLifecycle) -> BighelpActivityStep {
            ChatActivityPresentation.step(for: ChatActivityEvent(
                eventID: "tool-\(lifecycle.rawValue)", sessionID: "session", turnID: "turn", kind: .tool,
                lifecycle: lifecycle, title: "read_file", summary: nil, detail: nil, occurredAt: 1,
                toolCallID: "call-\(lifecycle.rawValue)", toolName: "read_file"))
        }
        #expect(step(.running).isRunning)
        #expect(step(.running).label == "Reading a file…")
        #expect(!step(.succeeded).isRunning)
        #expect(step(.succeeded).label == "Read a file")
        #expect(!step(.succeeded).metaIsFailure)
        #expect(step(.failed).metaIsFailure)
        #expect(step(.failed).meta == "Failed")
        #expect(!step(.cancelled).metaIsFailure)
        #expect(step(.cancelled).meta == "Stopped")
    }

    @Test func reasoningOnlyWorkUsesQuietAccurateLifecycleLabels() {
        func summary(_ lifecycle: ChatActivityLifecycle) -> String {
            BighelpActivitySummary.label(for: ChatActivityPresentation.thinkingPhase(for: [ChatActivityEvent(
                eventID: "reasoning-\(lifecycle.rawValue)",
                sessionID: "session",
                turnID: "turn",
                kind: .reasoning,
                lifecycle: lifecycle,
                title: "Reasoning",
                summary: "Real bounded status",
                detail: nil,
                occurredAt: 1
            )]))
        }

        #expect(summary(.running) == "Thinking")
        #expect(summary(.succeeded) == "Thought process")
        #expect(summary(.failed) == "Hit a snag")
        #expect(summary(.cancelled) == "Stopped")
    }

    @Test func sendAppendsExactlyOneHumanAndOneAssistantItemInOrder() async {
        let model = ChatModel(conversationID: "demo-finance", client: ConversationFixtureClient())
        let originalIDs = model.items.map(\.id)
        model.draft = "Give me an update"

        await model.send()

        #expect(Array(model.items.prefix(originalIDs.count)).map(\.id) == originalIDs)
        #expect(model.items.suffix(2).map(\.role) == [.human, .assistant])
        #expect(model.items.suffix(2).map(\.sender.id) == [UserIdentity.stableID, "default"])
    }

    @Test func emptyDraftDoesNotMutateTimeline() async {
        let model = ChatModel(conversationID: "demo", client: ConversationFixtureClient())
        let before = model.items
        model.draft = "   "

        await model.send()

        #expect(model.items == before)
    }

    @Test func weatherQuickActionAttachesCardAfterItsIntent() async {
        let model = ChatModel(conversationID: "demo", client: ConversationFixtureClient())

        await model.perform(.weatherAndTasks)

        #expect(model.items.suffix(2).map(\.content.kind) == [.message, .weatherAndTasks])
    }

    @Test func concurrentSecondSendIsIgnored() async {
        let sleeper = ControlledDemoSleeper()
        let model = ChatModel(
            conversationID: "demo",
            client: ConversationFixtureClient(),
            sleeper: sleeper
        )
        let initialCount = model.items.count
        model.draft = "First request"

        let firstSend = Task { await model.send() }
        await sleeper.waitUntilSleepStarts()
        #expect(model.isSending)
        #expect(model.items.count == initialCount + 1)

        model.draft = "Second request"
        await model.send()

        #expect(model.items.count == initialCount + 1)
        #expect(model.draft == "Second request")

        sleeper.resume()
        await firstSend.value

        #expect(model.items.count == initialCount + 2)
        #expect(model.items.suffix(2).map(\.role) == [.human, .assistant])
    }

    @Test func repeatedSendsAndQuickActionsKeepEveryTimelineIdentityUnique() async {
        let model = ChatModel(conversationID: "demo", client: ConversationFixtureClient())

        model.draft = "First request"
        await model.send()
        model.draft = "Second request"
        await model.send()
        await model.perform(.weatherAndTasks)
        await model.perform(.weatherAndTasks)

        let ids = model.items.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func externalVoiceBatchDeduplicatesAgainstHistoryAndWithinTheBatch() {
        let existing = TimelineItem(
            id: "existing",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
            content: .message("Existing"),
            metadata: TimelineMetadata(delivery: "Delivered")
        )
        let fresh = TimelineItem(
            id: "fresh",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
            content: .message("Fresh"),
            metadata: TimelineMetadata(delivery: "Delivered")
        )
        let model = ChatModel(
            conversationID: "voice-external",
            client: ConversationFixtureClient(),
            initialItems: [existing]
        )

        model.acceptExternal([existing, fresh, fresh])

        #expect(model.items.map(\.id) == ["existing", "fresh"])
    }

    @Test func failedSendOffersOneRetryWithoutRepeatingHumanIntent() async {
        let returnedItem = TimelineItem(
            id: "retry-assistant",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
            content: .message("Recovered fixture response"),
            metadata: TimelineMetadata(source: "Test fixture")
        )
        let client = SequenceConversationClient(
            sendResults: [
                .failure(.unavailable),
                .success(ConversationResponse(items: [returnedItem]))
            ]
        )
        let model = ChatModel(conversationID: "demo", client: client)
        let initialCount = model.items.count
        model.draft = "Please retry this"

        await model.send()

        #expect(model.items.count == initialCount + 1)
        #expect(model.failureMessage == "Message could not be delivered. Try again.")
        #expect(model.canRetry)

        await model.retry()

        #expect(model.items.count == initialCount + 2)
        #expect(model.items.last?.id == returnedItem.id)
        #expect(model.items.last?.content == returnedItem.content)
        #expect(model.failureMessage == nil)
        #expect(!model.canRetry)

        await model.retry()
        #expect(model.items.count == initialCount + 2)
    }

    @Test func restoredHistoryHumanIdentitySeedsTheNextHumanAppend() async {
        let restoredHuman = TimelineItem(
            id: "restored-human-1",
            role: .human,
            sender: .user(snapshot: .init(name: "You")),
            content: .message("Restored request"),
            metadata: TimelineMetadata(delivery: "Restored")
        )
        let model = ChatModel(
            conversationID: "restored",
            client: ConversationFixtureClient(),
            initialItems: [restoredHuman]
        )
        model.draft = "New request"

        await model.send()

        #expect(model.items.first?.id == restoredHuman.id)
        #expect(model.items.first?.content == restoredHuman.content)
        #expect(model.items[1].id == "restored-human-2")
        #expect(Set(model.items.map(\.id)).count == model.items.count)
    }

    @Test func existingResponseIdentityCollisionFailsAtomicallyAndRetriesOnlyOnce() async {
        let existing = TimelineItem(
            id: "existing-item",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
            content: .message("Existing history"),
            metadata: TimelineMetadata(source: "Restored")
        )
        let uniqueReturned = TimelineItem(
            id: "new-returned-item",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
            content: .message("Must not append partially"),
            metadata: TimelineMetadata(source: "Test fixture")
        )
        let collidingReturned = TimelineItem(
            id: existing.id,
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
            content: .message("Conflicting response"),
            metadata: TimelineMetadata(source: "Test fixture")
        )
        let response = ConversationResponse(items: [uniqueReturned, collidingReturned])
        let client = SequenceConversationClient(sendResults: [.success(response), .success(response)])
        let model = ChatModel(
            conversationID: "collision",
            client: client,
            initialItems: [existing]
        )
        model.draft = "Trigger collision"

        await model.send()

        #expect(model.items.count == 2)
        #expect(!model.items.contains(where: { $0.id == uniqueReturned.id }))
        #expect(model.failureMessage == "Response identities conflict with this conversation. Try once more.")
        #expect(model.canRetry)

        await model.retry()

        #expect(model.items.count == 2)
        #expect(model.failureMessage == "Response identities still conflict with this conversation.")
        #expect(!model.canRetry)

        await model.retry()
        #expect(model.items.count == 2)
    }

    @Test func internallyDuplicatedResponseIdentityFailsWithoutPartialAppend() async {
        let first = TimelineItem(
            id: "duplicate-response",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
            content: .message("First duplicate"),
            metadata: TimelineMetadata(source: "Test fixture")
        )
        let second = TimelineItem(
            id: "duplicate-response",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
            content: .message("Second duplicate"),
            metadata: TimelineMetadata(source: "Test fixture")
        )
        let client = SequenceConversationClient(
            sendResults: [.success(ConversationResponse(items: [first, second]))]
        )
        let model = ChatModel(
            conversationID: "internal-collision",
            client: client,
            initialItems: []
        )
        model.draft = "Trigger internal collision"

        await model.send()

        #expect(model.items.count == 1)
        #expect(model.items.first?.role == .human)
        #expect(model.failureMessage == "Response identities conflict with this conversation. Try once more.")
    }

    @Test func concurrentSecondQuickActionIsIgnored() async {
        let sleeper = ControlledDemoSleeper()
        let model = ChatModel(
            conversationID: "action-action",
            client: ConversationFixtureClient(),
            sleeper: sleeper,
            initialItems: []
        )

        let firstAction = Task { await model.perform(.weatherAndTasks) }
        await sleeper.waitUntilSleepStarts()
        await model.perform(.budgetAndPlan)

        #expect(model.items.count == 1)
        #expect(model.items.first?.content == .message(QuickAction.weatherAndTasks.intent))

        sleeper.resume()
        await firstAction.value

        #expect(model.items.map(\.content.kind) == [.message, .weatherAndTasks])
    }

    @Test func activeSendBlocksQuickActionWithoutCrossOperationAppend() async {
        let sleeper = ControlledDemoSleeper()
        let model = ChatModel(
            conversationID: "send-action",
            client: ConversationFixtureClient(),
            sleeper: sleeper,
            initialItems: []
        )
        model.draft = "Active send"

        let send = Task { await model.send() }
        await sleeper.waitUntilSleepStarts()
        await model.perform(.weatherAndTasks)

        #expect(model.items.count == 1)
        #expect(model.items.first?.content == .message("Active send"))

        sleeper.resume()
        await send.value

        #expect(model.items.map(\.content.kind) == [.message, .message])
    }

    @Test func activeQuickActionBlocksSendAndPreservesDraft() async {
        let sleeper = ControlledDemoSleeper()
        let model = ChatModel(
            conversationID: "action-send",
            client: ConversationFixtureClient(),
            sleeper: sleeper,
            initialItems: []
        )

        let action = Task { await model.perform(.weatherAndTasks) }
        await sleeper.waitUntilSleepStarts()
        model.draft = "Blocked send"
        await model.send()

        #expect(model.items.count == 1)
        #expect(model.draft == "Blocked send")

        sleeper.resume()
        await action.value

        #expect(model.items.map(\.content.kind) == [.message, .weatherAndTasks])
    }

    @Test func failedQuickActionRetriesOnceWithoutRepeatingIntent() async {
        let returnedItem = TimelineItem(
            id: "action-retry-result",
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
            content: .budgetSummary(ConversationFixtures.budgetSummary),
            metadata: TimelineMetadata(source: "Test fixture")
        )
        let client = SequenceConversationClient(
            actionResults: [
                .failure(.unavailable),
                .success(ConversationResponse(items: [returnedItem]))
            ]
        )
        let model = ChatModel(
            conversationID: "action-retry",
            client: client,
            initialItems: []
        )

        await model.perform(.budgetAndPlan)

        #expect(model.items.map(\.id) == ["action-retry-human-1"])
        #expect(model.items.map(\.content) == [.message(QuickAction.budgetAndPlan.intent)])
        #expect(model.failureMessage == "That action could not be completed. Try again.")
        #expect(model.canRetry)

        await model.retry()

        #expect(model.items.count == 2)
        #expect(model.items.last?.id == returnedItem.id)
        #expect(model.items.last?.content == returnedItem.content)
        #expect(model.failureMessage == nil)
        #expect(!model.canRetry)

        await model.retry()
        #expect(model.items.count == 2)
    }

    @Test func activityLifecycleReconcilesOnlyByExactCanonicalCoordinates() {
        var ledger = ChatActivityLedger(sessionID: "session_activity_0001")
        let running = ChatActivityEvent(
            eventID: "tool_event_00000001",
            sessionID: "session_activity_0001",
            turnID: "turn_activity_000001",
            kind: .tool,
            lifecycle: .running,
            title: "Searching the web",
            summary: "Weather for Chicago",
            detail: nil,
            occurredAt: 1_788_000_001,
            toolCallID: "call_weather_000001"
        )

        #expect(ledger.receive(running) == .inserted)
        #expect(ledger.receive(running) == .duplicate)

        let completed = running.updating(
            lifecycle: .succeeded,
            summary: "Found the current forecast",
            detail: "Completed in 420 ms",
            occurredAt: 1_788_000_002,
            durationMilliseconds: 420
        )
        #expect(ledger.receive(completed) == .updated)
        #expect(ledger.events(for: "turn_activity_000001") == [completed])

        let wrongTurn = ChatActivityEvent(
            eventID: completed.eventID,
            sessionID: completed.sessionID,
            turnID: "turn_activity_000002",
            kind: completed.kind,
            lifecycle: .failed,
            title: completed.title,
            summary: "Must not overwrite another turn",
            detail: nil,
            occurredAt: 1_788_000_003,
            toolCallID: completed.toolCallID
        )
        #expect(ledger.receive(wrongTurn) == .recovered)
        #expect(ledger.events(for: "turn_activity_000001") == [completed])
        #expect(ledger.events(for: "turn_activity_000002") == [wrongTurn])
    }

    @Test func canonicalTerminalBotHandoffRecoversWithoutAStartEvent() {
        let sessionID = "session_bot_handoff_return"
        let event = ChatActivityEvent(
            eventID: "handoff-return",
            sessionID: sessionID,
            turnID: "turn-bot-handoff-return",
            kind: .botHandoff,
            lifecycle: .succeeded,
            title: "Agent reply",
            summary: "@nova replied",
            detail: nil,
            occurredAt: 1_788_000_004,
            result: "Review complete.",
            botRunID: "bot-run-return",
            memberID: "default",
            fromMemberID: "nova"
        )
        var ledger = ChatActivityLedger(sessionID: sessionID)

        #expect(ledger.receive(event) == .recovered)
        #expect(ledger.events(for: event.turnID) == [event])
    }

    @Test func activityLedgerKeepsCanonicalInsertionSlotsWhenEventsAreEnriched() {
        let sessionID = "session_activity_order"
        let turnID = "turn_activity_order"
        let first = ChatActivityEvent(
            eventID: "event-first",
            sessionID: sessionID,
            turnID: turnID,
            kind: .tool,
            lifecycle: .running,
            title: "First",
            summary: nil,
            detail: nil,
            occurredAt: 20,
            toolCallID: "call-first",
            sourceOrder: 20
        )
        let second = ChatActivityEvent(
            eventID: "event-second",
            sessionID: sessionID,
            turnID: turnID,
            kind: .tool,
            lifecycle: .running,
            title: "Second",
            summary: nil,
            detail: nil,
            occurredAt: 30,
            toolCallID: "call-second",
            sourceOrder: 30
        )
        var ledger = ChatActivityLedger(sessionID: sessionID, events: [first, second])

        let settledFirst = first.updating(
            lifecycle: .succeeded,
            summary: "Finished later",
            detail: nil,
            occurredAt: 40
        ).ordered(20)
        #expect(ledger.receive(settledFirst) == .updated)
        #expect(ledger.allEvents.map(\.eventID) == ["event-first", "event-second"])
        #expect(ledger.events(for: turnID).map(\.eventID) == ["event-first", "event-second"])

        let reconnectedEarlier = ChatActivityEvent(
            eventID: "event-earlier",
            sessionID: sessionID,
            turnID: turnID,
            kind: .tool,
            lifecycle: .running,
            title: "Recovered earlier",
            summary: nil,
            detail: nil,
            occurredAt: 50,
            toolCallID: "call-earlier",
            sourceOrder: 10
        )
        #expect(ledger.receive(reconnectedEarlier) == .inserted)
        #expect(ledger.allEvents.map(\.eventID) == [
            "event-earlier",
            "event-first",
            "event-second",
        ])
    }

    @Test func activityLedgerTailInsertionAndUpdateWorkIsIndependentOfExistingTurns() {
        func work(existingCount: Int) -> (insert: Int, update: Int) {
            let sessionID = "ledger-scale"
            let existing = (1...existingCount).map { (index: Int) in
                ChatActivityEvent(
                    eventID: "event-\(index)",
                    sessionID: sessionID,
                    turnID: "turn-\(index)",
                    kind: .tool,
                    lifecycle: .running,
                    title: "Tool \(index)",
                    summary: nil,
                    detail: nil,
                    occurredAt: index,
                    toolCallID: "call-\(index)",
                    sourceOrder: index
                )
            }
            var ledger = ChatActivityLedger(sessionID: sessionID, events: existing)
            let tail = ChatActivityEvent(
                eventID: "tail",
                sessionID: sessionID,
                turnID: "tail-turn",
                kind: .tool,
                lifecycle: .running,
                title: "Tail",
                summary: nil,
                detail: nil,
                occurredAt: existingCount + 1,
                toolCallID: "tail-call",
                sourceOrder: existingCount + 1
            )
            #expect(ledger.receive(tail) == .inserted)
            let insertWork = ledger.lastMutationWorkCount
            #expect(ledger.receive(tail.updating(
                lifecycle: .succeeded,
                summary: "Done",
                detail: nil,
                occurredAt: existingCount + 2
            )) == .updated)
            return (insertWork, ledger.lastMutationWorkCount)
        }

        let short = work(existingCount: 10)
        let long = work(existingCount: 1_000)
        #expect(long.insert <= short.insert + 1)
        #expect(long.update <= short.update + 1)
        #expect(long.insert <= 5) // Includes the semantic-index lookup.
        #expect(long.update <= 3)
    }

    @Test func activityLedgerEarlierAndLegacyInsertionsRetainCanonicalFallbackOrdering() {
        let sessionID = "ledger-fallback"
        var ledger = ChatActivityLedger(sessionID: sessionID, events: [
            ChatActivityEvent(
                eventID: "ordered-later",
                sessionID: sessionID,
                turnID: "ordered-turn",
                kind: .tool,
                lifecycle: .running,
                title: "Later",
                summary: nil,
                detail: nil,
                occurredAt: 50,
                toolCallID: "later-call",
                sourceOrder: 50
            ),
        ])
        let earlier = ChatActivityEvent(
            eventID: "ordered-earlier",
            sessionID: sessionID,
            turnID: "earlier-turn",
            kind: .tool,
            lifecycle: .running,
            title: "Earlier",
            summary: nil,
            detail: nil,
            occurredAt: 100,
            toolCallID: "earlier-call",
            sourceOrder: 10
        )
        #expect(ledger.receive(earlier) == .inserted)
        #expect(ledger.allEvents.map(\.eventID) == ["ordered-earlier", "ordered-later"])

        var legacy = ChatActivityLedger(sessionID: sessionID)
        let legacyLater = ChatActivityEvent(
            eventID: "legacy-later",
            sessionID: sessionID,
            turnID: "legacy-turn-later",
            kind: .tool,
            lifecycle: .running,
            title: "Legacy later",
            summary: nil,
            detail: nil,
            occurredAt: 20,
            toolCallID: "legacy-later-call"
        )
        let legacyEarlier = ChatActivityEvent(
            eventID: "legacy-earlier",
            sessionID: sessionID,
            turnID: "legacy-turn",
            kind: .tool,
            lifecycle: .running,
            title: "Legacy earlier",
            summary: nil,
            detail: nil,
            occurredAt: 10,
            toolCallID: "legacy-earlier-call"
        )
        #expect(legacy.receive(legacyLater) == .inserted)
        #expect(legacy.receive(legacyEarlier) == .inserted)
        #expect(legacy.allEvents.map(\.eventID) == ["legacy-earlier", "legacy-later"])
    }

    @Test(arguments: ["todo", "todo_list"])
    func authenticatedTodoActivityProjectsMergeAwareLiveTaskState(toolName: String) throws {
        let model = ChatModel(
            conversationID: "session_todo_drawer_0001",
            client: ConversationFixtureClient(),
            initialItems: [],
            taskDrawerDismissDelay: .seconds(60)
        )
        let started = todoActivity(
            eventID: "todo_event_started_0001",
            toolCallID: "todo_call_started_0001",
            sessionID: model.conversationID,
            turnID: "turn_todo_drawer_0001",
            lifecycle: .running,
            arguments: #"{"todos":[{"id":"inspect","content":"Inspect the session","status":"in_progress"},{"id":"fix","content":"Fix the issue","status":"pending"}],"merge":false}"#,
            toolName: toolName
        )

        #expect(model.acceptActivity(started) == .inserted)
        #expect(model.taskDrawer?.items.map(\.content) == ["Inspect the session", "Fix the issue"])
        #expect(model.taskDrawer?.completedCount == 0)

        let mergeStarted = todoActivity(
            eventID: "todo_event_merge_0000001",
            toolCallID: "todo_call_merge_0000001",
            sessionID: model.conversationID,
            turnID: started.turnID,
            lifecycle: .running,
            arguments: #"{"todos":[{"id":"inspect","status":"completed"}],"merge":true}"#,
            occurredAt: 102,
            toolName: toolName
        )
        #expect(model.acceptActivity(mergeStarted) == .inserted)
        #expect(model.taskDrawer?.items.map(\.status) == [.completed, .pending])

        let authoritative = mergeStarted.updating(
            lifecycle: .succeeded,
            summary: "Completed",
            detail: nil,
            occurredAt: 103,
            result: #"{"todos":[{"id":"inspect","content":"Inspect the session","status":"completed"},{"id":"fix","content":"Implement the fix","status":"in_progress"}]}"#
        )
        #expect(model.acceptActivity(authoritative) == .updated)
        #expect(model.taskDrawer?.items.map(\.content) == ["Inspect the session", "Implement the fix"])
        #expect(model.taskDrawer?.completedCount == 1)
        #expect(model.taskDrawer?.totalCount == 2)
    }

    @Test func taskDrawerIgnoresUntrustedToolsAndSurvivesTurnCompletion() {
        let model = ChatModel(
            conversationID: "session_todo_drawer_0002",
            client: ConversationFixtureClient(),
            initialItems: [],
            taskDrawerDismissDelay: .seconds(60)
        )
        let todo = todoActivity(
            eventID: "todo_event_started_0002",
            toolCallID: "todo_call_started_0002",
            sessionID: model.conversationID,
            turnID: "turn_todo_drawer_0002",
            lifecycle: .running,
            arguments: #"{"todos":[{"id":"ship","content":"Ship the change","status":"in_progress"}]}"#
        )
        _ = model.acceptActivity(todo)

        let nonTodo = ChatActivityEvent(
            eventID: "tool_event_terminal_0001",
            sessionID: model.conversationID,
            turnID: todo.turnID,
            kind: .tool,
            lifecycle: .running,
            title: "Running a command",
            summary: nil,
            detail: nil,
            occurredAt: 102,
            toolCallID: "tool_call_terminal_0001",
            toolName: "terminal",
            arguments: #"{"todos":[]}"#
        )
        _ = model.acceptActivity(nonTodo)

        #expect(model.taskDrawer?.items.map(\.id) == ["ship"])
        model.acceptTurnEnded(turnID: "turn_todo_drawer_other")
        #expect(model.taskDrawer != nil)
        model.acceptTurnEnded(turnID: todo.turnID)
        #expect(model.taskDrawer?.items.map(\.id) == ["ship"])
    }

    @Test func terminalTodoStateRemainsVisibleUntilExplicitClear() async {
        let model = ChatModel(
            conversationID: "session_todo_drawer_0003",
            client: ConversationFixtureClient(),
            initialItems: [],
            taskDrawerDismissDelay: .milliseconds(10)
        )
        let started = todoActivity(
            eventID: "todo_event_started_0003",
            toolCallID: "todo_call_started_0003",
            sessionID: model.conversationID,
            turnID: "turn_todo_drawer_0003",
            lifecycle: .running,
            arguments: #"{"todos":[{"id":"done","content":"Finish the work","status":"in_progress"}]}"#
        )
        _ = model.acceptActivity(started)
        let completed = started.updating(
            lifecycle: .succeeded,
            summary: "Completed",
            detail: nil,
            occurredAt: 102,
            result: #"{"todos":[{"id":"done","content":"Finish the work","status":"completed"}]}"#
        )

        _ = model.acceptActivity(completed)
        #expect(model.taskDrawer?.items.map(\.status) == [.completed])

        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.taskDrawer?.items.map(\.status) == [.completed])
    }

    @Test func taskDrawerExpandsInPlaceAboveTheComposer() {
        let state = ChatTaskDrawerState(
            turnID: "turn_todo_drawer_layout",
            items: [
                ChatTaskItem(id: "one", content: "Inspect the canonical Hermes state", status: .completed),
                ChatTaskItem(id: "two", content: "Render the live task list", status: .inProgress),
                ChatTaskItem(id: "three", content: "Dismiss it at turn end", status: .pending),
            ]
        )
        let collapsed = UIHostingController(
            rootView: ChatTaskDrawer(state: state, isExpanded: .constant(false))
        )
        let expanded = UIHostingController(
            rootView: ChatTaskDrawer(state: state, isExpanded: .constant(true))
        )
        let proposal = CGSize(width: 390, height: 844)

        let collapsedSize = collapsed.sizeThatFits(in: proposal)
        let expandedSize = expanded.sizeThatFits(in: proposal)

        #expect(collapsedSize.height > 0)
        #expect(expandedSize.height > collapsedSize.height)
        #expect(expandedSize.width <= proposal.width)
    }

    private func todoActivity(
        eventID: String,
        toolCallID: String,
        sessionID: String,
        turnID: String,
        lifecycle: ChatActivityLifecycle,
        arguments: String?,
        result: String? = nil,
        occurredAt: Int = 101,
        toolName: String = "todo"
    ) -> ChatActivityEvent {
        ChatActivityEvent(
            eventID: eventID,
            sessionID: sessionID,
            turnID: turnID,
            kind: .tool,
            lifecycle: lifecycle,
            title: "Using todo",
            summary: nil,
            detail: nil,
            occurredAt: occurredAt,
            toolCallID: toolCallID,
            toolName: toolName,
            arguments: arguments,
            result: result
        )
    }

    @Test func toolLifecycleReconcilesByCanonicalToolCallIdentityAcrossFrameEventIDs() {
        var ledger = ChatActivityLedger(sessionID: "session_activity_tool_identity")
        let started = ChatActivityEvent(
            eventID: "tool_transport_started_0001",
            sessionID: "session_activity_tool_identity",
            turnID: "turn_activity_tool_identity",
            kind: .tool,
            lifecycle: .running,
            title: "Running a command",
            summary: nil,
            detail: nil,
            occurredAt: 100,
            toolCallID: "call_terminal_identity_0001"
        )
        let finished = ChatActivityEvent(
            eventID: "tool_transport_finished_0001",
            sessionID: started.sessionID,
            turnID: started.turnID,
            kind: .tool,
            lifecycle: .succeeded,
            title: started.title,
            summary: "Completed",
            detail: "420 ms",
            occurredAt: 101,
            durationMilliseconds: 420,
            toolCallID: started.toolCallID
        )

        #expect(ledger.receive(started) == .inserted)
        #expect(ledger.receive(finished) == .updated)
        #expect(ledger.events(for: started.turnID) == [finished])
    }

    @Test func validToolSuccessBeatsMalformedDuplicateFailureAndKeepsRichestData() throws {
        var ledger = ChatActivityLedger(sessionID: "session_activity_success_precedence")
        let success = ChatActivityEvent(
            eventID: "tool_success",
            sessionID: "session_activity_success_precedence",
            turnID: "turn_activity_success_precedence",
            kind: .tool,
            lifecycle: .succeeded,
            title: "Running a command",
            summary: "Completed",
            detail: nil,
            occurredAt: 100,
            durationMilliseconds: 420,
            toolCallID: "call_success_precedence",
            toolName: "terminal",
            arguments: #"{"command":"swift test"}"#,
            result: "All tests passed"
        )
        let malformedFailure = ChatActivityEvent(
            eventID: "tool_malformed_failure",
            sessionID: success.sessionID,
            turnID: success.turnID,
            kind: .tool,
            lifecycle: .failed,
            title: success.title,
            summary: "Tool did not complete",
            detail: "Duplicate callback omitted its arguments",
            occurredAt: 101,
            toolCallID: success.toolCallID,
            toolName: success.toolName,
            arguments: nil,
            result: nil
        )

        #expect(ledger.receive(success) == .recovered)
        #expect(ledger.receive(malformedFailure) == .updated)

        let reconciled = try #require(ledger.events(for: success.turnID).first)
        #expect(reconciled.lifecycle == .succeeded)
        #expect(reconciled.arguments == success.arguments)
        #expect(reconciled.result == success.result)
        #expect(reconciled.durationMilliseconds == 420)
        #expect(reconciled.detail == malformedFailure.detail)
    }

    @Test func genuineToolFailureRemainsTerminalWhenNoValidSuccessExists() throws {
        var ledger = ChatActivityLedger(sessionID: "session_activity_failure")
        let running = ChatActivityEvent(
            eventID: "tool_failure_running",
            sessionID: "session_activity_failure",
            turnID: "turn_activity_failure",
            kind: .tool,
            lifecycle: .running,
            title: "Searching the web",
            summary: "Inputs: query",
            detail: nil,
            occurredAt: 100,
            toolCallID: "call_genuine_failure",
            toolName: "web_search",
            arguments: #"{"query":"SwiftUI"}"#
        )
        let failed = running.updating(
            lifecycle: .failed,
            summary: "Tool did not complete",
            detail: "Network unavailable",
            occurredAt: 101,
            durationMilliseconds: 50
        )

        #expect(ledger.receive(running) == .inserted)
        #expect(ledger.receive(failed) == .updated)
        #expect(ledger.events(for: running.turnID).first?.lifecycle == .failed)
    }

    @Test func terminalToolStateDoesNotRegressButMergesRicherOlderData() throws {
        var ledger = ChatActivityLedger(sessionID: "session_activity_no_regression")
        let success = ChatActivityEvent(
            eventID: "tool_terminal_first",
            sessionID: "session_activity_no_regression",
            turnID: "turn_activity_no_regression",
            kind: .tool,
            lifecycle: .succeeded,
            title: "Using execute code",
            summary: "Completed",
            detail: nil,
            occurredAt: 200,
            toolCallID: "call_no_regression",
            toolName: "execute_code",
            arguments: #"{"name":"verify"}"#,
            result: "Verified"
        )
        let lateRunning = ChatActivityEvent(
            eventID: "tool_late_running",
            sessionID: success.sessionID,
            turnID: success.turnID,
            kind: .tool,
            lifecycle: .running,
            title: success.title,
            summary: "Starting verification with additional context",
            detail: "Richer diagnostic detail from reconnect",
            occurredAt: 100,
            toolCallID: success.toolCallID,
            toolName: success.toolName,
            arguments: success.arguments
        )

        #expect(ledger.receive(success) == .recovered)
        #expect(ledger.receive(lateRunning) == .updated)

        let reconciled = try #require(ledger.events(for: success.turnID).first)
        #expect(reconciled.lifecycle == .succeeded)
        #expect(reconciled.result == "Verified")
        #expect(reconciled.detail == lateRunning.detail)
        #expect(reconciled.occurredAt == 200)
    }

    @Test func terminalToolWithoutObservedRunningRecoversABoundedCanonicalRow() {
        var ledger = ChatActivityLedger(sessionID: "session_activity_recovery")
        let failed = ChatActivityEvent(
            eventID: "tool_terminal_recovered",
            sessionID: "session_activity_recovery",
            turnID: "turn_activity_recovery",
            kind: .tool,
            lifecycle: .failed,
            title: "Reading a file",
            summary: "Tool did not complete",
            detail: "Permission denied",
            occurredAt: 100,
            toolCallID: "call_terminal_recovered",
            toolName: "read_file",
            arguments: #"{"path":"Package.swift"}"#
        )

        #expect(ledger.receive(failed) == .recovered)
        #expect(ledger.events(for: failed.turnID) == [failed])
    }

    @Test func syntheticReasoningLifecycleDoesNotCreateAnEmptyTranscriptCard() {
        let reasoning = ChatActivityEvent(
            eventID: "reasoning_synthetic_0001",
            sessionID: "session_reasoning_synthetic",
            turnID: "turn_reasoning_synthetic",
            kind: .reasoning,
            lifecycle: .succeeded,
            title: "Reasoning",
            summary: "Response ready",
            detail: nil,
            occurredAt: 100
        )
        let model = ChatModel(
            conversationID: reasoning.sessionID,
            client: ConversationFixtureClient(),
            initialItems: [],
            initialActivityEvents: [reasoning],
            initialActivityVisibility: .init(showReasoning: true, showToolCalls: true)
        )

        #expect(model.transcriptEntries.isEmpty)
    }

    @Test func lateAndRegressiveActivityUpdatesCannotReopenSettledWork() {
        var ledger = ChatActivityLedger(sessionID: "session_activity_0002")
        let started = ChatActivityEvent(
            eventID: "reasoning_event_0001",
            sessionID: "session_activity_0002",
            turnID: "turn_activity_000003",
            kind: .reasoning,
            lifecycle: .running,
            title: "Thinking",
            summary: "Comparing options",
            detail: nil,
            occurredAt: 100
        )
        let finished = started.updating(
            lifecycle: .succeeded,
            summary: "Prepared an answer",
            detail: nil,
            occurredAt: 200
        )

        #expect(ledger.receive(started) == .inserted)
        #expect(ledger.receive(finished) == .updated)
        #expect(ledger.receive(started) == .stale)
        #expect(ledger.events(for: started.turnID) == [finished])
    }

    @Test func reasoningAndToolVisibilityAreIndependentWithoutDiscardingActivity() {
        var ledger = ChatActivityLedger(sessionID: "session_activity_0003")
        let reasoning = ChatActivityEvent(
            eventID: "reasoning_event_0002",
            sessionID: "session_activity_0003",
            turnID: "turn_activity_000004",
            kind: .reasoning,
            lifecycle: .running,
            title: "Thinking",
            summary: "Reviewing the request",
            detail: nil,
            occurredAt: 100
        )
        let tool = ChatActivityEvent(
            eventID: "tool_event_00000002",
            sessionID: reasoning.sessionID,
            turnID: reasoning.turnID,
            kind: .tool,
            lifecycle: .running,
            title: "Reading files",
            summary: "2 files",
            detail: nil,
            occurredAt: 101,
            toolCallID: "call_files_00000001"
        )
        let subagent = ChatActivityEvent(
            eventID: "delegate_event_0001",
            sessionID: reasoning.sessionID,
            turnID: reasoning.turnID,
            kind: .subagent,
            lifecycle: .running,
            title: "Research agent",
            summary: "Checking provider docs",
            detail: nil,
            occurredAt: 102,
            subagentID: "subagent_research_01"
        )
        _ = ledger.receive(reasoning)
        _ = ledger.receive(tool)
        _ = ledger.receive(subagent)

        let toolsHidden = ledger.visibleEvents(
            for: reasoning.turnID,
            visibility: .init(showReasoning: true, showToolCalls: false)
        )
        #expect(toolsHidden.map(\.kind) == [.reasoning, .subagent])

        let reasoningHidden = ledger.visibleEvents(
            for: reasoning.turnID,
            visibility: .init(showReasoning: false, showToolCalls: true)
        )
        #expect(reasoningHidden.map(\.kind) == [.tool, .subagent])
        #expect(ledger.events(for: reasoning.turnID).count == 3)
    }

    @Test func workTrailSummaryAccumulatesToolCallsInOneCompactTag() {
        let events = [
            ChatActivityEvent(
                eventID: "tool_event_summary_01",
                sessionID: "session_activity_0004",
                turnID: "turn_activity_000005",
                kind: .tool,
                lifecycle: .succeeded,
                title: "Read files",
                summary: "3 files",
                detail: nil,
                occurredAt: 100,
                toolCallID: "call_summary_000001"
            ),
            ChatActivityEvent(
                eventID: "tool_event_summary_02",
                sessionID: "session_activity_0004",
                turnID: "turn_activity_000005",
                kind: .tool,
                lifecycle: .running,
                title: "Search code",
                summary: "5 searches",
                detail: nil,
                occurredAt: 101,
                toolCallID: "call_summary_000002"
            ),
            ChatActivityEvent(
                eventID: "delegate_event_summary_01",
                sessionID: "session_activity_0004",
                turnID: "turn_activity_000005",
                kind: .subagent,
                lifecycle: .succeeded,
                title: "Research agent",
                summary: "Finished",
                detail: nil,
                occurredAt: 102,
                subagentID: "subagent_summary_001"
            ),
        ]

        #expect(ChatActivityPresentation.stepCount(of: events) == 3)
        let phase = ChatActivityPresentation.trailPhase(for: events)
        #expect(phase.isLive)
        #expect(BighelpActivitySummary.label(for: phase) == "Using tools…")
    }

    @Test func toolActivityPreservesExpandableArgumentsAndResultAcrossUpdates() throws {
        let event = ChatActivityEvent(
            eventID: "tool-event-details",
            sessionID: "session-details",
            turnID: "turn-details",
            kind: .tool,
            lifecycle: .running,
            title: "Running a command",
            summary: "Starting",
            detail: nil,
            occurredAt: 1_788_000_000,
            toolCallID: "call-details",
            arguments: #"{"command":"swift test"}"#,
            result: nil
        )

        let finished = event.updating(
            lifecycle: .succeeded,
            summary: "Completed",
            detail: nil,
            occurredAt: 1_788_000_001,
            durationMilliseconds: 240,
            result: "All tests passed"
        )
        let decoded = try JSONDecoder().decode(
            ChatActivityEvent.self,
            from: JSONEncoder().encode(finished)
        )

        #expect(decoded.arguments == #"{"command":"swift test"}"#)
        #expect(decoded.result == "All tests passed")
        #expect(decoded.ordered(42).arguments == decoded.arguments)
        #expect(decoded.ordered(42).result == decoded.result)
    }

    @Test func terminalToolReconciliationRetainsArgumentsWhenHermesOmitsThem() throws {
        let running = ChatActivityEvent(
            eventID: "tool-event-running-details",
            sessionID: "session-details",
            turnID: "turn-details",
            kind: .tool,
            lifecycle: .running,
            title: "Running a command",
            summary: "Starting",
            detail: nil,
            occurredAt: 1_788_000_000,
            toolCallID: "call-details",
            arguments: #"{"command":"swift test"}"#
        )
        let terminal = ChatActivityEvent(
            eventID: "tool-event-terminal-details",
            sessionID: "session-details",
            turnID: "turn-details",
            kind: .tool,
            lifecycle: .succeeded,
            title: "Running a command",
            summary: "Completed",
            detail: nil,
            occurredAt: 1_788_000_001,
            durationMilliseconds: 240,
            toolCallID: "call-details",
            result: "All tests passed"
        )
        var ledger = ChatActivityLedger(sessionID: "session-details")

        #expect(ledger.receive(running) == .inserted)
        #expect(ledger.receive(terminal) == .updated)

        let reconciled = try #require(ledger.event(id: running.id))
        #expect(reconciled.lifecycle == .succeeded)
        #expect(reconciled.arguments == #"{"command":"swift test"}"#)
        #expect(reconciled.result == "All tests passed")
    }

    @Test func hourlyWeatherFixtureProvidesSemanticConditions() {
        #expect(ConversationFixtures.weatherAndTasks.hourly.map(\.condition) == [
            "Sunny", "Sunny", "Sunny", "Sunny"
        ])
    }

    @Test func queuedShortcutTurnPersistsTheHumanMessageAfterDurableSubmission() async throws {
        let client = QueuedConversationClientFixture()
        var snapshots: [[TimelineItem]] = []
        let model = ChatModel(
            conversationID: "session_fixture_0001",
            client: client,
            initialItems: [],
            onSessionChange: { _, items, _, _ in snapshots.append(items) }
        )
        let attachment = try ChatAttachment(
            id: "attachment_shortcut_fixture_0001",
            fileName: "photo.png",
            mimeType: "image/png",
            data: Data("PNG".utf8)
        )

        try await model.submitWithoutWaiting(
            message: "Handle this in the background",
            attachments: [attachment]
        )

        #expect(client.submissions == ["Handle this in the background"])
        #expect(client.attachments == [[attachment]])
        #expect(model.items.map(\.role) == [.human])
        #expect(model.items[0].attachments == [attachment])
        #expect(snapshots.last == model.items)
        #expect(!model.isSending)
    }
}

@MainActor
private final class QueuedConversationClientFixture: QueuedConversationClient {
    private(set) var submissions: [String] = []
    private(set) var attachments: [[ChatAttachment]] = []

    func submit(
        message: String,
        attachments: [ChatAttachment],
        conversationID: String
    ) async throws {
        submissions.append(message)
        self.attachments.append(attachments)
    }

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        ConversationResponse(items: [])
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        ConversationResponse(items: [])
    }
}

@MainActor
private final class ControlledDemoSleeper: DemoSleeper {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didStart = false

    func sleep() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            didStart = true
        }
    }

    func waitUntilSleepStarts() async {
        while !didStart {
            await Task.yield()
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class ControlledStreamingConversationClient: StreamingConversationClient {
    private var continuation: CheckedContinuation<ConversationResponse, Error>?
    private var draft: ((TimelineItem) -> Void)?
    private var didStart = false

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        try await send(message: message, conversationID: conversationID, onDraft: { _ in })
    }

    func send(
        message: String,
        conversationID: String,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> ConversationResponse {
        didStart = true
        draft = onDraft
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        throw ConversationFixtureError.unavailable
    }

    func waitUntilStarted() async {
        while !didStart { await Task.yield() }
    }

    func yieldDraft(
        id: String = "message_streaming_draft_0001",
        text: String = "Working draft",
        agentName: String = "Assistant"
    ) {
        draft?(
            TimelineItem(
                id: id,
                role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: agentName)),
                content: .message(text),
                metadata: TimelineMetadata(delivery: "Streaming")
            )
        )
    }

    func finish(
        id: String = "message_streaming_final_0001",
        text: String = "Final answer"
    ) {
        continuation?.resume(
            returning: ConversationResponse(items: [
                TimelineItem(
                    id: id,
                    role: .assistant,
                    sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
                    content: .message(text),
                    metadata: TimelineMetadata(delivery: "Delivered")
                )
            ])
        )
        continuation = nil
        draft = nil
    }
}

@MainActor
private final class ControlledStoppableConversationClient: StoppableConversationClient,
    InactiveSessionReconciliationConversationClient
{
    enum Stop: Error { case requested }

    private var continuation: CheckedContinuation<ConversationResponse, Error>?
    private var didStart = false
    private(set) var stoppedConversationIDs: [String] = []
    private(set) var reconciledConversationIDs: [String] = []

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        didStart = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        try await send(message: action.intent, conversationID: conversationID)
    }

    func stop(conversationID: String) async throws {
        stoppedConversationIDs.append(conversationID)
        continuation?.resume(throwing: Stop.requested)
        continuation = nil
    }

    func reconcileInactiveSession(conversationID: String) {
        reconciledConversationIDs.append(conversationID)
    }

    func waitUntilStarted() async {
        while !didStart { await Task.yield() }
    }
}

@MainActor
private final class ControlledMidSessionConversationClient: MidSessionConversationClient,
    StreamingConversationClient, AttachmentConversationClient
{
    enum Failure: Error { case rejected }

    private var initialContinuation: CheckedContinuation<ConversationResponse, Error>?
    private var initialDraft: ((TimelineItem) -> Void)?
    private var midSessionContinuation: CheckedContinuation<MidSessionSubmissionOutcome, Error>?
    private var midSessionDraft: ((TimelineItem) -> Void)?
    private var didStartInitial = false
    private var didStartMidSession = false
    private(set) var midSessionBehaviors: [MidSessionChatBehavior] = []
    private(set) var initialAttachments: [ChatAttachment] = []

    func send(message: String, attachments: [ChatAttachment], conversationID: String,
              onDraft: @escaping (TimelineItem) -> Void) async throws -> ConversationResponse {
        initialAttachments = attachments
        return try await send(message: message, conversationID: conversationID, onDraft: onDraft)
    }

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        try await send(message: message, conversationID: conversationID, onDraft: { _ in })
    }

    func send(
        message: String,
        conversationID: String,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> ConversationResponse {
        didStartInitial = true
        initialDraft = onDraft
        return try await withCheckedThrowingContinuation { initialContinuation = $0 }
    }

    func sendMidSession(
        message: String,
        attachments: [ChatAttachment],
        conversationID: String,
        behavior: MidSessionChatBehavior,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> MidSessionSubmissionOutcome {
        midSessionBehaviors.append(behavior)
        didStartMidSession = true
        midSessionDraft = onDraft
        return try await withCheckedThrowingContinuation { midSessionContinuation = $0 }
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        throw Failure.rejected
    }

    func waitUntilInitialStarted() async {
        while !didStartInitial { await Task.yield() }
    }

    func waitUntilMidSessionStarted() async {
        while !didStartMidSession { await Task.yield() }
    }

    func yieldInitialDraft(id: String, text: String) {
        initialDraft?(assistantItem(id: id, text: text, delivery: "Streaming"))
    }

    func yieldMidSessionDraft(id: String, text: String) {
        midSessionDraft?(assistantItem(id: id, text: text, delivery: "Streaming"))
    }

    func finishInitial(text: String) {
        initialContinuation?.resume(returning: ConversationResponse(items: [
            assistantItem(id: "initial-final", text: text, delivery: "Delivered"),
        ]))
        initialContinuation = nil
    }

    func failInitial() {
        initialContinuation?.resume(throwing: Failure.rejected)
        initialContinuation = nil
    }

    func resolveMidSession(_ outcome: MidSessionSubmissionOutcome) {
        midSessionContinuation?.resume(returning: outcome)
        midSessionContinuation = nil
    }

    func rejectMidSession() {
        midSessionContinuation?.resume(throwing: Failure.rejected)
        midSessionContinuation = nil
    }

    private func assistantItem(id: String, text: String, delivery: String) -> TimelineItem {
        TimelineItem(
            id: id,
            role: .assistant,
            sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
            content: .message(text),
            metadata: .init(delivery: delivery)
        )
    }
}

@MainActor
private final class ControlledConcurrentMidSessionConversationClient: MidSessionConversationClient,
    StreamingConversationClient
{
    private var initialContinuation: CheckedContinuation<ConversationResponse, Error>?
    private var midSessionContinuations: [CheckedContinuation<MidSessionSubmissionOutcome, Error>?] = []
    private var didStartInitial = false
    private(set) var midSessionMessages: [String] = []

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        try await send(message: message, conversationID: conversationID, onDraft: { _ in })
    }

    func send(
        message: String,
        conversationID: String,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> ConversationResponse {
        didStartInitial = true
        return try await withCheckedThrowingContinuation { initialContinuation = $0 }
    }

    func sendMidSession(
        message: String,
        attachments: [ChatAttachment],
        conversationID: String,
        behavior: MidSessionChatBehavior,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> MidSessionSubmissionOutcome {
        midSessionMessages.append(message)
        return try await withCheckedThrowingContinuation { continuation in
            midSessionContinuations.append(continuation)
        }
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        fatalError("Not used by this fixture")
    }

    func waitUntilInitialStarted() async {
        while !didStartInitial { await Task.yield() }
    }

    func waitForMidSessionRequestCount(_ count: Int) async {
        while midSessionMessages.count < count { await Task.yield() }
    }

    func resolveMidSession(at index: Int, with outcome: MidSessionSubmissionOutcome) {
        midSessionContinuations[index]?.resume(returning: outcome)
        midSessionContinuations[index] = nil
    }

    func finishInitial(text: String) {
        initialContinuation?.resume(returning: ConversationResponse(items: [
            TimelineItem(
                id: "concurrent-initial-final",
                role: .assistant,
                sender: .agent(id: "default", snapshot: .init(name: "Assistant")),
                content: .message(text),
                metadata: .init(delivery: "Delivered")
            ),
        ]))
        initialContinuation = nil
    }
}

@MainActor
private final class MidSessionBehaviorBox {
    var value: MidSessionChatBehavior

    init(_ value: MidSessionChatBehavior) {
        self.value = value
    }
}

@MainActor
private final class SequenceConversationClient: ConversationClient {
    enum Failure: Error {
        case unavailable
    }

    private var sendResults: [Result<ConversationResponse, Failure>]
    private var actionResults: [Result<ConversationResponse, Failure>]

    init(
        sendResults: [Result<ConversationResponse, Failure>] = [],
        actionResults: [Result<ConversationResponse, Failure>] = []
    ) {
        self.sendResults = sendResults
        self.actionResults = actionResults
    }

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        guard !sendResults.isEmpty else { throw Failure.unavailable }
        return try sendResults.removeFirst().get()
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        guard !actionResults.isEmpty else { throw Failure.unavailable }
        return try actionResults.removeFirst().get()
    }
}

@MainActor
private final class AttachmentConversationClientFixture: AttachmentConversationClient {
    private(set) var attachments: [[ChatAttachment]] = []

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        ConversationResponse(items: [])
    }

    func send(
        message: String,
        attachments: [ChatAttachment],
        conversationID: String,
        onDraft: @escaping (TimelineItem) -> Void
    ) async throws -> ConversationResponse {
        self.attachments.append(attachments)
        return ConversationResponse(items: [])
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        ConversationResponse(items: [])
    }
}

@MainActor
private final class SlashCommandCatalogClientFixture: SlashCommandCatalogClient {
    struct Request: Equatable {
        let sessionID: String
        let agentID: String
    }

    private(set) var requests: [Request] = []

    func catalog(sessionID: String, agentID: String) async throws -> [SlashCommandDescriptor] {
        requests.append(.init(sessionID: sessionID, agentID: agentID))
        return []
    }
}

@MainActor
private final class TransientSlashCommandCatalogClient: SlashCommandCatalogClient {
    private(set) var requests: [String] = []
    private var shouldFail = true

    func catalog(sessionID: String, agentID: String) async throws -> [SlashCommandDescriptor] {
        requests.append("\(sessionID):\(agentID)")
        if shouldFail {
            shouldFail = false
            throw TransientSlashCommandError.unavailable
        }
        return [
            SlashCommandDescriptor(
                name: "help",
                description: "Show available commands",
                category: "Help",
                argsHint: "",
                aliases: [],
                argumentMode: .none,
                source: .core,
                requiresArguments: false
            ),
        ]
    }
}

@MainActor
private final class TransientLinkSlashCommandCatalogClient: SlashCommandCatalogClient {
    private(set) var requests = 0

    func catalog(sessionID: String, agentID: String) async throws -> [SlashCommandDescriptor] {
        requests += 1
        switch requests {
        case 1:
            throw BighelpLinkLiveSocketError.timedOut
        case 2:
            throw BighelpLinkLiveSocketError.disconnected
        default:
            return [
                SlashCommandDescriptor(
                    name: "help",
                    description: "Show available commands",
                    category: "Help",
                    argsHint: "",
                    aliases: [],
                    argumentMode: .none,
                    source: .core,
                    requiresArguments: false
                ),
            ]
        }
    }
}

@MainActor
private final class CancelledThenSuccessfulSlashCommandCatalogClient: SlashCommandCatalogClient {
    private var shouldCancel = true

    func catalog(sessionID: String, agentID: String) async throws -> [SlashCommandDescriptor] {
        if shouldCancel {
            shouldCancel = false
            throw CancellationError()
        }
        return [
            SlashCommandDescriptor(
                name: "help",
                description: "Show available commands",
                category: "Help",
                argsHint: "",
                aliases: [],
                argumentMode: .none,
                source: .core,
                requiresArguments: false
            ),
        ]
    }
}

private enum TransientSlashCommandError: Error {
    case unavailable
}

@MainActor
private final class RecordingSlashConversationClient: ConversationClient {
    private(set) var messages: [String] = []

    func send(message: String, conversationID: String) async throws -> ConversationResponse {
        messages.append(message)
        return ConversationResponse(items: [])
    }

    func perform(action: QuickAction, conversationID: String) async throws -> ConversationResponse {
        ConversationResponse(items: [])
    }
}

@MainActor
private final class DeferredRuntimeControlMessagingFixture: BighelpLinkSessionControlMessaging {
    enum Failure: Error { case unsupported }

    let modelPicker: BighelpLinkModelPicker
    let reasoningPicker: BighelpLinkChoicePicker
    private(set) var opened: [BighelpLinkPickerOpenRequest] = []

    init(
        modelPicker: BighelpLinkModelPicker,
        reasoningPicker: BighelpLinkChoicePicker
    ) {
        self.modelPicker = modelPicker
        self.reasoningPicker = reasoningPicker
    }

    func openPicker(_ request: BighelpLinkPickerOpenRequest) async throws -> BighelpLinkPicker {
        opened.append(request)
        try await Task.sleep(for: .milliseconds(100))
        switch request.kind {
        case .model:
            return .model(modelPicker)
        case .reasoning:
            return .choice(reasoningPicker)
        }
    }

    func selectPicker(
        _ selection: BighelpLinkPickerSelection
    ) async throws -> BighelpLinkPickerResult {
        throw Failure.unsupported
    }
}

@MainActor
private final class TransientPickerRuntimeControlMessagingFixture: BighelpLinkSessionControlMessaging {
    let modelPicker: BighelpLinkModelPicker
    let reasoningPicker: BighelpLinkChoicePicker
    private var modelFailures: [BighelpLinkLiveSocketError]
    private var reasoningFailures: [BighelpLinkLiveSocketError]
    private(set) var opened: [BighelpLinkPickerOpenRequest] = []

    init(
        modelPicker: BighelpLinkModelPicker,
        reasoningPicker: BighelpLinkChoicePicker,
        modelFailures: [BighelpLinkLiveSocketError] = [],
        reasoningFailures: [BighelpLinkLiveSocketError] = []
    ) {
        self.modelPicker = modelPicker
        self.reasoningPicker = reasoningPicker
        self.modelFailures = modelFailures
        self.reasoningFailures = reasoningFailures
    }

    func openPicker(_ request: BighelpLinkPickerOpenRequest) async throws -> BighelpLinkPicker {
        opened.append(request)
        switch request.kind {
        case .model:
            if !modelFailures.isEmpty { throw modelFailures.removeFirst() }
            return .model(modelPicker)
        case .reasoning:
            if !reasoningFailures.isEmpty { throw reasoningFailures.removeFirst() }
            return .choice(reasoningPicker)
        }
    }

    func selectPicker(
        _ selection: BighelpLinkPickerSelection
    ) async throws -> BighelpLinkPickerResult {
        throw BighelpLinkLiveSocketError.disconnected
    }
}

@MainActor
private final class RuntimeControlMessagingFixture: BighelpLinkSessionControlMessaging {
    let modelPicker: BighelpLinkModelPicker
    let reasoningPicker: BighelpLinkChoicePicker
    let resultStatus: BighelpLinkPickerResult.Status
    var onOpen: (() -> Void)?
    var onOpenAsync: (() async -> Void)?
    private(set) var opened: [BighelpLinkPickerOpenRequest] = []
    private(set) var selections: [BighelpLinkPickerSelection] = []

    init(
        modelPicker: BighelpLinkModelPicker,
        reasoningPicker: BighelpLinkChoicePicker,
        resultStatus: BighelpLinkPickerResult.Status = .completed
    ) {
        self.modelPicker = modelPicker
        self.reasoningPicker = reasoningPicker
        self.resultStatus = resultStatus
    }

    func openPicker(_ request: BighelpLinkPickerOpenRequest) async throws -> BighelpLinkPicker {
        opened.append(request)
        onOpen?()
        await onOpenAsync?()
        switch request.kind {
        case .model:
            return .model(modelPicker)
        case .reasoning:
            return .choice(reasoningPicker)
        }
    }

    func selectPicker(_ selection: BighelpLinkPickerSelection) async throws -> BighelpLinkPickerResult {
        selections.append(selection)
        let message = resultStatus == .completed
            ? "Updated"
            : "Hermes could not apply that selection"
        return try JSONDecoder().decode(
            BighelpLinkPickerResult.self,
            from: Data(
                """
                {
                  "version": 1,
                  "type": "picker.result",
                  "pickerId": "\(selection.pickerID)",
                  "sessionId": "\(selection.sessionID)",
                  "kind": "\(selection.kind.rawValue)",
                  "status": "\(resultStatus.rawValue)",
                  "message": "\(message)",
                  "sentAt": 1788000000
                }
                """.utf8
            )
        )
    }
}

private func decodeModelPicker() throws -> BighelpLinkModelPicker {
    try JSONDecoder().decode(
        BighelpLinkModelPicker.self,
        from: Data(
            """
            {
              "version": 1,
              "type": "picker.model",
              "pickerId": "picker_model_fixture_0001",
              "sessionId": "session_runtime_fixture_0001",
              "currentModel": "Hermes-4-405B",
              "currentProvider": "nous",
              "providers": [
                {
                  "id": "nous",
                  "name": "Nous Research",
                  "isCurrent": true,
                  "isCustom": false,
                  "models": ["Hermes-4-405B", "Hermes-4-70B"]
                },
                {
                  "id": "openai",
                  "name": "OpenAI",
                  "isCurrent": false,
                  "isCustom": false,
                  "models": ["gpt-5.6"]
                }
              ],
              "sentAt": 1788000000
            }
            """.utf8
        )
    )
}

private func decodeReasoningPicker(current: String = "reset") throws -> BighelpLinkChoicePicker {
    let mediumChoice = current == "medium"
        ? #"{"value": "medium", "label": "Medium", "isCurrent": true},"#
        : ""
    return try JSONDecoder().decode(
        BighelpLinkChoicePicker.self,
        from: Data(
            """
            {
              "version": 1,
              "type": "picker.choice",
              "pickerId": "picker_reason_fixture_0001",
              "sessionId": "session_runtime_fixture_0001",
              "kind": "reasoning",
              "title": "Reasoning effort",
              "choices": [
                {"value": "reset", "label": "Use default", "isCurrent": \(current == "reset")},
                {"value": "none", "label": "None", "isCurrent": \(current == "none")},
                {"value": "low", "label": "Low", "isCurrent": \(current == "low")},
                \(mediumChoice)
                {"value": "high", "label": "High", "isCurrent": \(current == "high")},
                {"value": "show", "label": "Show reasoning", "isCurrent": \(current == "show")},
                {"value": "hide", "label": "Hide reasoning", "isCurrent": false}
              ],
              "sentAt": 1788000000
            }
            """.utf8
        )
    )
}
