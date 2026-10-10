import SwiftUI
import WidgetKit

/// Your agent on the Home Screen: its real face, what it's doing right now,
/// its latest Feed posts and Goals, and one tap to a new chat. Mirrors the
/// app's agent home in the colors picked in Settings.
struct BighelpAgentWidget: Widget {
    var body: some WidgetConfiguration {
        // Widget kinds keep their original names so widgets already on home screens stay.
        AppIntentConfiguration(kind: "LoopdyAgentWidget", intent: GatewayWidgetIntent.self,
                               provider: GatewayWidgetProvider()) { entry in
            BighelpWidgetScaffold(snapshot: entry.snapshot) {
                BighelpAgentWidgetView(snapshot: entry.snapshot)
            }
        }
        .configurationDisplayName("Your Agent")
        .description("See what your agent is up to, its latest posts and goals, and start a chat.")
        .supportedFamilies(Self.families)
        .bighelpWidgetPlacement()
    }

    private static var families: [WidgetFamily] {
        #if os(visionOS)
        [.systemSmall, .systemMedium, .systemLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
    }
}

struct BighelpAgentWidgetView: View {
    let snapshot: BighelpWidgetSnapshot
    /// Set by render tests; WidgetKit supplies the family otherwise.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.bighelpWidgetColors) private var colors

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        switch family {
        #if os(iOS)
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .systemMedium: medium
        case .systemLarge: large
        #endif
        default: small
        }
    }

    private var pose: BighelpActivityPose? { snapshot.agentPose }
    private var name: String { snapshot.agentDisplayName }
    private var feed: [BighelpWidgetSnapshot.BoardItem] { snapshot.feed ?? [] }
    private var goals: [BighelpWidgetSnapshot.BoardItem] { snapshot.goals ?? [] }
    private var newChat: URL { snapshot.newChatURL(agentID: snapshot.defaultAgentID) }

