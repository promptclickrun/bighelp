import Observation
import os
import SwiftUI
import UIKit

/// The complete ordered canvas. Chrome and status rows participate in the same
/// native layout as messages, so there is no separately estimated live tail.
enum ChatCanvasRow: Identifiable, Equatable {
    case transcript(ChatTurnDisplayRow)
    /// A message of the person's waiting for the chat to take it (`ChatModel.stagedSends`). It has
    /// the ID of the row it becomes once sent, so it stays put as it goes.
    case staged(TimelineItem)
    /// A folder of tool calls. `isLive`: the agent is still working on it.
    case workTrailHeader(ChatActivityTurn, isLive: Bool)
    case activityDetail(ChatActivityEvent)
    case workTrailEnd(String)
    /// Agents messaging each other, back-to-back messages as one rail.
    case agentTalk(ChatAgentTalk)
    case earlierMessage(TimelineItem)
    case divider(String)
    case previousHistory(Bool, String?)
    case welcome, quickActions, bottom, botRetry
    case botStatus(String)
    /// Stop was pressed and Hermes' answer was lost. True while Stop again runs.
    case botStopUnconfirmed(Bool)
    case botApproval(HermesBotModePendingApproval)
    /// A member turn Hermes lost track of when its host stopped (session path).
    case botDiscard(HermesBotModePendingDiscard)
    case botObservedTool(BotModeObservedTool, Bool)
    case botActivityNotice(String)
    case memberFailure(BotModeMemberFailure)
    case clarification(DashboardAttentionItem)
    case directClarification(DirectHermesPrompt)
    /// Hermes asks to connect apps or tools for this chat (`manage_connections`).
    case connector(ConnectorCardStore.Card)
    case pending(String, Bool)
    /// A group member Hermes reports writing right now.
    case botTyping(TimelineSender)
    case failure(String)
    /// A turn Hermes reported failed, with its fixes and any timed retry.
    case turnFailure(ChatModel.FailedTurn, ChatScheduledRetry?)

    var id: String {
        switch self {
        case .transcript(let row): row.id
        case .staged(let item): ChatTranscriptEntry.message(item).id
        case .workTrailHeader(let turn, _): "work-trail:\(turn.id)"
        case .activityDetail(let event): "activity-detail:\(event.id)"
        case .workTrailEnd(let id): "work-trail-end:\(id)"
        case .agentTalk(let talk): "agent-talk:\(talk.id)"
        case .earlierMessage(let item): "earlier:\(item.id)"
        case .divider(let label): "divider:\(label)"
        case .previousHistory: "chat.previous-history"
        case .welcome: "chat.welcome"
        case .quickActions: "chat.quick-actions"
        case .bottom: "chat-bottom"
        case .botRetry: "chat.bot-retry"
        case .botStatus: "chat.bot-mode-status"
        case .botStopUnconfirmed: "chat.bot-stop-unconfirmed"
        case .botApproval(let approval): "chat.bot-approval:\(approval.id)"
        case .botDiscard(let discard): "chat.bot-discard:\(discard.id)"
        case .botObservedTool(let tool, _): "chat.bot-observed-tool:\(tool.id)"
        case .botActivityNotice: "chat.bot-activity-notice"
        case .memberFailure(let failure): "failure:\(failure.memberID)"
        case .clarification(let item): "chat.clarification.\(item.id)"
        case .directClarification(let prompt): "chat.direct-clarification.\(prompt.id)"
        case .connector(let card): "chat.connector.\(card.id)"
        case .pending: "chat-pending"
        case .botTyping(let sender): "chat.bot-typing:\(sender.id)"
        case .failure: "chat.failure"
        case .turnFailure: "chat.turn-failure"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.transcript(.entry(let a)), .transcript(.entry(let b))): a == b
        case (.transcript(.liveWork(let a)), .transcript(.liveWork(let b))): a == b
        case (.transcript(.completed(let a)), .transcript(.completed(let b))):
            a.id == b.id && a.entries == b.entries && a.elapsedSeconds == b.elapsedSeconds && a.stepCount == b.stepCount
                && a.summary == b.summary && a.style == b.style
        case (.workTrailHeader(let a, let liveA), .workTrailHeader(let b, let liveB)): a == b && liveA == liveB
        case (.activityDetail(let a), .activityDetail(let b)): a == b
        case (.workTrailEnd(let a), .workTrailEnd(let b)): a == b
        case (.agentTalk(let a), .agentTalk(let b)): a == b
        case (.earlierMessage(let a), .earlierMessage(let b)), (.staged(let a), .staged(let b)): a == b
        case (.divider(let a), .divider(let b)), (.botStatus(let a), .botStatus(let b)), (.failure(let a), .failure(let b)): a == b
        case (.previousHistory(let a, let b), .previousHistory(let c, let d)): a == c && b == d
        case (.memberFailure(let a), .memberFailure(let b)): a == b
        case (.botStopUnconfirmed(let a), .botStopUnconfirmed(let b)): a == b
        case (.botApproval(let a), .botApproval(let b)): a == b
        case (.botDiscard(let a), .botDiscard(let b)): a == b
        case (.botObservedTool(let a, let expandedA), .botObservedTool(let b, let expandedB)):
            a == b && expandedA == expandedB
        case (.botActivityNotice(let a), .botActivityNotice(let b)): a == b
        case (.clarification(let a), .clarification(let b)): a == b
        case (.directClarification(let a), .directClarification(let b)): a == b
        case (.connector(let a), .connector(let b)): a == b
        case (.pending(let a, let b), .pending(let c, let d)): a == c && b == d
        case (.botTyping(let a), .botTyping(let b)): a == b
        case (.turnFailure(let a, let b), .turnFailure(let c, let d)): a == c && b == d
        case (.welcome, .welcome), (.quickActions, .quickActions), (.bottom, .bottom), (.botRetry, .botRetry): true
        default: false
        }
    }
}

