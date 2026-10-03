import Foundation

/// One helper agent (a Hermes `delegate_task` child) as its canvas shows it.
///
/// Two real sources feed it. The parent chat's `subagent.*` events arrive the
/// moment they happen, but carry only a tool's name and short preview, the
/// child's thinking snippets (when the host shows reasoning) and its final
/// summary. The child's own saved session, read once it lands, has every call
/// with its real arguments and result, and its messages. The canvas shows the
/// saved record and adds only the live steps that are newer than it, matched by
/// the child's own tool count. Nothing is guessed: a step that hasn't been
/// reported isn't shown, and a finished child isn't called a success unless
/// Hermes said so.
struct SubagentCanvasState: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Hermes accepted the task; the helper hasn't started.
        case waiting
        case working
        case done
        case failed
        case stopped
        /// Finished without a reported outcome.
        case finished
    }

    struct LiveStep: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case tool(name: String, preview: String?)
            case thinking(String)
        }

        let key: String
        /// The child's 1-based tool number for a call; for thinking, how many
        /// calls it had started by then.
        let toolIndex: Int
        let kind: Kind
        let order: Int
    }

    static let maximumGoalLength = 4_000
    static let maximumPreviewLength = 400
    static let maximumThinkingLength = 2_000
    static let maximumSummaryLength = 4_000
    static let maximumLiveTextLength = 16_000
    static let maximumLiveSteps = 200
    static let maximumFiles = 40

    let id: String
    private(set) var childSessionID: String?
    private(set) var goal: String
    private(set) var model: String?
    private(set) var lifecycle: ChatActivityLifecycle = .running
    private(set) var hasStarted = false
    private(set) var isFinished = false
    private(set) var toolCount = 0
    private(set) var summary: String?
    private(set) var failureReason: String?
    private(set) var durationSeconds: Double?
    private(set) var filesWritten: [String] = []
    private(set) var liveSteps: [LiveStep] = []
    /// The child's reply as it streams, from hosts that relay it to the parent.
    private(set) var liveText = ""
    private(set) var history: SubagentCanvasHistory?
    /// The saved record was read after the helper finished, so it's complete.
    private(set) var historyIsFinal = false
    /// When the ledger first heard of this helper; orders the list.
    let arrival: Int
    private var stepArrivals = 0

    init(id: String, goal: String = "", childSessionID: String? = nil, arrival: Int) {
        self.id = id
        self.goal = Self.bounded(goal, Self.maximumGoalLength)
        self.childSessionID = childSessionID
        self.arrival = arrival
    }

    var phase: Phase {
        guard isFinished else { return hasStarted || !liveSteps.isEmpty || history != nil ? .working : .waiting }
        return switch lifecycle {
        case .succeeded: .done
        case .failed: .failed
        case .cancelled: .stopped
        case .running, .recorded: .finished
        }
    }

    // MARK: Live events

    /// Applies one parent-stream `subagent.*` event. Unknown event types and
    /// fields only refresh the helper's identity; they never add a step.
    mutating func apply(type: String, payload: [String: BighelpJSONValue]) {
        if let goal = Self.text(payload["goal"]), goal != "Subagent task" {
            self.goal = Self.bounded(goal, Self.maximumGoalLength)
        }
        if let child = Self.identifier(payload["child_session_id"]) { childSessionID = child }
        if let model = Self.identifier(payload["model"]) { self.model = model }
        let reportedCount = payload["tool_count"]?.integer.flatMap { (0...100_000).contains($0) ? $0 : nil }
        switch type {
        case "subagent.spawn_requested":
            break
        case "subagent.start":
            hasStarted = true
        case "subagent.tool":
            hasStarted = true
            let name = Self.identifier(payload["tool_name"]) ?? "tool"
            let preview = (Self.text(payload["tool_preview"]) ?? Self.text(payload["text"]))
                .map { Self.bounded($0, Self.maximumPreviewLength) }
            let index = reportedCount.flatMap { $0 > 0 ? $0 : nil } ?? toolCount + 1
            let key = "tool:\(index)"
            if !isFinished, !liveSteps.contains(where: { $0.key == key }) {
                appendStep(.init(key: key, toolIndex: index, kind: .tool(name: name, preview: preview),
                                 order: nextStepOrder()))
            }
            toolCount = max(toolCount, index)
        case "subagent.thinking":
            hasStarted = true
            // Hosts that hide reasoning send the frame without its text.
            guard !isFinished, let text = Self.text(payload["text"]) else { break }
            let bounded = Self.bounded(text, Self.maximumThinkingLength)
            let index = reportedCount ?? toolCount
            if !liveSteps.contains(where: { $0.toolIndex == index && $0.kind == .thinking(bounded) }) {
                appendStep(.init(key: "thinking:\(index):\(stepArrivals + 1)", toolIndex: index,
                                 kind: .thinking(bounded), order: nextStepOrder()))
            }
        case "subagent.text":
            hasStarted = true
            if !isFinished, let delta = payload["text"]?.string, !delta.isEmpty,
               liveText.count < Self.maximumLiveTextLength {
                liveText = String((liveText + delta).prefix(Self.maximumLiveTextLength))
            }
        case "subagent.complete":
            hasStarted = true
            isFinished = true
            lifecycle = Self.lifecycle(forStatus: payload["status"]?.string)
            if let summary = Self.text(payload["summary"]) ?? Self.text(payload["text"]) {
                self.summary = Self.bounded(summary, Self.maximumSummaryLength)
            }
            failureReason = Self.text(payload["failure_reason"]).map { Self.bounded($0, 400) }
            durationSeconds = payload["duration_seconds"]?.number.flatMap {
                $0.isFinite && $0 >= 0 && $0 < 31_536_000 ? $0 : nil
            }
            filesWritten = (payload["files_written"]?.array ?? []).compactMap { Self.identifier($0) }
                .prefix(Self.maximumFiles).map { $0 }
        default:
            break
        }
        if let reportedCount { toolCount = max(toolCount, reportedCount) }
    }

    /// A roster row (`subagent.list`) seeds a helper the stream hasn't named.
    mutating func adopt(_ item: NativeSubagentRailItem) {
        if goal.isEmpty, item.goal != "Subagent task" {
            goal = Self.bounded(item.goal, Self.maximumGoalLength)
        }
        if childSessionID == nil { childSessionID = item.childSessionID }
        if model == nil { model = item.model }
        if let count = item.toolCount { toolCount = max(toolCount, count) }
        if item.lifecycle == .running { hasStarted = true }
    }

    /// Adopts the child's saved record. An older read never replaces a newer
    /// one, and a read taken before the helper finished never counts as final.
    @discardableResult
    mutating func adoptHistory(_ value: SubagentCanvasHistory, readAfterFinish: Bool) -> Bool {
        guard let childSessionID, value.childSessionID == childSessionID else { return false }
        if history != nil, historyIsFinal, !readAfterFinish { return false }
        if let history, !readAfterFinish, value.toolCallCount < history.toolCallCount { return false }
        history = value
        historyIsFinal = readAfterFinish && isFinished
        toolCount = max(toolCount, value.toolCallCount)
        return true
    }

    private mutating func appendStep(_ step: LiveStep) {
        liveSteps.append(step)
        if liveSteps.count > Self.maximumLiveSteps {
            liveSteps.removeFirst(liveSteps.count - Self.maximumLiveSteps)
        }
    }

    private mutating func nextStepOrder() -> Int {
        stepArrivals += 1
        return stepArrivals
    }

    static func lifecycle(forStatus status: String?) -> ChatActivityLifecycle {
        switch status?.lowercased() {
        case "completed", "complete", "done", "success", "succeeded": .succeeded
        case "interrupted", "cancelled", "canceled": .cancelled
        case "failed", "error", "errored", "timeout", "timed_out": .failed
        default: .recorded
        }
    }

    // MARK: Presentation

    /// The steps the canvas draws with the chat's own tool folders: the saved
    /// record, then any live step newer than it. A saved record read after the
    /// helper finished is the whole story.
    func transcript() -> (items: [TimelineItem], events: [ChatActivityEvent]) {
        let sessionID = "subagent:\(id)"
        let turnID = "subagent:\(id):work"
        var items: [TimelineItem] = []
        var events: [ChatActivityEvent] = []
        var savedCalls = 0
        if let history {
            items = history.items
            savedCalls = history.toolCallCount
            let lastCallID = history.events.last(where: { $0.kind == .tool })?.id
            events = history.events.map { event in
                // A call saved without its result while the helper still works is
                // the one running now: Hermes saves each call before running it.
                guard event.kind == .tool, phase == .working, event.result == nil,
                      event.id == lastCallID, !liveSteps.contains(where: { $0.toolIndex > savedCalls })
                else { return event }
                return event.updating(lifecycle: .running, summary: nil, detail: event.detail,
                                      occurredAt: event.occurredAt)
            }
        }
        guard !historyIsFinal else { return (items, events) }
        let newer = liveSteps.filter { step in
            switch step.kind {
            case .tool: step.toolIndex > savedCalls
            case .thinking: history == nil || step.toolIndex >= savedCalls
            }
        }
        for (position, step) in newer.enumerated() {
            let order = 1_000_000 + step.order
            switch step.kind {
            case .tool(let name, let preview):
                // The newest step is the one running; earlier calls ended, but the
                // stream doesn't say how.
                let isNewest = position == newer.count - 1
                events.append(ChatActivityEvent(
                    eventID: "\(sessionID):live:\(step.key)", sessionID: sessionID, turnID: turnID,
                    kind: .tool, lifecycle: isNewest && phase == .working ? .running : .recorded,
                    title: name, summary: preview, detail: nil, occurredAt: 0,
                    toolCallID: "\(sessionID):live:\(step.key)", toolName: name, sourceOrder: order))
            case .thinking(let text):
                events.append(ChatActivityEvent(
                    eventID: "\(sessionID):live:\(step.key)", sessionID: sessionID, turnID: turnID,
                    kind: .reasoning, lifecycle: .recorded, title: "Thinking", summary: nil, detail: text,
                    occurredAt: 0, sourceOrder: order))
            }
        }
        if !liveText.isEmpty {
            items.append(TimelineItem(
                id: "\(sessionID):live-reply", role: .assistant,
                sender: .agent(id: sessionID, snapshot: .init(name: "Subagent")),
                content: .message(liveText),
                metadata: .init(delivery: "Received", sourceOrder: 2_000_000)))
        }
        return (items, events)
    }

    /// What it's doing right now, in the chat's plain words, or nil once done.
    var currentActivity: String? {
        guard phase == .working else { return nil }
        let (_, events) = transcript()
        if let running = events.last(where: { $0.kind == .tool && $0.lifecycle == .running }) {
            return running.toolPhrase.live
        }
        if case .thinking? = liveSteps.last?.kind { return BighelpToolActivityCatalog.thinking.label }
        return nil
    }

    /// "Read 2 files, ran tests", from the calls shown.
    var stepSummary: String? {
        ChatToolSummary.summary(of: transcript().events)
    }

    /// The result to show under the steps: Hermes' summary, unless the saved
    /// record already ends with that reply.
    var resultText: String? {
        guard isFinished, let summary, !summary.isEmpty else { return nil }
        if historyIsFinal, let last = history?.items.last, case .message(let text) = last.content,
           text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(
               String(summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))) {
            return nil
        }
        return summary
    }

    private static func text(_ value: BighelpJSONValue?) -> String? {
        guard let string = value?.string else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func identifier(_ value: BighelpJSONValue?) -> String? {
        guard let text = text(value), text.utf8.count <= 512,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return text
    }

    private static func bounded(_ text: String, _ maximum: Int) -> String {
        text.count > maximum ? String(text.prefix(maximum - 1)) + "…" : text
    }
}

