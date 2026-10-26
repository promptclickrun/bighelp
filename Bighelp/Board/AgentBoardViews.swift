import SwiftUI
import UIKit

/// Everything a board screen needs about the selected agent and the shell.
@MainActor
struct AgentBoardContext {
    let agentID: String
    let agentName: String
    let imageURL: URL?
    let activity: AgentActivityKind
    let store: AgentBoardStore
    let onProfile: () -> Void
    let onSwitchAgent: () -> Void
    /// Opens a chat with this agent with the text ready to send.
    let onAsk: (String) -> Void
    /// Opens a new chat with this agent and sends the text.
    let onSend: (String) -> Void
    /// The Chat tab's header controls, so every board has ☰, New chat and ⋯ too.
    let onMenu: () -> Void
    let onNewChat: () -> Void
    let onPickAgents: () -> Void
    /// This agent's places on the host, for ⋯ (Files, Memory, Skills & tools…).
    let tools: [(title: String, systemImage: String, action: () -> Void)]
    /// Something new on a board that's only in ☰, for a dot on ☰.
    var menuHasUnread = false
    /// Opened as a quick screen (from ☰, not in the bottom bar): Back where ☰ would be.
    var onBack: (() -> Void)? = nil
}

// MARK: - Shared pieces

/// A board page. A List, not a ScrollView: only List rows get swipe actions, so Feed, Ideas and
/// Goals items can swipe left to dismiss. Each view `content` lists is its own row, and each
/// sets its own insets (`boardRow()`, `boardCardSegment`) so a card's rows can touch.
struct BoardScroll<Content: View>: View {
    let context: AgentBoardContext
    let title: String?
    /// A small line under the title (Feed's date).
    var subtitle: String? = nil
    let identifier: String
    /// Items on this page; they count as read once it has been open a moment.
    var seen: [AgentBoardItem] = []
    /// Shows Blueprints beside the title.
    var onBlueprints: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            // The page keeps a 720-point column on iPad and the Mac; rows still swipe from the edge.
            let side = max(BighelpTokens.space20, (geometry.size.width - 720) / 2 + BighelpTokens.space20)
            List {
                Group {
                    // Between ☰ and New chat, as on the chat: the avatar opens the profile, the name
                    // switches agents.
                    AgentHeroHeader(agentID: context.agentID, displayName: context.agentName,
                                    imageURL: context.imageURL, activity: context.activity, avatarSize: 56,
                                    onAvatarTap: context.onProfile, onNameTap: context.onSwitchAgent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, BighelpTokens.space4)
                        .boardRow()
                    if title != nil || onBlueprints != nil {
                        titleRow
                            .boardRow(top: BighelpTokens.space8, bottom: BighelpTokens.space4)
                    }
                    content()
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .environment(\.boardRowSide, side)
            .contentMargins(.bottom, 120, for: .scrollContent)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .top) { AgentBoardHeaderButtons(context: context) }
        .bighelpRefreshable { await context.store.load(agentID: context.agentID) }
        .task(id: context.agentID) {
            if context.store.agentID != context.agentID || context.store.state == .idle {
                await context.store.load(agentID: context.agentID)
            }
        }
        .task(id: seen.filter { !$0.read }.map(\.id)) {
            guard seen.contains(where: { !$0.read }) else { return }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await context.store.markSeen(seen)
        }
        .overlay(alignment: .bottom) {
            if let hidden = context.store.recentlyHidden {
                BoardUndoBar(item: hidden, store: context.store)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: context.store.recentlyHidden?.id)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    /// The page's big title, left aligned under the header buttons.
    private var titleRow: some View {
        HStack(alignment: .center, spacing: BighelpTokens.space8) {
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .font(.bighelp(.title, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(theme.primaryText)
                        .accessibilityAddTraits(.isHeader)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.bighelp(.subheadline, weight: .medium))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Spacer(minLength: BighelpTokens.space8)
            if let onBlueprints {
                BoardBlueprintsButton(action: onBlueprints)
            }
        }
    }

    @BighelpThemeReader private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
}

/// Why a thumbs down. The agent reads it to post better things; never required.
enum BoardFeedbackReason {
    static let all = ["Not relevant", "Too frequent", "Already knew", "Wrong timing"]
}

/// Long press (right-click on the Mac) on a Feed, Ideas or Goals item, and the same actions for
/// VoiceOver: only the ones that fit the item's kind. The last one is the item's dismiss
/// (`BoardDismissAction`), the same as swiping left. For an item that has its own List row;
/// tiles that share a row put `BoardItemMenu` in a `Menu` of their own.
private struct BoardItemActions: ViewModifier {
    let item: AgentBoardItem
    let context: AgentBoardContext
    @State private var asksWhy = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                BoardItemMenu.info(item, context: context)
                BoardItemMenu.items(item, context: context, asksWhy: $asksWhy, includesShare: true)
            }
            .accessibilityActions {
                BoardItemMenu.items(item, context: context, asksWhy: $asksWhy, includesShare: false)
            }
            .modifier(LessLikeThis(isPresented: $asksWhy, item: item, context: context))
    }
}

/// What a board item's long-press menu offers. A tile in a grid shares its List row with
/// others, and a List row shows its first `.contextMenu` for every item in it, so tiles put
/// these in their own `Menu(primaryAction:)` instead.
@MainActor
enum BoardItemMenu {
    /// Who posted it and when, and why a thumbs down: what a post's info button used to show.
    @ViewBuilder
    static func info(_ item: AgentBoardItem, context: AgentBoardContext) -> some View {
        if item.kind == .feed {
            Text((item.source.isEmpty ? "Posted by \(context.agentName)" : item.source) + " · "
                 + item.createdAt.formatted(date: .abbreviated, time: .shortened))
            if item.rating == .down, !item.reason.isEmpty {
                Text("You said: \(item.reason)")
            }
            Divider()
        }
    }

