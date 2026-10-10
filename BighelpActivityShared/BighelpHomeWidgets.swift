// Home screen widgets; on Vision Pro they're glass in the room. Lock Screen
// sizes are iPhone-only.
import SwiftUI
import WidgetKit

// MARK: - Timeline

struct BighelpWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BighelpWidgetSnapshot
}

extension BighelpWidgetSnapshot {
    static let preview = BighelpWidgetSnapshot(
        defaultAgentID: "default", defaultAgentName: "Juno",
        sessions: [
            .init(id: "a", title: "Fix the build", agentName: "Juno", status: "Running tests",
                  preview: "Build succeeded, running the unit suite.", isRunning: true, updatedAt: .now,
                  agentID: "default", activity: BighelpActivityPose.coding.rawValue),
            .init(id: "b", title: "Weekend plans", agentName: "Juno", status: "Replied",
                  preview: "Saturday looks clear after 2 PM.", isRunning: false, updatedAt: .now.addingTimeInterval(-900),
                  agentID: "default"),
        ],
        tasks: [.init(id: "t", name: "Morning brief", agentName: "Juno", schedule: "Every day at 7:00 AM",
                      nextRun: .now.addingTimeInterval(3600), lastResult: nil)],
        generatedAt: .now,
        feed: [
            .init(id: "f1", title: "Three flights under $300 for your May trip", icon: "✈️", date: .now.addingTimeInterval(-1800)),
            .init(id: "f2", title: "Your weekly spending recap is ready", icon: "📊", date: .now.addingTimeInterval(-7200)),
            .init(id: "f3", title: "New from the Swift blog: macros in practice", icon: "📰", date: .now.addingTimeInterval(-86_400)),
        ],
        goals: [
            .init(id: "g1", title: "Run a 10K", icon: "🏃", note: "4 of 8 weeks", date: .now),
            .init(id: "g2", title: "Read 12 books", icon: "📚", note: "7 so far", date: .now),
            .init(id: "g3", title: "Launch the app", icon: "🚀", isDone: true, date: .now),
        ])
}

// MARK: - Shared pieces

private struct RunningDot: View {
    let running: Bool
    @Environment(\.bighelpWidgetColors) private var colors
    var body: some View {
        Circle().fill(running ? colors.accent : colors.secondary.opacity(0.4))
            .frame(width: 7, height: 7).widgetAccentable().accessibilityHidden(true)
    }
}

private struct EmptyState: View {
    let symbol: String
    let text: String
    @Environment(\.bighelpWidgetColors) private var colors
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title3).foregroundStyle(colors.accent.opacity(0.7)).widgetAccentable()
            Text(text).font(.caption).foregroundStyle(colors.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WidgetHeader: View {
    let title: String
    let symbol: String
    var count: Int? = nil
    @Environment(\.bighelpWidgetColors) private var colors
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(colors.accent).widgetAccentable()
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(count > 0 ? colors.accentForeground : colors.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(count > 0 ? colors.accent : colors.secondary.opacity(0.15)))
                    .widgetAccentable()
                    .contentTransition(.numericText())
            }
        }
    }
}

/// One chat: what the agent is doing while it runs, else its last reply.
private struct WidgetSessionRow: View {
    let session: BighelpWidgetSnapshot.Session
    var avatar: CGFloat = 0
    var detailLines = 1
    @Environment(\.bighelpWidgetColors) private var colors

    var body: some View {
        HStack(alignment: avatar > 0 ? .top : .center, spacing: 8) {
            if avatar > 0 {
                BighelpWidgetAvatar(agentID: session.agentID, name: session.agentName, diameter: avatar,
                                   pose: session.isRunning ? pose : nil)
            } else if session.isRunning {
                Image(systemName: pose.symbolName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(colors.accentForeground)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(colors.accent))
                    .widgetAccentable()
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(session.title).font(.caption.weight(.semibold)).foregroundStyle(colors.primary).lineLimit(1)
                    if avatar > 0 {
                        Spacer(minLength: 4)
                        if session.isRunning {
                            RunningDot(running: true)
                        } else {
                            Text(session.updatedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                                .font(.caption2).foregroundStyle(colors.secondary).lineLimit(1).fixedSize()
                        }
                    }
                }
                Text(session.isRunning ? session.status : (session.preview ?? session.status))
                    .font(.caption2).foregroundStyle(colors.secondary).lineLimit(detailLines)
            }
            if avatar == 0 { Spacer(minLength: 0) }
        }
    }

