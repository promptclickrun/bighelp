import Foundation
import Testing
@testable import Bighelp

@MainActor
struct RecordedActivityTests {
    @Test func recordedToolRemainsActivityAndCannotBecomeAssistantOrVoiceReply() {
        let model = ChatModel(conversationID: "recorded-session",
                              client: ConversationFixtureClient(), initialItems: [])
        _ = model.acceptActivity(event)
        #expect(model.items.isEmpty)
        #expect(!model.isSending)
        #expect(model.activityLedger.allEvents.first?.result == "Original tool result")
        #expect(model.activityLedger.allEvents.first?.lifecycle == .recorded)
    }

    @Test func recordedEvidenceIsNeitherRunningNorKnownTerminalSuccess() {
        #expect(!ChatActivityLifecycle.recorded.isTerminal)
        let visual = ChatActivityVisualState(lifecycle: .recorded)
        #expect(visual.tone == .secondary)
        #expect(!visual.shimmers)
        let phase = ChatActivityPresentation.trailPhase(for: [event])
        #expect(phase == .finished("Ran a command"))
        #expect(!phase.isLive)
        #expect(!ChatActivityPresentation.step(for: event).isRunning)
        let record = SessionRecord(id: "recorded-session", kind: .direct, agentIDs: ["default"],
                                   title: "Saved", activityEvents: [event])
        #expect(SessionSubagentDetailPresentation.statusTitle(for: record) == "Saved child session; outcome unavailable")
    }

    @Test func recordedHistoryCannotStartOrCompleteLiveActivityWork() {
        var reducer = BighelpLiveActivityWorkReducer()
        let accepted = reducer.accept(event)
        #expect(!accepted)
        #expect(reducer.turnIDs.isEmpty)
        #expect(!reducer.isCurrentParentActive)
    }

    @Test func recordedStateRoundTripsOnlyInLocalTypedStorageAndLegacyWireRejectsIt() throws {
        #expect(try JSONDecoder().decode(ChatActivityEvent.self, from: JSONEncoder().encode(event)) == event)
        let wire: [String: Any] = [
            "version": 1, "type": "activity.event", "eventId": "event_recorded_0001",
            "sessionId": "session_recorded_0001", "turnId": "turn_recorded_001",
            "kind": "tool", "lifecycle": "recorded", "title": "Saved tool",
            "occurredAt": 123, "toolCallId": "call_recorded_0001",
        ]
        #expect(throws: BighelpLinkWireError.invalidValue) { try BighelpLinkActivityEvent.decode(wire) }
    }

    private var event: ChatActivityEvent {
        ChatActivityEvent(eventID: "stored-row-42", sessionID: "recorded-session", turnID: "stored-turn",
                          kind: .tool, lifecycle: .recorded, title: "Recorded tool",
                          summary: "Outcome unavailable", detail: nil, occurredAt: 123,
                          toolCallID: "actual-call-id", toolName: "terminal",
                          arguments: "Original arguments", result: "Original tool result", sourceOrder: 1)
    }
}
