import SwiftUI

/// A display-only fold of one turn's reasoning and tool calls. The canonical
/// transcript and message identities stay intact.
struct ChatCompletedTurn: Identifiable {
    let id: String
    /// The folded activity entries, in order.
    let entries: [ChatTranscriptEntry]
    let elapsedSeconds: TimeInterval?
    /// The tool calls and helper agents the turn ran, shown or hidden.
    var stepCount = 0
    /// What the turn did ("Searched the web, read 2 files"), for a turn
    /// without a recorded time. Nil when it has one.
    var summary: String?

    /// The fold's content in order: each folder and note as it was during
    /// the turn, so unfolding shows the same steps the reader watched.
    var expandedEntries: [ChatTranscriptEntry] { entries }

    var foldsMessages: Bool {
        entries.contains { if case .message = $0 { true } else { false } }
    }

    /// "Worked for 2m 14s" from the turn's real time; without one, what it
    /// did. Never a bare "Done".
    var label: String { BighelpActivitySummary.label(for: phase) }

    var phase: BighelpActivityPhase {
        if let elapsedSeconds, elapsedSeconds.isFinite, (0..<31_536_000).contains(elapsedSeconds) {
            return .done(elapsed: elapsedSeconds)
        }
        return .finished(summary ?? "Worked on it")
    }
}

enum ChatTurnDisplayRow: Identifiable {
    case entry(ChatTranscriptEntry)
    case completed(ChatCompletedTurn)
    /// Simple Bot mode: a turn's interim messages under one "{Agent}'s reasoning" row.
    case reasoning(ChatInterimReasoning)

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .completed(let turn): turn.id
        case .reasoning(let group): group.id
        }
    }
}

/// The messages a bot wrote on the way to a turn's answer, in Simple Bot mode: one row named for the bot,
/// its messages under it in reasoning's quiet look.
struct ChatInterimReasoning: Identifiable, Equatable {
    let id: String
    let agentName: String
    var entries: [ChatTranscriptEntry]
}

/// Where a finished turn's interim notes go. For Claude they're the only
/// readable reasoning (its thinking is saved blank), so they follow Show
/// reasoning, not Show tool calls: into the fold with the work, or out of
/// sight. A turn still running keeps them in place either way.
enum ChatInterimReplyPlacement: Equatable, Sendable {
    case inline, fold, hidden

    static func following(_ visibility: ChatActivityVisibility) -> Self {
        visibility.showReasoning ? .fold : .hidden
    }
}

