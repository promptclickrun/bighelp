import SwiftUI
import UIKit

// A bot's Dashboard (the first tab of its profile in Bots mode): Feed, Ideas and Goals as piles of
// the boards' color blocks. Swipe the top card right to act on it, left to put it away; Undo shows
// after each swipe. Touch and hold (right-click on the Mac) has the card's usual menu, and VoiceOver
// has both swipes as actions, so swiping is never the only way. Rules: `BoardDashboard.swift`.

// MARK: - Model

/// The Dashboard's one sheet at a time.
enum BoardDashboardSheet: Identifiable, Equatable {
    case seeAll(AgentBoardItem.Kind), templates(AgentBoardItem.Kind), blueprints(AgentBoardItem.Kind)
    case post(String), idea(AgentBoardItem)

    var id: String {
        switch self {
        case .seeAll(let kind): "all.\(kind.rawValue)"
        case .templates(let kind): "templates.\(kind.rawValue)"
        case .blueprints(let kind): "blueprints.\(kind.rawValue)"
        case .post(let id): "post.\(id)"
        case .idea(let idea): "idea.\(idea.id)"
        }
    }
}

/// What one bot's Dashboard knows: its own board store, which follows the shell's connection, and
/// what this device keeps (Not today, cards taken to the chat, the Undo bar, the tutorial).
@MainActor
@Observable
final class BoardDashboardModel {
    /// What Undo puts back.
    struct Undo: Identifiable, Equatable {
        enum Revert: Equatable { case putBack, unhide, unmarkDone, unsnooze }
        let id = UUID()
        let item: AgentBoardItem?
        let message: String
        /// Nil for a plain notice (nothing to undo).
        let revert: Revert?
    }

    let agentID: String
    /// This bot's board. Its own store, so the shell's (the home agent's, which widgets show) stays put.
    let store = AgentBoardStore()
    private(set) var undo: Undo?
    var tutorialStep: DashboardTutorialStep?
    /// The sheet on the Dashboard. The model holds it so the profile can open one straight away
    /// (`BotProfileOpening`); the view clears it when it goes.
    var sheet: BoardDashboardSheet?
    /// What a closing sheet asked for runs once it has closed (a push under a closing sheet gets
    /// dropped).
    @ObservationIgnored var afterSheet: (() -> Void)?
    /// Asked about or taken to the chat: off the piles while this profile is open (the host keeps them).
    private var takenToChat: Set<String> = []
    /// Swiped and on their way to the host: off the piles at once, back if the host says no.
    private var inFlight: Set<String> = []
    /// Goals put away with Not today (`DashboardSnoozes`).
    private var snoozed: Set<String> = []
    /// The computer the board is on, for Not today's keys.
    private var scope = ""
    /// While the Dashboard is on screen; a late answer after it's gone opens nothing.
    @ObservationIgnored var isShown = false
    @ObservationIgnored private let snoozes: DashboardSnoozes
    @ObservationIgnored let tutorial: DashboardTutorial

    init(agentID: String, snoozes: DashboardSnoozes = DashboardSnoozes(), tutorial: DashboardTutorial = DashboardTutorial()) {
        self.agentID = agentID
        self.snoozes = snoozes
        self.tutorial = tutorial
    }

    func cards(_ kind: AgentBoardItem.Kind) -> [AgentBoardItem] {
        DashboardPiles.cards(kind, items: store.items, hidden: takenToChat.union(inFlight).union(snoozed))
    }

    /// Uses the shell's connection: the same computer and client, this bot's board.
    func follow(_ shell: AgentBoardStore) async {
        if let connection = shell.followableConnection {
            scope = connection.scope
            refreshSnoozes()
            await store.connect(client: connection.client, scope: connection.scope)
            if store.agentID != agentID || store.state == .idle { await store.load(agentID: agentID) }
        } else if shell.isWaitingForConnection {
            store.waitForConnection()
            await store.load(agentID: agentID)
        } else {
            store.configure(client: nil, isDisconnected: shell.isDisconnected)
        }
    }

    func refreshSnoozes(now: Date = .now) {
        let current = snoozes.snoozedGoalIDs(scope: scope, agentID: agentID, now: now)
        if current != snoozed { snoozed = current }
    }

    /// A swipe (or its VoiceOver action, or the menu's) on a card.
    func swipe(_ item: AgentBoardItem, _ direction: DashboardSwipeDirection, botName: String,
               onAsk: @escaping (String) -> Void) {
        let action = DashboardCardAction.action(for: item.kind, direction)
        let message = action.undoMessage(for: item.title, botName: botName)
        switch action {
        case .ask:
            takenToChat.insert(item.id)
            undo = Undo(item: item, message: message, revert: .putBack)
            onAsk("About “\(item.title)”: ")
        case .clear, .notNow:
            undo = Undo(item: item, message: message, revert: .unhide)
            run(item) { await $0.store.dismiss(item) }
        case .doIt:
            // Let's do it, as on Ideas: the host records the yes by the idea's ID before the chat opens.
            inFlight.insert(item.id)
            Task { [weak self] in
                guard let self else { return }
                let outcome = await store.accept(item)
                inFlight.remove(item.id)
                guard outcome != .failed else {
                    undo = Undo(item: nil, message: String(localized: "Couldn't tell \(botName) yet. Try again."), revert: nil)
                    return
                }
                guard isShown else { return }
                takenToChat.insert(item.id)
                undo = Undo(item: item, message: message, revert: .putBack)
                onAsk(item.letsDoItMessage)
            }
        case .markDone:
            undo = Undo(item: item, message: message, revert: .unmarkDone)
            run(item) { await $0.store.setDone(item, true) }
        case .notToday:
            // Kept per computer; before the Dashboard knows which, it only hides the card here.
            if !scope.isEmpty { snoozes.snooze(goalID: item.id, scope: scope, agentID: agentID) }
            snoozed.insert(item.id)
            undo = Undo(item: item, message: message, revert: .unsnooze)
        case .useTemplate, .skipTemplate:
            break
        }
    }