    private var pose: BighelpActivityPose {
        session.activity.flatMap(BighelpActivityPose.init(rawValue:)) ?? .thinking
    }
}

// MARK: - Active sessions (small / accessory)

struct BighelpActiveSessionsView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: BighelpWidgetSnapshot

    var body: some View {
        let running = snapshot.runningSessions
        switch family {
        #if os(iOS)
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text("\(running.count)").font(.title2.weight(.semibold).monospacedDigit())
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.caption2)
                }
            }
            .accessibilityLabel("\(running.count) active bighelp chats")
            .widgetURL(snapshot.sessionsURL)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(running.isEmpty ? "No active chats" : "\(running.count) active")
                    .font(.headline).widgetAccentable()
                if let first = running.first {
                    Text(first.title).font(.caption).lineLimit(1)
                    Text(first.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(running.first.map { snapshot.chatURL($0.id) } ?? snapshot.sessionsURL)
        #endif
        default:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "Working on", symbol: "bolt.fill", count: running.count)
                if running.isEmpty {
                    EmptyState(symbol: "checkmark.circle", text: "All caught up")
                } else {
                    ForEach(running.prefix(family == .systemMedium ? 3 : 2)) { session in
                        Link(destination: snapshot.chatURL(session.id)) {
                            WidgetSessionRow(session: session)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .widgetURL(snapshot.sessionsURL)
        }
    }
}

struct BighelpActiveSessionsWidget: Widget {
    var body: some WidgetConfiguration {
        // Widget kinds keep their original names so widgets already on home screens stay.
        AppIntentConfiguration(kind: "LoopdyActiveSessionsWidget", intent: GatewayWidgetIntent.self,
                               provider: GatewayWidgetProvider()) { entry in
            BighelpWidgetScaffold(snapshot: entry.snapshot) {
                BighelpActiveSessionsView(snapshot: entry.snapshot)
            }
        }
        .configurationDisplayName("Active Chats")
        .description("See which chats your agents are working on, and what they're doing.")
        .supportedFamilies(Self.families)
        .bighelpWidgetPlacement()
    }

    private static var families: [WidgetFamily] {
        #if os(visionOS)
        [.systemSmall, .systemMedium]
        #else
        [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular]
        #endif
    }
}

// MARK: - Scheduled tasks

struct BighelpScheduledTasksView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.bighelpWidgetColors) private var colors
    let snapshot: BighelpWidgetSnapshot

    var body: some View {
        let tasks = snapshot.tasks.sorted { ($0.nextRun ?? .distantFuture) < ($1.nextRun ?? .distantFuture) }
        switch family {
        #if os(iOS)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(tasks.first?.name ?? "No scheduled tasks").font(.headline).lineLimit(1).widgetAccentable()
                if let next = tasks.first?.nextRun {
                    Text(next, format: .relative(presentation: .named, unitsStyle: .abbreviated)).font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(tasks.first.map { snapshot.taskURL($0.id) } ?? snapshot.tasksURL)
        #endif
        default:
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeader(title: "Scheduled", symbol: "clock.arrow.circlepath", count: tasks.count)
                if tasks.isEmpty {
                    EmptyState(symbol: "calendar.badge.clock", text: "No active tasks")
                } else {
                    ForEach(Array(tasks.prefix(family == .systemSmall ? 2 : 3).enumerated()), id: \.element.id) { index, task in
                        Link(destination: snapshot.taskURL(task.id)) {
                            HStack(spacing: 8) {
                                // The next task leads, in the bubble color.
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(index == 0 ? colors.accent : colors.secondary.opacity(0.3))
                                    .frame(width: 3)
                                    .widgetAccentable()
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(task.name).font(.caption.weight(.semibold)).foregroundStyle(colors.primary).lineLimit(1)
                                    if let next = task.nextRun {
                                        Text(next, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                                            .font(.caption2).foregroundStyle(index == 0 ? colors.accent : colors.secondary).lineLimit(1)
                                    } else {
                                        Text(task.schedule).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .widgetURL(snapshot.tasksURL)
        }
    }
}

struct BighelpScheduledTasksWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LoopdyScheduledTasksWidget", intent: GatewayWidgetIntent.self,
                               provider: GatewayWidgetProvider()) { entry in
            BighelpWidgetScaffold(snapshot: entry.snapshot) {
                BighelpScheduledTasksView(snapshot: entry.snapshot)
            }
        }
        .configurationDisplayName("Scheduled Tasks")
        .description("Your active scheduled tasks and when they run next.")
        .supportedFamilies(Self.families)
        .bighelpWidgetPlacement()
    }

    private static var families: [WidgetFamily] {
        #if os(visionOS)
        [.systemSmall, .systemMedium]
        #else
        [.systemSmall, .systemMedium, .accessoryRectangular]
        #endif
    }
}

// MARK: - New chat with the default agent

struct BighelpNewChatView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.bighelpWidgetColors) private var colors
    let snapshot: BighelpWidgetSnapshot
    /// The agent the widget is set to; nil is the gateway's default agent.
    var agentID: String? = nil

    /// The chosen agent while it's on the gateway, else the default one.
    private var agent: (id: String?, name: String) {
        if let agentID, let agent = snapshot.agents?.first(where: { $0.id == agentID }) { return (agent.id, agent.name) }
        return (snapshot.defaultAgentID, snapshot.agentDisplayName)
    }

    var body: some View {
        let name = agent.name
        let url = snapshot.newChatURL(agentID: agent.id)
        Group {
            switch family {
            #if os(iOS)
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "square.and.pencil").font(.title3.weight(.semibold))
                }
                .accessibilityLabel("New chat with \(name)")
            #endif
            default:
                VStack(alignment: .leading, spacing: 0) {
                    BighelpWidgetAvatar(agentID: agent.id, name: name, diameter: 56)
                    Spacer(minLength: 0)
                    Text("New chat").font(.headline)
                    Text("with \(name)").font(.caption).foregroundStyle(colors.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.accentForeground)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(colors.accent))
                        .widgetAccentable()
                }
            }
        }
        .widgetURL(url)
    }
}