@MainActor
enum ChatCompletedTurnProjection {
    static func rows(
        from entries: [ChatTranscriptEntry],
        isSending: Bool,
        enabled: Bool,
        activityEvents: [ChatActivityEvent] = [],
        interimReplies: ChatInterimReplyPlacement = .inline
    ) -> [ChatTurnDisplayRow] {
        // Incremental activity updates can leave a terminal reasoning marker
        // in the cached transcript after its content has been settled away.
        // Reapply the canonical presentation predicate here so that marker
        // cannot become a trailing continuation fold.
        let presentableEntries = entries.compactMap { entry -> ChatTranscriptEntry? in
            switch entry {
            case .message:
                return entry
            case .activity(let turn):
                let events = turn.events.filter(\.isPresentable)
                guard !events.isEmpty else { return nil }
                return .activity(ChatActivityTurn(id: turn.id, events: events))
            }
        }
        guard enabled else { return presentableEntries.map(ChatTurnDisplayRow.entry) }
        // Every turn finds its steps and timed reasoning in the chat's ledger. Sort those out
        // and index them once per redraw: walking the whole ledger for each turn made a long
        // chat full of tool calls take a second or more to redraw.
        let chatSteps = ChatLedgerIndex(activityEvents.filter(isStep))
        let timedReasoning = ChatLedgerIndex(activityEvents.filter { event in
            event.kind == .reasoning && event.lifecycle != .running
                && event.durationMilliseconds.map { (0...86_400_000).contains($0) } == true
        })
        var rows: [ChatTurnDisplayRow] = []
        var work: [ChatTranscriptEntry] = []
        var startedAt: Date?
        var startOrder: Int?

        func flush(isActive: Bool, endOrder: Int? = nil) {
            defer { work.removeAll(keepingCapacity: true) }
            let hasUnsettledContent = work.contains { entry in
                switch entry {
                case .message(let item): item.metadata.delivery == "Streaming"
                case .activity(let turn): turn.events.contains { $0.lifecycle == .running }
                }
            }
            guard !isActive, !hasUnsettledContent, !work.isEmpty else {
                rows.append(contentsOf: work.map(ChatTurnDisplayRow.entry))
                return
            }
            // Assistant text has no trustworthy "disposable progress" marker.
            // A reply before clarify or verification can be the useful answer,
            // so every message that isn't an interim note stays visible, in
            // order. All of the turn's reasoning and tool calls go into one
            // fold, in order, placed where the work began; interim notes join
            // it or leave with Show reasoning (`ChatInterimReplyPlacement`).
            var folded: [ChatTranscriptEntry] = []
            var turnRows: [ChatTurnDisplayRow] = []
            var foldPosition: Int?
            for entry in work {
                switch entry {
                case .activity(let turn):
                    // Generated output is conversation content. Folding its
                    // completed tool would hide the image exactly when the
                    // animation is replaced, including after a reopen.
                    if turn.events.contains(where: { GeneratedMediaProjection.kind(for: $0) != nil }) {
                        turnRows.append(.entry(entry))
                    } else if turn.events.contains(where: { $0.agentTalkCall != nil }) {
                        // Agents messaging each other is conversation too: each
                        // message stays out where it happened, the work around it folds.
                        var work: [ChatActivityEvent] = []
                        func foldWork() {
                            guard let first = work.first else { return }
                            if foldPosition == nil { foldPosition = turnRows.count }
                            folded.append(.activity(ChatActivityTurn(
                                id: first.id == turn.events.first?.id ? turn.id : "\(turn.id):work:\(first.id)",
                                events: work)))
                            work.removeAll()
                        }
                        for event in turn.events {
                            if event.agentTalkCall != nil {
                                foldWork()
                                turnRows.append(.entry(.activity(ChatActivityTurn(
                                    id: "agent-talk:\(event.id)", events: [event]))))
                            } else {
                                work.append(event)
                            }
                        }
                        foldWork()
                    } else {
                        if foldPosition == nil { foldPosition = turnRows.count }
                        folded.append(entry)
                    }
                case .message(let item):
                    switch item.metadata.isInterimReply ? interimReplies : .inline {
                    case .inline:
                        turnRows.append(.entry(entry))
                    case .fold:
                        if foldPosition == nil { foldPosition = turnRows.count }
                        folded.append(entry)
                    case .hidden:
                        break
                    }
                }
            }
            if let foldPosition, let first = folded.first {
                let elapsed = elapsed(work, startedAt: startedAt, startOrder: startOrder, endOrder: endOrder,
                                      timedReasoning: timedReasoning)
                let steps = steps(folded, startOrder: startOrder, endOrder: endOrder, chatSteps: chatSteps)
                turnRows.insert(.completed(ChatCompletedTurn(
                    id: "completed-turn:\(first.id)",
                    entries: folded,
                    elapsedSeconds: elapsed,
                    stepCount: steps.count,
                    // Only a turn without a real time needs the words.
                    summary: elapsed == nil ? ChatToolSummary.summary(of: steps) : nil
                )), at: foldPosition)
            }
            rows.append(contentsOf: turnRows)
        }

        for entry in presentableEntries {
            if case .message(let item) = entry, item.role == .human {
                flush(isActive: false, endOrder: item.metadata.sourceOrder)
                rows.append(.entry(entry))
                startedAt = item.metadata.timestamp
                startOrder = item.metadata.sourceOrder
            } else {
                work.append(entry)
            }
        }
        // Never fold the turn being delivered, including gaps between batches.
        flush(isActive: isSending)
        return rows
    }

    /// A tool call or helper the fold counts; pictures and agents talking stay out in the chat.
    private static func isStep(_ event: ChatActivityEvent) -> Bool {
        (event.kind == .tool || event.kind == .subagent) && GeneratedMediaProjection.kind(for: event) == nil
            && event.agentTalkCall == nil
    }

