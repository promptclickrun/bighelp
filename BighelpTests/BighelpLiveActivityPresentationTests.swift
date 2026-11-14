import Foundation
import Testing
@testable import Bighelp

struct BighelpLiveActivityPresentationTests {
    @Test func failedChildDoesNotDeclareTheWholeParentFailed() {
        let initial = LoopdySessionActivityAttributes.ContentState.initial(
            agentName: "Juno", timestamp: 1_788_000_000)
        let projected = BighelpLiveActivityProjection.apply(
            event(kind: .subagent, lifecycle: .failed,
                  title: "Research agent", summary: "Child stopped"),
            to: initial, agentName: "Juno")
        #expect(projected.phase != .failed)
        #expect(projected.phase != .completed)
    }

    @Test func routineProgressDoesNotInventPercentageCompletion() {
        let initial = LoopdySessionActivityAttributes.ContentState.initial(
            agentName: "Juno", timestamp: 1_788_000_000)
        let projected = BighelpLiveActivityProjection.apply(
            event(kind: .reasoning, lifecycle: .running,
                  title: "Reasoning", summary: "Preparing"),
            to: initial, agentName: "Juno")
        #expect(projected.progress == 0)
    }

    @Test func descriptorKeepsUsefulIdentityWhileBoundingLockScreenCopy() throws {
        let descriptor = try #require(
            LoopdySessionActivityAttributes.make(
                sessionID: "session_live_activity_0001",
                sessionTitle: "  Weather, calendar, and family plans\nfor the weekend  ",
                agentID: "juno",
                agentName: "  Juno  "
            )
        )

        #expect(descriptor.sessionID == "session_live_activity_0001")
        #expect(descriptor.sessionTitle == "Active chat")
        #expect(descriptor.agentID == "juno")
        #expect(descriptor.agentName == "Juno")
        #expect(descriptor.deepLink.absoluteString == "loopdy://chat/session_live_activity_0001")
    }

    @Test func lifecycleProjectsReasoningToolsDelegationAndFinalResponse() throws {
        let initial = LoopdySessionActivityAttributes.ContentState.initial(
            agentName: "Juno",
            timestamp: 1_788_000_000
        )
        #expect(initial.phase == .thinking)
        #expect(initial.currentAction == "Juno is getting started")

        let reasoning = BighelpLiveActivityProjection.apply(
            event(
                kind: .reasoning,
                lifecycle: .running,
                title: "Reasoning",
                summary: "Preparing a response"
            ),
            to: initial,
            agentName: "Juno"
        )
        #expect(reasoning.phase == .thinking)
        #expect(reasoning.currentAction == "Juno is thinking through your request")
        #expect(reasoning.progress == 0)

        let tool = BighelpLiveActivityProjection.apply(
            event(
                kind: .tool,
                lifecycle: .running,
                title: "Checking weather",
                summary: "Inputs: city"
            ),
            to: reasoning,
            agentName: "Juno"
        )
        #expect(tool.phase == .usingTool)
        #expect(tool.currentAction == "Juno is using a tool")
        #expect(tool.latestTool == nil)
        #expect(tool.completedSteps == 0)

        let toolFinished = BighelpLiveActivityProjection.apply(
            event(
                kind: .tool,
                lifecycle: .succeeded,
                title: "Checking weather",
                summary: "Completed"
            ),
            to: tool,
            agentName: "Juno"
        )
        #expect(toolFinished.completedSteps == 0)

        let delegation = BighelpLiveActivityProjection.apply(
            event(
                kind: .subagent,
                lifecycle: .running,
                title: "Research agent",
                summary: "Delegated work started"
            ),
            to: toolFinished,
            agentName: "Juno"
        )
        #expect(delegation.phase == .delegating)
        #expect(delegation.currentAction == "Juno is working with other bots")
        #expect(delegation.activeSubagentCount == 0)

        let finished = BighelpLiveActivityProjection.final(
            agentName: "Juno",
            previous: delegation,
            succeeded: true,
            timestamp: 1_788_000_010
        )
        #expect(finished.phase == .completed)
        #expect(finished.currentAction == "Finished")
        #expect(finished.progress == 100)
        #expect(finished.activeSubagentCount == 0)
    }

    @Test func displayStateNeverLeaksActivityDetailsOrToolArguments() {
        let projected = BighelpLiveActivityProjection.apply(
            event(
                kind: .tool,
                lifecycle: .running,
                title: "Running a command\nwith secret-token-value",
                summary: "Inputs: password, api_key"
            ),
            to: .initial(agentName: "Juno", timestamp: 1_788_000_000),
            agentName: "Juno"
        )

        #expect(!projected.currentAction.contains("secret-token-value"))
        #expect(!projected.currentAction.contains("password"))
        #expect(!projected.currentAction.contains("api_key"))
        #expect(projected.currentAction.count <= 96)
    }

    private func event(
        kind: ChatActivityKind,
        lifecycle: ChatActivityLifecycle,
        title: String,
        summary: String?
    ) -> ChatActivityEvent {
        ChatActivityEvent(
            eventID: "event_live_activity_0001",
            sessionID: "session_live_activity_0001",
            turnID: "turn_live_0001",
            kind: kind,
            lifecycle: lifecycle,
            title: title,
            summary: summary,
            detail: nil,
            occurredAt: 1_788_000_001,
            durationMilliseconds: nil,
            toolCallID: kind == .tool ? "tool_live_activity_0001" : nil,
            subagentID: kind == .subagent ? "subagent_live_activity_0001" : nil,
            botRunID: kind == .botHandoff ? "bot_live_activity_0001" : nil,
            memberID: kind == .botHandoff ? "member_live_activity_0001" : nil
        )
    }
}