    @ViewBuilder
    static func items(_ item: AgentBoardItem, context: AgentBoardContext, asksWhy: Binding<Bool>,
                      includesShare: Bool) -> some View {
        let store = context.store
        switch item.kind {
        case .feed:
            Button(item.rating == .up ? "Remove thumbs up" : "Thumbs up",
                   systemImage: item.rating == .up ? "hand.thumbsup.fill" : "hand.thumbsup") {
                Task { await store.rate(item, item.rating == .up ? .none : .up) }
            }
            if store.supportsFeedback {
                Button(item.rating == .down ? "Remove thumbs down" : "Thumbs down",
                       systemImage: item.rating == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                    if item.rating == .down {
                        Task { await store.rate(item, .none) }
                    } else {
                        Task { await store.rate(item, .down) }
                        asksWhy.wrappedValue = true
                    }
                }
            }
            Button("Discuss", systemImage: "bubble.left") { context.onAsk("About “\(item.title)”: ") }
        case .idea:
            Button("Start a chat about this", systemImage: "bubble.left") {
                context.onAsk("About your idea “\(item.title)”: ")
            }
            if store.supportsFeedback {
                Button("Turn into a goal", systemImage: "target") { Task { await store.promote(item) } }
            }
        case .goal:
            Button(item.isDone ? "Mark active" : "Mark done",
                   systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark") {
                Task { await store.setDone(item, !item.isDone) }
            }
            Button("Discuss", systemImage: "bubble.left") { context.onAsk("About my goal “\(item.title)”: ") }
        }
        if store.supportsFeedback {
            Button(item.read ? "Mark as unread" : "Mark as read",
                   systemImage: item.read ? "circlebadge.fill" : "checkmark.circle") {
                Task { await store.setRead(item, !item.read) }
            }
        }
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.shareText }
        if includesShare {
            ShareLink(item: item.shareText) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        let dismiss = BoardDismissAction(kind: item.kind)
        Button(dismiss.title, systemImage: dismiss.systemImage, role: dismiss.isDestructive ? .destructive : nil) {
            Task { await store.dismiss(item) }
        }
    }
}

/// After a thumbs down: "Less like this?" with quick reasons. Skipping is fine.
struct LessLikeThis: ViewModifier {
    @Binding var isPresented: Bool
    let item: AgentBoardItem
    let context: AgentBoardContext

    func body(content: Content) -> some View {
        content.confirmationDialog("Less like this?", isPresented: $isPresented, titleVisibility: .visible) {
            ForEach(BoardFeedbackReason.all, id: \.self) { reason in
                Button(reason) { Task { await context.store.rate(item, .down, reason: reason) } }
            }
            Button("Skip", role: .cancel) {}
        } message: {
            Text("Optional. It helps \(context.agentName) post things you want.")
        }
    }
}

/// Swipe left on a board item to clear it (Feed), say not now (Ideas) or remove it (Goals),
/// with Undo. Swipe actions belong to a List row, so this goes on the row's outermost view.
private struct BoardItemSwipe: ViewModifier {
    let item: AgentBoardItem
    let store: AgentBoardStore

    func body(content: Content) -> some View {
        let dismiss = BoardDismissAction(kind: item.kind)
        content.swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: dismiss.isDestructive ? .destructive : nil) {
                Task { await store.dismiss(item) }
            } label: {
                Label(dismiss.title, systemImage: dismiss.systemImage)
            }
            .tint(dismiss.isDestructive ? theme.danger : (item.kind == .idea ? theme.warning : .gray))
        }
    }

    @BighelpThemeReader private var theme
}

extension View {
    func boardItemActions(_ item: AgentBoardItem, context: AgentBoardContext) -> some View {
        modifier(BoardItemActions(item: item, context: context))
    }

    func boardItemSwipe(_ item: AgentBoardItem, store: AgentBoardStore) -> some View {
        modifier(BoardItemSwipe(item: item, store: store))
    }
}

/// Something the person hasn't seen yet.
struct UnreadDot: View {
    let item: AgentBoardItem
    let store: AgentBoardStore

    var body: some View {
        if store.supportsFeedback, !item.read {
            Circle()
                .fill(theme.action)
                .frame(width: 8, height: 8)
                .accessibilityLabel("New")
                .accessibilityIdentifier("board.unread.\(item.id)")
        }
    }

    @BighelpThemeReader private var theme
}

/// "Cleared", "Not now" or "Removed" with Undo, for a few seconds after.
private struct BoardUndoBar: View {
    let item: AgentBoardItem
    let store: AgentBoardStore

