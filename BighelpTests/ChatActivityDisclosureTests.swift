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

    @Test func activeTurnDefaultsExpandParentFoldersButNotIndividualTools() {
        let store = ChatActivityDisclosureStore()
        store.configureActiveTurn(isSending: true, turnID: "active-turn",
                                  expandReasoning: true, expandToolCalls: true)

        let activeReasoning = reasoning("active-reasoning", turnID: "active-turn", lifecycle: .succeeded)
        let earlierReasoning = reasoning("earlier-reasoning", turnID: "earlier-turn", lifecycle: .succeeded)
        #expect(store.isExpanded(reasoning: [activeReasoning]))
        #expect(!store.isExpanded(reasoning: [earlierReasoning]))

        let liveTool = event("active-tool", lifecycle: .succeeded)
        let activeTool = ChatActivityEvent(eventID: liveTool.eventID, sessionID: liveTool.sessionID,
                                           turnID: "active-turn", kind: .tool, lifecycle: .succeeded,
                                           title: liveTool.title, summary: nil, detail: nil,
                                           occurredAt: liveTool.occurredAt, toolCallID: liveTool.toolCallID,
                                           toolName: liveTool.toolName, arguments: liveTool.arguments,
                                           result: liveTool.result)
        let trail = ChatActivityTurn(id: "active-trail", events: [activeTool])
        #expect(store.isExpanded(trail, isLive: false))
        #expect(!store.isExpanded(activeTool), "The parent setting does not open individual tool details")

        let earlierTool = ChatActivityEvent(eventID: "earlier-tool", sessionID: "session",
                                            turnID: "earlier-turn", kind: .tool, lifecycle: .succeeded,
                                            title: "Tool", summary: nil, detail: nil, occurredAt: 1,
                                            toolCallID: "earlier-call", toolName: "terminal")
        let earlierTrail = ChatActivityTurn(id: "earlier-trail", events: [earlierTool])
        #expect(!store.isExpanded(earlierTrail, isLive: false))
    }

    @Test func activeTurnDefaultsPreserveManualOverridesAndCompletion() {
        let store = ChatActivityDisclosureStore()
        store.configureActiveTurn(isSending: true, turnID: "active-turn",
                                  expandReasoning: true, expandToolCalls: true)

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

        store.configureActiveTurn(isSending: false, turnID: nil,
                                  expandReasoning: true, expandToolCalls: true)
        #expect(!store.isExpanded(trail, isLive: false))
        #expect(!store.isExpanded(reasoning: [reasoning("finished-reasoning", turnID: "active-turn",
                                                        lifecycle: .succeeded)]))

        let simpleBotReasoning = ChatInterimReasoning(
            id: "simple-bot-active", agentName: "Avery", entries: [], isLive: true
        )
        let simpleBotStore = ChatActivityDisclosureStore()
        simpleBotStore.configureActiveTurn(isSending: true, turnID: "active-turn",
                                           expandReasoning: true, expandToolCalls: false)
        #expect(simpleBotStore.isExpanded(simpleBotReasoning))
        simpleBotStore.setExpanded(false, for: simpleBotReasoning)
        #expect(!simpleBotStore.isExpanded(simpleBotReasoning))
        let finishedSimpleBotReasoning = ChatInterimReasoning(
            id: "simple-bot-finished", agentName: "Avery", entries: [], isLive: false
        )
        #expect(!simpleBotStore.isExpanded(finishedSimpleBotReasoning))
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