    private var statusText: String { pose?.label ?? BighelpActivityPose.idle.label }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                BighelpWidgetAvatar(agentID: snapshot.defaultAgentID, name: name, diameter: 54, pose: pose)
                Spacer(minLength: 0)
                Link(destination: newChat) { newChatGlyph(size: 30) }
            }
            Spacer(minLength: 6)
            Text(name)
                .font(.headline)
                .lineLimit(1)
            status
            if pose == nil, let post = feed.first {
                Text(post.title)
                    .font(.caption2)
                    .foregroundStyle(colors.secondary)
                    .lineLimit(2)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(snapshot.agentRunningSession.map { snapshot.chatURL($0.id) }
                   ?? snapshot.agentURL())
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                BighelpWidgetAvatar(agentID: snapshot.defaultAgentID, name: name, diameter: 58, pose: pose)
                Spacer(minLength: 6)
                Text(name).font(.headline).lineLimit(1)
                status
                Spacer(minLength: 8)
                Link(destination: newChat) { newChatCapsule }
            }
            .frame(width: 118, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                if let session = snapshot.agentRunningSession {
                    BighelpWidgetSectionTitle(title: "Now", symbol: "bolt.fill")
                    Link(destination: snapshot.chatURL(session.id)) {
                        boardRow(symbol: pose?.symbolName ?? "sparkles", title: session.title,
                                 detail: session.status, highlighted: true)
                    }
                }
                if !feed.isEmpty {
                    BighelpWidgetSectionTitle(title: "Feed", glyph: .feed)
                    ForEach(feed.prefix(snapshot.agentRunningSession == nil ? 3 : 1)) { post in
                        Link(destination: snapshot.agentURL("feed")) {
                            boardRow(emoji: post.icon, symbol: "newspaper", title: post.title, date: post.date)
                        }
                    }
                } else if snapshot.agentRunningSession == nil {
                    recentOrEmpty(limit: 3)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .widgetURL(snapshot.agentURL())
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                BighelpWidgetAvatar(agentID: snapshot.defaultAgentID, name: name, diameter: 52, pose: pose)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.title3.weight(.semibold)).lineLimit(1)
                    status
                }
                Spacer(minLength: 0)
                Link(destination: newChat) { newChatGlyph(size: 36) }
            }
            if let session = snapshot.agentRunningSession {
                Link(destination: snapshot.chatURL(session.id)) {
                    boardRow(symbol: pose?.symbolName ?? "sparkles", title: session.title,
                             detail: session.status, highlighted: true)
                }
            }
            if !feed.isEmpty {
                section("Feed", glyph: .feed) {
                    ForEach(feed.prefix(snapshot.agentRunningSession == nil ? 3 : 2)) { post in
                        Link(destination: snapshot.agentURL("feed")) {
                            boardRow(emoji: post.icon, symbol: "newspaper", title: post.title, date: post.date)
                        }
                    }
                }
            }
            if !goals.isEmpty {
                section("Goals", glyph: .goals) {
                    ForEach(goals.prefix(feed.isEmpty ? 4 : 2)) { goal in
                        Link(destination: snapshot.agentURL("goals")) { goalRow(goal) }
                    }
                }
            }
            if feed.isEmpty, goals.isEmpty {
                recentOrEmpty(limit: 4)
            }
            Spacer(minLength: 0)
            tabStrip
        }
        .widgetURL(snapshot.agentURL())
    }

    #if os(iOS)
    // MARK: Lock Screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let pose {
                Image(systemName: pose.symbolName)
                    .font(.title3.weight(.semibold))
                    .widgetAccentable()
            } else if let id = snapshot.defaultAgentID, let image = BighelpActivityAvatarStore.image(agentID: id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
                    .padding(3)
            } else {
                Text(String(name.first ?? "b").uppercased())
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .widgetAccentable()
            }
        }
        .accessibilityLabel("\(name), \(statusText)")
        .widgetURL(snapshot.agentRunningSession.map { snapshot.chatURL($0.id) }
                   ?? snapshot.agentURL())
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: pose?.symbolName ?? "sparkles")
                Text(name).lineLimit(1)
            }
            .font(.headline)
            .widgetAccentable()
            Text(statusText).font(.caption).lineLimit(1)
            if let line = snapshot.agentRunningSession?.title ?? feed.first?.title ?? goals.first?.title {
                Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(snapshot.agentRunningSession.map { snapshot.chatURL($0.id) }
                   ?? snapshot.agentURL())
    }

    private var inline: some View {
        Label("\(name): \(statusText)", systemImage: pose?.symbolName ?? "sparkles")
            .widgetURL(snapshot.agentURL())
    }
    #endif

    // MARK: Pieces

    private var status: some View {
        HStack(spacing: 4) {
            if let pose {
                Image(systemName: pose.symbolName)
                    .foregroundStyle(colors.accent)
                    .widgetAccentable()
            }
            Text(statusText)
                .foregroundStyle(pose == nil ? colors.secondary : colors.primary)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .id(pose)
        .transition(.push(from: .bottom))
    }

    private func newChatGlyph(size: CGFloat) -> some View {
        Image(systemName: "square.and.pencil")
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(colors.accentForeground)
            .frame(width: size, height: size)
            .background(Circle().fill(colors.accent))
            .widgetAccentable()
            .accessibilityLabel("New chat with \(name)")
    }

    private var newChatCapsule: some View {
        Label("New chat", systemImage: "square.and.pencil")
            .font(.caption.weight(.semibold))
            .foregroundStyle(colors.accentForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(colors.accent))
            .widgetAccentable()
    }

    private func section<Content: View>(_ title: String, glyph: BighelpTabGlyph,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            BighelpWidgetSectionTitle(title: title, glyph: glyph)
            content()
        }
    }

    /// A board post keeps its emoji; everything else gets a symbol.
    private func boardRow(emoji: String? = nil, symbol: String, title: String, detail: String? = nil,
                          date: Date? = nil, highlighted: Bool = false) -> some View {
        HStack(spacing: 8) {
            Group {
                if let emoji, !emoji.isEmpty {
                    Text(emoji).font(.system(size: 14))
                } else {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(highlighted ? colors.accentForeground : colors.accent)
                }
            }
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(highlighted ? colors.accent : colors.accent.opacity(0.14)))
            .widgetAccentable()
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colors.primary)
                    .lineLimit(1)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                } else if let date {
                    Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                        .font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func goalRow(_ goal: BighelpWidgetSnapshot.BoardItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: goal.isDone ? "checkmark.circle.fill" : "circle")
                .font(.body)
                .foregroundStyle(goal.isDone ? colors.accent : colors.secondary)
                .widgetAccentable()
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(goal.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(goal.isDone ? colors.secondary : colors.primary)
                    .strikethrough(goal.isDone, color: colors.secondary)
                    .lineLimit(1)
                if let note = goal.note {
                    Text(note).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func recentOrEmpty(limit: Int) -> some View {
        let recent = snapshot.feedSessions.prefix(limit)
        if recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("All quiet").font(.caption.weight(.semibold))
                Text("Posts and goals from \(name) show up here.")
                    .font(.caption2)
                    .foregroundStyle(colors.secondary)
                    .lineLimit(2)
            }
        } else {
            BighelpWidgetSectionTitle(title: "Recent chats", symbol: "bubble.left.and.bubble.right.fill")
            ForEach(Array(recent)) { session in
                Link(destination: snapshot.chatURL(session.id)) {
                    boardRow(symbol: "bubble.left.fill", title: session.title, date: session.updatedAt)
                }
            }
        }
    }

    /// Chat, Feed, Ideas and Goals, like the app's bottom bar.
    private var tabStrip: some View {
        HStack(spacing: 6) {
            ForEach([("chat", "Chat", BighelpTabGlyph.chat), ("feed", "Feed", .feed),
                     ("ideas", "Ideas", .ideas), ("goals", "Goals", .goals)], id: \.0) { tab in
                Link(destination: snapshot.agentURL(tab.0)) {
                    VStack(spacing: 2) {
                        BighelpTabGlyphShape(glyph: tab.2).frame(width: 18, height: 18)
                        Text(tab.1).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(colors.primary)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colors.primary.opacity(0.06)))
                }
            }
        }
    }
}
