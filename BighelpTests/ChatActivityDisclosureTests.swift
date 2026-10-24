import Testing
@testable import Bighelp

@MainActor
struct ChatActivityDisclosureTests {
    private func event(_ id: String = "live-event", session: String = "session", call: String = "call", lifecycle: ChatActivityLifecycle = .running) -> ChatActivityEvent {
        ChatActivityEvent(eventID: id, sessionID: session, turnID: "turn", kind: .tool,
                          lifecycle: lifecycle, title: "Tool", summary: nil, detail: nil,
                          occurredAt: 1, toolCallID: call, toolName: "terminal",
                          arguments: "{\"command\":\"pwd\"}", result: lifecycle == .running ? nil : "complete")
    }

    private func reasoning(_ id: String, turnID: String, lifecycle: ChatActivityLifecycle = .running) -> ChatActivityEvent {
        ChatActivityEvent(eventID: id, sessionID: "session", turnID: turnID, kind: .reasoning,
                          lifecycle: lifecycle, title: "Thinking", summary: nil, detail: "Thought \(id)",
                          occurredAt: 1)
    }

    /// Full (`ChatWorkStyle`) opens every folder and thought, in every turn, but never a tool's own details.
    @Test func fullOpensFoldersAndThoughtsButNotIndividualTools() {
        let store = ChatActivityDisclosureStore()
        store.configure(style: .full)

        #expect(store.isExpanded(reasoning: [reasoning("finished-reasoning", turnID: "earlier-turn", lifecycle: .succeeded)]))
        let tool = event("finished-tool", lifecycle: .succeeded)
        let trail = ChatActivityTurn(id: "finished-trail", events: [tool])
        #expect(store.isExpanded(trail, isLive: false))
        #expect(!store.isExpanded(tool), "Full does not open individual tool details")
    }

    @Test func fullKeepsTheReadersChoicesAndOtherStylesStartClosed() {
        let store = ChatActivityDisclosureStore()
        store.configure(style: .full)

        let reasoningEvent = reasoning("manual-reasoning", turnID: "active-turn")
        store.setExpanded(false, reasoning: [reasoningEvent])
        #expect(!store.isExpanded(reasoning: [reasoningEvent]))

        let tool = ChatActivityEvent(eventID: "manual-tool", sessionID: "session",
                                     turnID: "active-turn", kind: .tool, lifecycle: .running,
                                     title: "Tool", summary: nil, detail: nil, occurredAt: 1,
                                     toolCallID: "manual-call", toolName: "terminal")
        let trail = ChatActivityTurn(id: "manual-trail", events: [tool])
        store.setExpanded(false, for: trail)
        #expect(!store.isExpanded(trail, isLive: true))

        for style in [ChatWorkStyle.card, .minimal, nil] {
            store.configure(style: style)
            #expect(!store.isExpanded(ChatActivityTurn(id: "other", events: [event("other", call: "other",
                                                                                   lifecycle: .succeeded)])))
            #expect(!store.isExpanded(reasoning: [reasoning("finished-reasoning", turnID: "active-turn",
                                                            lifecycle: .succeeded)]))
        }
    }

    @Test func explicitChoiceSurvivesLifecycleAndCanonicalEventReplacement() {
        let store = ChatActivityDisclosureStore()
        let running = event()
        let finished = event("canonical-event", lifecycle: .succeeded)
        store.setExpanded(true, for: running)
        #expect(store.isExpanded(finished))
        store.setExpanded(false, for: finished)
        #expect(!store.isExpanded(running))
        #expect(!store.isExpanded(event(session: "different")))
        #expect(!store.isExpanded(event(call: "different")))
        #expect(!ChatActivityDisclosureStore().isExpanded(finished))
    }

    @Test func parentRecreationAndRegroupingKeepIndependentReaderChoices() {
        let store = ChatActivityDisclosureStore()
        let first = event()
        let second = event("event-two", call: "two")
        let original = ChatActivityTurn(id: "original", events: [first, second])
        store.setExpanded(true, for: original)
        store.setExpanded(true, for: first)
        store.setExpanded(false, for: second)
        let regrouped = ChatActivityTurn(id: "different-segment", events: [event("canonical-event", lifecycle: .succeeded)])
        #expect(store.isExpanded(regrouped))
        #expect(store.isExpanded(first))
        #expect(!store.isExpanded(second))
        store.setExpanded(false, for: original)
        #expect(!store.isExpanded(original))
        #expect(store.isExpanded(first), "Closing the parent does not silently close a tool")
        store.setExpanded(true, for: original)
        #expect(store.isExpanded(first))
        #expect(!store.isExpanded(second))
    }
}
