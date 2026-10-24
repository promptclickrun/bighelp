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
    /// How the chat draws it: a line (Full), a card (Card) or a receipt under the answer (Minimal).
    var style: ChatWorkStyle = .full

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
    /// Card and Minimal: the work of the turn being answered, as one block.
    case liveWork(ChatLiveWork)

    var id: String {
        switch self {
        case .entry(let entry): entry.id
        case .completed(let turn): turn.id
        case .liveWork(let work): work.id
        }
    }
}

/// The running turn's work as one block (`ChatWorkStyle.gathersLiveWork`): its tool calls, thinking and
/// the agent's notes so far, in order. Card shows the newest of them; Minimal, one line. A tap lists them all.
/// A note joins the block once more work follows it; until then it's the agent's newest message, under it.
struct ChatLiveWork: Identifiable, Equatable {
    /// Named for the turn's question, so it stays the same row as work arrives.
    let id: String
    let style: ChatWorkStyle
    let entries: [ChatTranscriptEntry]
    /// The tool calls and helper agents the turn ran so far, shown or hidden.
    let stepCount: Int
    /// When the question was sent, for how long the agent has worked.
    let startedAt: Date?
    /// The agent is writing its answer under the block: the work is done, so the block says what it did.
    var isAnswering = false
}

/// Where a turn's interim notes go. For Claude they're the only readable
/// reasoning (its thinking is saved blank), so they follow Show reasoning,
/// not Show tool calls: into the fold with the work, or out of sight. A turn
/// still running keeps them in place, unless its work is one block
/// (`ChatLiveWork`), which takes them too.
enum ChatInterimReplyPlacement: Equatable, Sendable {
    case inline, fold, hidden

    static func following(_ visibility: ChatActivityVisibility) -> Self {
        visibility.showReasoning ? .fold : .hidden
    }
}

@MainActor
enum ChatCompletedTurnProjection {
    /// Every turn finds its steps and timed reasoning in the chat's ledger. Sort those out
    /// and index them once per redraw: walking the whole ledger for each turn made a long
    /// chat full of tool calls take a second or more to redraw.
    @MainActor
    struct Ledger {
        let chatSteps: ChatLedgerIndex
        let timedReasoning: ChatLedgerIndex

        init(_ activityEvents: [ChatActivityEvent]) {
            chatSteps = ChatLedgerIndex(activityEvents.filter(ChatCompletedTurnProjection.isStep))
            timedReasoning = ChatLedgerIndex(activityEvents.filter { event in
                event.kind == .reasoning && event.lifecycle != .running
                    && event.durationMilliseconds.map { (0...86_400_000).contains($0) } == true
            })
        }
    }

    /// `enabled`: Fold finished turns. `style`: the chat's `ChatWorkStyle`; nil in a group chat, whose
    /// running turns stay in place and whose folds are lines.
    static func rows(
        from entries: [ChatTranscriptEntry],
        isSending: Bool,
        enabled: Bool,
        activityEvents: [ChatActivityEvent] = [],
        interimReplies: ChatInterimReplyPlacement = .inline,
        style: ChatWorkStyle? = nil
    ) -> [ChatTurnDisplayRow] {
        let ledger = Ledger(enabled || style?.gathersLiveWork == true ? activityEvents : [])
        return ChatTranscriptTurn.split(entries).flatMap { turn in
            rows(ofTurn: entries[turn.range], endOrder: turn.nextQuestionOrder, isActive: turn.isLast && isSending,
                 enabled: enabled, ledger: ledger, interimReplies: interimReplies, style: style)
        }
    }

    /// One turn (`ChatTranscriptTurn`): its question, then what it did, folded once it's done.
    /// `endOrder` is the next question's order; `isActive`, the turn is still being delivered.
    static func rows(
        ofTurn entries: ArraySlice<ChatTranscriptEntry>,
        endOrder: Int?,
        isActive: Bool,
        enabled: Bool,
        ledger: Ledger,
        interimReplies: ChatInterimReplyPlacement,
        style: ChatWorkStyle? = nil
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
        guard enabled || style?.gathersLiveWork == true else { return presentableEntries.map(ChatTurnDisplayRow.entry) }
        var rows: [ChatTurnDisplayRow] = []
        var work = presentableEntries[...]
        var startedAt: Date?
        var startOrder: Int?
        if case .message(let item)? = work.first, item.role == .human {
            rows.append(.entry(.message(item)))
            startedAt = item.metadata.timestamp
            startOrder = item.metadata.sourceOrder
            work = work.dropFirst()
        }
        // A turn with no question of its own (the chat's first, or one Hermes ran) is only ever the last.
        let anchorID = rows.first?.id ?? "turn"
        rows += fold(Array(work), isActive: isActive, startedAt: startedAt, startOrder: startOrder,
                     endOrder: endOrder, ledger: ledger, interimReplies: interimReplies,
                     foldsFinished: enabled, style: style, anchorID: anchorID)
        return rows
    }

