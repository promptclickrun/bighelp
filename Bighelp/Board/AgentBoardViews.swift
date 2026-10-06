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
}

// MARK: - Shared pieces

/// A board page. A List, not a ScrollView: only List rows get swipe actions, so Feed, Ideas and
/// Goals items can swipe left to dismiss. Each view `content` lists is its own row.
struct BoardScroll<Content: View>: View {
    let context: AgentBoardContext
    let title: String?
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
                    AgentHeroHeader(agentID: context.agentID, displayName: context.agentName,
                                    imageURL: context.imageURL, activity: context.activity,
                                    onAvatarTap: context.onProfile, onNameTap: context.onSwitchAgent)
                        .frame(maxWidth: .infinity)
                        .padding(.top, BighelpTokens.space8)
                    if title != nil || onBlueprints != nil {
                        titleRow
                    }
                    content()
                }
                .listRowInsets(EdgeInsets(top: BighelpTokens.space8, leading: side, bottom: BighelpTokens.space8,
                                          trailing: side))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .contentMargins(.bottom, 120, for: .scrollContent)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .top) { AgentBoardHeaderButtons(context: context) }
        .refreshable { await context.store.load(agentID: context.agentID) }
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
        .animation(.snappy, value: context.store.recentlyHidden?.id)
        .background(BighelpThemeCanvas(theme: theme).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: BighelpTokens.space8) {
            if let title {
                Text(title)
                    .font(.bighelp(.largeTitle).weight(.bold))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: BighelpTokens.space8)
            if let onBlueprints {
                BoardBlueprintsButton(action: onBlueprints)
            }
        }
    }

    @BighelpThemeReader private var theme
}

/// Why a thumbs down. The agent reads it to post better things; never required.
enum BoardFeedbackReason {
    static let all = ["Not relevant", "Too frequent", "Already knew", "Wrong timing"]
}

/// Long press (right-click on the Mac) on a Feed, Ideas or Goals item, and the same actions for
/// VoiceOver: only the ones that fit the item's kind. The last one is the item's dismiss
/// (`BoardDismissAction`), the same as swiping left.
private struct BoardItemActions: ViewModifier {
    let item: AgentBoardItem
    let context: AgentBoardContext
    @State private var asksWhy = false

    func body(content: Content) -> some View {
        content
            .contextMenu { actions(includesShare: true) }
            .accessibilityActions { actions(includesShare: false) }
            .modifier(LessLikeThis(isPresented: $asksWhy, item: item, context: context))
    }

    @ViewBuilder
    private func actions(includesShare: Bool) -> some View {
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
                        asksWhy = true
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
private struct LessLikeThis: ViewModifier {
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
                .foregroundStyle(theme.primaryText)
                .multilineTextAlignment(.center)
                .padding(BighelpTokens.space12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.incomingMessageBackground))
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
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(theme.border))
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

    static func grouped(_ items: [AgentBoardItem], now: Date = .now) -> [(title: String, items: [AgentBoardItem])] {
        var groups: [(title: String, items: [AgentBoardItem])] = []
        for item in items.sorted(by: { $0.createdAt > $1.createdAt }) {
            let title = self.title(for: item.createdAt, now: now)
            if groups.last?.title == title {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((title, [item]))
            }
        }
        return groups
    }
}

// MARK: - Feed

struct AgentFeedView: View {
    let context: AgentBoardContext
    @State private var showsBlueprints = false
    @State private var openedPost: OpenedFeedPost?

    var body: some View {
        let store = context.store
        let isEmpty = store.feed.isEmpty && store.state == .loaded
        BoardScroll(context: context, title: nil, identifier: "board.feed", seen: store.feed,
                    onBlueprints: isEmpty ? nil : { showsBlueprints = true }) {
            BoardStateBanner(state: store.state, context: context)
            if isEmpty {
                BoardEmptyState(
                    symbol: "newspaper",
                    title: "Your feed is quiet",
                    message: "Tell \(context.agentName) what you'd like to hear about. Posts show up here when they're ready.",
                    example: "Every evening, post the top three AI stories to my feed.",
                    agentName: context.agentName, onAsk: context.onAsk, identifier: "board.feed.empty",
                    onBlueprints: { showsBlueprints = true })
            }
            ForEach(BoardTimeBucket.grouped(store.feed), id: \.title) { group in
                Text(group.title)
                    .font(.bighelp(.title2).weight(.bold))
                    .foregroundStyle(theme.primaryText)
                    .padding(.top, BighelpTokens.space8)
                    .accessibilityAddTraits(.isHeader)
                ForEach(group.items) { item in
                    VStack(spacing: 0) {
                        FeedPostView(item: item, context: context) { openedPost = .init(id: item.id) }
                        Divider().overlay(theme.border)
                    }
                    .boardItemSwipe(item, store: store)
                }
            }
        }
        .boardBlueprints(isPresented: $showsBlueprints, kind: .feed, context: context)
        .bighelpSheet(item: $openedPost) { post in
            FeedPostDetailSheet(itemID: post.id, context: context)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .bighelpSheetSize(.standard)
        }
    }