/// Expanded groups share disclosure state, but each event gets a recycling
/// boundary. A hundred consecutive tools must not become one giant view tree.
@MainActor
enum ChatCanvasTranscriptProjection {
    /// The lines a message wraps to at `columns` characters a line. One pass over its
    /// Unicode scalars: splitting it into Characters was a long answer's cost again on
    /// each streamed word (and every message's when a chat opens). An emoji made of
    /// several scalars counts as several, which only makes the estimate a little taller.
    static func wrappedLineCount(_ text: String, columns: CGFloat) -> CGFloat {
        var lines: CGFloat = 0
        var column = 0
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                lines += max(1, ceil(CGFloat(column) / columns))
                column = 0
            } else {
                column += 1
            }
        }
        return lines + max(1, ceil(CGFloat(column) / columns))
    }

    static func rows(from displayRows: [ChatTurnDisplayRow], disclosures: ChatActivityDisclosureStore,
                     isSending: Bool = false, readsAgentMessages: Bool = true) -> [ChatCanvasRow] {
        rows(from: displayRows[...], disclosures: disclosures, isSending: isSending,
             tailEntryID: tailEntryID(of: displayRows[...], isSending: isSending),
             talk: ChatAgentTalkIndex(displayRows, readsAgentMessages: readsAgentMessages))
    }

    /// While a turn runs, the folder at its tail is the work in progress:
    /// the agent hasn't moved on to text, thinking or another folder yet.
    static func tailEntryID(of displayRows: ArraySlice<ChatTurnDisplayRow>, isSending: Bool) -> String? {
        guard isSending, case .entry(let entry)? = displayRows.last, case .activity = entry else { return nil }
        return entry.id
    }

    /// `rows(from:…)` for some of the display rows (`ChatTranscriptCanvasCache` projects a turn at
    /// a time), with the chat's tail and agent talk worked out from all of them.
    static func rows(from displayRows: ArraySlice<ChatTurnDisplayRow>, disclosures: ChatActivityDisclosureStore,
                     isSending: Bool, tailEntryID: String?, talk: ChatAgentTalkIndex) -> [ChatCanvasRow] {
        var result: [ChatCanvasRow] = []
        func appendTalk(_ piece: ChatAgentTalk.Piece) {
            // Messages back to back read as one exchange.
            if case .agentTalk(var previous)? = result.last {
                previous.append(ChatAgentTalk(piece))
                result[result.count - 1] = .agentTalk(previous)
            } else {
                result.append(.agentTalk(ChatAgentTalk(piece)))
            }
        }
        func append(_ entry: ChatTranscriptEntry, inOpenedTurn: Bool = false) {
            guard case .activity(let turn) = entry else {
                if case .message(let item) = entry, talk.hides(item) {
                    return
                } else if case .message(let item) = entry, let piece = talk.piece(for: item) {
                    appendTalk(piece)
                } else {
                    result.append(.transcript(.entry(entry)))
                }
                return
            }
            let segments = ChatActivityTurnPresentation(turn: turn).segments
            for (index, segment) in segments.enumerated() {
                switch segment {
                case .agentTalk(let event):
                    appendTalk(.call(event, answer: talk.answer(for: event)))
                case .workTrail(let trail) where inOpenedTurn:
                    // The opened "Worked for…" is the folder already: its tools show as they are.
                    result += trail.events.map(ChatCanvasRow.activityDetail)
                    result.append(.workTrailEnd(trail.id))
                case .workTrail(let trail):
                    let isTail = entry.id == tailEntryID && index == segments.count - 1
                    let isLive = isSending && (isTail || trail.events.contains { $0.lifecycle == .running })
                    result.append(.workTrailHeader(trail, isLive: isLive))
                    if disclosures.isExpanded(trail, isLive: isLive) {
                        result += trail.events.map(ChatCanvasRow.activityDetail)
                        result.append(.workTrailEnd(trail.id))
                    }
                case .collaboration(let event), .generatedMedia(let event):
                    result.append(.transcript(.entry(.activity(ChatActivityTurn(
                        id: "card:\(event.id)", events: [event])))))
                case .thinking(let events):
                    // One row for the run; its ID follows the first entry so it
                    // stays put while later thinking streams in.
                    guard let first = events.first else { break }
                    result.append(.transcript(.entry(.activity(ChatActivityTurn(
                        id: "card:\(first.id)", events: events)))))
                }
            }
        }
        for row in displayRows {
            switch row {
            case .entry(let entry): append(entry)
            case .completed(let turn):
                // Keep the existing accessible disclosure control, with its
                // expanded content projected as sibling native rows.
                let header = ChatCompletedTurn(id: turn.id, entries: [], elapsedSeconds: turn.elapsedSeconds,
                                               stepCount: turn.stepCount, summary: turn.summary, style: turn.style)
                result.append(.transcript(.completed(header)))
                if disclosures.isWorkExpanded(turn.id) {
                    turn.expandedEntries.forEach { append($0, inOpenedTurn: true) }
                }
            case .liveWork(let work):
                // The block keeps its entries: Card previews its newest steps, Minimal its newest note.
                // Opened, every step follows as its own row, as in an opened "Worked for…".
                result.append(.transcript(.liveWork(work)))
                if disclosures.isWorkExpanded(work.id) {
                    work.entries.forEach { append($0, inOpenedTurn: true) }
                }
            }
        }
        return result
    }

    /// The chat plays one loader at a time: on the newest live tool folder, running
    /// thinking row or running turn's block while a turn runs. Every other row stays still.
    static func activeLoaderID(in rows: [ChatCanvasRow], isSending: Bool) -> String? {
        guard isSending else { return nil }
        for row in rows.reversed() {
            switch row {
            case .workTrailHeader(let trail, let isLive) where isLive:
                return ChatLoaderID.workTrail(trail)
            case .transcript(.liveWork(let work)) where !work.isAnswering:
                return work.id
            case .transcript(.entry(.activity(let turn))):
                if !turn.events.isEmpty, turn.events.allSatisfy({ $0.kind == .reasoning }),
                   turn.events.contains(where: { $0.lifecycle == .running }) {
                    return ChatLoaderID.thinking(turn.events)
                }
            case .agentTalk(let talk) where talk.isLive:
                return ChatAgentTalkRail.loaderID(talk)
            default: continue
            }
        }
        return nil
    }
}

