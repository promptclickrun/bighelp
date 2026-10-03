import Foundation
import Testing
@testable import Bighelp

/// The chat's adapters from real activity events to the shared activity row.
@MainActor
struct ChatActivityPresentationTests {
    private func tool(_ id: String, name: String? = nil, title: String = "Tool", lifecycle: ChatActivityLifecycle = .succeeded,
                      arguments: String? = nil, ms: Int? = nil, turn: String = "turn", order: Int? = nil) -> ChatActivityEvent {
        ChatActivityEvent(eventID: id, sessionID: "session", turnID: turn, kind: .tool, lifecycle: lifecycle,
                          title: title, summary: "server summary", detail: "server detail", occurredAt: 1,
                          durationMilliseconds: ms, toolCallID: "call-\(id)", toolName: name, arguments: arguments,
                          sourceOrder: order)
    }

    private func thought(_ id: String, lifecycle: ChatActivityLifecycle = .succeeded, ms: Int? = 2_000,
                         turn: String = "turn", order: Int? = nil) -> ChatActivityEvent {
        ChatActivityEvent(eventID: id, sessionID: "session", turnID: turn, kind: .reasoning, lifecycle: lifecycle,
                          title: "Reasoning", summary: nil, detail: "Thinking about \(id)", occurredAt: 1,
                          durationMilliseconds: ms, sourceOrder: order)
    }