    /// Hidden from the pile at once; the store's own optimistic change takes over, and puts it
    /// back if the host refuses.
    private func run(_ item: AgentBoardItem, _ work: @escaping @MainActor (BoardDashboardModel) async -> Void) {
        inFlight.insert(item.id)
        Task { [weak self] in
            guard let self else { return }
            await work(self)
            inFlight.remove(item.id)
        }
    }

    func performUndo() {
        guard let undo, let item = undo.item, let revert = undo.revert else { self.undo = nil; return }
        self.undo = nil
        switch revert {
        case .putBack: takenToChat.remove(item.id)
        case .unhide: Task { await store.undoHide() }
        case .unmarkDone: Task { await store.setDone(item, false) }
        case .unsnooze:
            snoozes.unsnooze(goalID: item.id, scope: scope, agentID: agentID)
            snoozed.remove(item.id)
        }
    }

    func expire(_ shown: Undo) {
        guard undo?.id == shown.id else { return }
        undo = nil
        if shown.revert == .unhide, let item = shown.item { store.clearUndo(item) }
    }

    /// A dismiss from a card's menu (Clear, Not now, Remove) gets the same Undo bar.
    func noticeHidden(_ item: AgentBoardItem) {
        guard undo?.item?.id != item.id else { return }
        undo = Undo(item: item, message: BoardDismissAction(kind: item.kind).undoMessage(for: item.title), revert: .unhide)
    }

    func startTutorialIfNeeded(cardCount: Int) {
        guard tutorialStep == nil, tutorial.shouldShow(cardCount: cardCount) else { return }
        tutorialStep = .swipeLeft
    }

    func finishTutorial() {
        tutorial.markSeen()
        tutorialStep = nil
    }
}

extension AgentBoardItem.Kind {
    /// The page's name, over its pile and on Templates' switch.
    var pageTitle: String {
        switch self {
        case .feed: String(localized: "Feed")
        case .idea: String(localized: "Ideas")
        case .goal: String(localized: "Goals")
        }
    }

    /// The page's own block color, on Templates' switch.
    var pageColor: BighelpBlockColor {
        switch self {
        case .feed: .sky
        case .idea: .lilac
        case .goal: .lime
        }
    }
}

extension DashboardCardAction {
    func stamp(botName: String) -> DashboardStamp {
        DashboardStamp(title: title(botName: botName), systemImage: systemImage, detail: detail, isPositive: isPositive)
    }
}

/// What a card shows while it's dragged: the action letting go will run.
struct DashboardStamp: Equatable {
    let title: String
    let systemImage: String
    var detail: String?
    let isPositive: Bool
}

// MARK: - Dashboard

/// What goes on top of the screen, not inside the scrolling Dashboard: the Undo bar and the tutorial.
struct BoardDashboardOverlays: ViewModifier {
    let model: BoardDashboardModel?
    let isActive: Bool
    let botName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if isActive, let model, let undo = model.undo {
                    DashboardUndoBar(message: undo.message, showsUndo: undo.revert != nil,
                                     onUndo: { model.performUndo() }, onExpire: { model.expire(undo) })
                        .id(undo.id)
                        .padding(.bottom, BighelpTokens.space12)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .overlay {
                if isActive, let model, model.tutorialStep != nil {
                    DashboardTutorialOverlay(model: model, botName: botName)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: model?.undo?.id)
            .animation(.easeOut(duration: 0.2), value: model?.tutorialStep == nil)
    }
}

/// The Dashboard tab: Templates, then the Feed, Ideas and Goals piles.
struct BoardDashboardView: View {
    @Bindable var model: BoardDashboardModel
    /// The bot's board, with its chat for Ask and blueprints.
    let context: AgentBoardContext
    /// The shell's board, whose connection this one follows.
    let shellBoard: AgentBoardStore
    /// The connection the shell's board should be on now (`RootShellView.agentBoardClientKey`).
    let shellBoardKey: @MainActor () -> RootShellView.AgentBoardClientKey
    let configureShellBoard: @MainActor (RootShellView.AgentBoardClientKey) async -> Void

    @State private var filling: BoardBlueprint?
    @Environment(\.scenePhase) private var scenePhase
    @BighelpThemeReader private var theme

    private struct FollowKey: Equatable {
        let connection: RootShellView.AgentBoardClientKey
        let client: ObjectIdentifier?
        let waiting: Bool
        let disconnected: Bool
    }

