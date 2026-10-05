import Observation
import SwiftUI
import UIKit

/// The complete ordered canvas. Chrome and status rows participate in the same
/// native layout as messages, so there is no separately estimated live tail.
enum ChatCanvasRow: Identifiable, Equatable {
    case transcript(ChatTurnDisplayRow)
    /// A folder of tool calls. `isLive`: the agent is still working on it.
    case workTrailHeader(ChatActivityTurn, isLive: Bool)
    case activityDetail(ChatActivityEvent)
    case workTrailEnd(String)
    case earlierMessage(TimelineItem)
    case divider(String)
    case previousHistory(Bool, String?)
    case welcome, quickActions, bottom, botRetry
    case botStatus(String)
    case botApproval(HermesBotModePendingApproval)
    case botObservedTool(BotModeObservedTool, Bool)
    case botActivityNotice(String)
    case memberFailure(BotModeMemberFailure)
    case clarification(DashboardAttentionItem)
    case directClarification(DirectHermesPrompt)
    case pending(String, Bool)
    case failure(String)

    var id: String {
        switch self {
        case .transcript(let row): row.id
        case .workTrailHeader(let turn, _): "work-trail:\(turn.id)"
        case .activityDetail(let event): "activity-detail:\(event.id)"
        case .workTrailEnd(let id): "work-trail-end:\(id)"
        case .earlierMessage(let item): "earlier:\(item.id)"
        case .divider(let label): "divider:\(label)"
        case .previousHistory: "chat.previous-history"
        case .welcome: "chat.welcome"
        case .quickActions: "chat.quick-actions"
        case .bottom: "chat-bottom"
        case .botRetry: "chat.bot-retry"
        case .botStatus: "chat.bot-mode-status"
        case .botApproval(let approval): "chat.bot-approval:\(approval.id)"
        case .botObservedTool(let tool, _): "chat.bot-observed-tool:\(tool.id)"
        case .botActivityNotice: "chat.bot-activity-notice"
        case .memberFailure(let failure): "failure:\(failure.memberID)"
        case .clarification(let item): "chat.clarification.\(item.id)"
        case .directClarification(let prompt): "chat.direct-clarification.\(prompt.id)"
        case .pending: "chat-pending"
        case .failure: "chat.failure"
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.transcript(.entry(let a)), .transcript(.entry(let b))): a == b
        case (.transcript(.completed(let a)), .transcript(.completed(let b))):
            a.id == b.id && a.entries == b.entries && a.elapsedSeconds == b.elapsedSeconds && a.stepCount == b.stepCount
                && a.summary == b.summary
        case (.workTrailHeader(let a, let liveA), .workTrailHeader(let b, let liveB)): a == b && liveA == liveB
        case (.activityDetail(let a), .activityDetail(let b)): a == b
        case (.workTrailEnd(let a), .workTrailEnd(let b)): a == b
        case (.earlierMessage(let a), .earlierMessage(let b)): a == b
        case (.divider(let a), .divider(let b)), (.botStatus(let a), .botStatus(let b)), (.failure(let a), .failure(let b)): a == b
        case (.previousHistory(let a, let b), .previousHistory(let c, let d)): a == c && b == d
        case (.memberFailure(let a), .memberFailure(let b)): a == b
        case (.botApproval(let a), .botApproval(let b)): a == b
        case (.botObservedTool(let a, let expandedA), .botObservedTool(let b, let expandedB)):
            a == b && expandedA == expandedB
        case (.botActivityNotice(let a), .botActivityNotice(let b)): a == b
        case (.clarification(let a), .clarification(let b)): a == b
        case (.directClarification(let a), .directClarification(let b)): a == b
        case (.pending(let a, let b), .pending(let c, let d)): a == c && b == d
        case (.welcome, .welcome), (.quickActions, .quickActions), (.bottom, .bottom), (.botRetry, .botRetry): true
        default: false
        }
    }
}