    @BighelpThemeReader private var theme
}

private struct FeedPostView: View {
    let item: AgentBoardItem
    let context: AgentBoardContext
    /// Opens the post with its files. Only posts with files open: the Feed already shows
    /// the rest of a post in full.
    let onOpen: () -> Void
    @State private var isShowingInfo = false
    @State private var asksWhy = false
    @AppStorage(LinkPreviewPreferences.enabledKey) private var showsLinkPreviews = true

    var body: some View {
        let files = context.store.visibleFiles(of: item)
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            BoardIcon(icon: item.icon, fallback: "newspaper", size: 44)
                .modifier(OpensPost(isEnabled: !files.isEmpty, open: onOpen))
            VStack(alignment: .leading, spacing: BighelpTokens.space8) {
                HStack(alignment: .firstTextBaseline, spacing: BighelpTokens.space8) {
                    Text(item.title)
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    UnreadDot(item: item, store: context.store)
                }
                // The title opens the post; the text keeps its own links.
                .modifier(OpensPost(isEnabled: !files.isEmpty, open: onOpen))
                if !item.body.isEmpty {
                    // Agents write posts in Markdown (bighelp_board): headings, lists, quotes, code
                    // and tables draw as they do in chat.
                    MarkdownMessageView(document: MarkdownDocument(item.body),
                                        primaryText: theme.primaryText.opacity(0.9))
                        .foregroundStyle(theme.primaryText.opacity(0.9))
                        .tint(theme.action)
                }
                if !item.pictures.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: BighelpTokens.space8) {
                            ForEach(Array(item.pictures.enumerated()), id: \.offset) { _, picture in
                                BoardPictureView(item: item, picture: picture, store: context.store)
                                    .frame(width: 220, height: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .modifier(OpensPost(isEnabled: !files.isEmpty, open: onOpen))
                            }
                        }
                    }
                    .scrollClipDisabled()
                }
                if !files.isEmpty {
                    BoardFilesStrip(item: item, files: files, store: context.store, onOpen: onOpen)
                }
                if let previewed = previewedLink {
                    LinkPreviewCard(url: previewed.url, fallbackTitle: previewed.title)
                        .frame(maxWidth: 420, alignment: .leading)
                }
                ForEach(item.links.filter { $0.url != previewedLink?.url }, id: \.url) { link in
                    Link(destination: link.url) {
                        Label(link.title.isEmpty ? (link.url.host() ?? "Open link") : link.title, systemImage: "link")
                            .font(.bighelp(.subheadline).weight(.medium))
                    }
                    // Only the link takes the tap in a List row.
                    .buttonStyle(.borderless)
                    .tint(theme.action)
                }
                actions
            }
        }
        .padding(.vertical, BighelpTokens.space8)
        .contentShape(.rect)
        .boardItemActions(item, context: context)
        .modifier(LessLikeThis(isPresented: $asksWhy, item: item, context: context))
        .accessibilityElement(children: .contain)
        .modifier(OpensPostForVoiceOver(isEnabled: !files.isEmpty, open: onOpen))
        .accessibilityIdentifier("board.feed.post.\(item.id)")
    }

    /// The post's first web link, else the first one in its text, as a preview card.
    private var previewedLink: AgentBoardItem.Link? {
        guard showsLinkPreviews else { return nil }
        if let link = item.links.first(where: { LinkPreviewPolicy.loadableURL($0.url) != nil }) { return link }
        return LinkPreviewCandidate.firstURL(inMarkdown: item.body).map { .init(url: $0, title: "") }
    }

    private var actions: some View {
        HStack(spacing: BighelpTokens.space12) {
            Button {
                Task { await context.store.rate(item, item.rating == .up ? .none : .up) }
            } label: {
                Image(systemName: item.rating == .up ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(.bighelp(.title3))
                    .foregroundStyle(item.rating == .up ? theme.action : theme.primaryText)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
            }
            .buttonStyle(.plain)
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
                    Image(systemName: item.rating == .down ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.bighelp(.title3))
                        .foregroundStyle(item.rating == .down ? theme.action : theme.primaryText)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rating == .down ? "Remove thumbs down" : "Thumbs down")
                .accessibilityAddTraits(item.rating == .down ? .isSelected : [])
                .accessibilityIdentifier("board.feed.thumbs-down")
            }
            Button {
                context.onAsk("About “\(item.title)”: ")
            } label: {
                Label("Discuss", systemImage: "bubble.left")
                    .font(.bighelp(.body).weight(.medium))
                    .foregroundStyle(theme.primaryText)
                    .frame(minHeight: BighelpTokens.hitTarget)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("board.feed.discuss")
            Spacer()
            Button {
                isShowingInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.bighelp(.title3))
                    .foregroundStyle(theme.secondaryText)
                    .frame(minWidth: BighelpTokens.hitTarget, minHeight: BighelpTokens.hitTarget, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About this post")
            .popover(isPresented: $isShowingInfo) {
                VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                    Text(item.source.isEmpty ? "Posted by \(context.agentName)" : item.source)
                        .font(.bighelp(.subheadline).weight(.semibold))
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.bighelp(.caption))
                        .foregroundStyle(.secondary)
                    if item.rating == .down, !item.reason.isEmpty {
                        Label("You said: \(item.reason)", systemImage: "hand.thumbsdown")
                            .font(.bighelp(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Button("Clear this post") {
                        isShowingInfo = false
                        Task { await context.store.dismiss(item) }
                    }
                    .padding(.top, BighelpTokens.space4)
                }
                .padding()
                .presentationCompactAdaptation(.popover)
                .bighelpPopoverDismissal(isPresented: $isShowingInfo)
            }
        }
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

struct AgentIdeasView: View {
    let context: AgentBoardContext
    @State private var selected: AgentBoardItem?
    @State private var showsBlueprints = false

    var body: some View {
        let store = context.store
        let isEmpty = store.ideas.isEmpty && store.state == .loaded
        BoardScroll(context: context, title: "Ideas", identifier: "board.ideas", seen: store.ideas,
                    onBlueprints: isEmpty ? nil : { showsBlueprints = true }) {
            BoardStateBanner(state: store.state, context: context)
            if isEmpty {
                BoardEmptyState(
                    symbol: "lightbulb",
                    title: "No ideas yet",
                    message: "Ask \(context.agentName) to suggest things it could do for you. Ideas it proposes land here.",
                    example: "Look through my week and suggest a few things you could take off my plate.",
                    agentName: context.agentName, onAsk: context.onAsk, identifier: "board.ideas.empty",
                    onBlueprints: { showsBlueprints = true })
            }
            ForEach(sections(store.ideas), id: \.title) { section in
                if !section.title.isEmpty {
                    Text(section.title)
                        .font(.bighelp(.title2).weight(.bold))
                        .foregroundStyle(theme.primaryText)
                        .padding(.top, BighelpTokens.space8)
                }
                ForEach(section.items) { idea in
                    VStack(spacing: 0) {
                        Button { selected = idea } label: { ideaRow(idea) }
                            .buttonStyle(.plain)
                            .boardItemActions(idea, context: context)
                            .accessibilityIdentifier("board.idea.\(idea.id)")
                        Divider().overlay(theme.border)
                    }
                    .boardItemSwipe(idea, store: store)
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

    private func sections(_ ideas: [AgentBoardItem]) -> [(title: String, items: [AgentBoardItem])] {
        var order: [String] = []
        var groups: [String: [AgentBoardItem]] = [:]
        for idea in ideas.sorted(by: { $0.createdAt > $1.createdAt }) {
            let key = idea.section.trimmingCharacters(in: .whitespaces)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(idea)
        }
        // Unsectioned ideas lead, under the page title.
        return order.sorted { $0.isEmpty && !$1.isEmpty }.map { ($0, groups[$0] ?? []) }
    }

    private func ideaRow(_ idea: AgentBoardItem) -> some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            BoardIcon(icon: idea.icon, fallback: "lightbulb", size: 48)
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(idea.title)
                    .font(.bighelp(.headline))
                    .foregroundStyle(theme.primaryText)
                    .multilineTextAlignment(.leading)
                // A short preview reads like a message preview: the Markdown's words, no symbols.
                Text(MarkdownDocument(idea.body).visiblePlainText.replacingOccurrences(of: "\n\n", with: "\n"))
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
            UnreadDot(item: idea, store: context.store)
                .padding(.top, 6)
        }
        .padding(.vertical, BighelpTokens.space8)
        .contentShape(.rect)
    }

    @BighelpThemeReader private var theme
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
                                ProgressView().tint(theme.actionForeground)
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
        .refreshable { await media.load(agentID: context.agentID) }
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