    var body: some View {
        let store = model.store
        let piles = AgentBoardItem.Kind.dashboardOrder.map { ($0, model.cards($0)) }
        let cardCount = piles.map(\.1.count).reduce(0, +)
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            templatesRow
            switch store.state {
            case .failed, .unavailable:
                BoardStateBanner(state: store.state, context: context)
            default:
                EmptyView()
            }
            ForEach(piles, id: \.0) { kind, cards in
                DashboardSection(kind: kind, cards: cards, model: model, context: context,
                                 isLoading: store.state != .loaded && store.items.isEmpty,
                                 neverHad: DashboardPiles.neverHad(kind, items: store.items),
                                 onSeeAll: { model.sheet = .seeAll(kind) },
                                 onTemplates: { model.sheet = .templates(kind) },
                                 onOpen: { open($0) })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard")
        .task(id: FollowKey(connection: shellBoardKey(),
                            client: shellBoard.followableConnection.map { ObjectIdentifier($0.client) },
                            waiting: shellBoard.isWaitingForConnection, disconnected: shellBoard.isDisconnected)) {
            // The shell sets its board up in a root task, which waits while this profile (or the
            // chat it came from) covers the root: bring it to the connection of the moment first.
            // Its own task, so this one ending for the new connection never cuts it short.
            let connection = shellBoardKey()
            await Task { await configureShellBoard(connection) }.value
            guard !Task.isCancelled else { return }
            await model.follow(shellBoard)
        }
        .task(id: store.state == .loaded && cardCount > 0) {
            guard store.state == .loaded else { return }
            // A moment, so the piles have settled before the page dims.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            model.startTutorialIfNeeded(cardCount: cardCount)
        }
        .onChange(of: store.recentlyHidden?.id) { _, _ in
            if let hidden = store.recentlyHidden { model.noticeHidden(hidden) }
        }
        .onChange(of: scenePhase) { _, phase in
            // Not today runs out at midnight.
            if phase == .active { model.refreshSnoozes() }
        }
        .onAppear { model.isShown = true }
        .onDisappear {
            model.isShown = false
            // A sheet doesn't outlive the tab it was opened from.
            model.sheet = nil
            model.afterSheet = nil
        }
        .bighelpSheet(item: $model.sheet, onDismiss: {
            let next = model.afterSheet
            model.afterSheet = nil
            next?()
        }) { shown in
            sheetContent(shown)
        }
        .blueprintFill($filling, context: context)
    }

    private var templatesRow: some View {
        Button { model.sheet = .templates(.feed) } label: {
            HStack(spacing: BighelpTokens.space8) {
                Image(systemName: "square.grid.2x2")
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Text("Templates")
                    .font(.bighelp(.title3, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: BighelpTokens.space8)
                DashboardSeeAllLabel(title: String(localized: "Browse"))
            }
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .bighelpPlainButtonStyle()
        .accessibilityLabel("Templates")
        .accessibilityHint("Starter prompts for Feed, Ideas and Goals, one card at a time")
        .driveTarget("dashboard.templates")
        .accessibilityIdentifier("dashboard.templates")
    }

    private func open(_ item: AgentBoardItem) {
        switch item.kind {
        case .feed: model.sheet = .post(item.id)
        case .idea: model.sheet = .idea(item)
        case .goal: model.sheet = .seeAll(.goal)
        }
    }

    @ViewBuilder
    private func sheetContent(_ shown: BoardDashboardSheet) -> some View {
        let inSheet = closingFirst(context)
        switch shown {
        case .seeAll(let kind):
            Group {
                switch kind {
                case .feed: AgentFeedView(context: inSheet)
                case .idea: AgentIdeasView(context: inSheet)
                case .goal: AgentGoalsView(context: inSheet)
                }
            }
            .presentationDragIndicator(.visible)
            .bighelpSheetSize(.large)
        case .templates(let kind):
            DashboardTemplatesSheet(kind: kind, botName: context.agentName,
                                    onUse: { blueprint in after { use(blueprint) } },
                                    onSeeEvery: { kind in
                                        // The full list replaces the deck once it has closed.
                                        model.afterSheet = { model.sheet = .blueprints(kind) }
                                        model.sheet = nil
                                    })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
        case .blueprints(let kind):
            BoardBlueprintsSheet(kind: kind, agentName: context.agentName,
                                 blueprints: BoardBlueprintCatalog.shared.blueprints(for: kind),
                                 onSend: { text in after { context.onSend(text) } },
                                 onEdit: { text in after { context.onAsk(text) } })
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
        case .post(let id):
            FeedPostDetailSheet(itemID: id, context: inSheet)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
        case .idea(let idea):
            IdeaDetailSheet(idea: idea, context: inSheet)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
        }
    }

    /// Closes the sheet, then does what it asked.
    private func after(_ action: @escaping () -> Void) {
        model.afterSheet = action
        model.sheet = nil
    }

    /// As tapping a blueprint on its page: [blanks] first, then the message box; nothing is sent.
    private func use(_ blueprint: BoardBlueprint) {
        if blueprint.needsFilling {
            filling = blueprint
        } else {
            TemplateUsage.shared.recordUse(blueprint.id)
            context.onAsk(blueprint.text)
        }
    }

    /// The same board, for a page in the sheet: going to the chat closes the sheet first.
    private func closingFirst(_ context: AgentBoardContext) -> AgentBoardContext {
        AgentBoardContext(
            agentID: context.agentID, agentName: context.agentName, imageURL: context.imageURL,
            activity: context.activity, store: context.store,
            onProfile: { model.sheet = nil }, onSwitchAgent: {},
            onAsk: { text in after { context.onAsk(text) } },
            onSend: { text in after { context.onSend(text) } },
            onMenu: {}, onNewChat: { after { context.onNewChat() } }, onPickAgents: {},
            tools: [], onBack: { model.sheet = nil })
    }
}

extension AgentBoardItem.Kind {
    static let dashboardOrder: [Self] = [.feed, .idea, .goal]
}

/// "See all ›" and "Browse ›": the small link at the end of a section's header.
private struct DashboardSeeAllLabel: View {
    let title: String
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
            Image(systemName: "chevron.right").imageScale(.small)
        }
        .font(.bighelp(.subheadline, weight: .medium))
        .foregroundStyle(theme.secondaryText)
    }
}

// MARK: - A section

/// One pile with its header: title, how many cards, See all.
private struct DashboardSection: View {
    let kind: AgentBoardItem.Kind
    let cards: [AgentBoardItem]
    let model: BoardDashboardModel
    let context: AgentBoardContext
    let isLoading: Bool
    let neverHad: Bool
    let onSeeAll: () -> Void
    let onTemplates: () -> Void
    let onOpen: (AgentBoardItem) -> Void
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 176
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            header
            if let top = cards.first {
                DashboardPileStack(layers: cards.prefix(3).map { DashboardPileLayer(id: $0.id, color: color($0)) },
                                   height: cardHeight) {
                    card(top)
                }
            } else if isLoading {
                DashboardPlainCard(height: cardHeight) {
                    Text("Loading…")
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if neverHad {
                emptyCard
            } else {
                caughtUpCard
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.\(kind.rawValue)")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
            Text(kind.pageTitle)
                .font(.bighelp(.title3, weight: .bold))
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            if !cards.isEmpty {
                Text(cards.count, format: .number)
                    .font(.bighelp(.subheadline, weight: .medium))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityLabel(cards.count == 1 ? "1 card" : "\(cards.count) cards")
                    .accessibilityIdentifier("dashboard.\(kind.rawValue).count")
            }
            Spacer(minLength: BighelpTokens.space8)
            Button(action: onSeeAll) {
                DashboardSeeAllLabel(title: String(localized: "See all"))
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .bighelpPlainButtonStyle()
            .accessibilityLabel("See all of \(kind.pageTitle)")
            .driveTarget("dashboard.\(kind.rawValue).see-all")
            .accessibilityIdentifier("dashboard.\(kind.rawValue).see-all")
        }
    }

    private func color(_ item: AgentBoardItem) -> BighelpBlockColor {
        switch item.kind {
        // What's new gets the Feed's deep green, as its "new today" block does.
        case .feed: context.store.supportsFeedback && !item.read ? .forest : .feed(item)
        case .idea: .idea(item)
        case .goal: .goal(item.goalCategory ?? .other)
        }
    }

    private func card(_ item: AgentBoardItem) -> some View {
        let right = DashboardCardAction.action(for: kind, .right)
        let left = DashboardCardAction.action(for: kind, .left)
        let swipe: (DashboardSwipeDirection) -> Void = { direction in
            model.swipe(item, direction, botName: context.agentName, onAsk: context.onAsk)
        }
        return DashboardSwipeCard(
            right: right.stamp(botName: context.agentName), left: left.stamp(botName: context.agentName),
            accessibilityLabel: DashboardItemFace.spoken(item), identifier: "dashboard.card.\(item.id)",
            onOpen: { onOpen(item) }, onSwipe: swipe
        ) {
            DashboardItemFace(item: item, color: color(item), height: cardHeight, isNew: context.store.supportsFeedback && !item.read)
        } menu: {
            DashboardCardMenu(item: item, context: context, onSwipe: swipe)
        }
        .id(item.id)
    }

    private var emptyCopy: (symbol: String, title: String, message: String, ask: String) {
        switch kind {
        case .feed: ("newspaper", String(localized: "No posts yet"),
                     String(localized: "Ask \(context.agentName) for a morning brief or news you care about."),
                     "Every evening, post the top three AI stories to my feed.")
        case .idea: ("lightbulb", String(localized: "No ideas yet"),
                     String(localized: "Ask \(context.agentName) to suggest things it could take off your plate."),
                     "Look through my week and suggest a few things you could take off my plate.")
        case .goal: ("flag", String(localized: "No goals yet"),
                     String(localized: "Tell \(context.agentName) something you want to work on."),
                     GoalCategory.other.prompt)
        }
    }

    /// Nothing here yet, by design: no AI runs until the person asks.
    private var emptyCard: some View {
        let copy = emptyCopy
        return DashboardPlainCard(height: nil) {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                Label(copy.title, systemImage: copy.symbol)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                Text(copy.message + " " + String(localized: "It opens the chat with a suggestion to edit; nothing runs until you tap Send."))
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BighelpTokens.space8) { askButton(copy.ask); templateButton }
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) { askButton(copy.ask); templateButton }
                }
                .padding(.top, BighelpTokens.space4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.\(kind.rawValue).empty")
    }

    private func askButton(_ suggestion: String) -> some View {
        Button { context.onAsk(suggestion) } label: {
            BoardActionPillLabel(title: String(localized: "Ask \(context.agentName)"), systemImage: "bubble.left")
                .fixedSize()
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier("dashboard.\(kind.rawValue).empty.ask")
    }

    private var templateButton: some View {
        Button(action: onTemplates) {
            // A quiet second choice beside Ask, so an empty section stays short.
            Label("Start from a template", systemImage: "square.grid.2x2")
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
                .padding(.horizontal, BighelpTokens.space4)
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
                .fixedSize()
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier("dashboard.\(kind.rawValue).empty.templates")
    }

    private var caughtUpCard: some View {
        DashboardPlainCard(height: nil) {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text("You’re all caught up")
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                Text(caughtUpMessage)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                Button(action: onSeeAll) {
                    Text("See all in \(kind.pageTitle)")
                        .font(.bighelp(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.action)
                        .frame(minHeight: BighelpTokens.hitTarget)
                        .contentShape(.rect)
                }
                .bighelpPlainButtonStyle()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.\(kind.rawValue).caught-up")
    }

    private var caughtUpMessage: String {
        switch kind {
        case .feed: String(localized: "New posts land here.")
        case .idea: String(localized: "New ideas land here.")
        case .goal: String(localized: "Goals you put away for today come back tomorrow.")
        }
    }
}

/// A card's long-press menu: its page's menu, with the swipes that menu doesn't have on top.
private struct DashboardCardMenu: View {
    let item: AgentBoardItem
    let context: AgentBoardContext
    let onSwipe: (DashboardSwipeDirection) -> Void

    var body: some View {
        switch item.kind {
        case .idea:
            let doIt = DashboardCardAction.doIt
            Button(doIt.title(botName: context.agentName), systemImage: doIt.systemImage) { onSwipe(.right) }
        case .goal:
            let notToday = DashboardCardAction.notToday
            Button(notToday.title(botName: context.agentName), systemImage: notToday.systemImage) { onSwipe(.left) }
        case .feed:
            EmptyView()
        }
        BoardItemMenu.info(item, context: context)
        // Thumbs down's "Less like this?" needs a dialog the Dashboard doesn't host; the page has it.
        BoardItemMenu.items(item, context: context, asksWhy: .constant(false), includesShare: true)
    }
}

/// A plain card with a hairline edge, for empty, caught-up and loading.
private struct DashboardPlainCard<Content: View>: View {
    let height: CGFloat?
    @ViewBuilder let content: () -> Content
    @BighelpThemeReader private var theme

    var body: some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: BoardBlockMetrics.blockRadius, style: .continuous)
                .fill(theme.canvas))
            .overlay(RoundedRectangle(cornerRadius: BoardBlockMetrics.blockRadius, style: .continuous)
                .strokeBorder(theme.separator))
    }
}

// MARK: - Piles

struct DashboardPileLayer: Identifiable, Equatable {
    let id: String
    let color: BighelpBlockColor
}

/// Up to three cards, the top one whole and the next ones peeking out under it. When the top
/// goes, the next slides up into its place.
struct DashboardPileStack<Top: View>: View {
    let layers: [DashboardPileLayer]
    let height: CGFloat
    @ViewBuilder let top: () -> Top
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme

    private static var peek: CGFloat { 9 }

    var body: some View {
        ZStack(alignment: .top) {
            ForEach(Array(layers.enumerated()), id: \.element.id) { depth, layer in
                Group {
                    if depth == 0 {
                        top()
                    } else {
                        RoundedRectangle(cornerRadius: BoardBlockMetrics.blockRadius, style: .continuous)
                            .fill(layer.color.fill(dark: theme.isDarkPalette))
                            .frame(height: height)
                            .accessibilityHidden(true)
                    }
                }
                .scaleEffect(1 - 0.05 * CGFloat(depth), anchor: .bottom)
                .offset(y: Self.peek * CGFloat(depth))
                .zIndex(Double(-depth))
            }
        }
        .frame(height: height + Self.peek * 2, alignment: .top)
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: layers.first?.id)
    }
}

/// A Feed, Ideas or Goals card's face: its label and time, title (two lines) and a short preview.
/// No closures, so dragging the card above it doesn't draw it again.
private struct DashboardItemFace: View, Equatable {
    let item: AgentBoardItem
    let color: BighelpBlockColor
    let height: CGFloat
    let isNew: Bool