    var body: some View {
        HStack(spacing: BighelpTokens.space12) {
            Text(BoardDismissAction(kind: item.kind).undoMessage(for: item.title))
                .font(.bighelp(.subheadline).weight(.medium))
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            Spacer(minLength: BighelpTokens.space8)
            Button("Undo") { Task { await store.undoHide() } }
                .font(.bighelp(.subheadline).weight(.semibold))
                .foregroundStyle(theme.action)
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("board.undo")
        }
        .padding(.horizontal, BighelpTokens.space16)
        .frame(maxWidth: 520)
        .bighelpNavigationGlass(in: Capsule())
        .padding(.horizontal, BighelpTokens.space20)
        .task(id: item.id) {
            try? await Task.sleep(for: .seconds(5))
            store.clearUndo(item)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.undo-bar")
    }

    @BighelpThemeReader private var theme
}

/// "Tell your agent what you want here": the only way content starts.
private struct BoardEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    let example: String
    let agentName: String
    let onAsk: (String) -> Void
    let identifier: String
    var onBlueprints: (() -> Void)?

    var body: some View {
        VStack(spacing: BighelpTokens.space12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(theme.action)
                .padding(.top, BighelpTokens.space24)
            Text(title)
                .font(.bighelp(.title3).weight(.bold))
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
            Text("“\(example)”")
                .font(.bighelp(.subheadline).italic())
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .boardBlock(BighelpBlockColor.pastel(for: identifier), padding: BighelpTokens.space16)
            Button {
                onAsk(example)
            } label: {
                Label("Ask \(agentName)", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.bighelp(.body).weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
            }
            .bighelpProminentButtonStyle()
            .buttonBorderShape(.capsule)
            .tint(theme.action)
            .foregroundStyle(theme.actionForeground)
            .accessibilityIdentifier(identifier + ".ask")
            if let onBlueprints {
                BoardBlueprintsButton(action: onBlueprints)
            }
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    @BighelpThemeReader private var theme
}

struct BoardIcon: View {
    let icon: String
    let fallback: String
    var size: CGFloat = 40

    var body: some View {
        Group {
            if icon.isEmpty {
                Image(systemName: fallback)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(theme.action)
            } else {
                Text(icon).font(.system(size: size * 0.8))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @BighelpThemeReader private var theme
}

struct BoardStateBanner: View {
    let state: AgentBoardStore.LoadState
    let context: AgentBoardContext
    /// For the agent: plugins before 3.0.0 only know the command's old name.
    static let updateInstruction = "run `hermes bighelp update --restart` (on plugins before 3.0.0 the command is "
        + "`hermes loopdy update --restart`)"

    var body: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, BighelpTokens.space24)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
        case .unavailable where context.store.isDisconnected:
            Label("Connect to your Hermes host to see this.", systemImage: "bolt.horizontal.circle")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
        case .unavailable:
            pluginUpdate
        case .idle, .loaded:
            EmptyView()
        }
    }

    /// The host (a Mac, a server or a cloud sandbox) runs an older plugin.
    private var pluginUpdate: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            Label("Your Hermes host is running an older bighelp plugin", systemImage: "puzzlepiece.extension")
                .font(.bighelp(.headline))
                .foregroundStyle(theme.primaryText)
            Text("Update it in Settings, under this computer's Plugin version, or ask \(context.agentName) to do it. "
                 + "Already updated? Restart every Hermes dashboard this phone connects to, so it loads the new copy.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
            HStack(spacing: BighelpTokens.space12) {
                Button {
                    context.onAsk("Please update the bighelp plugin on this host: \(Self.updateInstruction), "
                        + "then restart every Hermes dashboard process (including launchd or systemd services) "
                        + "so they load it, and tell me when it's back.")
                } label: {
                    Label("Ask \(context.agentName)", systemImage: "bubble.left.and.text.bubble.right")
                        .frame(minHeight: BighelpTokens.hitTarget)
                }
                // Only the button takes the tap in a List row.
                .buttonStyle(.borderless)
                .accessibilityIdentifier("board.plugin-required.ask")
            }
            .font(.bighelp(.subheadline).weight(.semibold))
            .tint(theme.action)
        }
        .padding(BighelpTokens.space16)
        .background(RoundedRectangle(cornerRadius: BoardBlockMetrics.cardRadius, style: .continuous)
            .strokeBorder(theme.separator))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.plugin-required")
    }

    @BighelpThemeReader private var theme
}

/// Friendly buckets: "This evening", "Yesterday afternoon", "Friday morning".
enum BoardTimeBucket {
    static func title(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        let part = switch hour {
        case 5..<12: "morning"
        case 12..<17: "afternoon"
        case 17..<22: "evening"
        default: "night"
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return part == "night" ? "Tonight" : "This \(part)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(part)"
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(part)"
        }
        return date.formatted(.dateTime.month(.wide).day())
    }
}

// MARK: - Feed

/// Feed: what's new today in a green block, the newest posts as tiles two to a row, then the
/// rest as rows in a card. Every post opens in full (`FeedPostDetailSheet`).
struct AgentFeedView: View {
    let context: AgentBoardContext
    @State private var showsBlueprints = false
    @State private var openedPost: OpenedFeedPost?
    /// Posts that were new while the page was open. They count as read a moment after they
    /// show (`BoardScroll`), so this keeps the page from rearranging under the person.
    @State private var newIDs: Set<String> = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// At most this many tiles; older posts are rows.
    private static let maximumTiles = 6

    var body: some View {
        let store = context.store
        let posts = store.feed.sorted { $0.createdAt > $1.createdAt }
        let isEmpty = posts.isEmpty && store.state == .loaded
        let fresh = posts.filter { newIDs.contains($0.id) }
        // The new posts, rounded up to fill the last row, and at least the newest two.
        let tileCount = min(posts.count, Self.maximumTiles, max(2, fresh.count + fresh.count % 2))
        let tiles = Array(posts.prefix(tileCount))
        let rows = Array(posts.dropFirst(tileCount))
        BoardScroll(context: context, title: "Feed",
                    subtitle: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()),
                    identifier: "board.feed", seen: store.feed,
                    onBlueprints: isEmpty ? nil : { showsBlueprints = true }) {
            BoardStateBanner(state: store.state, context: context)
                .boardRow()
            if isEmpty {
                BoardEmptyState(
                    symbol: "newspaper",
                    title: "Your feed is quiet",
                    message: "Tell \(context.agentName) what you'd like to hear about. Posts show up here when they're ready.",
                    example: "Every evening, post the top three AI stories to my feed.",
                    agentName: context.agentName, onAsk: context.onAsk, identifier: "board.feed.empty",
                    onBlueprints: { showsBlueprints = true })
                    .boardRow()
            }
            if !fresh.isEmpty {
                FeedTodayBlock(posts: fresh, context: context)
                    .boardRow()
            }
            BoardTileRows(items: tiles, columns: dynamicTypeSize.isAccessibilitySize ? 1 : 2, store: store) { item in
                FeedPostTile(item: item, context: context) { openedPost = .init(id: item.id) }
            }
            if !rows.isEmpty {
                BoardSectionCaption(title: "Earlier")
                    .boardRow(top: BighelpTokens.space8, bottom: 0)
                ForEach(rows) { item in
                    FeedPostRow(item: item, context: context) { openedPost = .init(id: item.id) }
                        .boardCardSegment(isFirst: item.id == rows.first?.id, isLast: item.id == rows.last?.id)
                        .boardItemSwipe(item, store: store)
                }
            }
        }
        .onChange(of: unreadIDs, initial: true) { _, unread in
            newIDs.formUnion(unread)
        }
        .onChange(of: context.agentID) { newIDs = [] }
        .boardBlueprints(isPresented: $showsBlueprints, kind: .feed, context: context)
        .bighelpSheet(item: $openedPost) { post in
            FeedPostDetailSheet(itemID: post.id, context: context)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
        }
    }

    /// Posts not seen yet. Hosts without read state (plugins before 2.19.0) have none.
    private var unreadIDs: Set<String> {
        guard context.store.supportsFeedback else { return [] }
        return Set(context.store.feed.filter { !$0.read }.map(\.id))
    }
}

/// The deep green block on top of Feed: how many posts are new, from whom.
private struct FeedTodayBlock: View {
    let posts: [AgentBoardItem]
    let context: AgentBoardContext