extension ChatCanvasTranscriptProjection {
    /// The running turn's work is one block (Card, Minimal), which says the agent is working itself.
    /// Only the newest turn can hold one, so the search stops at its question.
    static func hasLiveWork(in rows: [ChatCanvasRow]) -> Bool {
        for row in rows.reversed() {
            switch row {
            case .transcript(.liveWork): return true
            case .transcript(.entry(.message(let item))) where item.role == .human: return false
            default: continue
            }
        }
        return false
    }
}

/// The names the chat's folders answer to in `BighelpActivityLoaderFocus`.
enum ChatLoaderID {
    static func workTrail(_ trail: ChatActivityTurn) -> String { "work-trail:\(trail.id)" }
    static func thinking(_ events: [ChatActivityEvent]) -> String { "thinking:\(events.first?.id ?? "")" }
}

@MainActor @Observable
final class ChatTimelineController {
    private(set) var isAtBottom = true
    @ObservationIgnored fileprivate weak var table: ChatTimelineTableView?
    /// The chat's scroll view, for the blur under the header and message box.
    var scrollView: UIScrollView? { table }

    func beginReview() { table?.followsTail = false }

    func scrollToLatest(animated: Bool) {
        // A finger on the chat owns it. A glide left from a flick doesn't: Return to latest shows
        // as the reader flicks up, so taps often land mid-glide, and ignoring them made the button
        // feel as if it only worked when pressed just so.
        guard let table, !table.isTouched else { return }
        if table.isGliding { table.setContentOffset(table.contentOffset, animated: false) }
        table.followsTail = true
        table.isAnimatingReturn = animated
        if table.numberOfRows(inSection: 0) > 0 {
            table.scrollToRow(at: IndexPath(row: table.numberOfRows(inSection: 0) - 1, section: 0), at: .bottom, animated: animated)
        }
        if !animated { table.setNeedsLayout() }
    }

    func scrollToOldest() {
        guard let table, !table.isUserInteracting, table.numberOfRows(inSection: 0) > 0 else { return }
        beginReview()
        table.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
    }

    fileprivate func publish(isAtBottom: Bool) {
        if self.isAtBottom != isAtBottom { self.isAtBottom = isAtBottom }
    }
}

/// UIKit owns drag/deceleration, row recycling and self-sizing. Pinning happens
/// in layout, not in competing delayed tasks that write offsets after a drag.
@MainActor
final class ChatTimelineTableView: UITableView {
    var followsTail = true
    var isAnimatingReturn = false
    /// Set by an update; its first layout, which resizes the changed rows, records `updateLaidOutAt`.
    var awaitsUpdateLayout = false
    private(set) var updateLaidOutAt: CFTimeInterval = 0
    var onLayout: (() -> Void)?
    #if DEBUG
    // Deterministic gesture tests avoid private UIScrollView state.
    var interactionStateOverride: Bool?
    var glidingStateOverride: Bool?
    var onProgrammaticContentOffsetWrite: (() -> Void)?
    #endif
    /// A finger on the chat, holding or dragging it.
    var isTouched: Bool {
        #if DEBUG
        if let interactionStateOverride { return interactionStateOverride }
        #endif
        return isTracking || isDragging
    }
    /// The chat still glides after a flick, with no finger on it.
    var isGliding: Bool {
        #if DEBUG
        if let glidingStateOverride { return glidingStateOverride }
        #endif
        return isDecelerating
    }
    var isUserInteracting: Bool { isTouched || isGliding }
    /// The reader drags or the chat decelerates, on screen. A finger resting on the chat doesn't count.
    var isScrolling: Bool {
        #if DEBUG
        if let interactionStateOverride { return interactionStateOverride }
        #endif
        return window != nil && (isDragging || isDecelerating)
    }
    var bottomOffset: CGFloat { max(-adjustedContentInset.top, contentSize.height + adjustedContentInset.bottom - bounds.height) }
    var distanceFromBottom: CGFloat { bottomOffset - contentOffset.y }

    #if DEBUG
    override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
        onProgrammaticContentOffsetWrite?()
        super.setContentOffset(contentOffset, animated: animated)
    }
    #endif

    private var appliedCustomContentInsets = UIEdgeInsets.zero

    /// Applies the chrome-owned inset while preserving the reader's visible
    /// content. UIKit continues to contribute system and keyboard safe-area
    /// values through `adjustedContentInset` because the table remains on its
    /// automatic adjustment behavior.
    func applyCustomContentInsets(_ insets: UIEdgeInsets) {
        guard appliedCustomContentInsets != insets else { return }

        let wasFollowingTail = followsTail
        let previousOffset = contentOffset
        appliedCustomContentInsets = insets
        contentInset = insets
        verticalScrollIndicatorInsets = insets

        if wasFollowingTail {
            // The existing layout pass owns tail pinning. Avoid a competing
            // offset write while a snapshot or keyboard transition is settling.
            setNeedsLayout()
        } else if !isUserInteracting {
            // The full-height table remains the reader's viewport; changing
            // the chrome inset must not move its existing content coordinate.
            // Re-apply the captured offset after UIKit's inset adjustment so
            // the row under the reader's finger stays at the same screen point.
            // During a live gesture, UIKit owns the resulting offset. Writing
            // the stale pre-inset value here would cancel the user's drag.
            setContentOffset(
                previousOffset,
                animated: false
            )
        }
    }

    override func layoutSubviews() {
        // UIKit animates a self-sizing row's new height over 0.3 s. A streamed answer resizes many
        // times a second, so those animations piled up and the answer and the rows under it bounced.
        // Inside a real animation (rotation, the keyboard), rows still move with it.
        if UIView.inheritedAnimationDuration > 0 {
            super.layoutSubviews()
        } else {
            UIView.performWithoutAnimation { super.layoutSubviews() }
        }
        if awaitsUpdateLayout {
            awaitsUpdateLayout = false
            updateLaidOutAt = CACurrentMediaTime()
        }
        if followsTail, !isUserInteracting, !isAnimatingReturn, bounds.height > 0,
           abs(distanceFromBottom) > 0.5 {
            setContentOffset(CGPoint(x: contentOffset.x, y: bottomOffset), animated: false)
        }
        onLayout?()
    }
}