    var body: some View {
        let ink = color.ink
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: BighelpTokens.space8) {
                BoardOutlinePill(title: tag, systemImage: tagImage, ink: ink)
                Spacer(minLength: 0)
                Text(Self.when(item))
                    .font(.bighelp(.caption, weight: .medium))
                    .foregroundStyle(ink.opacity(0.7))
                    .lineLimit(1)
            }
            Text(item.title)
                .font(.bighelp(.title3, weight: .bold))
                .tracking(-0.2)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.top, BighelpTokens.space4)
            if !detail.isEmpty {
                Text(detail)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(ink.opacity(0.8))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .boardBlock(color, padding: 18)
        .frame(height: height)
    }

    private var tag: String {
        switch item.kind {
        case .feed:
            let source = item.source.isEmpty ? String(localized: "Post") : item.source
            return isNew ? String(localized: "New · \(source)") : source
        case .idea:
            let section = item.section.trimmingCharacters(in: .whitespaces)
            return section.isEmpty ? String(localized: "Idea") : section
        case .goal:
            return (item.goalCategory ?? .other).groupTitle
        }
    }

    private var tagImage: String? {
        switch item.kind {
        case .feed: isNew ? "circle.fill" : nil
        case .idea: nil
        case .goal: (item.goalCategory ?? .other).systemImage
        }
    }

