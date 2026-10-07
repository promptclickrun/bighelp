import Foundation
import Testing
@testable import Bighelp

/// Voice mode's status line: the agent's own current step in plain words, one at a
/// time, held long enough to read.
@MainActor
struct VoiceStepLineTests {
    @Test func theLineNamesTheAgentsOwnRunningStep() {
        let model = ChatModel(conversationID: "voice-steps", client: ConversationFixtureClient(), initialItems: [])
        #expect(model.liveStepPhrase == nil, "Nothing while no turn runs")
        model.beginExternallyOwnedTurn(with: human("What's on tomorrow?"))
        #expect(model.isSending)
        #expect(model.liveStepPhrase == nil, "Thinking isn't a step")

        let calendar = tool("calendar", name: "mcp_google_calendar_list_events", arguments: #"{"day":"tomorrow"}"#)
        model.acceptActivity(calendar)
        #expect(model.liveStepPhrase == "Checking your calendars…")

        let clone = tool("clone", name: "terminal",
                         arguments: #"{"command":"git clone https://github.com/example/weather-app"}"#)
        model.acceptActivity(clone)
        #expect(model.liveStepPhrase == "Cloning weather-app…", "The newest step replaces the last")

        model.acceptActivity(clone.updating(lifecycle: .succeeded, summary: nil, detail: nil, occurredAt: 3))
        #expect(model.liveStepPhrase == "Checking your calendars…", "Back to the step still running")
        model.acceptActivity(calendar.updating(lifecycle: .succeeded, summary: nil, detail: nil, occurredAt: 4))
        #expect(model.liveStepPhrase == nil)
    }

    @Test func aHelpersOwnStepsStayInsideItsFolder() {
        let model = ChatModel(conversationID: "voice-steps", client: ConversationFixtureClient(), initialItems: [])
        model.beginExternallyOwnedTurn(with: human("Find me a route"))
        model.acceptActivity(ChatActivityEvent(eventID: "helper", sessionID: "voice-steps", turnID: "turn",
            kind: .subagent, lifecycle: .running, title: "Compare routes", summary: nil, detail: nil,
            occurredAt: 1, subagentID: "helper-1"))
        #expect(model.liveStepPhrase == "Asking another agent…")
        model.acceptActivity(tool("helper-read", name: "read_file", arguments: #"{"path":"routes.md"}"#,
                                  subagentID: "helper-1"))
        #expect(model.liveStepPhrase == "Asking another agent…", "The helper's file read isn't the agent's step")
    }

    @Test func eachStepStaysLongEnoughToReadAndGapsDontBlink() {
        let dwell = VoiceStepLine.minimumDwell
        #expect(VoiceStepLine.delay(showing: "Checking the weather…", current: nil, shownFor: 0) == 0,
                "The first step shows at once")
        #expect(VoiceStepLine.delay(showing: "Cloning weather-app…", current: "Checking the weather…",
                                    shownFor: 0.2) == dwell - 0.2, "A quick step waits its turn")
        #expect(VoiceStepLine.delay(showing: "Cloning weather-app…", current: "Checking the weather…",
                                    shownFor: 5) == 0)
        #expect(VoiceStepLine.delay(showing: nil, current: "Checking the weather…", shownFor: 5)
                == VoiceStepLine.gapGrace, "Between steps the line waits before it clears")
        #expect(VoiceStepLine.delay(showing: "Same", current: "Same", shownFor: 0) == 0)
    }

    private func human(_ text: String) -> TimelineItem {
        TimelineItem(id: "voice-user-\(UUID().uuidString.lowercased())", role: .human,
                     sender: .user(snapshot: .init(name: "You")), content: .message(text),
                     metadata: .init(source: "Voice", delivery: "Sent"))
    }

    private func tool(_ id: String, name: String, arguments: String?, subagentID: String? = nil) -> ChatActivityEvent {
        ChatActivityEvent(eventID: id, sessionID: "voice-steps", turnID: "turn", kind: .tool, lifecycle: .running,
                          title: name, summary: nil, detail: nil, occurredAt: 1, toolCallID: "call-\(id)",
                          toolName: name, arguments: arguments, subagentID: subagentID)
    }
}