@MainActor
/// A chat's rows keyed by ID, for the timeline. An item can reach the rows twice (two records of one tool
/// call in an open folder, say); the first stays and the repeat is dropped, with a log line naming its kind
/// so its source can be found.
enum ChatCanvasRowIDs {
    private static let log = Logger(subsystem: "app.loopdy.mobile", category: "ChatTimeline")

    static func firstOfEach(_ rows: [ChatCanvasRow]) -> [ChatCanvasRow] {
        var seen = Set<String>(minimumCapacity: rows.count)
        var repeated: [String] = []
        let kept = rows.filter { row in
            if seen.insert(row.id).inserted { return true }
            repeated.append(kind(row))
            return false
        }
        guard !repeated.isEmpty else { return rows }
        log.error("Dropped \(repeated.count, privacy: .public) repeated chat rows: \(Set(repeated).sorted().joined(separator: ", "), privacy: .public)")
        return kept
    }

    /// Whether rows replacing `removed` repeat an ID: among themselves, or of a row that stays.
    static func repeatsAnID(_ inserted: ArraySlice<ChatCanvasRow>, replacing removed: ArraySlice<ChatCanvasRow>,
                            among current: [String: ChatCanvasRow]) -> Bool {
        guard !inserted.isEmpty else { return false }
        let leaving = Set(removed.lazy.map(\.id))
        var seen = Set<String>(minimumCapacity: inserted.count)
        for row in inserted {
            let id = row.id
            if !seen.insert(id).inserted || (current[id] != nil && !leaving.contains(id)) { return true }
        }
        return false
    }

    /// The case name only (`activityDetail`): row IDs and contents can carry messages and tool IDs.
    private static func kind(_ row: ChatCanvasRow) -> String {
        Mirror(reflecting: row).children.first?.label ?? String(describing: row)
    }
}

/// Whether a kept row is on screen. False while it waits off screen: its loaders hold still.
@MainActor @Observable
final class ChatRowPresence {
    var isOnScreen = true
}

/// UIKit no longer pauses a kept row that has gone by (`ChatTimelineCell`), so it holds its
/// loaders still itself. Only this modifier reads `isOnScreen`: the row isn't drawn again
/// each time it comes and goes.
struct ChatRowMotion: ViewModifier {
    let presence: ChatRowPresence
    @Environment(\.bighelpLoaderMotionOverride) private var override

    func body(content: Content) -> some View {
        var motion = override
        if !presence.isOnScreen { motion.sceneInactive = true }
        return content.environment(\.bighelpLoaderMotionOverride, motion)
    }
}

/// What rows take from the chat screen that changes without changing how a row looks: the scene
/// phase (each trip to the background and back) and the card actions (none while the host
/// connection is closed, the new connection's after it opens). Rows follow them as they change.
/// Copied into rows as they were built, each change built every row again and forgot every
/// row's height, so the first scroll up after coming back to the app dropped frames.
@MainActor @Observable
final class ChatRowLiveValues {
    var scenePhase = ScenePhase.active
    var cardInteractions: ChatCardInteractionHandler?

    /// Takes the chat screen's values. Card actions count as changed when their scope does
    /// (a closed connection has none), so an update for each streamed word leaves rows alone.
    func take(_ environment: EnvironmentValues) {
        if scenePhase != environment.scenePhase { scenePhase = environment.scenePhase }
        let cards = environment.chatCardInteractions
        if cardInteractions?.scope != cards?.scope { cardInteractions = cards }
    }
}

/// Hands a row the live values. Only this modifier reads them: a change reaches the views
/// that use them without drawing the row again.
struct ChatRowLiveEnvironment: ViewModifier {
    let values: ChatRowLiveValues

    func body(content: Content) -> some View {
        content
            .environment(\.scenePhase, values.scenePhase)
            .environment(\.chatCardInteractions, values.cardInteractions)
    }
}

/// What rows take from the chat screen besides their own value. A row whose part of it
/// changes is drawn again; built rows otherwise stay as they are.
struct ChatCanvasRowContext: Equatable {
    /// Messages followed by another of their group, and messages that continue one.
    var groupedIDs: Set<String> = []
    var continuedIDs: Set<String> = []
    var density: ChatDensity = .comfortable
    /// Agent replies in a bubble or on the page; a change draws every row again, once.
    var agentStyle: ChatAgentMessageStyle = .bubble
}