    var body: some View {
        let block = BighelpBlockColor.forest
        let isToday = posts.allSatisfy { Calendar.current.isDateInToday($0.createdAt) }
        HStack(alignment: .center, spacing: BighelpTokens.space16) {
            VStack(alignment: .leading, spacing: BighelpTokens.space12) {
                BoardOutlinePill(title: isToday ? "Today" : "New", ink: block.ink)
                Text(posts.count == 1 ? "1 new post from \(context.agentName)"
                                      : "\(posts.count) new posts from \(context.agentName)")
                    .font(.bighelp(.title2, weight: .bold))
                    .tracking(-0.4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            // The agent itself, bare: no circle or glass behind it.
            AgentLiveAvatar(agentID: context.agentID, displayName: context.agentName, imageURL: context.imageURL,
                            activity: context.activity, size: 56, showsBadge: false)
        }
        .boardBlock(block, padding: 20)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("board.feed.today")
    }
}

/// A new post as a pastel tile. It shares a List row with its neighbor, so its long-press menu
/// is its own `Menu` (a tap opens the post) and it has no swipe.
private struct FeedPostTile: View {
    let item: AgentBoardItem
    let context: AgentBoardContext
    let onOpen: () -> Void
    @State private var asksWhy = false

    var body: some View {
        let block = BighelpBlockColor.feed(item)
        let files = context.store.visibleFiles(of: item)
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            Menu {
                BoardItemMenu.info(item, context: context)
                BoardItemMenu.items(item, context: context, asksWhy: $asksWhy, includesShare: true)
            } label: {
                label(ink: block.ink)
            } primaryAction: {
                onOpen()
            }
            .tint(block.ink)
            .accessibilityHint("Opens the post")
            if !files.isEmpty {
                BoardTileFiles(item: item, files: files, store: context.store, ink: block.ink, onOpen: onOpen)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                FeedThumbs(item: item, context: context, asksWhy: $asksWhy, ink: block.ink)
                #if targetEnvironment(macCatalyst)
                Spacer(minLength: 0)
                BoardTileMoreMenu(item: item, context: context, ink: block.ink, asksWhy: $asksWhy)
                #endif
            }
        }
        .boardBlock(block, padding: 14)
        .modifier(LessLikeThis(isPresented: $asksWhy, item: item, context: context))
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            BoardItemMenu.items(item, context: context, asksWhy: $asksWhy, includesShare: false)
        }
        .accessibilityIdentifier("board.feed.post.\(item.id)")
    }

