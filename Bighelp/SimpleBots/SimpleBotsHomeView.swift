import Observation
import SwiftUI

/// What Simple Bot mode's home needs from the shell.
@MainActor
struct SimpleBotsContext {
    let agents: AgentDirectoryStore
    let catalog: SessionCatalogStore
    let personName: String
    let personImageURL: URL?
    /// This computer, for things kept per computer (Mark Unread).
    let scope: String
    let canCreateBots: Bool
    let canCreateGroups: Bool
    let onOpenBot: (String) -> Void
    let onOpenSession: (SessionSummary) -> Void
    let onOpenSettings: () -> Void
    let onOpenProfile: (String) -> Void
    let onNewChat: (String) -> Void
    let onCreateGroup: ([String]) -> Void
    /// A model for a new bot, set up the way the shell creates agents; nil when this computer can't.
    let makeCreator: () -> AgentEditorModel?
    let onRoutines: (String) -> Void
}

/// One row of the home list: a bot and its latest chat, or a group chat.
struct SimpleBotsItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case bot(AgentProfile)
        case group(SessionSummary)
    }

    let kind: Kind
    let preview: String?
    let date: Date?
    let isPinned: Bool

    var id: String {
        switch kind {
        case .bot(let profile): "bot:\(profile.id)"
        case .group(let summary): "group:\(summary.id)"
        }
    }
}

/// Who's on the home screen, and in what order.
enum SimpleBotsHomeProjection {
    struct Home: Equatable {
        var primary: AgentProfile?
        var primaryPreview: SessionSummary?
        var rows: [SimpleBotsItem]
    }

    /// The primary bot leads on its own. Then pinned bots in their order, then
    /// the rest by their latest chat (bots without one last, by name). Hidden
    /// bots stay off the list; group chats sit among them by their own time.
    static func home(profiles: [AgentProfile], primaryID: String?, pinnedIDs: [String],
                     summaries: [SessionSummary]) -> Home {
        let primary = profiles.first { $0.id == primaryID } ?? profiles.first(where: \.isDefault) ?? profiles.first
        func latest(_ agentID: String) -> SessionSummary? {
            summaries.filter { $0.kind == .direct && $0.agentIDs == [agentID] }.max { $0.updatedAt < $1.updatedAt }
        }
        var rows: [SimpleBotsItem] = []
        for profile in profiles where profile.id != primary?.id && profile.placement?.isHidden != true {
            let chat = latest(profile.id)
            rows.append(SimpleBotsItem(kind: .bot(profile), preview: chat?.preview, date: chat?.updatedAt,
                                       isPinned: pinnedIDs.contains(profile.id)))
        }
        for summary in summaries where summary.kind == .botMode {
            rows.append(SimpleBotsItem(kind: .group(summary), preview: summary.preview, date: summary.updatedAt,
                                       isPinned: summary.isPinned))
        }
        rows.sort { left, right in
            switch (left.pinOrder(pinnedIDs), right.pinOrder(pinnedIDs)) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                switch (left.date, right.date) {
                case let (l?, r?) where l != r: return l > r
                case (.some, nil): return true
                case (nil, .some): return false
                default: return left.sortName.localizedStandardCompare(right.sortName) == .orderedAscending
                }
            }
        }
        return Home(primary: primary, primaryPreview: primary.flatMap { latest($0.id) }, rows: rows)
    }
}

private extension SimpleBotsItem {
    func pinOrder(_ pinnedIDs: [String]) -> Int? {
        guard isPinned else { return nil }
        if case .bot(let profile) = kind { return pinnedIDs.firstIndex(of: profile.id) }
        return pinnedIDs.count
    }

    var sortName: String {
        switch kind {
        case .bot(let profile): profile.name
        case .group(let summary): summary.title
        }
    }
}

/// Bots someone marked unread on this device, per computer. Opening one clears it.
@MainActor
@Observable
final class SimpleBotsUnreadStore {
    static let shared = SimpleBotsUnreadStore()
    private static let key = "bighelp.simple-bots.unread"

    private(set) var keys: Set<String>
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        keys = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isUnread(_ id: String, scope: String) -> Bool { keys.contains(Self.key(id, scope)) }

    func set(_ unread: Bool, id: String, scope: String) {
        let key = Self.key(id, scope)
        guard keys.contains(key) != unread else { return }
        if unread { keys.insert(key) } else { keys.remove(key) }
        defaults.set(Array(keys.sorted().suffix(512)), forKey: Self.key)
    }