    /// A goal's latest note, else the words without Markdown's symbols.
    private var detail: String {
        if item.kind == .goal { return item.note }
        return MarkdownDocument(item.body).visiblePlainText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func when(_ item: AgentBoardItem, now: Date = .now, calendar: Calendar = .current) -> String {
        let date = item.kind == .goal ? item.updatedAt : item.createdAt
        let text: String
        if calendar.isDate(date, inSameDayAs: now) {
            text = item.kind == .goal ? String(localized: "today") : date.formatted(date: .omitted, time: .shortened)
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            text = String(localized: "Yesterday")
        } else if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            text = date.formatted(.dateTime.weekday(.abbreviated))
        } else {
            text = date.formatted(.dateTime.month(.abbreviated).day())
        }
        return item.kind == .goal ? String(localized: "Updated \(text)") : text
    }

    /// What VoiceOver reads for the card.
    static func spoken(_ item: AgentBoardItem) -> String {
        [item.kind.pageTitle, item.title, item.kind == .goal ? item.note : ""]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - The swipe card

/// A card that follows the finger sideways with a slight tilt, a stamp fading in for what letting
/// go will do. Past `DashboardSwipe.threshold` (or a flick) it flies off and `onSwipe` runs;
/// short of it, it springs back. Reduce Motion: no tilt, and it fades instead of flying.
/// Only this view's offset changes while dragging; the face is drawn once.
struct DashboardSwipeCard<Face: View, MenuItems: View>: View {
    let right: DashboardStamp
    let left: DashboardStamp
    let accessibilityLabel: String
    let identifier: String
    let onOpen: (() -> Void)?
    let allows: (DashboardSwipeDirection) -> Bool
    let onSwipe: (DashboardSwipeDirection) -> Void
    let face: () -> Face
    let menu: () -> MenuItems

    @State private var offset: CGFloat = 0
    @State private var isPast = false
    @State private var isGone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(right: DashboardStamp, left: DashboardStamp, accessibilityLabel: String, identifier: String,
         onOpen: (() -> Void)? = nil, allows: @escaping (DashboardSwipeDirection) -> Bool = { _ in true },
         onSwipe: @escaping (DashboardSwipeDirection) -> Void,
         @ViewBuilder face: @escaping () -> Face, @ViewBuilder menu: @escaping () -> MenuItems) {
        self.right = right; self.left = left; self.accessibilityLabel = accessibilityLabel
        self.identifier = identifier; self.onOpen = onOpen; self.allows = allows; self.onSwipe = onSwipe
        self.face = face; self.menu = menu
    }

    var body: some View {
        // The stamp is solid well before the line, so it reads over the card's own label.
        let progress = min(1, DashboardSwipe.progress(offset) * 1.6)
        face()
            .overlay(alignment: .topLeading) {
                DashboardStampView(stamp: right).opacity(offset > 0 ? progress : 0).padding(16)
            }
            .overlay(alignment: .topTrailing) {
                DashboardStampView(stamp: left).opacity(offset < 0 ? progress : 0).padding(16)
            }
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: BoardBlockMetrics.blockRadius, style: .continuous))
            .contentShape(.rect)
            .onTapGesture { onOpen?() }
            .contextMenu { menu() }
            .rotationEffect(.degrees(reduceMotion ? 0 : Double(offset / 18)), anchor: .bottom)
            .offset(x: offset)
            .opacity(isGone ? 0 : 1)
            .modifier(DashboardHorizontalPan(onChanged: changed, onEnded: ended))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
            .accessibilityAction { onOpen?() }
            .accessibilityAction(named: Text(right.title)) { if allows(.right) { onSwipe(.right) } }
            .accessibilityAction(named: Text(left.title)) { if allows(.left) { onSwipe(.left) } }
            .accessibilityIdentifier(identifier)
    }

