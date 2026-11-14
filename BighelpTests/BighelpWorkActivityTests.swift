import Foundation
import Testing
@testable import Bighelp

struct BighelpWorkActivityTests {
    @Test func duplicateChildrenAndUnknownStopsDoNotChangeCounts() {
        var owner = BighelpLiveActivityWorkReducer()
        let start = event(id: "child-a", turn: "turn-a", lifecycle: .running)
        let accepted = owner.accept(start)
        let duplicate = owner.accept(start)
        let unknown = owner.accept(event(id: "child-b", turn: "turn-a", lifecycle: .succeeded))
        #expect(accepted && !duplicate && !unknown)
        let state = owner.project(previous: initial, agentName: "Agent", timestamp: 100)
        #expect(state.activeSubagentCount == 1)
        #expect(state.completedSteps == 0)
    }

    @Test func parentFinalKeepsChildrenUntilTheirExactCompletion() {
        var owner = BighelpLiveActivityWorkReducer()
        _ = owner.accept(event(id: "child-a", turn: "turn-a", lifecycle: .running))
        _ = owner.finish(turnID: "turn-a", outcome: .succeeded)
        let pending = owner.project(previous: initial, agentName: "Agent", timestamp: 101)
        #expect(pending.phase == .delegating)
        #expect(pending.currentAction == "Response ready")
        _ = owner.accept(event(id: "child-a", turn: "turn-a", lifecycle: .succeeded, timestamp: 102))
        let done = owner.project(previous: pending, agentName: "Agent", timestamp: 102)
        #expect(done.phase == .completed)
        #expect(done.completedSteps == 1)
        let replay = owner.accept(event(id: "child-a", turn: "turn-a", lifecycle: .running, timestamp: 103))
        #expect(!replay)
    }

    @Test func olderTurnCannotFinishNewTurnAndUnknownStopIsNotSuccess() {
        var owner = BighelpLiveActivityWorkReducer()
        _ = owner.accept(event(id: "child-a", turn: "turn-a", lifecycle: .running))
        _ = owner.accept(event(id: "child-b", turn: "turn-b", lifecycle: .running, timestamp: 101))
        _ = owner.finish(turnID: "turn-a", outcome: .succeeded)
        let active = owner.project(previous: initial, agentName: "Agent", timestamp: 102)
        #expect(!active.phase.isTerminal)
        #expect(active.activeSubagentCount == 2)
        #expect(owner.legacyFinishTurnID == nil)
        _ = owner.accept(event(id: "child-a", turn: "turn-a", lifecycle: .failed, timestamp: 102))
        let afterFailure = owner.project(previous: active, agentName: "Agent", timestamp: 102)
        #expect(!afterFailure.phase.isTerminal)
        #expect(afterFailure.activeSubagentCount == 1)
        #expect(afterFailure.completedSteps == 0)
    }

    @Test func restoredRosterNeedsAuthoritativeReconciliation() {
        var owner = BighelpLiveActivityWorkReducer(restoredChildCount: 2)
        _ = owner.accept(event(id: "child-a", turn: "turn-a", lifecycle: .running, timestamp: 110))
        let uncertain = owner.project(previous: initial, agentName: "Agent", timestamp: 110)
        #expect(uncertain.activeSubagentCount == 2)
        #expect(uncertain.timestamp == 100)
        let reconciled = owner.reconcile(turnID: "turn-a", children: [], timestamp: 111)
        #expect(reconciled)
        let known = owner.project(previous: uncertain, agentName: "Agent", timestamp: 111)
        #expect(known.activeSubagentCount == 0)
        #expect(known.completedSteps == 0)
        #expect(!known.phase.isTerminal)
    }

    @Test func staleAndMaliciousDisplayTextNeverBecomeLockScreenCopy() throws {
        let attrs = LoopdySessionActivityAttributes(sessionID: "session", sessionTitle: "PRIVATE TITLE",
            agentID: "agent", agentName: "Agent")
        let state = LoopdySessionActivityAttributes.ContentState(phase: .usingTool, currentAction: "PRIVATE PROMPT",
            progress: 85, completedSteps: 9, activeSubagentCount: 2, latestTool: "PRIVATE COMMAND", timestamp: 100)
        let normal = BighelpActivityPresentation(attributes: attrs, state: state, isStale: false)
        #expect(normal.status == "Working")
        #expect(normal.detail == "2 bots still working")
        #expect(!normal.accessibilityLabel.contains("PRIVATE"))
        let stale = BighelpActivityPresentation(attributes: attrs, state: state, isStale: true)
        #expect(stale.status == "Updates paused")
        #expect(!stale.accessibilityLabel.contains("PRIVATE"))
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == Set(["phase", "currentAction", "progress", "completedSteps", "activeSubagentCount", "latestTool", "timestamp"]))
    }

    private var initial: LoopdySessionActivityAttributes.ContentState { .initial(agentName: "Agent", timestamp: 100) }
    private func event(id: String, turn: String, lifecycle: ChatActivityLifecycle, timestamp: Int = 100) -> ChatActivityEvent {
        ChatActivityEvent(eventID: id, sessionID: "session", turnID: turn, kind: .subagent,
                          lifecycle: lifecycle, title: "Private child purpose", summary: nil, detail: nil,
                          occurredAt: timestamp, subagentID: id)
    }
}
