import Foundation

/// What a live turn is paused on, from Hermes' own requests to the person.
enum ChatActivityWaiting: Equatable, Sendable {
    /// An approval the person hasn't answered.
    case approval
    /// A question (clarify) the person hasn't answered.
    case answer
    /// The agent asked for a password or key through secure input.
    case secureInput

    var label: String {
        switch self {
        case .approval: "Waiting for your yes"
        case .answer: "Waiting for your answer"
        case .secureInput: "Waiting for your secure input"
        }
    }

    /// The most pressing wait: an approval first, then a question; a secure
    /// input request is known from its running tool.
    static func resolve(prompts: [DirectHermesPrompt], events: [ChatActivityEvent]) -> Self? {
        if prompts.contains(where: { $0.kind == .approval }) { return .approval }
        if prompts.contains(where: { $0.kind == .clarification }) { return .answer }
        let asksForSecureInput = events.contains {
            $0.lifecycle == .running && $0.canonicalToolName.map(ChatActivityPresentation.isSecureInputTool) == true
        }
        return asksForSecureInput ? .secureInput : nil
    }
}

/// Turns the chat's real activity events into the shared activity row's
/// phases and steps. Every word and number comes from the events: no time
/// estimates and no invented step names.
enum ChatActivityPresentation {
    /// One tool call (or helper agent) as a step line.
    static func step(for event: ChatActivityEvent) -> BighelpActivityStep {
        let outcome: String? = switch event.lifecycle {
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .running, .recorded: nil
        case .succeeded: duration(event.durationMilliseconds)
        }
        let phrase = event.toolPhrase
        let label = event.lifecycle == .running ? phrase.live : phrase.past
        // The detail names what the words don't already ("Running tests…  swift").
        let detail = event.presentationDetail.flatMap { label.contains($0) ? nil : $0 }
        return BighelpActivityStep(
            id: event.id,
            glyph: event.presentationActivity.glyph,
            label: label,
            detail: detail,
            meta: outcome,
            isRunning: event.lifecycle == .running,
            metaIsFailure: event.lifecycle == .failed
        )
    }

    /// A recorded duration, as the row shows it: "0.8s", "14s", "2m 5s".
    static func duration(_ milliseconds: Int?) -> String? {
        // Under a tenth of a second reads as "0.0s"; it says nothing worth a glance.
        guard let milliseconds, (100..<86_400_000).contains(milliseconds) else { return nil }
        if milliseconds < 10_000 {
            return String(format: "%.1fs", Double(milliseconds) / 1_000)
        }
        let seconds = milliseconds / 1_000
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    /// Where a folder of tool calls is. Running: the newest running call in
    /// plain words ("Reading notes.md…"), or what the turn waits on. Live
    /// between calls (`isLive`, the folder is still the turn's newest work):
    /// thinking. Ended: what it did ("Read 2 files, ran tests"), or how it
    /// ended when that went wrong. It never says "Done" while the agent works.
    static func trailPhase(for events: [ChatActivityEvent], waiting: ChatActivityWaiting? = nil,
                           isLive: Bool = false) -> BighelpActivityPhase {
        if let running = events.last(where: { $0.lifecycle == .running }) {
            if let waiting { return .waitingForApproval(label: waiting.label) }
            let phrase = running.toolPhrase
            return .working(BighelpToolActivity(glyph: running.presentationActivity.glyph,
                                                label: phrase.live, doneLabel: phrase.past))
        }
        if isLive { return .thinking }
        switch events.last?.lifecycle {
        case .failed: return .failed
        case .cancelled: return .stopped
        default: return .finished(ChatToolSummary.summary(of: events) ?? BighelpToolActivityCatalog.fallback.doneLabel)
        }
    }

    /// Back-to-back thinking: live while any of it runs, then its recorded total
    /// ("Thought for 6s") once every entry has a time.
    static func thinkingPhase(for events: [ChatActivityEvent]) -> BighelpActivityPhase {
        if events.contains(where: { $0.lifecycle == .running }) { return .thinking }
        switch events.last?.lifecycle {
        case .failed: return .failed
        case .cancelled: return .stopped
        default: break
        }
        let durations = events.compactMap(\.durationMilliseconds).filter { (0..<86_400_000).contains($0) }
        guard durations.count == events.count, !durations.isEmpty else { return .thought(elapsed: nil) }
        return .thought(elapsed: TimeInterval(durations.reduce(0, +)) / 1_000)
    }

    /// The thinking text the agent shared, each entry its own paragraph.
    static func thinkingNote(for events: [ChatActivityEvent]) -> String? {
        let lines = events.compactMap(\.reasoningText)
        return lines.isEmpty ? nil : lines.joined(separator: "\n\n")
    }

    /// The steps work counts: tool calls and helper agents, not thinking.
    static func stepCount(of events: [ChatActivityEvent]) -> Int {
        events.count { $0.kind == .tool || $0.kind == .subagent }
    }

    /// The words for what the agent is doing right now, for places that show
    /// one line (the Watch): the newest running tool, else thinking.
    static func liveLabel(for events: [ChatActivityEvent]) -> String? {
        let running = events.filter { $0.lifecycle == .running && $0.isPresentable }
        if let tool = running.last(where: { $0.kind == .tool || $0.kind == .subagent }) {
            return tool.toolPhrase.live
        }
        return running.contains { $0.kind == .reasoning } ? BighelpToolActivityCatalog.thinking.label : nil
    }

    static func isSecureInputTool(_ name: String) -> Bool {
        ["bighelp_request_secure_input", "loopdy_request_secure_input"].contains(name)
    }
}