    private func changed(_ translation: CGFloat) {
        offset = translation
        let past = abs(translation) >= DashboardSwipe.threshold
        if past != isPast {
            isPast = past
            if past { BighelpHaptics.tap() }
        }
    }

    private func ended(_ translation: CGFloat, _ velocity: CGFloat) {
        isPast = false
        guard let direction = DashboardSwipe.decide(translation: translation, velocity: velocity), allows(direction) else {
            withAnimation(reduceMotion ? .linear(duration: 0.12) : .spring(response: 0.32, dampingFraction: 0.68)) {
                offset = 0
            }
            return
        }
        let finish = {
            onSwipe(direction)
            // The pile drops this card; if it stays (a refused action), it's back in place.
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { offset = 0; isGone = false }
        }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) { isGone = true } completion: { finish() }
        } else {
            withAnimation(.easeIn(duration: 0.22)) { offset = direction == .right ? 720 : -720 } completion: { finish() }
        }
    }
}

/// The pill on a dragged card: the person's color for acting, an outline for putting away.
private struct DashboardStampView: View {
    let stamp: DashboardStamp
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: stamp.systemImage).font(.bighelp(.subheadline, weight: .bold))
            Text(stamp.title).font(.bighelp(.subheadline, weight: .bold))
            if let detail = stamp.detail {
                Text("· \(detail)").font(.bighelp(.caption)).opacity(0.8)
            }
        }
        .lineLimit(1)
        .foregroundStyle(stamp.isPositive ? theme.actionForeground : theme.primaryText)
        .padding(.horizontal, 14)
        .frame(minHeight: 34)
        .background(Capsule().fill(stamp.isPositive ? theme.action : theme.canvas))
        .overlay { if !stamp.isPositive { Capsule().strokeBorder(theme.separator) } }
        .accessibilityHidden(true)
    }
}

/// A sideways drag that leaves up-and-down to the page's scrolling. iOS 18 and later use a UIKit
/// pan that only starts when the finger moves more sideways than up or down, so the page never
/// scrolls under a swipe; iOS 17 and Vision Pro (which has no UIKit gesture bridge) lock a
/// SwiftUI drag to its first direction.
private struct DashboardHorizontalPan: ViewModifier {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
    @State private var isHorizontal: Bool?

    func body(content: Content) -> some View {
        #if os(visionOS)
        locked(content)
        #else
        if #available(iOS 18.0, *) {
            content.gesture(HorizontalPanRecognizer(onChanged: onChanged, onEnded: onEnded))
        } else {
            locked(content)
        }
        #endif
    }

    private func locked(_ content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in
                    if isHorizontal == nil {
                        isHorizontal = abs(value.translation.width) > abs(value.translation.height) * 1.2
                    }
                    if isHorizontal == true { onChanged(value.translation.width) }
                }
                .onEnded { value in
                    defer { isHorizontal = nil }
                    guard isHorizontal == true else { return }
                    onEnded(value.translation.width, value.velocity.width)
                }
        )
    }
}

#if !os(visionOS)
@available(iOS 18.0, *)
private struct HorizontalPanRecognizer: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            onEnded(0, 0)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}

#endif

// MARK: - Undo

/// "Cleared …" with Undo, for a few seconds after each swipe.
private struct DashboardUndoBar: View {
    let message: String
    let showsUndo: Bool
    let onUndo: () -> Void
    let onExpire: () -> Void
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            Text(message)
                .font(.bighelp(.subheadline, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .lineLimit(2)
                .accessibilityIdentifier("dashboard.undo.message")
            Spacer(minLength: BighelpTokens.space8)
            if showsUndo {
                Button("Undo", action: onUndo)
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.action)
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .accessibilityIdentifier("dashboard.undo")
            }
        }
        .padding(.horizontal, BighelpTokens.space16)
        .frame(minHeight: BighelpTokens.hitTarget)
        .frame(maxWidth: 520)
        .bighelpNavigationGlass(in: Capsule())
        .padding(.horizontal, BighelpTokens.space20)
        .task {
            // Longer with VoiceOver, so there's time to reach it.
            try? await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 10 : 5))
            guard !Task.isCancelled else { return }
            onExpire()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.undo-bar")
    }
}

// MARK: - Tutorial

/// The first time a Dashboard has a card: a dimmed page with one practice card. Swipe it left,
/// then right; Skip any time. Nothing on the board changes.
private struct DashboardTutorialOverlay: View {
    let model: BoardDashboardModel
    let botName: String
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 190
    @BighelpThemeReader private var theme