    /// Steps the fold stands for, in order: its own tool calls and helper
    /// agents, plus the turn's work the chat hides (Show tool calls off), from
    /// the ledger by turn or by order (`chatSteps`: the chat's events that pass
    /// `isStep`). Generated pictures and messages to other agents stay outside
    /// the fold and the count.
    private static func steps(
        _ folded: [ChatTranscriptEntry], startOrder: Int?, endOrder: Int?, chatSteps: ChatLedgerIndex
    ) -> [ChatActivityEvent] {
        var steps: [ChatActivityEvent] = []
        var seen = Set<String>()
        var turnIDs = Set<String>()
        for entry in folded {
            guard case .activity(let turn) = entry else { continue }
            for event in turn.events {
                turnIDs.insert(event.turnID)
                if isStep(event), seen.insert(event.id).inserted { steps.append(event) }
            }
        }
        for event in chatSteps.events(inTurns: turnIDs, startOrder: startOrder, endOrder: endOrder)
        where seen.insert(event.id).inserted {
            steps.append(event)
        }
        return steps
    }

    private static func elapsed(
        _ entries: [ChatTranscriptEntry], startedAt: Date?, startOrder: Int?,
        endOrder: Int?, timedReasoning: ChatLedgerIndex
    ) -> TimeInterval? {
        let messages = entries.compactMap { entry -> TimelineItem? in
            guard case .message(let item) = entry else { return nil }
            return item
        }
        // A recorded completion always wins over transport or restored row time.
        if let duration = messages.compactMap(\.metadata.turnDurationMilliseconds)
            .filter({ (0...86_400_000).contains($0) }).max() {
            return TimeInterval(duration) / 1_000
        }
        let turnIDs = Set(entries.flatMap { entry -> [String] in
            guard case .activity(let turn) = entry else { return [] }
            return turn.events.map(\.turnID)
        })
        if let duration = timedReasoning.events(inTurns: turnIDs, startOrder: startOrder, endOrder: endOrder)
            .compactMap(\.durationMilliseconds).max() {
            return TimeInterval(duration) / 1_000
        }
        // Older hosts have no measured duration. Use only persisted human/final
        // message timestamps, never synthetic activity order or the render clock.
        guard let start = startedAt,
              let final = messages.last(where: { $0.role == .assistant && $0.metadata.delivery != "Streaming" }),
              let end = final.metadata.timestamp, end >= start else { return nil }
        return end.timeIntervalSince(start)
    }
}

/// Ledger events a fold can claim, found by turn or by source order without walking
/// the whole ledger for every turn of a long chat.
struct ChatLedgerIndex {
    private let events: [ChatActivityEvent]
    private let positionsByTurn: [String: [Int]]
    /// (source order, position), sorted by order.
    private let byOrder: [(order: Int, position: Int)]

    init(_ events: [ChatActivityEvent]) {
        self.events = events
        positionsByTurn = Dictionary(grouping: events.indices, by: { events[$0].turnID })
        byOrder = events.indices.compactMap { index in events[index].sourceOrder.map { (order: $0, position: index) } }
            .sorted { $0.order < $1.order }
    }

    /// In ledger order: the events of `turnIDs`, and those ordered from `startOrder` up to
    /// (not including) `endOrder`, or onward without one.
    func events(inTurns turnIDs: Set<String>, startOrder: Int?, endOrder: Int?) -> [ChatActivityEvent] {
        var positions = Set<Int>()
        for turnID in turnIDs { positions.formUnion(positionsByTurn[turnID] ?? []) }
        if let startOrder {
            var low = 0, high = byOrder.count
            while low < high {
                let middle = (low + high) / 2
                if byOrder[middle].order < startOrder { low = middle + 1 } else { high = middle }
            }
            for entry in byOrder[low...] {
                if let endOrder, entry.order >= endOrder { break }
                positions.insert(entry.position)
            }
        }
        return positions.sorted().map { events[$0] }
    }
}

@MainActor
struct ChatCompletedTurnView<Content: View>: View {
    let turn: ChatCompletedTurn
    let disclosures: ChatActivityDisclosureStore
    let onDisclosureChange: () -> Void
    @ViewBuilder let content: (ChatTranscriptEntry) -> Content

    private var isExpanded: Bool { disclosures.isCompletedTurnExpanded(turn.id) }

    var body: some View {
        let disclosures = disclosures
        let id = turn.id
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            BighelpActivityRow(
                phase: turn.phase,
                stepCount: turn.stepCount,
                detailsBelow: true,
                isExpanded: Binding(get: { disclosures.isCompletedTurnExpanded(id) },
                                    set: { disclosures.setCompletedTurnExpanded($0, id: id) }),
                onDisclosureChange: onDisclosureChange,
                accessibilityIdentifier: "chat.\(turn.id)"
            )

            if isExpanded {
                ForEach(turn.expandedEntries) { entry in
                    content(entry)
                }
            }
        }
    }
}