/// Expanded groups share disclosure state, but each event gets a recycling
/// boundary. A hundred consecutive tools must not become one giant view tree.
@MainActor
enum ChatCanvasTranscriptProjection {
    static func rows(from displayRows: [ChatTurnDisplayRow], disclosures: ChatActivityDisclosureStore,
                     isSending: Bool = false) -> [ChatCanvasRow] {
        var result: [ChatCanvasRow] = []
        // While a turn runs, the folder at its tail is the work in progress:
        // the agent hasn't moved on to text, thinking or another folder yet.
        var tailEntryID: String?
        if isSending, case .entry(let entry)? = displayRows.last, case .activity = entry { tailEntryID = entry.id }
        func append(_ entry: ChatTranscriptEntry) {
            guard case .activity(let turn) = entry else {
                result.append(.transcript(.entry(entry)))
                return
            }
            let segments = ChatActivityTurnPresentation(turn: turn).segments
            for (index, segment) in segments.enumerated() {
                switch segment {
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
                                               stepCount: turn.stepCount, summary: turn.summary)
                result.append(.transcript(.completed(header)))
                if disclosures.isCompletedTurnExpanded(turn.id) {
                    turn.expandedEntries.forEach(append)
                }
            }
        }
        return result
    }
}

@MainActor @Observable
final class ChatTimelineController {
    private(set) var isAtBottom = true
    @ObservationIgnored fileprivate weak var table: ChatTimelineTableView?
    /// The chat's scroll view, for the blur under the header and message box.
    var scrollView: UIScrollView? { table }

    func beginReview() { table?.followsTail = false }

    func scrollToLatest(animated: Bool) {
        guard let table, !table.isUserInteracting else { return }
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
    var onLayout: (() -> Void)?
    #if DEBUG
    // Deterministic gesture tests avoid private UIScrollView state.
    var interactionStateOverride: Bool?
    var onProgrammaticContentOffsetWrite: (() -> Void)?
    #endif
    var isUserInteracting: Bool {
        #if DEBUG
        if let interactionStateOverride { return interactionStateOverride }
        #endif
        return isTracking || isDragging || isDecelerating
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
        super.layoutSubviews()
        if followsTail, !isUserInteracting, !isAnimatingReturn, bounds.height > 0,
           abs(distanceFromBottom) > 0.5 {
            setContentOffset(CGPoint(x: contentOffset.x, y: bottomOffset), animated: false)
        }
        onLayout?()
    }
}

@MainActor
struct NativeChatTimeline<Content: View>: UIViewRepresentable {
    let conversationID: String
    let ownerID: ObjectIdentifier
    let rows: [ChatCanvasRow]
    let controller: ChatTimelineController
    let entryCount: Int
    var contentInsets: UIEdgeInsets = .zero
    @ViewBuilder let rowContent: (ChatCanvasRow) -> Content
    /// Rows get a copy of the scene phase. Reading it here makes SwiftUI call
    /// updateUIView when it changes, so rows don't stay "inactive" from launch
    /// (which froze every working animation in chat).
    @Environment(\.scenePhase) private var scenePhase

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
        table.isPrefetchingEnabled = false
        table.selfSizingInvalidation = .enabled
        table.sectionHeaderTopPadding = 0
        table.allowsSelection = false
        #if !os(visionOS)
        table.keyboardDismissMode = .interactive
        #endif
        table.contentInsetAdjustmentBehavior = .automatic
        table.alwaysBounceVertical = true
        table.accessibilityIdentifier = "chat.timeline"
        table.register(UITableViewCell.self, forCellReuseIdentifier: "message")
        table.delegate = context.coordinator
        context.coordinator.install(on: table)
        return table
    }

    func updateUIView(_ table: ChatTimelineTableView, context: Context) {
        _ = scenePhase
        controller.table = table
        context.coordinator.scheduleUpdate(self, environment: context.environment, table: table)
    }

    static func dismantleUIView(_ table: ChatTimelineTableView, coordinator: Coordinator) {
        table.onLayout = nil
        table.delegate = nil
        coordinator.cancelPendingUpdate()
        if coordinator.controller?.table === table { coordinator.controller?.table = nil }
    }

    @MainActor @Observable
    final class HostedRowState {
        var row: ChatCanvasRow
        var render: (ChatCanvasRow) -> Content
        let generation: Int

        init(row: ChatCanvasRow, render: @escaping (ChatCanvasRow) -> Content, generation: Int) {
            self.row = row
            self.render = render
            self.generation = generation
        }
    }