    var body: some View {
        let step = model.tutorialStep ?? .done
        ZStack(alignment: .top) {
            Rectangle().fill(.ultraThinMaterial).overlay(Color.black.opacity(0.5))
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture {}
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BighelpTokens.space20) {
                HStack {
                    Spacer()
                    Button { model.finishTutorial() } label: {
                        Text("Skip")
                            .font(.bighelp(.subheadline, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, BighelpTokens.space16)
                            .frame(minHeight: BighelpTokens.hitTarget)
                            .background(Capsule().fill(.white.opacity(0.18)))
                            .contentShape(.capsule)
                    }
                    .bighelpPlainButtonStyle()
                    .accessibilityIdentifier("dashboard.tutorial.skip")
                }
                if step == .done {
                    finalCard
                } else {
                    VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                        Text("Sort with a swipe")
                            .font(.bighelp(.title, weight: .bold))
                            .foregroundStyle(.white)
                            .accessibilityAddTraits(.isHeader)
                        Text("Each section is a pile. Swipe the top card to go to the next one.")
                            .font(.bighelp(.body))
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    practiceCard(step)
                        .id(step)
                        .transition(.opacity)
                    VStack(spacing: BighelpTokens.space4) {
                        Text("Your turn").font(.bighelp(.headline)).foregroundStyle(.white)
                        Text("Touch and hold a card any time for every choice.")
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(BighelpTokens.space24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .animation(.easeOut(duration: 0.2), value: step)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.tutorial")
        .accessibilityAddTraits(.isModal)
    }

    private func practiceCard(_ step: DashboardTutorialStep) -> some View {
        let isLeft = step == .swipeLeft
        return DashboardSwipeCard(
            right: DashboardStamp(title: String(localized: "Act"), systemImage: "checkmark", isPositive: true),
            left: DashboardStamp(title: String(localized: "Put away"), systemImage: "xmark", isPositive: false),
            accessibilityLabel: isLeft ? String(localized: "Practice card. Swipe left to put a card away.")
                                       : String(localized: "Practice card. Now swipe right to act on it."),
            identifier: "dashboard.tutorial.card",
            allows: { $0 == step.expected },
            onSwipe: { direction in model.tutorialStep = step.after(direction) }
        ) {
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                HStack {
                    Text("Try it")
                        .font(.bighelp(.caption, weight: .bold))
                        .foregroundStyle(theme.actionForeground)
                        .padding(.horizontal, BighelpTokens.space8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.action))
                    Spacer()
                    Text(isLeft ? "1 of 2" : "2 of 2")
                        .font(.bighelp(.caption, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }
                Text(isLeft ? "Swipe left to put a card away" : "Now swipe right to act on it")
                    .font(.bighelp(.title3, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                Text(isLeft ? "Try it on this card. Undo shows after every swipe."
                            : "Right asks about a post, does an idea or marks a goal done.")
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Label(isLeft ? "Drag it to the left" : "Drag it to the right",
                      systemImage: isLeft ? "arrow.left" : "arrow.right")
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: cardHeight)
            .background(RoundedRectangle(cornerRadius: BoardBlockMetrics.blockRadius, style: .continuous)
                .fill(theme.isDarkPalette ? theme.surface : theme.canvas))
        } menu: {
            EmptyView()
        }
    }

    private var finalCard: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Text("That’s it")
                .font(.bighelp(.title2, weight: .bold))
                .foregroundStyle(theme.primaryText)
            Text("Left puts a card away. Right acts on it. Touch and hold any card for more.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                legend(String(localized: "Feed"), String(localized: "Clear · Ask \(botName)"))
                legend(String(localized: "Ideas"), String(localized: "Not now · Do it"))
                legend(String(localized: "Goals"), String(localized: "Not today · Mark done"))
                legend(String(localized: "Changed your mind?"), String(localized: "Undo shows after each swipe"))
            }
            Button { model.finishTutorial() } label: {
                Text("Got it")
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.actionForeground)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                    .background(Capsule().fill(theme.action))
                    .contentShape(.capsule)
            }
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier("dashboard.tutorial.done")
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: BoardBlockMetrics.blockRadius, style: .continuous).fill(theme.isDarkPalette ? theme.surface : theme.canvas))
    }

    private func legend(_ title: String, _ detail: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { legendTitle(title); Spacer(); legendDetail(detail) }
            VStack(alignment: .leading, spacing: 0) { legendTitle(title); legendDetail(detail) }
        }
        .accessibilityElement(children: .combine)
    }

    private func legendTitle(_ text: String) -> some View {
        Text(text).font(.bighelp(.subheadline, weight: .semibold)).foregroundStyle(theme.primaryText)
    }

    private func legendDetail(_ text: String) -> some View {
        Text(text).font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
    }
}

// MARK: - Templates

/// The template catalog's Feed, Ideas and Goals blueprints as a pile for this bot. Right uses one
/// (its blanks, then the bot's message box; nothing is sent), left skips to the next.
struct DashboardTemplatesSheet: View {
    @State var kind: AgentBoardItem.Kind
    let botName: String
    let onUse: (BoardBlueprint) -> Void
    let onSeeEvery: (AgentBoardItem.Kind) -> Void
    @State private var decks: [AgentBoardItem.Kind: DashboardTemplateDeck] = [:]
    @State private var skipped: UUID?
    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 250
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @BighelpThemeReader private var theme

    var body: some View {
        let deck = decks[kind] ?? DashboardTemplateDeck(kind: kind, catalog: .shared)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BighelpTokens.space20) {
                    switcher
                    if let top = deck.current {
                        DashboardPileStack(layers: deck.upcoming(3).map { DashboardPileLayer(id: $0.id, color: color($0)) },
                                           height: cardHeight) {
                            card(top, deck: deck).id(top.id)
                        }
                        .driveTarget("dashboard.templates.deck")
                        buttons(top)
                        Text("Swipe right to use a template, left to skip it. It opens \(botName)’s chat with the text in the message box; nothing runs until you tap Send.")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        runOut
                    }
                }
                .padding(BighelpTokens.space20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background(theme.canvas.ignoresSafeArea())
            .overlay(alignment: .bottom) {
                if let skipped {
                    DashboardUndoBar(message: String(localized: "Skipped"), showsUndo: true,
                                     onUndo: { update { $0.back() }; self.skipped = nil },
                                     onExpire: { if self.skipped == skipped { self.skipped = nil } })
                        .id(skipped)
                        .padding(.bottom, BighelpTokens.space12)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .snappy, value: skipped)
            .navigationTitle("Templates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .bighelpToolbarText()
                        .accessibilityIdentifier("dashboard.templates.done")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.templates.sheet")
    }

    private var switcher: some View {
        HStack(spacing: BighelpTokens.space8) {
            ForEach(AgentBoardItem.Kind.dashboardOrder, id: \.self) { page in
                let isSelected = page == kind
                Button { kind = page; skipped = nil } label: {
                    HStack(spacing: 6) {
                        Circle().fill(page.pageColor.fill(dark: theme.isDarkPalette)).frame(width: 10, height: 10)
                            .opacity(isSelected ? 0 : 1)
                        Text(page.pageTitle).font(.bighelp(.subheadline, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? page.pageColor.ink : theme.primaryText)
                    .padding(.horizontal, BighelpTokens.space12)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                    .background(Capsule().fill(isSelected ? page.pageColor.fill(dark: theme.isDarkPalette) : .clear))
                    .overlay { if !isSelected { Capsule().strokeBorder(theme.separator) } }
                    .contentShape(.capsule)
                }
                .bighelpPlainButtonStyle()
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .driveTarget("dashboard.templates.page.\(page.rawValue)")
                .accessibilityIdentifier("dashboard.templates.page.\(page.rawValue)")
            }
        }
    }

    private func color(_ blueprint: BoardBlueprint) -> BighelpBlockColor {
        .pastel(for: blueprint.category.id)
    }

    private func card(_ blueprint: BoardBlueprint, deck: DashboardTemplateDeck) -> some View {
        let block = color(blueprint)
        let position = deck.blueprints.count - deck.remaining + 1
        return DashboardSwipeCard(
            right: DashboardCardAction.useTemplate.stamp(botName: botName),
            left: DashboardCardAction.skipTemplate.stamp(botName: botName),
            accessibilityLabel: "\(blueprint.category.title). \(blueprint.text)",
            identifier: "dashboard.template.\(blueprint.id)",
            onSwipe: { swiped(blueprint, $0) }
        ) {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                HStack(spacing: BighelpTokens.space8) {
                    BoardOutlinePill(title: blueprint.category.title, systemImage: blueprint.category.systemImage, ink: block.ink)
                    Spacer(minLength: 0)
                    Text("\(position) of \(deck.blueprints.count)")
                        .font(.bighelp(.caption, weight: .medium))
                        .foregroundStyle(block.ink.opacity(0.7))
                }
                Text(Self.prompt(blueprint.text))
                    .font(.bighelp(.title3, weight: .semibold))
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .boardBlock(block, padding: 20)
            .frame(height: cardHeight)
        } menu: {
            Button("Use", systemImage: "arrow.up.right") { swiped(blueprint, .right) }
            Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = blueprint.text }
        }
    }

    private func buttons(_ top: BoardBlueprint) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            Button { swiped(top, .left) } label: {
                Label("Skip", systemImage: "xmark")
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                    .overlay(Capsule().strokeBorder(theme.separator))
                    .contentShape(.capsule)
            }
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier("dashboard.templates.skip")
            Button { swiped(top, .right) } label: {
                Label("Use", systemImage: "arrow.up.right")
                    .font(.bighelp(.subheadline, weight: .semibold))
                    .foregroundStyle(theme.actionForeground)
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                    .background(Capsule().fill(theme.action))
                    .contentShape(.capsule)
            }
            .bighelpPlainButtonStyle()
            .accessibilityIdentifier("dashboard.templates.use")
        }
    }

    private var runOut: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Text("That’s all for now")
                .font(.bighelp(.title3, weight: .bold))
                .foregroundStyle(theme.primaryText)
            Text("You’ve been through every \(kind.pageTitle) template here.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
            Button { onSeeEvery(kind) } label: {
                BoardActionPillLabel(title: String(localized: "See every template"), systemImage: "list.bullet")
            }
            .bighelpPlainButtonStyle()
            .padding(.top, BighelpTokens.space4)
            .accessibilityIdentifier("dashboard.templates.see-every")
            Button("Start over") { update { $0 = DashboardTemplateDeck(kind: kind, catalog: .shared) } }
                .font(.bighelp(.subheadline, weight: .semibold))
                .foregroundStyle(theme.action)
                .frame(minHeight: BighelpTokens.hitTarget)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: BoardBlockMetrics.blockRadius, style: .continuous)
            .strokeBorder(theme.separator))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard.templates.run-out")
    }

    private func swiped(_ blueprint: BoardBlueprint, _ direction: DashboardSwipeDirection) {
        switch direction {
        case .right:
            onUse(blueprint)
        case .left:
            update { $0.advance() }
            skipped = UUID()
        }
    }

    private func update(_ change: (inout DashboardTemplateDeck) -> Void) {
        var deck = decks[kind] ?? DashboardTemplateDeck(kind: kind, catalog: .shared)
        change(&deck)
        decks[kind] = deck
    }

    /// The prompt with its [blanks] in bold, so what to fill in stands out on any block color.
    static func prompt(_ text: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "["), let close = rest[open...].firstIndex(of: "]") {
            result += AttributedString(String(rest[..<open]))
            var slot = AttributedString(String(rest[open...close]))
            slot.inlinePresentationIntent = .stronglyEmphasized
            slot.underlineStyle = .single
            result += slot
            rest = rest[rest.index(after: close)...]
        }
        result += AttributedString(String(rest))
        return result
    }
}