    private static func key(_ id: String, _ scope: String) -> String { "\(scope)|\(id)" }
}

private enum SimpleBotsSheet: Identifiable {
    case search, create, group, primary

    var id: String {
        switch self {
        case .search: "search"
        case .create: "create"
        case .group: "group"
        case .primary: "primary"
        }
    }
}

/// Simple Bot mode's home: your circle top left, search and + top right, the
/// primary bot large in the middle, then every other bot and group chat with
/// its latest message.
@MainActor
struct SimpleBotsHomeView: View {
    let context: SimpleBotsContext

    @State private var sheet: SimpleBotsSheet?
    @State private var hideError: String?
    @State private var templateNotice: String?
    private let unread = SimpleBotsUnreadStore.shared
    @BighelpThemeReader private var theme

    private var home: SimpleBotsHomeProjection.Home {
        SimpleBotsHomeProjection.home(
            profiles: context.agents.profiles, primaryID: context.agents.primaryAgentID,
            pinnedIDs: context.agents.pinnedAgentIDs,
            summaries: context.catalog.recentSummaries(includeCronSessions: false))
    }

    var body: some View {
        let home = home
        ScrollView {
            LazyVStack(spacing: 0) {
                if let primary = home.primary {
                    hero(primary, chat: home.primaryPreview)
                } else {
                    emptyHome
                }
                ForEach(home.rows) { item in
                    row(item)
                }
            }
            .padding(.bottom, BighelpTokens.space32)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(theme.canvas.ignoresSafeArea())
        .bighelpSheet(item: $sheet) { sheet in sheetView(sheet) }
        .alert("Couldn't hide this bot", isPresented: Binding(get: { hideError != nil },
                                                             set: { if !$0 { hideError = nil } })) {
            Button("OK") { hideError = nil }
        } message: { Text(hideError ?? "") }
        .alert("Saved as a template", isPresented: Binding(get: { templateNotice != nil },
                                                          set: { if !$0 { templateNotice = nil } })) {
            Button("OK") { templateNotice = nil }
        } message: { Text(templateNotice ?? "") }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-bots.home")
    }

    private var header: some View {
        HStack(spacing: BighelpTokens.space8) {
            SimpleBotsPersonButton(name: context.personName, imageURL: context.personImageURL,
                                   action: context.onOpenSettings)
            Spacer()
            SimpleBotsCircleButton(systemImage: "magnifyingglass", label: "Search bots",
                                   identifier: "simple-bots.search") { sheet = .search }
            Menu {
                Button("New Bot", systemImage: "plus.circle") { sheet = .create }
                    .disabled(!context.canCreateBots)
                Button("New Group Chat", systemImage: "person.2") { sheet = .group }
                    .disabled(!context.canCreateGroups)
            } label: {
                Image(systemName: "plus")
                    .font(.bighelp(.title3, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.circle)
                    .bighelpNavigationGlass(in: Circle(), isInteractive: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("New")
            .accessibilityIdentifier("simple-bots.new")
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.top, BighelpTokens.space4)
        .padding(.bottom, BighelpTokens.space8)
        .background { SimpleBotsHeaderFade() }
    }

    private func hero(_ primary: AgentProfile, chat: SessionSummary?) -> some View {
        Button {
            unread.set(false, id: primary.id, scope: context.scope)
            context.onOpenBot(primary.id)
        } label: {
            VStack(spacing: BighelpTokens.space12) {
                SimpleBotFace(agentID: primary.id, name: primary.name,
                              imageURL: context.agents.avatarURL(for: primary), size: 104, isPrimary: true)
                HStack(spacing: BighelpTokens.space4) {
                    Text(primary.name)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                    if unread.isUnread(primary.id, scope: context.scope) { unreadDot }
                }
            }
            .padding(.top, BighelpTokens.space24)
            .padding(.bottom, BighelpTokens.space32)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            botMenu(primary, isPrimary: true)
        } preview: {
            SimpleBotsPreview(agentID: primary.id, name: primary.name,
                              imageURL: context.agents.avatarURL(for: primary), message: chat?.preview)
        }
        .accessibilityLabel("\(primary.name), your primary bot")
        .accessibilityHint("Opens its chat")
        .accessibilityIdentifier("simple-bots.primary")
    }

    private var emptyHome: some View {
        VStack(spacing: BighelpTokens.space12) {
            Text("No bots yet")
                .font(.bighelp(.title3, weight: .semibold))
            Text("Tap + to make your first one.")
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.top, 120)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(_ item: SimpleBotsItem) -> some View {
        switch item.kind {
        case .bot(let profile):
            Button {
                unread.set(false, id: profile.id, scope: context.scope)
                context.onOpenBot(profile.id)
            } label: {
                SimpleBotsRowLabel(
                    face: AnyView(SimpleBotFace(agentID: profile.id, name: profile.name,
                                                imageURL: context.agents.avatarURL(for: profile), size: 56)),
                    title: profile.name, preview: item.preview ?? profile.role, date: item.date,
                    isUnread: unread.isUnread(profile.id, scope: context.scope), isPinned: item.isPinned)
            }
            .buttonStyle(.plain)
            .contextMenu {
                botMenu(profile, isPrimary: false)
            } preview: {
                SimpleBotsPreview(agentID: profile.id, name: profile.name,
                                  imageURL: context.agents.avatarURL(for: profile), message: item.preview)
            }
            .accessibilityIdentifier("simple-bots.bot.\(profile.id)")
        case .group(let summary):
            Button {
                unread.set(false, id: summary.id, scope: context.scope)
                context.onOpenSession(summary)
            } label: {
                SimpleBotsRowLabel(face: AnyView(groupFaces(summary)), title: summary.title,
                                   preview: item.preview, date: item.date,
                                   isUnread: unread.isUnread(summary.id, scope: context.scope), isPinned: item.isPinned)
            }
            .buttonStyle(.plain)
            .contextMenu {
                unreadButton(summary.id)
            }
            .accessibilityIdentifier("simple-bots.group.\(summary.id)")
        }
    }

    private func groupFaces(_ summary: SessionSummary) -> some View {
        let members = summary.agentIDs.prefix(2).compactMap { id in context.agents.profiles.first { $0.id == id } }
        return ZStack {
            ForEach(Array(members.enumerated()), id: \.element.id) { index, profile in
                SimpleBotFace(agentID: profile.id, name: profile.name,
                              imageURL: context.agents.avatarURL(for: profile), size: 38)
                    .offset(x: index == 0 ? -9 : 9, y: index == 0 ? -8 : 8)
            }
        }
        .frame(width: 56, height: 56)
    }

    @ViewBuilder
    private func botMenu(_ profile: AgentProfile, isPrimary: Bool) -> some View {
        unreadButton(profile.id)
        if context.agents.isPinned(profile.id) {
            Button("Unpin", systemImage: "pin.slash") { _ = context.agents.unpinAgent(profile.id) }
        } else if !isPrimary, context.agents.canPin(profile.id) {
            Button("Pin", systemImage: "pin") { _ = context.agents.pinAgent(profile.id) }
        }
        if isPrimary {
            Button("Replace Primary Bot…", systemImage: "arrow.left.arrow.right") { sheet = .primary }
        } else {
            Button("Make Primary Bot", systemImage: "star") { _ = context.agents.setPrimaryAgent(profile.id) }
        }
        Button("Save as Template", systemImage: "square.and.arrow.down.on.square") {
            let template = AgentTemplateLibrary.shared.save(from: profile)
            templateNotice = "“\(template.title)” is saved on this device. Pick it when you make a new bot."
        }
        if !isPrimary {
            Button("Hide", systemImage: "eye.slash", role: .destructive) { hide(profile) }
        }
        Menu("More", systemImage: "ellipsis") {
            Button("Bot Profile", systemImage: "person.crop.circle") { context.onOpenProfile(profile.id) }
            Button("New Chat", systemImage: "square.and.pencil") { context.onNewChat(profile.id) }
            Button("Routines", systemImage: "clock") { context.onRoutines(profile.id) }
        }
    }

    private func unreadButton(_ id: String) -> some View {
        let isUnread = unread.isUnread(id, scope: context.scope)
        return Button(isUnread ? "Mark Read" : "Mark Unread", systemImage: isUnread ? "message" : "message.badge") {
            unread.set(!isUnread, id: id, scope: context.scope)
        }
    }

    private func hide(_ profile: AgentProfile) {
        var placement = profile.placement ?? AgentListPlacement()
        placement.isHidden = true
        Task { @MainActor in
            do {
                try await context.agents.setPlacement(placement, profileID: profile.id)
            } catch {
                hideError = "This computer didn't save that. Try again in a moment."
            }
        }
    }

    private var unreadDot: some View {
        Circle().fill(theme.information).frame(width: 9, height: 9).accessibilityLabel("Unread")
    }

    @ViewBuilder
    private func sheetView(_ sheet: SimpleBotsSheet) -> some View {
        switch sheet {
        case .search:
            SimpleBotsSearchView(context: context, onOpen: { id in
                self.sheet = nil
                context.onOpenBot(id)
            })
            .bighelpSheetSize(.large)
        case .create:
            SimpleBotCreateView(makeCreator: context.makeCreator, onCreated: { profile in
                self.sheet = nil
                context.onOpenBot(profile.id)
            })
            .bighelpSheetSize(.large)
        case .group:
            SimpleBotsGroupChatView(context: context, onCreate: { ids in
                self.sheet = nil
                context.onCreateGroup(ids)
            })
            .bighelpSheetSize(.large)
        case .primary:
            SimpleBotsPrimaryPicker(context: context) { id in
                _ = context.agents.setPrimaryAgent(id)
                self.sheet = nil
            }
            .bighelpSheetSize(.standard)
        }
    }
}

/// A home row: the face, the name over the latest message, and its time.
private struct SimpleBotsRowLabel: View {
    let face: AnyView
    let title: String
    let preview: String?
    let date: Date?
    let isUnread: Bool
    let isPinned: Bool
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space16) {
            face.frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: BighelpTokens.space8) {
                    Text(title)
                        .font(.bighelp(.title3, weight: isUnread ? .semibold : .medium))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.bighelp(.caption2))
                            .foregroundStyle(theme.tertiaryText)
                            .accessibilityLabel("Pinned")
                    }
                    Spacer(minLength: BighelpTokens.space8)
                    if let date {
                        Text(SessionRow.compactTimestamp(date))
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.tertiaryText)
                    }
                    if isUnread {
                        Circle().fill(theme.information).frame(width: 9, height: 9).accessibilityLabel("Unread")
                    }
                }
                if let preview = preview.map(SessionPreviewText.plain), !preview.isEmpty {
                    Text(preview)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.vertical, BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Touch and hold a bot: its latest message, the way its chat shows it.
private struct SimpleBotsPreview: View {
    let agentID: String
    let name: String
    let imageURL: URL?
    let message: String?
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: BighelpTokens.space12) {
                SimpleBotFace(agentID: agentID, name: name, imageURL: imageURL, size: 32)
                Text(name).font(.bighelp(.title3, weight: .semibold))
            }
            .padding(BighelpTokens.space20)
            Rectangle().fill(theme.separator).frame(height: BighelpTokens.hairline)
            Group {
                if let message = message.map(SessionPreviewText.plain), !message.isEmpty {
                    Text(message)
                        .font(.bighelp(.body))
                        .lineLimit(6)
                        .padding(.horizontal, BighelpTokens.space16)
                        .padding(.vertical, BighelpTokens.space12)
                        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: 20))
                } else {
                    Text("No messages yet")
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(BighelpTokens.space20)
        }
        .frame(width: 320, alignment: .leading)
        // A preview is drawn outside the app's own colors; the system's match Simple Bot mode.
        .background(Color(uiColor: .systemBackground))
    }
}

/// Replace Primary Bot: the bot that leads the home screen.
private struct SimpleBotsPrimaryPicker: View {
    let context: SimpleBotsContext
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme

    var body: some View {
        NavigationStack {
            List(context.agents.profiles.filter { $0.placement?.isHidden != true }) { profile in
                Button { onPick(profile.id) } label: {
                    HStack(spacing: BighelpTokens.space16) {
                        SimpleBotFace(agentID: profile.id, name: profile.name,
                                      imageURL: context.agents.avatarURL(for: profile), size: 44)
                        Text(profile.name).font(.bighelp(.body))
                        Spacer()
                        if context.agents.isPrimary(profile.id) || (context.agents.primaryAgentID == nil && profile.isDefault) {
                            Image(systemName: "checkmark").foregroundStyle(theme.action)
                        }
                    }
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("simple-bots.primary-pick.\(profile.id)")
            }
            .listStyle(.plain)
            .navigationTitle("Primary Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