    private func label(ink: Color) -> some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space8) {
            HStack(spacing: 6) {
                AgentLiveAvatar(agentID: context.agentID, displayName: context.agentName, imageURL: context.imageURL,
                                size: 22, showsBadge: false)
                Text(item.source.isEmpty ? context.agentName : item.source)
                    .font(.bighelp(.caption, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 0)
                UnreadDot(item: item, store: context.store)
            }
            Text(item.title)
                .font(.bighelp(.headline, weight: .bold))
                .foregroundStyle(ink)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            if let picture = item.pictures.first {
                BoardPictureView(item: item, picture: picture, store: context.store)
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if !preview.isEmpty {
                Text(preview)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(ink.opacity(0.8))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }

    /// The post's words without Markdown's symbols, like a message preview.
    private var preview: String {
        MarkdownDocument(item.body).visiblePlainText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// An older post as a row of the Earlier card. It has its own List row: it swipes, and holds
/// for the usual menu.
private struct FeedPostRow: View {
    let item: AgentBoardItem
    let context: AgentBoardContext
    let onOpen: () -> Void
    @State private var asksWhy = false

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            Button(action: onOpen) {
                HStack(spacing: BighelpTokens.space12) {
                    BoardIconTile(icon: item.icon, fallback: "newspaper", color: BighelpBlockColor.feed(item))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.bighelp(.subheadline, weight: .semibold))
                            .foregroundStyle(theme.primaryText)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Text((item.source.isEmpty ? context.agentName : item.source) + " · "
                             + BoardTimeBucket.title(for: item.createdAt))
                            .font(.bighelp(.caption))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    UnreadDot(item: item, store: context.store)
                }
                .frame(minHeight: BighelpTokens.hitTarget)
                .contentShape(.rect)
            }
            .bighelpPlainButtonStyle()
            .accessibilityHint("Opens the post")
            FeedThumbs(item: item, context: context, asksWhy: $asksWhy, ink: theme.primaryText)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, BighelpTokens.space8)
        .boardItemActions(item, context: context)
        .modifier(LessLikeThis(isPresented: $asksWhy, item: item, context: context))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.feed.post.\(item.id)")
    }

    @BighelpThemeReader private var theme
}

/// Thumbs up and down on a post. They tell the agent what's worth posting; a thumbs down may
/// ask why (`asksWhy`). The chosen one fills with the color picked in Appearance.
private struct FeedThumbs: View {
    let item: AgentBoardItem
    let context: AgentBoardContext
    @Binding var asksWhy: Bool
    /// The glyphs' color on the tile or the page.
    let ink: Color

    var body: some View {
        HStack(spacing: 0) {
            Button {
                Task { await context.store.rate(item, item.rating == .up ? .none : .up) }
            } label: {
                glyph(item.rating == .up ? "hand.thumbsup.fill" : "hand.thumbsup", isSelected: item.rating == .up)
            }
            .bighelpPlainButtonStyle()
            .accessibilityLabel(item.rating == .up ? "Remove thumbs up" : "Thumbs up")
            .accessibilityAddTraits(item.rating == .up ? .isSelected : [])
            .accessibilityIdentifier("board.feed.thumbs-up")
            if context.store.supportsFeedback {
                Button {
                    if item.rating == .down {
                        Task { await context.store.rate(item, .none) }
                    } else {
                        Task { await context.store.rate(item, .down) }
                        asksWhy = true
                    }
                } label: {
                    glyph(item.rating == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                          isSelected: item.rating == .down)
                }
                .bighelpPlainButtonStyle()
                .accessibilityLabel(item.rating == .down ? "Remove thumbs down" : "Thumbs down")
                .accessibilityAddTraits(item.rating == .down ? .isSelected : [])
                .accessibilityIdentifier("board.feed.thumbs-down")
            }
        }
    }

    private func glyph(_ systemImage: String, isSelected: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.bighelp(.subheadline, weight: .semibold))
            .foregroundStyle(isSelected ? theme.actionForeground : ink)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 34, height: 34)
            .background { if isSelected { Circle().fill(theme.action) } }
            .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
    }

    @BighelpThemeReader private var theme
}

struct BoardPictureView: View {
    let item: AgentBoardItem
    let picture: AgentBoardItem.Picture
    let store: AgentBoardStore
    @State private var image: UIImage?

    var body: some View {
        Group {
            switch picture {
            case .remote(let url):
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() } else { placeholder }
                }
            case .stored(let index):
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    placeholder.task(id: "\(item.id)#\(index)") {
                        if let data = await store.picture(for: item, index: index) { image = UIImage(data: data) }
                    }
                }
            }
        }
        .accessibilityLabel("Picture for \(item.title)")
    }

    private var placeholder: some View {
        Rectangle().fill(theme.incomingMessageBackground).overlay(ProgressView())
    }

    @BighelpThemeReader private var theme
}