    private struct HostedRow: View {
        let state: HostedRowState

        var body: some View {
            // Evaluate under a SwiftUI body observation scope. Building the
            // message here (rather than in the UIKit configuration closure)
            // keeps pending state, mode changes and sender stores live even
            // when the transcript item's value itself has not changed.
            state.render(state.row).id(state.row.id)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITableViewDelegate {
        weak var controller: ChatTimelineController?
        private var dataSource: UITableViewDiffableDataSource<Int, String>!
        private var rowsByID: [String: ChatCanvasRow] = [:]
        private var orderedIDs: [String] = []
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
            let disclosureStoreID: ObjectIdentifier?
            let cardInteractionScope: ChatCardInteractionScope?
            let hasContentReader: Bool
            let scenePhase: ScenePhase

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
                disclosureStoreID = environment.chatActivityDisclosureStore.map(ObjectIdentifier.init)
                cardInteractionScope = environment.chatCardInteractions?.scope
                hasContentReader = environment.bighelpSessionContentReader != nil
                scenePhase = environment.scenePhase
            }
        }
        private var style: Style?
        private var heights: [String: (width: CGFloat, height: CGFloat)] = [:]
        private var publicationPending = false
        private var presentationGeneration = 0
        private var pendingUpdate: (parent: NativeChatTimeline, environment: EnvironmentValues)?
        private var updateScheduled = false
        private let hostedRows = NSMapTable<UITableViewCell, HostedRowState>(
            keyOptions: .weakMemory, valueOptions: .strongMemory)