    private static func fold(
        _ work: [ChatTranscriptEntry], isActive: Bool, startedAt: Date?, startOrder: Int?, endOrder: Int?,
        ledger: Ledger, interimReplies: ChatInterimReplyPlacement, foldsFinished: Bool, style: ChatWorkStyle?,
        anchorID: String
    ) -> [ChatTurnDisplayRow] {
        let hasUnsettledContent = work.contains { entry in
            switch entry {
            case .message(let item): item.metadata.delivery == "Streaming"
            case .activity(let turn): turn.events.contains { $0.lifecycle == .running }
            }
        }
        // Never fold the turn being delivered, including gaps between batches: it stays in place,
        // or Card and Minimal gather its work into one block. An older turn with a step that never
        // settled stays in place too, rather than a block that says the agent is still working.
        let isLive = isActive || hasUnsettledContent
        let gathersLive = isActive && style?.gathersLiveWork == true
        guard !work.isEmpty, isLive ? gathersLive : foldsFinished else {
            return work.map(ChatTurnDisplayRow.entry)
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
        guard let foldPosition, let first = folded.first else { return turnRows }
        let steps = steps(folded, startOrder: startOrder, endOrder: endOrder, chatSteps: ledger.chatSteps)
        if gathersLive, let style {
            let isAnswering = turnRows[foldPosition...].contains { row in
                guard case .entry(.message(let item)) = row, item.role == .assistant,
                      case .message = item.content else { return false }
                return true
            }
            turnRows.insert(.liveWork(ChatLiveWork(id: "live-work:\(anchorID)", style: style, entries: folded,
                                                   stepCount: steps.count, startedAt: startedAt,
                                                   isAnswering: isAnswering)),
                            at: foldPosition)
            return turnRows
        }
        let elapsed = elapsed(work, startedAt: startedAt, startOrder: startOrder, endOrder: endOrder,
                              timedReasoning: ledger.timedReasoning)
        let style = style ?? .full
        // Minimal's receipt goes under the answer; the others sit where the work began.
        turnRows.insert(.completed(ChatCompletedTurn(
            id: "completed-turn:\(first.id)",
            entries: folded,
            elapsedSeconds: elapsed,
            stepCount: steps.count,
            // Only a turn without a real time needs the words.
            summary: elapsed == nil ? ChatToolSummary.summary(of: steps) : nil,
            style: style
        )), at: style == .minimal ? turnRows.count : foldPosition)
        return turnRows
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

    private var isExpanded: Bool { disclosures.isWorkExpanded(turn.id) }

    var body: some View {
        let disclosures = disclosures
        let id = turn.id
        let expansion = Binding(get: { disclosures.isWorkExpanded(id) },
                                set: { disclosures.setWorkExpanded($0, id: id) })
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            switch turn.style {
            case .minimal:
                ChatWorkReceipt(turn: turn, isExpanded: expansion, onDisclosureChange: onDisclosureChange)
            case .card:
                header(expansion).modifier(ChatWorkCardSurface())
            case .full:
                header(expansion)
            }

            if isExpanded {
                ForEach(turn.expandedEntries) { entry in
                    content(entry)
                }
            }
        }
    }

    private func header(_ expansion: Binding<Bool>) -> some View {
        BighelpActivityRow(
            phase: turn.phase,
            stepCount: turn.stepCount,
            detailsBelow: true,
            isExpanded: expansion,
            onDisclosureChange: onDisclosureChange,
            accessibilityIdentifier: "chat.\(turn.id)"
        )
    }
}

/// Card's soft surface, for the running turn's card and the "Worked for…" line it becomes.
struct ChatWorkCardSurface: ViewModifier {
    @BighelpThemeReader private var theme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, BighelpTokens.space8)
            .padding(.vertical, BighelpTokens.space4)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: BighelpTokens.radius16, style: .continuous))
    }
}

/// Minimal: a finished turn's work as a small line under its answer ("18s · 4 steps"). A tap lists the
/// steps under it.
struct ChatWorkReceipt: View {
    let turn: ChatCompletedTurn
    @Binding var isExpanded: Bool
    let onDisclosureChange: () -> Void
    @BighelpThemeReader private var theme
    @BighelpLoaderMotionReader private var motion
    @State private var isHovered = false

    var body: some View {
        Button {
            onDisclosureChange()
            withAnimation(motion.moves ? BighelpLoaderCurve.site.animation(duration: BighelpTokens.transitionDuration)
                                       : .easeOut(duration: BighelpTokens.stateDuration)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: BighelpTokens.space4) {
                Image(systemName: "checkmark")
                    .font(.bighelp(.caption2, weight: .bold))
                    .foregroundStyle(theme.success)
                Text([Self.label(for: turn), BighelpActivitySummary.stepCountLabel(turn.stepCount)]
                    .compactMap { $0 }.joined(separator: " "))
                    .font(.bighelp(.caption))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(theme.tertiaryText)
                Image(systemName: "chevron.right")
                    .font(.bighelp(.caption2, weight: .bold))
                    .foregroundStyle(theme.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Spacer(minLength: 0)
            }
            .padding(.leading, BighelpTokens.space12)
            .frame(maxWidth: .infinity, minHeight: BighelpPlatform.isMac ? BighelpTokens.scaled(28) : BighelpTokens.hitTarget,
                   alignment: .leading)
            .contentShape(.rect)
            .modifier(BighelpActivityHover(isHovered: $isHovered))
        }
        .buttonStyle(BighelpActivityHeaderPressStyle())
        .accessibilityLabel([BighelpActivitySummary.label(for: turn.phase),
                             BighelpActivitySummary.stepCountLabel(turn.stepCount).map { String($0.dropFirst(2)) }]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(ChatActivityDisclosureAccessibility.value(isExpanded: isExpanded))
        .accessibilityHint(isExpanded ? "Hides the steps." : "Shows the steps.")
        .accessibilityIdentifier("chat.\(turn.id)")
    }

    /// "18s" from the turn's real time, else what it did: a receipt, so shorter than "Worked for 18s".
    static func label(for turn: ChatCompletedTurn) -> String {
        guard case .done(let elapsed) = turn.phase, let elapsed else { return BighelpActivitySummary.label(for: turn.phase) }
        let seconds = Int(elapsed.rounded())
        if seconds < 1 { return "Under 1s" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
    }
}