struct BighelpNewChatWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LoopdyNewChatWidget", intent: NewChatWidgetIntent.self,
                               provider: NewChatWidgetProvider()) { entry in
            BighelpWidgetScaffold(snapshot: entry.snapshot) {
                BighelpNewChatView(snapshot: entry.snapshot, agentID: entry.agentID)
            }
        }
        .configurationDisplayName("New Chat")
        .description("Start a new chat in one tap, with your default agent or one you choose.")
        .supportedFamilies(Self.families)
        .bighelpWidgetPlacement()
    }

    private static var families: [WidgetFamily] {
        #if os(visionOS)
        [.systemSmall]
        #else
        [.systemSmall, .accessoryCircular]
        #endif
    }
}

// MARK: - Activity feed (large)

struct BighelpActivityFeedView: View {
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.bighelpWidgetColors) private var colors
    let snapshot: BighelpWidgetSnapshot
    /// Set by render tests; WidgetKit supplies the family otherwise.
    var familyOverride: WidgetFamily? = nil

    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    var body: some View {
        let sessions = snapshot.feedSessions
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                WidgetHeader(title: "Recent chats", symbol: "bubble.left.and.bubble.right.fill",
                             count: snapshot.runningSessions.count)
                Link(destination: snapshot.newChatURL(agentID: snapshot.defaultAgentID)) {
                    Image(systemName: "square.and.pencil")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(colors.accentForeground)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(colors.accent))
                        .widgetAccentable()
                }
            }
            if sessions.isEmpty {
                EmptyState(symbol: "bubble.left.and.bubble.right", text: "No recent chats")
            } else {
                let large = family == .systemLarge || family == .systemExtraLarge
                ForEach(sessions.prefix(family == .systemExtraLarge ? 8 : large ? 5 : 2)) { session in
                    Link(destination: snapshot.chatURL(session.id)) {
                        WidgetSessionRow(session: session, avatar: 30, detailLines: large ? 2 : 1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

struct BighelpActivityFeedWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "LoopdyActivityFeedWidget", intent: GatewayWidgetIntent.self,
                               provider: GatewayWidgetProvider()) { entry in
            BighelpWidgetScaffold(snapshot: entry.snapshot) {
                BighelpActivityFeedView(snapshot: entry.snapshot)
                    .widgetURL(entry.snapshot.sessionsURL)
            }
        }
        .configurationDisplayName("Recent Chats")
        .description("Your latest chats, newest first, with what each agent is doing.")
        .supportedFamilies(Self.families)
        .bighelpWidgetPlacement()
    }

    private static var families: [WidgetFamily] {
        #if os(visionOS)
        [.systemMedium, .systemLarge, .systemExtraLarge]
        #else
        [.systemMedium, .systemLarge]
        #endif
    }
}