/// A child's saved session, read from the host: its messages, every call with
/// real arguments and results, and its reasoning.
struct SubagentCanvasHistory: Equatable, Sendable {
    let childSessionID: String
    let items: [TimelineItem]
    let events: [ChatActivityEvent]
    let toolCallCount: Int
    /// The child's first prompt: the task it was given, with its context.
    let task: String?

    static let pageSize = 100

    init(childSessionID: String, items: [TimelineItem], events: [ChatActivityEvent], toolCallCount: Int,
         task: String?) {
        self.childSessionID = childSessionID
        self.items = items
        self.events = events
        self.toolCallCount = toolCallCount
        self.task = task
    }

    /// Projects saved rows the same way a reopened chat does, keeping the
    /// helper's own messages and work. Its first prompt (the delegated task) is
    /// shown once, in the canvas header, not as a bubble.
    init(childSessionID: String, subagentID: String, profile: String,
         rows: [DirectHermesHistoryRow]) throws {
        let sessionID = "subagent:\(subagentID)"
        let projection = try DirectHermesHistoryProjection(
            rows: rows, appID: sessionID, profileID: profile, source: nil, sourceOrderBase: 0)
        let turnID = "\(sessionID):work"
        self.childSessionID = childSessionID
        // A saved row holds reasoning, then text, then the calls it made; they
        // share the row's order, so spread them out to read in that order.
        items = projection.messages.filter { $0.role != .human }
            .map { $0.ordered(($0.metadata.sourceOrder ?? 0) * 3 + 1) }
        events = projection.activityEvents(sessionID: sessionID).compactMap { event in
            // One folder for the helper's work; the reopened chat's boilerplate
            // ("outcome not classified") is no use here.
            guard event.kind == .tool || event.kind == .reasoning else { return nil }
            return ChatActivityEvent(
                eventID: event.eventID, sessionID: sessionID, turnID: turnID, kind: event.kind,
                lifecycle: .recorded, title: event.title,
                summary: event.kind == .reasoning ? event.summary : nil, detail: event.detail,
                occurredAt: event.occurredAt, toolCallID: event.toolCallID, toolName: event.toolName,
                arguments: event.arguments, result: event.result,
                sourceOrder: (event.sourceOrder ?? 0) * 3 + (event.kind == .reasoning ? 0 : 2))
        }
        toolCallCount = projection.tools.filter { $0.requestRowID != nil }.count
        task = rows.first(where: { $0.role == "user" && $0.isVisible })
            .map { HermesUserMessageDisplay.text($0.text) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Every helper this chat has seen, newest last, bounded.
struct SubagentCanvasLedger: Equatable, Sendable {
    static let capacity = 24

    private(set) var states: [String: SubagentCanvasState] = [:]
    private var arrivals = 0

    var isEmpty: Bool { states.isEmpty }

    var ordered: [SubagentCanvasState] {
        states.values.sorted { ($0.arrival, $0.id) < ($1.arrival, $1.id) }
    }

    subscript(id: String) -> SubagentCanvasState? { states[id] }

    /// The same identity rule as the rail: `subagent_id`, or the child's
    /// session for older hosts. An event with neither is dropped.
    static func identity(of payload: [String: BighelpJSONValue]) -> String? {
        for key in ["subagent_id", "child_session_id"] {
            if let value = payload[key]?.string, !value.isEmpty, value.utf8.count <= 512 { return value }
        }
        return nil
    }

    mutating func accept(type: String, payload: [String: BighelpJSONValue]) {
        guard type.hasPrefix("subagent."), let id = Self.identity(of: payload) else { return }
        var state = states[id] ?? newState(id: id)
        state.apply(type: type, payload: payload)
        states[id] = state
        trim()
    }

    mutating func seed(_ items: [NativeSubagentRailItem]) {
        for item in items {
            var state = states[item.id] ?? newState(id: item.id)
            state.adopt(item)
            states[item.id] = state
        }
        trim()
    }

    @discardableResult
    mutating func adoptHistory(_ history: SubagentCanvasHistory, for id: String, readAfterFinish: Bool) -> Bool {
        guard var state = states[id], state.adoptHistory(history, readAfterFinish: readAfterFinish) else {
            return false
        }
        states[id] = state
        return true
    }

    mutating func removeAll() {
        states.removeAll()
    }

    private mutating func newState(id: String) -> SubagentCanvasState {
        arrivals += 1
        return SubagentCanvasState(id: id, arrival: arrivals)
    }

    /// Finished helpers go first, oldest first; running ones stay.
    private mutating func trim() {
        guard states.count > Self.capacity else { return }
        let finished = states.values.filter(\.isFinished).sorted { $0.arrival < $1.arrival }
        for state in finished.prefix(states.count - Self.capacity) { states[state.id] = nil }
    }
}