        func install(on table: ChatTimelineTableView) {
            dataSource = UITableViewDiffableDataSource(tableView: table) { [weak self] table, index, id in
                let cell = table.dequeueReusableCell(withIdentifier: "message", for: index)
                self?.configure(cell, id: id)
                return cell
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
            DispatchQueue.main.async { [weak self, weak table] in
                guard let self else { return }
                self.updateScheduled = false
                guard let table, let update = self.pendingUpdate else { return }
                self.pendingUpdate = nil
                self.update(update.parent, environment: update.environment, table: table)
                table.applyCustomContentInsets(update.parent.contentInsets)
                table.accessibilityValue = "\(update.parent.entryCount) conversation entries"
            }
        }

        func cancelPendingUpdate() {
            pendingUpdate = nil
        }

        private func configure(_ cell: UITableViewCell, id: String) {
            guard let row = rowsByID[id], let rowContent else { return }
            if let state = hostedRows.object(forKey: cell), state.row.id == id,
               state.generation == presentationGeneration {
                // Streaming changes the content inside the existing hosting
                // view. Reassigning its configuration makes UIKit remeasure
                // the hosting root in addition to the changed message.
                state.render = rowContent
                state.row = row
                return
            }
            let state = HostedRowState(row: row, render: rowContent, generation: presentationGeneration)
            hostedRows.setObject(state, forKey: cell)
            let environment = environment
            cell.backgroundColor = .clear
            cell.isOpaque = false
            cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
            cell.selectionStyle = .none
            let configuration = UIHostingConfiguration {
                HostedRow(state: state)
                    .transformEnvironment(\.self) { Self.applyHostedEnvironment(from: environment, to: &$0) }
                    .buttonStyle(.plain)
            }.margins(.all, 0)
            // The bottom spacer, and activity lines (which set their own touch
            // height), are shorter than a list row's default minimum height.
            // An unfolded trail's steps must sit flush so their line is unbroken.
            switch row {
            case .bottom, .workTrailEnd, .workTrailHeader, .activityDetail, .transcript(.completed),
                 .transcript(.entry(.activity)):
                cell.contentConfiguration = configuration.minSize(height: 0)
            default: cell.contentConfiguration = configuration
            }
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
            let nextStyle = Style(environment)
            let styleChanged = style != nextStyle
            style = nextStyle
            self.environment = environment
            let reset = conversationID != parent.conversationID || ownerID != parent.ownerID
            conversationID = parent.conversationID
            ownerID = parent.ownerID
            if reset {
                table.followsTail = true
                table.isAnimatingReturn = false
                heights.removeAll()
                hostedRows.removeAllObjects()
            }
            let previousRows = rowsByID
            rowsByID = Dictionary(uniqueKeysWithValues: parent.rows.map { ($0.id, $0) })
            let ids = parent.rows.map(\.id)
            let previousFirstID = orderedIDs.first
            if reset || styleChanged || previousFirstID != ids.first {
                presentationGeneration &+= 1
            }
            let changed = ids.filter {
                styleChanged || previousRows[$0] != rowsByID[$0]
                    || (previousFirstID != ids.first && ($0 == previousFirstID || $0 == ids.first))
            }
            for id in changed { heights[id] = nil }
            if ids != orderedIDs || reset {
                orderedIDs = ids
                heights = heights.filter { rowsByID[$0.key] != nil }
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
                for index in table.indexPathsForVisibleRows ?? [] {
                    let id = ids[index.row]
                    if changed.contains(id), let cell = table.cellForRow(at: index) {
                        configure(cell, id: id)
                    }
                }
            }
            table.setNeedsLayout()
        }

        private static func applyHostedEnvironment(from source: EnvironmentValues, to values: inout EnvironmentValues) {
            // Each hosting configuration owns its own layout/accessibility
            // bridge. Copy public presentation values and app dependencies,
            // never the parent hosting graph's private environment storage.
            values.appAppearance = source.appAppearance
            values.bighelpUIV2Enabled = source.bighelpUIV2Enabled
            values.bighelpUIV3Enabled = source.bighelpUIV3Enabled
            values.chatActivityDisclosureStore = source.chatActivityDisclosureStore
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
            values.chatCardInteractions = source.chatCardInteractions
            values.bighelpCardDataClient = source.bighelpCardDataClient
            values.bighelpSessionContentReader = source.bighelpSessionContentReader
            values.providerLogoStore = source.providerLogoStore
            values.reflectiveVisionEnabled = source.reflectiveVisionEnabled
            values.reflectiveVisionCamera = source.reflectiveVisionCamera
            values.scenePhase = source.scenePhase
        }

        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            guard orderedIDs.indices.contains(indexPath.row) else { return 120 }
            let id = orderedIDs[indexPath.row]
            if let measurement = heights[id], measurement.width == tableView.bounds.width { return measurement.height }
            // A uniform 120-point estimate makes a tall streamed message look
            // like several short rows, provoking speculative sizing around
            // every tail insertion. These are estimates only; UIKit measures
            // the actual content before display.
            switch rowsByID[id] {
            case .bottom: return ChatBottomAnchorVisibility.contentBottomPadding + ChatBottomAnchorVisibility.anchorHeight
            case .workTrailEnd: return BighelpTokens.space4
            case .workTrailHeader: return BighelpTokens.hitTarget + BighelpTokens.space8
            case .activityDetail: return 180
            case .transcript(.completed): return BighelpTokens.hitTarget + BighelpTokens.space16
            case .transcript(.entry(.message(let item))), .earlierMessage(let item):
                guard case .message(let text) = item.content else { return 240 }
                let font = UIFont.bighelp(.body, compatibleWith: tableView.traitCollection)
                let width = max(80, min(tableView.bounds.width - 40, ChatCanvasLayout.regularLaneMaximumWidth))
                let columns = max(10, width / (font.pointSize * 0.5))
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .reduce(CGFloat.zero) { $0 + max(1, ceil(CGFloat($1.count) / columns)) }
                return 110 + lines * font.lineHeight
            default: return 120
            }
        }

        func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            // Height is keyed to the item still represented by this cell, not
            // a possibly shifted index following history insertion.
            guard let id = cell.accessibilityIdentifier, cell.bounds.height > 0 else { return }
            heights[id] = (tableView.bounds.width, cell.bounds.height)
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            guard orderedIDs.indices.contains(indexPath.row) else { return }
            cell.accessibilityIdentifier = orderedIDs[indexPath.row]
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard let table = scrollView as? ChatTimelineTableView else { return }
            table.followsTail = false
            table.isAnimatingReturn = false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let table = scrollView as? ChatTimelineTableView else { return }
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
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            guard let table = scrollView as? ChatTimelineTableView else { return }
            table.isAnimatingReturn = false
            table.setNeedsLayout()
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