// MARK: - Ideas

/// Ideas: chips for its sections, then a bento of pastel tiles. The newest idea is the tall one
/// with Let's do it; a tap on any idea opens it (`IdeaDetailSheet`).
struct AgentIdeasView: View {
    let context: AgentBoardContext
    @State private var selected: AgentBoardItem?
    @State private var showsBlueprints = false
    /// The chosen section chip; nil is All.
    @State private var section: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let store = context.store
        let isEmpty = store.ideas.isEmpty && store.state == .loaded
        let ideas = store.ideas.sorted { $0.createdAt > $1.createdAt }
        let sections = Self.sections(ideas)
        // A chip whose ideas are all gone shows All again.
        let chosen = section.flatMap { sections.contains($0) ? $0 : nil }
        let shown = chosen.map { name in ideas.filter { Self.key($0) == name } } ?? ideas
        let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        BoardScroll(context: context, title: "Ideas", identifier: "board.ideas", seen: store.ideas,
                    onBlueprints: isEmpty ? nil : { showsBlueprints = true }) {
            BoardStateBanner(state: store.state, context: context)
                .boardRow()
            if isEmpty {
                BoardEmptyState(
                    symbol: "lightbulb",
                    title: "No ideas yet",
                    message: "Ask \(context.agentName) to suggest things it could do for you. Ideas it proposes land here.",
                    example: "Look through my week and suggest a few things you could take off my plate.",
                    agentName: context.agentName, onAsk: context.onAsk, identifier: "board.ideas.empty",
                    onBlueprints: { showsBlueprints = true })
                    .boardRow()
            }
            if sections.count > 1 || (sections.count == 1 && ideas.contains { Self.key($0).isEmpty }) {
                chips(sections, chosen: chosen)
                    .boardRow(top: BighelpTokens.space4, bottom: BighelpTokens.space4)
            }
            if let hero = shown.first {
                let beside = Array(shown.dropFirst().prefix(columns == 1 ? 0 : 2))
                if beside.isEmpty {
                    IdeaHeroTile(idea: hero, context: context) { selected = hero }
                        .boardRow(top: BoardBlockMetrics.tileSpacing / 2, bottom: BoardBlockMetrics.tileSpacing / 2)
                        .boardItemSwipe(hero, store: store)
                } else {
                    // The tall tile beside two short ones, all the same height.
                    HStack(alignment: .top, spacing: BoardBlockMetrics.tileSpacing) {
                        IdeaHeroTile(idea: hero, context: context) { selected = hero }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        VStack(spacing: BoardBlockMetrics.tileSpacing) {
                            ForEach(beside) { idea in
                                IdeaTile(idea: idea, context: context) { selected = idea }
                                    .frame(maxHeight: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .boardRow(top: BoardBlockMetrics.tileSpacing / 2, bottom: BoardBlockMetrics.tileSpacing / 2)
                }
                BoardTileRows(items: Array(shown.dropFirst(1 + beside.count)), columns: columns, store: store) { idea in
                    IdeaTile(idea: idea, context: context) { selected = idea }
                }
            }
        }
        .boardBlueprints(isPresented: $showsBlueprints, kind: .idea, context: context)
        .bighelpSheet(item: $selected) { idea in
            IdeaDetailSheet(idea: idea, context: context)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
        }
    }

    private func chips(_ sections: [String], chosen: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BighelpTokens.space8) {
                BoardFilterChip(title: "All", isSelected: chosen == nil) { section = nil }
                    .accessibilityIdentifier("board.ideas.chip.all")
                ForEach(sections, id: \.self) { name in
                    BoardFilterChip(title: name, isSelected: chosen == name) { section = name }
                        .accessibilityIdentifier("board.ideas.chip.\(name)")
                }
            }
        }
        .scrollClipDisabled()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.ideas.chips")
    }

    /// An idea's section (the agent's own words, like "Health"); empty for none.
    private static func key(_ idea: AgentBoardItem) -> String {
        idea.section.trimmingCharacters(in: .whitespaces)
    }

    /// The named sections, newest first.
    private static func sections(_ ideas: [AgentBoardItem]) -> [String] {
        var names: [String] = []
        for idea in ideas {
            let name = key(idea)
            if !name.isEmpty, !names.contains(name) { names.append(name) }
        }
        return names
    }
}

/// An idea's words without Markdown's symbols, like a message preview.
@MainActor
private func ideaPreview(_ idea: AgentBoardItem) -> String {
    MarkdownDocument(idea.body).visiblePlainText
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The newest idea: its section and agent, a big title, a few lines, and Let's do it, which
/// says yes the same way as the idea's own page. It shares a List row with the tiles beside
/// it, so its long-press menu is its own `Menu` (a tap opens the idea).
private struct IdeaHeroTile: View {
    let idea: AgentBoardItem
    let context: AgentBoardContext
    let onOpen: () -> Void
    @State private var isAccepting = false
    @State private var acceptFailed = false

    var body: some View {
        let block = BighelpBlockColor.idea(idea)
        let preview = ideaPreview(idea)
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            Menu {
                BoardItemMenu.items(idea, context: context, asksWhy: .constant(false), includesShare: true)
            } label: {
                VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                    HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space4) {
                        Text([idea.section.trimmingCharacters(in: .whitespaces), context.agentName]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.bighelp(.caption, weight: .semibold))
                            .foregroundStyle(block.ink.opacity(0.7))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        UnreadDot(item: idea, store: context.store)
                    }
                    Text(idea.title)
                        .font(.bighelp(.title2, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(block.ink)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !preview.isEmpty {
                        Text(preview)
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(block.ink.opacity(0.8))
                            .multilineTextAlignment(.leading)
                            .lineLimit(4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            } primaryAction: {
                onOpen()
            }
            .tint(block.ink)
            .accessibilityHint("Opens the idea")
            // The menu's actions for VoiceOver too, as on every other board item.
            .accessibilityActions {
                BoardItemMenu.items(idea, context: context, asksWhy: .constant(false), includesShare: false)
            }
            .accessibilityIdentifier("board.idea.\(idea.id)")
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                #if targetEnvironment(macCatalyst)
                HStack(spacing: 0) {
                    letsDoItButton
                    Spacer(minLength: 0)
                    BoardTileMoreMenu(item: idea, context: context, ink: block.ink, asksWhy: .constant(false))
                }
                #else
                letsDoItButton
                #endif
                if acceptFailed {
                    Text("Couldn't tell \(context.agentName) yet.")
                        .font(.bighelp(.caption))
                        .foregroundStyle(block.ink.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .boardBlock(block)
        .accessibilityElement(children: .contain)
    }

    private var letsDoItButton: some View {
        Button {
            Task { await letsDoIt() }
        } label: {
            BoardActionPillLabel(title: acceptFailed ? "Try again" : "Let's do it", isBusy: isAccepting)
        }
        .bighelpPlainButtonStyle()
        .disabled(isAccepting)
        .accessibilityLabel(acceptFailed ? "Try again" : "Let's do it")
        .accessibilityIdentifier("board.idea.lets-do-it.\(idea.id)")
    }

    /// As on the idea's page: the yes is recorded by the idea's ID, and the chat that opens gets
    /// only the readable text. Older plugins go straight to the chat.
    private func letsDoIt() async {
        isAccepting = true
        let outcome = await context.store.accept(idea)
        isAccepting = false
        guard outcome != .failed else { acceptFailed = true; return }
        acceptFailed = false
        context.onAsk(idea.letsDoItMessage)
    }
}

/// Any other idea as a pastel tile: its section, title and a line or two. The whole tile is its
/// `Menu`: a tap opens the idea, touch and hold shows its actions.
private struct IdeaTile: View {
    let idea: AgentBoardItem
    let context: AgentBoardContext
    let onOpen: () -> Void

    var body: some View {
        let block = BighelpBlockColor.idea(idea)
        let preview = ideaPreview(idea)
        Menu {
            BoardItemMenu.items(idea, context: context, asksWhy: .constant(false), includesShare: true)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: BighelpTokens.space4) {
                    if idea.icon.isEmpty {
                        Text(idea.section.trimmingCharacters(in: .whitespaces))
                            .font(.bighelp(.caption, weight: .semibold))
                            .foregroundStyle(block.ink.opacity(0.7))
                            .lineLimit(1)
                    } else {
                        Text(idea.icon).font(.bighelp(.title3)).accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                    UnreadDot(item: idea, store: context.store)
                }
                Text(idea.title)
                    .font(.bighelp(.headline, weight: .bold))
                    .foregroundStyle(block.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if !preview.isEmpty {
                    Text(preview)
                        .font(.bighelp(.footnote))
                        .foregroundStyle(block.ink.opacity(0.8))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .boardBlock(block, padding: 16)
            .contentShape(.rect)
        } primaryAction: {
            onOpen()
        }
        .tint(block.ink)
        .accessibilityHint("Opens the idea")
        .accessibilityActions {
            BoardItemMenu.items(idea, context: context, asksWhy: .constant(false), includesShare: false)
        }
        .accessibilityIdentifier("board.idea.\(idea.id)")
        #if targetEnvironment(macCatalyst)
        .overlay(alignment: .bottomTrailing) {
            BoardTileMoreMenu(item: idea, context: context, ink: block.ink, asksWhy: .constant(false))
                .padding(BighelpTokens.space4)
        }
        #endif
    }
}

private struct IdeaDetailSheet: View {
    let idea: AgentBoardItem
    let context: AgentBoardContext
    @Environment(\.dismiss) private var dismiss
    @State private var isAccepting = false
    @State private var acceptFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BighelpTokens.space16) {
                BoardIcon(icon: idea.icon, fallback: "lightbulb", size: 64)
                Text(idea.title)
                    .font(.bighelp(.title2).weight(.bold))
                    .foregroundStyle(theme.primaryText)
                MarkdownMessageView(document: MarkdownDocument(idea.body))
                    .foregroundStyle(theme.primaryText)
                    .tint(theme.action)
                VStack(spacing: BighelpTokens.space8) {
                    Button {
                        Task { await letsDoIt() }
                    } label: {
                        Group {
                            if isAccepting {
                                BighelpNoodleView(motion: .loader, size: 20, tint: theme.actionForeground)
                            } else {
                                Text(acceptFailed ? "Try again" : "Let's do it")
                            }
                        }
                        .font(.bighelp(.body).weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                    }
                    .bighelpProminentButtonStyle()
                    .buttonBorderShape(.capsule)
                    .tint(theme.action)
                    .foregroundStyle(theme.actionForeground)
                    .disabled(isAccepting)
                    .accessibilityIdentifier("board.idea.accept")
                    if acceptFailed {
                        Text("Couldn't tell \(context.agentName) yet. Check the connection and try again.")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.secondaryText)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("board.idea.accept.failed")
                    }
                    if context.store.supportsFeedback {
                        Button {
                            dismiss()
                            Task { await context.store.promote(idea) }
                        } label: {
                            Label("Make it a goal", systemImage: "target")
                                .font(.bighelp(.body).weight(.semibold))
                                .foregroundStyle(theme.primaryText)
                                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("board.idea.promote")
                    }
                    Button {
                        dismiss()
                        Task { await context.store.hide(idea) }
                    } label: {
                        Text("Not now")
                            .font(.bighelp(.body).weight(.semibold))
                            .foregroundStyle(theme.secondaryText)
                            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("board.idea.dismiss")
                }
                .padding(.top, BighelpTokens.space8)
            }
            .padding(BighelpTokens.space24)
        }
        .background(theme.canvas.ignoresSafeArea())
        #if targetEnvironment(macCatalyst)
        // iPhone swipes the sheet away; a Mac sheet needs a button (and Esc).
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.bighelp(.body).weight(.semibold))
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(BighelpTokens.space8)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("board.idea.close")
        }
        #endif
    }

    /// The yes is recorded when the person taps, by the idea's ID; the chat that opens
    /// gets only the readable text. Older plugins skip straight to the chat, as before.
    private func letsDoIt() async {
        isAccepting = true
        let outcome = await context.store.accept(idea)
        isAccepting = false
        guard outcome != .failed else { acceptFailed = true; return }
        dismiss()
        context.onAsk(idea.letsDoItMessage)
    }

    @BighelpThemeReader private var theme
}

// MARK: - Apps

struct AgentAppsView<Artifacts: View>: View {
    enum Segment: String, CaseIterable, Identifiable {
        case artifacts = "Artifacts", media = "Media"
        var id: String { rawValue }
    }

    let context: AgentBoardContext
    let media: AgentMediaStore
    @ViewBuilder let artifacts: () -> Artifacts
    @State private var segment: Segment = .artifacts
    @State private var preview: ChatAttachment?

    var body: some View {
        VStack(spacing: BighelpTokens.space12) {
            AgentHeroHeader(agentID: context.agentID, displayName: context.agentName,
                            imageURL: context.imageURL, activity: context.activity,
                            onAvatarTap: context.onProfile, onNameTap: context.onSwitchAgent)
                .frame(maxWidth: .infinity)
                .padding(.top, BighelpTokens.space8)
                .overlay(alignment: .top) { AgentBoardHeaderButtons(context: context) }
            Picker("Show", selection: $segment) {
                ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
            }
            .bighelpSegmentedPicker()
            .padding(.horizontal, BighelpTokens.space20)
            .accessibilityIdentifier("board.apps.segment")
            switch segment {
            case .artifacts:
                artifacts()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .media:
                mediaGrid
            }
        }
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .task(id: context.agentID) {
            if context.store.agentID != context.agentID { await context.store.load(agentID: context.agentID) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("board.apps")
    }

    /// Pictures and videos the agent sent or made, then pictures from its posts.
    private var mediaGrid: some View {
        let pictures = context.store.items.filter { !$0.dismissed }.flatMap { item in
            item.pictures.map { (item, $0) }
        }
        return ScrollView {
            if media.items.isEmpty, pictures.isEmpty {
                if media.state == .loading || media.state == .idle {
                    ProgressView().padding(.top, BighelpTokens.space32)
                } else {
                    ContentUnavailableView("No media yet", systemImage: "photo.on.rectangle",
                        description: Text(emptyMediaText))
                        .padding(.top, BighelpTokens.space24)
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
                    ForEach(media.items) { item in
                        AgentMediaTile(item: item, store: media) {
                            Task { preview = await media.attachment(for: item) }
                        }
                    }
                    ForEach(Array(pictures.enumerated()), id: \.offset) { _, entry in
                        BoardPictureView(item: entry.0, picture: entry.1, store: context.store)
                            .aspectRatio(1, contentMode: .fill)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, BighelpTokens.space20)
            }
        }
        .bighelpRefreshable { await media.load(agentID: context.agentID) }
        .task(id: context.agentID) { await media.load(agentID: context.agentID) }
        .bighelpSheet(item: $preview) { ChatAttachmentPreviewView(attachment: $0).bighelpSheetSize(.large) }
        .padding(.bottom, 100)
        .accessibilityIdentifier("board.media")
    }

    private var emptyMediaText: String {
        media.state == .unavailable
            ? "Pictures and videos \(context.agentName) sends you show up here once the bighelp plugin on your Hermes host is updated."
            : "Pictures and videos \(context.agentName) sends you or makes show up here."
    }

    @BighelpThemeReader private var theme
}