    @Test func toolCallsUnwrapToTheNestedToolBeforeTheCatalog() {
        let wrapped = tool("wrapped", name: "tool_call", lifecycle: .running,
                           arguments: #"{"name":"web_search","arguments":{"query":"ryokan near Gion"}}"#)
        #expect(wrapped.canonicalToolName == "web_search")
        let step = ChatActivityPresentation.step(for: wrapped)
        #expect(step.label == "Searching the web…")
        #expect(step.glyph == BighelpToolActivityCatalog.activity(forTool: "web_search").glyph)
        #expect(step.isRunning)
        // The arguments never reach the collapsed line.
        #expect(step.detail == nil)
        #expect(!wrapped.collapsedAccessibilityLabel(status: nil).contains("Gion"))

        // A wrapper without a usable nested name says nothing it can't prove.
        let unnamed = tool("unnamed", name: "tool_call", arguments: #"{"name":"has spaces; rm"}"#)
        #expect(unnamed.canonicalToolName == nil)
        #expect(unnamed.presentationTitle == "Used tools")
    }

    @Test func finishedStepsUsePastTenseAndRealDurationsOnly() {
        let read = ChatActivityPresentation.step(for: tool("read", name: "read_file", ms: 820))
        #expect(read.label == "Read a file")
        #expect(read.meta == "0.8s")
        #expect(!read.isRunning)
        #expect(ChatActivityPresentation.step(for: tool("slow", name: "terminal", ms: 75_000)).meta == "1m 15s")
        #expect(ChatActivityPresentation.step(for: tool("untimed", name: "terminal")).meta == nil)
        #expect(ChatActivityPresentation.step(for: tool("instant", name: "terminal", ms: 40)).meta == nil)
        #expect(ChatActivityPresentation.step(for: tool("bogus", name: "terminal", ms: -5)).meta == nil)
        let failed = ChatActivityPresentation.step(for: tool("failed", name: "terminal", lifecycle: .failed, ms: 900))
        #expect(failed.meta == "Failed")
        #expect(failed.metaIsFailure)
        // An unknown tool keeps its own (sanitized) name beside "Used tools".
        let custom = ChatActivityPresentation.step(for: tool("custom", name: "acme_sync_ledger"))
        #expect(custom.label == "Used tools")
        #expect(custom.detail == "acme_sync_ledger")
    }

    @Test func aTrailNamesItsNewestRunningCallThenHowItEnded() {
        let running = [tool("a", name: "read_file"), tool("b", name: "browser_navigate", lifecycle: .running)]
        #expect(ChatActivityPresentation.trailPhase(for: running)
                == .working(BighelpToolActivityCatalog.activity(forTool: "browser_navigate")))
        // Finished: what it did, never a bare "Done".
        #expect(ChatActivityPresentation.trailPhase(for: [tool("a", name: "read_file")]) == .finished("Read a file"))
        #expect(ChatActivityPresentation.trailPhase(for: [tool("a", name: "read_file", lifecycle: .failed)]) == .failed)
        #expect(ChatActivityPresentation.trailPhase(for: [tool("a", name: "read_file", lifecycle: .cancelled)]) == .stopped)
        // A failure the agent recovered from isn't how the run ended.
        #expect(ChatActivityPresentation.trailPhase(for: [
            tool("a", name: "terminal", lifecycle: .failed), tool("b", name: "terminal"),
        ]) == .finished("Ran 2 commands"))
        #expect(ChatActivityPresentation.stepCount(of: running + [thought("r")]) == 2)
    }

    @Test func aLiveTrailWaitsOnTheApprovalOrAnswerHermesAskedFor() {
        let running = [tool("t", name: "terminal", lifecycle: .running)]
        #expect(ChatActivityPresentation.trailPhase(for: running, waiting: .approval)
                == .waitingForApproval(label: "Waiting for your yes"))
        #expect(BighelpActivitySummary.label(for: ChatActivityPresentation.trailPhase(for: running, waiting: .answer))
                == "Waiting for your answer")
        // A finished trail never waits.
        #expect(ChatActivityPresentation.trailPhase(for: [tool("t", name: "terminal")], waiting: .approval)
                == .finished("Ran a command"))
        // Hermes' requests decide; with none, only a running secure input request waits.
        #expect(ChatActivityWaiting.resolve(prompts: [], events: running) == nil)
        let secure = tool("s", name: "bighelp_request_secure_input", lifecycle: .running)
        #expect(ChatActivityWaiting.resolve(prompts: [], events: [secure]) == .secureInput)
        let legacySecure = tool("l", name: "loopdy_request_secure_input", lifecycle: .running)
        #expect(ChatActivityWaiting.resolve(prompts: [], events: [legacySecure]) == .secureInput)
        #expect(ChatActivityWaiting.resolve(prompts: [], events: [tool("s", name: "bighelp_request_secure_input")]) == nil)
    }

    @Test func thinkingSettlesIntoItsRecordedTotal() {
        #expect(ChatActivityPresentation.thinkingPhase(for: [thought("a"), thought("b", lifecycle: .running)]) == .thinking)
        let finished = ChatActivityPresentation.thinkingPhase(for: [thought("a", ms: 2_500), thought("b", ms: 4_000)])
        #expect(BighelpActivitySummary.label(for: finished) == "Thought for 6s")
        #expect(BighelpActivitySummary.label(for: ChatActivityPresentation.thinkingPhase(for: [thought("a", ms: 400)]))
                == "Thought process")
        #expect(BighelpActivitySummary.label(for: ChatActivityPresentation.thinkingPhase(for: [thought("a", ms: 95_000)]))
                == "Thought for 1m 35s")
        #expect(ChatActivityPresentation.thinkingNote(for: [thought("a"), thought("b")])
                == "Thinking about a\n\nThinking about b")
    }

    @Test func theWatchHearsTheNewestRunningWorkInPlainWords() {
        #expect(ChatActivityPresentation.liveLabel(for: []) == nil)
        #expect(ChatActivityPresentation.liveLabel(for: [tool("a", name: "read_file")]) == nil)
        #expect(ChatActivityPresentation.liveLabel(for: [thought("r", lifecycle: .running)]) == "Thinking")
        #expect(ChatActivityPresentation.liveLabel(for: [
            thought("r", lifecycle: .running), tool("a", name: "web_search", lifecycle: .running),
        ]) == "Searching the web…")
        #expect(ChatActivityPresentation.liveLabel(for: [tool("x", name: "secret_internal_tool", lifecycle: .running)])
                == "Using tools…")
    }

    /// The fold counts the turn's real steps, including tool calls the chat
    /// hides with Show tool calls off, but never thinking or generated pictures.
    @Test func aFinishedTurnCountsItsStepsIncludingHiddenWork() {
        let human = TimelineItem(id: "q", role: .human, sender: .user(snapshot: .init(name: "You")),
                                 content: .message("Plan the trip"), metadata: .init(sourceOrder: 10))
        let answer = TimelineItem(id: "a", role: .assistant, sender: .agent(id: "a", snapshot: .init(name: "Avery")),
                                  content: .message("Here's the plan."),
                                  metadata: .init(sourceOrder: 60, turnDurationMilliseconds: 14_000))
        let shownThinking = thought("r", order: 20)
        let hiddenTools = [tool("t1", name: "web_search", order: 30), tool("t2", name: "read_file", order: 40)]
        let picture = tool("img", name: "image_generate", order: 50)
        let rows = ChatCompletedTurnProjection.rows(
            from: [.message(human), .activity(ChatActivityTurn(id: "turn", events: [shownThinking])), .message(answer)],
            isSending: false, enabled: true, activityEvents: [shownThinking] + hiddenTools + [picture]
        )
        guard case .completed(let fold)? = rows.first(where: { if case .completed = $0 { true } else { false } }) else {
            Issue.record("Missing fold")
            return
        }
        #expect(fold.stepCount == 2)
        #expect(fold.label == "Worked for 14s")
        #expect(BighelpActivitySummary.stepCountLabel(fold.stepCount) == "· 2 steps")
    }
}