struct NativeChatTimeline<Content: View>: UIViewRepresentable {
    let conversationID: String
    let ownerID: ObjectIdentifier
    let rows: [ChatCanvasRow]
    let controller: ChatTimelineController
    let entryCount: Int
    var contentInsets: UIEdgeInsets = .zero
    var rowContext = ChatCanvasRowContext()
    @ViewBuilder let rowContent: (ChatCanvasRow) -> Content
    /// Rows follow the scene phase and card actions (`ChatRowLiveValues`). Reading them here
    /// makes SwiftUI call updateUIView when they change, so rows don't stay "inactive" from
    /// launch (which froze every working animation in chat) or keep a closed connection's cards.
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatCardInteractions) private var cardInteractions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ChatTimelineTableView {
        let table = ChatTimelineTableView(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.isOpaque = false
        table.backgroundView = nil
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 120
        // A streaming tail continuously inserts rich, tall rows. Preparing
        // speculative neighboring hosting views amplifies each insertion.
        // The coordinator builds the rows above while the chat is still instead.
        table.isPrefetchingEnabled = false
        // Rows host their SwiftUI content as a subview (`ChatTimelineCell`), so a row that
        // grows reaches its cell through Auto Layout.
        table.selfSizingInvalidation = .enabledIncludingConstraints
        table.sectionHeaderTopPadding = 0
        table.allowsSelection = false
        #if !os(visionOS)
        table.keyboardDismissMode = .interactive
        #endif
        table.contentInsetAdjustmentBehavior = .automatic
        table.alwaysBounceVertical = true
        table.accessibilityIdentifier = "chat.timeline"
        table.delegate = context.coordinator
        context.coordinator.install(on: table)
        return table
    }

    func updateUIView(_ table: ChatTimelineTableView, context: Context) {
        _ = scenePhase
        _ = cardInteractions
        controller.table = table
        context.coordinator.scheduleUpdate(self, environment: context.environment, table: table)
    }

    static func dismantleUIView(_ table: ChatTimelineTableView, coordinator: Coordinator) {
        table.onLayout = nil
        table.delegate = nil
        coordinator.cancelPendingUpdate()
        coordinator.releaseBuiltRows()
        if coordinator.controller?.table === table { coordinator.controller?.table = nil }
    }

    @MainActor @Observable
    final class HostedRowState {
        var row: ChatCanvasRow
        var render: (ChatCanvasRow) -> Content
        let generation: Int
        let presence = ChatRowPresence()

        init(row: ChatCanvasRow, render: @escaping (ChatCanvasRow) -> Content, generation: Int) {
            self.row = row
            self.render = render
            self.generation = generation
            ChatPerformanceProbe.live("live.hosted-row", 1)
        }

        deinit { ChatPerformanceProbe.live("live.hosted-row", -1) }
    }

    private struct HostedRow: View {
        let state: HostedRowState
        let live: ChatRowLiveValues

        var body: some View {
            // Evaluate under a SwiftUI body observation scope. Building the
            // message here (rather than in the UIKit configuration closure)
            // keeps pending state, mode changes and sender stores live even
            // when the transcript item's value itself has not changed.
            let _ = ChatPerformanceProbe.count("row.body")
            state.render(state.row).id(state.row.id)
                .modifier(ChatRowMotion(presence: state.presence))
                .modifier(ChatRowLiveEnvironment(values: live))
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDelegate {
        weak var controller: ChatTimelineController?
        private var dataSource: UITableViewDiffableDataSource<Int, String>!
        private var rows: [ChatCanvasRow] = []
        private var rowsByID: [String: ChatCanvasRow] = [:]
        private var orderedIDs: [String] = []
        /// Where each row is in `orderedIDs`, for keeping the built rows nearest the screen.
        private var indexByID: [String: Int] = [:]
        private var conversationID: String?
        private var ownerID: ObjectIdentifier?
        private var rowContent: ((ChatCanvasRow) -> Content)?
        private var environment = EnvironmentValues()
        private struct Style: Equatable {
            let colorScheme: ColorScheme
            let contrast: ColorSchemeContrast
            let typeSize: DynamicTypeSize
            let appearance: BighelpAppearanceContext
            let v2: Bool
            let v3: Bool
            let reduceMotion: Bool
            let locale: Locale
            let direction: LayoutDirection
            let sizeClass: UserInterfaceSizeClass?
            let verticalSizeClass: UserInterfaceSizeClass?
            let isEnabled: Bool
            let reflectiveVisionEnabled: Bool
            let cameraID: ObjectIdentifier?
            let providerStoreID: ObjectIdentifier?
            let companionStoreID: ObjectIdentifier?
            let companionAgentScope: String
            let disclosureStoreID: ObjectIdentifier?
            let loaderFocusID: ObjectIdentifier?
            let hasContentReader: Bool

            init(_ environment: EnvironmentValues) {
                colorScheme = environment.colorScheme
                contrast = environment.colorSchemeContrast
                typeSize = environment.dynamicTypeSize
                appearance = environment.appAppearance
                v2 = environment.bighelpUIV2Enabled
                v3 = environment.bighelpUIV3Enabled
                reduceMotion = environment.accessibilityReduceMotion
                locale = environment.locale
                direction = environment.layoutDirection
                sizeClass = environment.horizontalSizeClass
                verticalSizeClass = environment.verticalSizeClass
                isEnabled = environment.isEnabled
                reflectiveVisionEnabled = environment.reflectiveVisionEnabled
                cameraID = environment.reflectiveVisionCamera.map(ObjectIdentifier.init)
                providerStoreID = environment.providerLogoStore.map(ObjectIdentifier.init)
                companionStoreID = environment.companionStore.map(ObjectIdentifier.init)
                companionAgentScope = environment.companionAgentScope
                disclosureStoreID = environment.chatActivityDisclosureStore.map(ObjectIdentifier.init)
                loaderFocusID = environment.bighelpActivityLoaderFocus.map(ObjectIdentifier.init)
                hasContentReader = environment.bighelpSessionContentReader != nil
            }
        }
        private var style: Style?
        private let live = ChatRowLiveValues()
        private var heights: [String: (width: CGFloat, height: CGFloat)] = [:]
        /// UIKit asks every row's estimate whenever rows are added; working each out from its
        /// text again made each new row of a long chat cost as much as reading the whole chat.
        private var estimates: [String: (width: CGFloat, height: CGFloat)] = [:]
        private var publicationPending = false
        private var presentationGeneration = 0
        private var rowContext = ChatCanvasRowContext()
        /// About 2 MB each on a 3x screen, mostly the drawn text. A built row shows as it was
        /// when it scrolls back in, unless it changed, so scrolling alone redraws nothing.
        private let built = ChatTimelineBuiltRows<HostedRowState>(limit: 40)
        /// Rows above the screen built while the chat is still, so the next scroll up finds
        /// them ready, measured at the table's width.
        static var prewarmedRowsAbove: Int { 24 }
        private var prewarm: DispatchWorkItem?
        private var memoryWarning: NSObjectProtocol?
        private var lastScrolledAt: CFTimeInterval = 0
        private var pendingUpdate: (parent: NativeChatTimeline, environment: EnvironmentValues)?
        private var updateScheduled = false
        /// A streamed answer can arrive far faster than it can be laid out again, and each layout of a
        /// long answer kept the main thread from the reader's drag. After an update is laid out, the
        /// next waits this long.
        static var updateInterval: CFTimeInterval { 0.05 }

        func install(on table: ChatTimelineTableView) {
            dataSource = UITableViewDiffableDataSource(tableView: table) { [weak self] table, indexPath, id in
                guard let self else { return UITableViewCell() }
                let isNew = self.built[id] == nil
                let row = self.built.row(for: id)
                self.configure(row, id: id)
                if isNew { self.trimBuiltRows(around: indexPath.row, in: table) }
                return row.cell
            }
            table.addSubview(built.parking)
            memoryWarning = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.built.removeAll(keepingOnScreen: true) }
            }
            table.onLayout = { [weak self, weak table] in
                guard let self, let table else { return }
                self.publishPosition(of: table)
            }
        }

        func scheduleUpdate(_ parent: NativeChatTimeline, environment: EnvironmentValues, table: ChatTimelineTableView) {
            pendingUpdate = (parent, environment)
            guard !updateScheduled else { return }
            updateScheduled = true
            // Diffable self-sizing measures hosting views synchronously. Do
            // that outside the enclosing SwiftUI layout transaction, and use
            // the newest complete rows if several updates arrive together.
            DispatchQueue.main.async { [weak self, weak table] in self?.applyPendingUpdate(to: table) }
        }

        /// Reader interaction owns the chat: while the reader drags or the chat decelerates, the rows
        /// wait (the chrome insets don't) and the newest rows are shown once it settles.
        private func applyPendingUpdate(to table: ChatTimelineTableView?) {
            guard let table, let update = pendingUpdate else {
                updateScheduled = false
                return
            }
            let sameChat = update.parent.conversationID == conversationID && update.parent.ownerID == ownerID
            let wait = table.updateLaidOutAt + Self.updateInterval - CACurrentMediaTime()
            if sameChat, wait > 0 || table.isScrolling {
                table.applyCustomContentInsets(update.parent.contentInsets)
                let delay = table.isScrolling ? Self.updateInterval / 2 : max(wait, 0.005)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak table] in
                    self?.applyPendingUpdate(to: table)
                }
                return
            }
            updateScheduled = false
            pendingUpdate = nil
            ChatPerformanceProbe.measure("timeline.update") {
                self.update(update.parent, environment: update.environment, table: table)
            }
            table.applyCustomContentInsets(update.parent.contentInsets)
            table.accessibilityValue = "\(update.parent.entryCount) conversation entries"
            table.awaitsUpdateLayout = true
        }

        func cancelPendingUpdate() {
            pendingUpdate = nil
            prewarm?.cancel()
        }

        func releaseBuiltRows() {
            prewarm?.cancel()
            memoryWarning.map(NotificationCenter.default.removeObserver)
            memoryWarning = nil
            built.removeAll()
        }

        /// Keeps the built rows nearest the screen and `row`.
        private func trimBuiltRows(around row: Int, in table: UITableView) {
            let visible = (table.indexPathsForVisibleRows ?? []).map(\.row)
            built.trim(around: min(visible.min() ?? row, row)...max(visible.max() ?? row, row)) { self.indexByID[$0] }
        }

        /// Builds the rows above the screen, one per turn of the main queue, once the chat
        /// has been still for a moment: no scrolling, no new rows. Any touch, scroll or
        /// update stops it until the chat is still again.
        private func schedulePrewarm(_ table: ChatTimelineTableView) {
            prewarm?.cancel()
            let work = DispatchWorkItem { [weak self, weak table] in
                guard let self, let table else { return }
                self.prewarmNextRow(in: table)
            }
            prewarm = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }

        private func prewarmNextRow(in table: ChatTimelineTableView) {
            // Programmatic scrolls (Return to latest) move the table without a drag.
            if CACurrentMediaTime() - lastScrolledAt < 0.35 { return schedulePrewarm(table) }
            guard table.window != nil, !table.isUserInteracting, !table.isAnimatingReturn, !updateScheduled,
                  table.bounds.width > 0, let first = table.indexPathsForVisibleRows?.first?.row,
                  first < orderedIDs.count else { return }
            let range = max(0, first - Self.prewarmedRowsAbove)..<first
            guard let index = range.reversed().first(where: { built[orderedIDs[$0]] == nil }) else { return }
            let id = orderedIDs[index]
            let row = built.row(for: id)
            trimBuiltRows(around: first, in: table)
            // Full of rows nearer the screen than this one.
            guard built[id] != nil else { return }
            let cell = row.cell
            let width = table.bounds.width
            // Built in the table itself, out of sight: a row first built anywhere else (in
            // `parking`) made its views again the first time it showed.
            table.addSubview(cell)
            cell.frame = CGRect(x: 0, y: -100_000, width: width, height: heights[id]?.height ?? 120)
            configure(row, id: id)
            row.state?.presence.isOnScreen = false
            let size = ChatPerformanceProbe.measure("row.prewarm") {
                let size = cell.systemLayoutSizeFitting(
                    CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                    withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
                // Laid out at the size it will show at, so its text views are made now, not when it shows.
                cell.frame.size.height = size.height
                cell.layoutIfNeeded()
                return size
            }
            built.parking.addSubview(cell)
            if size.height > 0 { heights[id] = (width, size.height) }
            let work = DispatchWorkItem { [weak self, weak table] in
                guard let self, let table else { return }
                self.prewarmNextRow(in: table)
            }
            prewarm = work
            DispatchQueue.main.async(execute: work)
        }

        private func configure(_ built: ChatTimelineBuiltRows<HostedRowState>.Row, id: String) {
            ChatPerformanceProbe.count("row.configure")
            guard let row = rowsByID[id], let rowContent else { return }
            if let state = built.state, state.generation == presentationGeneration {
                // Streaming changes the content inside the existing hosting
                // view. Reassigning its configuration makes UIKit remeasure
                // the hosting root in addition to the changed message.
                // A built row scrolling back in is left alone unless it changed.
                if state.row != row || built.isStale {
                    state.render = rowContent
                    state.row = row
                    built.isStale = false
                }
                return
            }
            let state = HostedRowState(row: row, render: rowContent, generation: presentationGeneration)
            built.state = state
            built.isStale = false
            let cell = built.cell
            let environment = environment
            let live = live
            cell.backgroundColor = .clear
            cell.isOpaque = false
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            cell.selectionStyle = .none
            let configuration = UIHostingConfiguration {
                HostedRow(state: state, live: live)
                    .transformEnvironment(\.self, transform: Self.hostedEnvironment(from: environment))
                    .buttonStyle(.plain)
            }.margins(.all, 0)
            // The bottom spacer, and activity lines (which set their own touch
            // height), are shorter than a list row's default minimum height.
            // An unfolded trail's steps must sit flush so their line is unbroken.
            switch row {
            case .bottom, .workTrailEnd, .workTrailHeader, .activityDetail, .transcript(.completed),
                 .transcript(.entry(.activity)), .agentTalk:
                cell.host(configuration.minSize(height: 0))
            default: cell.host(configuration)
            }
        }

        /// How many rows at the start and at the end didn't change.
        private static func unchangedEnds(_ previous: [ChatCanvasRow], _ next: [ChatCanvasRow]) -> (Int, Int) {
            let shorter = min(previous.count, next.count)
            var start = 0
            while start < shorter, previous[start] == next[start] { start += 1 }
            var end = 0
            while end < shorter - start, previous[previous.count - 1 - end] == next[next.count - 1 - end] { end += 1 }
            return (start, end)
        }

        func update(_ parent: NativeChatTimeline, environment: EnvironmentValues, table: ChatTimelineTableView) {
            // Preserve known visible heights before a structural update makes
            // UIKit estimate the old viewport again. Changed rows are still
            // invalidated below and always receive native self-sizing.
            for cell in table.visibleCells {
                guard let id = cell.accessibilityIdentifier, rowsByID[id] != nil,
                      cell.bounds.height > 0 else { continue }
                heights[id] = (table.bounds.width, cell.bounds.height)
            }
            controller = parent.controller
            rowContent = parent.rowContent
            defer { schedulePrewarm(table) }
            live.take(environment)
            let nextStyle = Style(environment)
            let previousContext = rowContext
            rowContext = parent.rowContext
            let styleChanged = style != nextStyle || previousContext.density != rowContext.density
                || previousContext.agentStyle != rowContext.agentStyle
            style = nextStyle
            self.environment = environment
            let reset = conversationID != parent.conversationID || ownerID != parent.ownerID
            conversationID = parent.conversationID
            ownerID = parent.ownerID
            if reset {
                table.followsTail = true
                table.isAnimatingReturn = false
                heights.removeAll()
                estimates.removeAll()
                built.removeAll()
            }
            // A long chat changes at its tail (a growing answer, a new tool). Only the rows
            // between the unchanged ends are looked at: hashing and comparing every row of
            // the history on each update made a long chat's streaming stutter.
            let previous = rows
            // Each ID once: the index below and diffable snapshots trap on a repeat (2.6.7 crashed opening a
            // chat that had one). A reset walks every row anyway; an update checks only the rows it changes.
            var next = reset ? ChatCanvasRowIDs.firstOfEach(parent.rows) : parent.rows
            var (start, end) = Self.unchangedEnds(previous, next)
            if !reset, ChatCanvasRowIDs.repeatsAnID(next[start..<(next.count - end)],
                                                    replacing: previous[start..<(previous.count - end)],
                                                    among: rowsByID) {
                next = ChatCanvasRowIDs.firstOfEach(next)
                (start, end) = Self.unchangedEnds(previous, next)
            }
            rows = next
            let removed = previous[start..<(previous.count - end)]
            let inserted = next[start..<(next.count - end)]
            // A message that gains a follower in its group loses its tail and some space below.
            let regrouped = reset || styleChanged ? [] : previousContext.groupedIDs
                .symmetricDifference(rowContext.groupedIDs)
                .union(previousContext.continuedIDs.symmetricDifference(rowContext.continuedIDs))
            guard reset || styleChanged || !removed.isEmpty || !inserted.isEmpty || !regrouped.isEmpty else {
                table.setNeedsLayout()
                return
            }
            let previousRows = rowsByID
            if reset {
                rowsByID = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            } else {
                for row in removed { rowsByID[row.id] = nil }
                for row in inserted { rowsByID[row.id] = row }
            }
            let insertedIDs = inserted.map(\.id)
            let reordered = reset || !removed.map(\.id).elementsEqual(insertedIDs)
            let ids = reordered
                ? Array(orderedIDs.prefix(start)) + insertedIDs + Array(orderedIDs.suffix(end))
                : orderedIDs
            let previousFirstID = orderedIDs.first
            if reset || styleChanged || previousFirstID != ids.first {
                presentationGeneration &+= 1
                // Rows off screen are built again when they show, in the new look.
                if !reset { built.removeAll(keepingOnScreen: true) }
            }
            var changed = styleChanged ? ids : insertedIDs.filter { previousRows[$0] != rowsByID[$0] }
            if !styleChanged, previousFirstID != ids.first {
                // The first row's top padding moves to the new first row.
                for id in [previousFirstID, ids.first].compactMap({ $0 })
                where rowsByID[id] != nil && !changed.contains(id) {
                    changed.append(id)
                }
            }
            for id in regrouped where rowsByID[id] != nil && !changed.contains(id) { changed.append(id) }
            built.markStale(changed)
            for id in changed {
                heights[id] = nil
                estimates[id] = nil
            }
            if reordered {
                orderedIDs = ids
                indexByID = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                heights = heights.filter { rowsByID[$0.key] != nil }
                if !removed.isEmpty { built.remove(notIn: Set(rowsByID.keys)) }
                var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
                snapshot.appendSections([0])
                snapshot.appendItems(ids)
                snapshot.reconfigureItems(changed.filter { previousRows[$0] != nil && !reset })
                // Diffable updates can finish a self-sizing adjustment after
                // the first layout pass. Settle that same update before another
                // frame can display an offset based on the removed row heights.
                let settleLayout = { [weak table] in
                    guard let table else { return }
                    table.setNeedsLayout()
                    table.layoutIfNeeded()
                }
                UIView.performWithoutAnimation {
                    if reset { dataSource.applySnapshotUsingReloadData(snapshot, completion: settleLayout) }
                    else { dataSource.apply(snapshot, animatingDifferences: false, completion: settleLayout) }
                    // Diffable can publish its new content size before invoking
                    // the completion. Settle the current pass as well so a
                    // following-tail viewport never exposes that intermediate
                    // offset for one rendered frame under aggregate load.
                    settleLayout()
                }
            } else {
                // Unchanged history keeps its hosting views, text selection and
                // measured layout. Offscreen changes are rendered on reuse.
                let changed = Set(changed)
                for index in table.indexPathsForVisibleRows ?? [] {
                    let id = ids[index.row]
                    if changed.contains(id), let row = built[id], row.cell === table.cellForRow(at: index) {
                        configure(row, id: id)
                    }
                }
            }
            table.setNeedsLayout()
        }

        /// SwiftUI can apply this off the main thread, while a row animates on its own renderer: made on the main
        /// actor, the closure trapped there (Swift 6 isolation check). Rows hosted as a subview render that way.
        nonisolated private static func hostedEnvironment(from source: EnvironmentValues) -> (inout EnvironmentValues) -> Void {
            { applyHostedEnvironment(from: source, to: &$0) }
        }

        nonisolated private static func applyHostedEnvironment(from source: EnvironmentValues, to values: inout EnvironmentValues) {
            // Each hosting configuration owns its own layout/accessibility
            // bridge. Copy public presentation values and app dependencies,
            // never the parent hosting graph's private environment storage.
            values.appAppearance = source.appAppearance
            values.bighelpUIV2Enabled = source.bighelpUIV2Enabled
            values.bighelpUIV3Enabled = source.bighelpUIV3Enabled
            values.chatActivityDisclosureStore = source.chatActivityDisclosureStore
            values.bighelpActivityLoaderFocus = source.bighelpActivityLoaderFocus
            values.colorScheme = source.colorScheme
            values.dynamicTypeSize = source.dynamicTypeSize
            values.locale = source.locale
            values.layoutDirection = source.layoutDirection
            values.horizontalSizeClass = source.horizontalSizeClass
            values.verticalSizeClass = source.verticalSizeClass
            values.isEnabled = source.isEnabled
            values.openURL = source.openURL
            values.openWiki = source.openWiki
            values.openGitHub = source.openGitHub
            values.opensHostFiles = source.opensHostFiles
            values.chatOpenSentFile = source.chatOpenSentFile
            values.bighelpCardDataClient = source.bighelpCardDataClient
            values.bighelpSessionContentReader = source.bighelpSessionContentReader
            values.providerLogoStore = source.providerLogoStore
            // Agents' faces in rows (`AgentLiveAvatar`) draw their saved characters and pets.
            values.companionStore = source.companionStore
            values.companionAgentScope = source.companionAgentScope
            values.reflectiveVisionEnabled = source.reflectiveVisionEnabled
            values.reflectiveVisionCamera = source.reflectiveVisionCamera
            // The scene phase and card actions come live from `ChatRowLiveValues`.
        }

        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            guard orderedIDs.indices.contains(indexPath.row) else { return 120 }
            let id = orderedIDs[indexPath.row]
            let width = tableView.bounds.width
            if let measurement = heights[id], measurement.width == width { return measurement.height }
            if let estimate = estimates[id], estimate.width == width { return estimate.height }
            let estimate = estimatedHeight(id: id, in: tableView)
            estimates[id] = (width, estimate)
            return estimate
        }

        private func estimatedHeight(id: String, in tableView: UITableView) -> CGFloat {
            // A uniform 120-point estimate makes a tall streamed message look
            // like several short rows, provoking speculative sizing around
            // every tail insertion. These are estimates only; UIKit measures
            // the actual content before display.
            switch rowsByID[id] {
            case .bottom: return ChatBottomAnchorVisibility.contentBottomPadding + ChatBottomAnchorVisibility.anchorHeight
            case .workTrailEnd: return BighelpTokens.space4
            case .workTrailHeader, .agentTalk: return BighelpTokens.hitTarget + BighelpTokens.space8
            case .activityDetail: return 180
            case .transcript(.completed): return BighelpTokens.hitTarget + BighelpTokens.space16
            case .transcript(.entry(.message(let item))), .earlierMessage(let item), .staged(let item):
                guard case .message(let text) = item.content else { return 240 }
                let font = UIFont.bighelp(.body, compatibleWith: tableView.traitCollection)
                let width = max(80, min(tableView.bounds.width - 40, ChatCanvasLayout.regularLaneMaximumWidth))
                let columns = max(10, width / (font.pointSize * 0.5))
                return 110 + ChatCanvasTranscriptProjection.wrappedLineCount(text, columns: columns) * font.lineHeight
            default: return 120
            }
        }

        func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            // Height is keyed to the item still represented by this cell, not
            // a possibly shifted index following history insertion.
            guard let id = cell.accessibilityIdentifier else { return }
            if cell.bounds.height > 0 { heights[id] = (tableView.bounds.width, cell.bounds.height) }
            if let presence = built[id]?.state?.presence, presence.isOnScreen { presence.isOnScreen = false }
            DispatchQueue.main.async { [weak self] in self?.built.park(id) }
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            guard orderedIDs.indices.contains(indexPath.row) else { return }
            let id = orderedIDs[indexPath.row]
            cell.accessibilityIdentifier = id
            if let presence = built[id]?.state?.presence, !presence.isOnScreen { presence.isOnScreen = true }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard let table = scrollView as? ChatTimelineTableView else { return }
            prewarm?.cancel()
            table.followsTail = false
            table.isAnimatingReturn = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let table = scrollView as? ChatTimelineTableView else { return }
            lastScrolledAt = CACurrentMediaTime()
            publishPosition(of: table)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishInteraction(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishInteraction(scrollView) }

        private func finishInteraction(_ scrollView: UIScrollView) {
            guard let table = scrollView as? ChatTimelineTableView else { return }
            table.followsTail = table.distanceFromBottom <= ChatTimelineFollowState.nearBottomThreshold
            table.setNeedsLayout()
            publishPosition(of: table)
            schedulePrewarm(table)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard let table = scrollView as? ChatTimelineTableView else { return }
            table.isAnimatingReturn = false
            table.setNeedsLayout()
            schedulePrewarm(table)
        }

        private func publishPosition(of table: ChatTimelineTableView) {
            guard !publicationPending else { return }
            publicationPending = true
            // Publish only the UI-relevant boolean, outside UIKit/SwiftUI layout.
            DispatchQueue.main.async { [weak self, weak table] in
                guard let self else { return }
                self.publicationPending = false
                guard let table, self.controller?.table === table else { return }
                self.controller?.publish(isAtBottom: abs(table.distanceFromBottom) <= 1)
            }
        }
    }
}
