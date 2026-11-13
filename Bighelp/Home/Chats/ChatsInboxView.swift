import SwiftUI

/// What the Chats view needs from the shell. It reads its stores only through this.
@MainActor
struct ChatsInboxContext {
    /// The computer in use: live rows, pins, read state, drafts.
    let catalog: SessionCatalogStore
    let agents: AgentDirectoryStore
    /// Every computer's all-hosts copies; nil leaves only the computer in use.
    var fleet: FleetStore? = nil
    /// Settings' Show every computer: the other computers' chats join the list.
    var showsEveryComputer = false
    /// The computer in use's group chats (`BotModeRoomStore.catalogRooms`): one with no message yet
    /// shows from here.
    var rooms: [HermesBotModeRoomSummary] = []
    /// `CodeHomeStore.sessions` IDs, for the Code tag.
    var codeSessionIDs: Set<String> = []
    /// Which Bot Chats are working or need you, kept current while the list shows.
    var activity: BotChatActivityStore? = nil
    var activitySource: BotChatActivitySource? = nil
    /// Whether a chat's message box holds something unsent, from the draft journal without
    /// observing it (`SessionsModel.unsentDraft`); nil keeps the catalog's own mark.
    var unsentDraft: ((String) -> Bool?)? = nil
    /// The computer in use answers; while it doesn't, its last chats show under a note.
    var isConnected = true
    /// `HomeHeaderBar`, drawn on top.
    let header: AnyView
    let onOpen: (ChatsInboxTarget) -> Void
    /// Makes a long-press change; the shell reports a failure. Nil leaves the actions out.
    var onChange: ((ChatsInboxRow, ChatsInboxChange) -> Void)? = nil
    /// Pull to refresh for the computer in use; the other computers are read again here.
    var onRefresh: (@MainActor @Sendable () async -> Void)? = nil
    /// The empty list's one action.
    var onNewChat: (() -> Void)? = nil
    var onOpenArchived: (() -> Void)? = nil
    /// The computer in use's own Sessions page: projects, imports from other apps.
    var onOpenThisComputer: (() -> Void)? = nil
}

/// The first tab's Chats view: every chat on every computer in one list, Pinned on top, then the
/// newest. Search and one row of chips (All, each computer, Unread) sit over it.
struct ChatsInboxView: View {
    let context: ChatsInboxContext

    @State private var search = ""
    @State private var filter: ChatsInboxFilter = .all
    @State private var renaming: ChatsInboxRow?
    @State private var renameDraft = ""
    @State private var cache = ChatsInboxCache()
    @Environment(\.scenePhase) private var scenePhase
    @BighelpThemeReader private var theme

    var body: some View {
        let list = listState
        List {
            BighelpSearchField(text: $search, prompt: String(localized: "Search chats"),
                               accessibilityLabel: String(localized: "Search chats"),
                               accessibilityIdentifier: "chats.search")
                .bighelpListSearchRow()
            ChatsInboxChips(computers: list.chipComputers, statuses: context.fleet?.statuses ?? [:],
                            selection: $filter)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: BighelpTokens.space4, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(list.offline, id: \.self) { name in
                ChatsInboxOfflineNote(name: name)
            }
            content(list)
            moreSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .dismissesKeyboardOnScroll(true, immediately: true)
        .frame(maxWidth: ChatCanvasLayout.regularLaneMaximumWidth)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .top, spacing: 0) { context.header }
        .background(theme.canvas.ignoresSafeArea())
        .bighelpRefreshable { [onRefresh = context.onRefresh, fleet = shownFleet] in
            if let fleet { fleet.refresh(force: true) }
            await onRefresh?()
            if let fleet { await fleet.waitForReads() }
        }
        // The other computers are read again as the list shows (at most once a minute).
        .task(id: shownFleet != nil) { shownFleet?.refresh() }
        .botChatActivityUpdates(context.activity, source: context.activitySource, isActive: scenePhase == .active)
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { row in
            TextField("Chat name", text: $renameDraft)
                .accessibilityIdentifier("chats.rename.field")
            Button("Cancel", role: .cancel) {}
            Button("Save") { context.onChange?(row, .rename(renameDraft)) }
                .accessibilityIdentifier("chats.rename.save")
        } message: { row in
            Text(row.isBotChat
                 ? "Renamed, this becomes a regular chat, and tapping the bot starts a new Bot Chat."
                 : "Enter a name up to \(SessionTitleRules.maximumLength) characters.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chats.inbox")
    }

    // MARK: State

    private var shownFleet: FleetStore? { context.showsEveryComputer ? context.fleet : nil }

    /// What one drawing shows, worked out from the cache.
    private struct ListState {
        let all: [ChatsInboxRow]
        let sections: [ChatsInboxSection]
        /// The computers to pick by chip; empty with one computer, so only All and Unread show.
        let chipComputers: [FleetHost]
        /// Computers that don't answer, among those shown: their last chats stay, under a note.
        let offline: [String]
        let filter: ChatsInboxFilter
    }

    private var listState: ListState {
        // Read every time, also on a cache hit: this is what draws the list again when chats change.
        _ = context.catalog.presentedRecords
        let fleet = shownFleet
        let hosts = fleet?.hosts ?? []
        let showsComputers = hosts.count > 1
        let selectedHostID = fleet?.selectedHostID
        let computers: [ChatsInboxComputer] = hosts.compactMap { host in
            guard host.id != selectedHostID, let snapshot = fleet?.snapshots[host.id] else { return nil }
            return ChatsInboxComputer(id: host.id, name: host.name, chats: snapshot.chats, groups: snapshot.groups ?? [])
        }
        // Read on every draw: the catalog's revision doesn't move for what only an open chat's
        // message box holds (files are never saved), so the Draft mark went stale. Two lookups a chat.
        var unsentDrafts: [String: Bool] = [:]
        if let unsentDraft = context.unsentDraft {
            for record in context.catalog.presentedRecords {
                if let unsent = unsentDraft(record.id) { unsentDrafts[record.id] = unsent }
            }
        }
        let key = ChatsInboxCache.Key(
            catalog: ObjectIdentifier(context.catalog),
            revision: context.catalog.presentedRevision, rooms: context.rooms, codeSessionIDs: context.codeSessionIDs,
            selectedHostID: selectedHostID, computers: computers, showsComputerTags: showsComputers,
            unsentDrafts: unsentDrafts
        )
        let all = cache.rows(for: key) { [context] in
            let summaries = context.catalog.recentSummaries(includeCronSessions: false).map { summary in
                var summary = summary
                if let unsent = unsentDrafts[summary.id] { summary.hasDraft = unsent }
                return summary
            }
            return ChatsInboxProjection.rows(ChatsInboxInput(
                sessions: summaries, rooms: context.rooms, codeSessionIDs: context.codeSessionIDs,
                selectedHostID: selectedHostID, computers: computers, showsComputerTags: showsComputers))
        }
        // A computer chip whose computer went (or that no longer shows) falls back to All.
        let effective: ChatsInboxFilter = switch filter {
        case .computer(let id) where !showsComputers || !hosts.contains(where: { $0.id == id }): .all
        default: filter
        }
        let sections = cache.sections(effective, query: search, now: .now)
        var offline: [String] = []
        if let fleet {
            for host in hosts {
                if case .computer(let id) = effective, id != host.id { continue }
                if host.id == selectedHostID ? !context.isConnected : fleet.statuses[host.id].isUnreachable {
                    offline.append(host.name)
                }
            }
        } else if !context.isConnected {
            offline.append(String(localized: "This computer"))
        }
        return ListState(all: all, sections: sections, chipComputers: showsComputers ? hosts : [],
                         offline: offline, filter: effective)
    }

    // MARK: Rows

    @ViewBuilder
    private func content(_ list: ListState) -> some View {
        if list.all.isEmpty, !context.catalog.hasLoadedState, context.isConnected {
            ForEach(0..<4, id: \.self) { index in
                ChatsInboxPlaceholderRow(index: index)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } else if list.sections.isEmpty {
            emptyState(list)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            let faces = ChatsInboxFaces(agents: context.agents, fleet: context.fleet)
            ForEach(list.sections) { section in
                Section {
                    ForEach(section.rows) { row in rowButton(row, faces: faces) }
                } header: {
                    sectionHeader(section.kind)
                }
            }
        }
    }

    private func rowButton(_ row: ChatsInboxRow, faces: ChatsInboxFaces) -> some View {
        Button { context.onOpen(row.target) } label: {
            ChatsInboxRowLabel(row: row, face: faces.face(for: row, activity: context.activity),
                               activity: context.activity)
        }
        .buttonStyle(.plain)
        // One menu for each row of the list, so a hold always acts on the row held. Right-click on the Mac.
        .contextMenu { actions(row) }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: BighelpTokens.space16, bottom: 0, trailing: BighelpTokens.space16))
        .accessibilityIdentifier("chats.row.\(row.id)")
    }

    @ViewBuilder
    private func actions(_ row: ChatsInboxRow) -> some View {
        if let onChange = context.onChange {
            if row.canPin {
                Button(row.isPinned ? "Unpin" : "Pin", systemImage: row.isPinned ? "pin.slash" : "pin") {
                    onChange(row, .pin(!row.isPinned))
                }
                .accessibilityIdentifier("chats.action.pin.\(row.id)")
            }
            if row.canMarkUnread {
                Button(row.isUnread ? "Mark read" : "Mark unread",
                       systemImage: row.isUnread ? "message" : "message.badge") {
                    onChange(row, .unread(!row.isUnread))
                }
                .accessibilityIdentifier("chats.action.unread.\(row.id)")
            }
            if row.canRename {
                Button("Rename", systemImage: "pencil") {
                    renameDraft = row.title
                    renaming = row
                }
                .accessibilityIdentifier("chats.action.rename.\(row.id)")
            }
            if row.canArchive {
                Button("Archive", systemImage: "archivebox") { onChange(row, .archive) }
                    .accessibilityIdentifier("chats.action.archive.\(row.id)")
            }
        }
    }

    private func sectionHeader(_ kind: ChatsInboxSection.Kind) -> some View {
        let title: LocalizedStringKey = switch kind {
        case .pinned: "Pinned"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .earlier: "Earlier"
        }
        return FleetSectionCaption(title: title)
            .accessibilityIdentifier("chats.section.\(kind.rawValue)")
    }

    // MARK: Empty and more

    @ViewBuilder
    private func emptyState(_ list: ListState) -> some View {
        Group {
            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: search)
            } else if list.filter == .unread {
                ContentUnavailableView("No unread chats", systemImage: "checkmark.message")
            } else if case .computer(let id) = list.filter, let fleet = context.fleet, !list.all.isEmpty {
                ContentUnavailableView("No chats on \(fleet.hostName(id))", systemImage: "desktopcomputer")
            } else {
                ContentUnavailableView {
                    Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start one with New chat.")
                } actions: {
                    if let onNewChat = context.onNewChat {
                        Button("New chat", action: onNewChat)
                            .bighelpProminentButtonStyle()
                            .buttonBorderShape(.capsule)
                            .tint(theme.action)
                            .accessibilityIdentifier("chats.empty.new-chat")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BighelpTokens.space32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chats.empty")
    }

    @ViewBuilder
    private var moreSection: some View {
        if context.onOpenArchived != nil || context.onOpenThisComputer != nil {
            Section {
                if let open = context.onOpenThisComputer {
                    moreRow("This computer", value: thisComputerName, systemImage: "desktopcomputer",
                            id: "chats.more.this-computer", action: open)
                }
                if let open = context.onOpenArchived {
                    moreRow("Archived", value: nil, systemImage: "archivebox", id: "chats.more.archived", action: open)
                }
            } header: {
                FleetSectionCaption(title: "More")
            }
        }
    }

    /// The computer in use's name, only where computers are named at all.
    private var thisComputerName: String? {
        guard let fleet = shownFleet, fleet.showsHostNames, let id = fleet.selectedHostID else { return nil }
        return fleet.hostName(id)
    }

    private func moreRow(_ title: LocalizedStringKey, value: String?, systemImage: String, id: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: BighelpTokens.space12) {
                Image(systemName: systemImage)
                    .foregroundStyle(theme.secondaryText)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.bighelp(.body)).foregroundStyle(theme.primaryText)
                    if let value {
                        Text(value).font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
                    }
                }
                Spacer(minLength: BighelpTokens.space8)
                Image(systemName: "chevron.right")
                    .font(.bighelp(.footnote, weight: .semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .accessibilityIdentifier(id)
    }
}

/// Keeps the merged rows until the catalog's revision or a computer's copy changes, and the
/// sections until the chip, the search or the day changes, so a redraw for each streamed piece
/// of an answer doesn't sort the list again. Not observed: writing it from `body` draws nothing.
@MainActor
final class ChatsInboxCache {
    struct Key: Equatable {
        /// Whose chats these are. Every computer has its own catalog, each counting its revisions
        /// from zero, and the list stays on screen through a switch: without this, two computers at
        /// the same revision showed the first one's chats.
        let catalog: ObjectIdentifier
        let revision: Int
        let rooms: [HermesBotModeRoomSummary]
        let codeSessionIDs: Set<String>
        let selectedHostID: UUID?
        let computers: [ChatsInboxComputer]
        let showsComputerTags: Bool
        /// The Draft marks that aren't the catalog's own: what open chats' message boxes hold, by
        /// chat. The revision doesn't move for these.
        var unsentDrafts: [String: Bool] = [:]
    }

    private struct SectionsKey: Equatable {
        let generation: Int
        let filter: ChatsInboxFilter
        let query: String
        let day: Date
    }

    private var key: Key?
    private var rows: [ChatsInboxRow] = []
    private var generation = 0
    private var sectionsKey: SectionsKey?
    private var sections: [ChatsInboxSection] = []

    func rows(for key: Key, build: () -> [ChatsInboxRow]) -> [ChatsInboxRow] {
        if key == self.key { return rows }
        rows = build()
        self.key = key
        generation &+= 1
        return rows
    }

    /// The last `rows(for:build:)` result, filtered and put under its headers.
    func sections(_ filter: ChatsInboxFilter, query: String, now: Date,
                  calendar: Calendar = .current) -> [ChatsInboxSection] {
        let key = SectionsKey(generation: generation, filter: filter, query: query, day: calendar.startOfDay(for: now))
        if key == sectionsKey { return sections }
        sections = ChatsInboxProjection.sections(ChatsInboxProjection.filter(rows, by: filter, matching: query),
                                                 now: now, calendar: calendar)
        sectionsKey = key
        return sections
    }
}

/// The faces for rows: bots on the computer in use from its live profiles, others from their
/// all-hosts copies. Made once for each drawing of the list, not once for each row.
@MainActor
struct ChatsInboxFaces {
    let agents: AgentDirectoryStore
    let fleet: FleetStore?
    private let profiles: [String: AgentProfile]

    init(agents: AgentDirectoryStore, fleet: FleetStore?) {
        self.agents = agents
        self.fleet = fleet
        profiles = Dictionary(agents.profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func face(for row: ChatsInboxRow, activity: BotChatActivityStore?) -> AnyView {
        let size = ChatsInboxRowLabel.faceSize
        let bots = members(of: row)
        if row.isGroup {
            return AnyView(SimpleBotsGroupFace(members: bots, size: size))
        }
        let bot = bots.first ?? SimpleBotsBot(id: row.id, profileID: row.memberIDs.first ?? row.id,
                                              hostID: row.hostID, name: row.title, role: "")
        // Only a Bot Chat's face moves with its bot's state; the store knows nothing of other chats.
        return AnyView(SimpleBotLiveFace(bot: bot, size: size, activity: row.activityKey == nil ? nil : activity)
            .accessibilityHidden(true))
    }

    private func members(of row: ChatsInboxRow) -> [SimpleBotsBot] {
        if row.isOnComputerInUse {
            return row.memberIDs.compactMap { id in
                profiles[id].map { SimpleBotsBot($0, imageURL: agents.avatarURL(for: $0)) }
            }
        }
        guard let fleet, let hostID = row.hostID else { return [] }
        return row.memberIDs.compactMap { id in
            fleet.agent(hostID: hostID, profileID: id).map {
                SimpleBotsBot($0, imageURL: fleet.avatars.url(for: $0.avatarFile))
            }
        }
    }
}

/// The chip row: All, then each computer (with two or more), then Unread. One row that scrolls
/// sideways. Drawn as `FleetHostFilter`'s chips are, which can't hold the Unread chip.
struct ChatsInboxChips: View {
    let computers: [FleetHost]
    let statuses: [UUID: FleetHostStatus]
    @Binding var selection: ChatsInboxFilter
    @BighelpThemeReader private var theme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BighelpTokens.space8) {
                chip(Text("All"), isOn: selection == .all, id: "chats.filter.all") { selection = .all }
                ForEach(computers) { host in
                    chip(Text(verbatim: host.name), isOn: selection == .computer(host.id),
                         isOffline: statuses[host.id].isUnreachable,
                         id: "chats.filter.computer.\(host.name)") { selection = .computer(host.id) }
                }
                chip(Text("Unread"), isOn: selection == .unread, id: "chats.filter.unread") { selection = .unread }
            }
            .padding(.horizontal, BighelpTokens.space16)
        }
        .accessibilityElement(children: .contain)
    }

    private func chip(_ title: Text, isOn: Bool, isOffline: Bool = false,
                      id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isOffline {
                    BighelpConnectionIndicator(phase: .disconnected, tint: isOn ? theme.actionForeground : nil)
                }
                title.lineLimit(1)
            }
            .font(.bighelp(.subheadline).weight(.semibold))
            .foregroundStyle(isOn ? theme.actionForeground : theme.primaryText)
            .padding(.horizontal, BighelpTokens.space12)
            .frame(minHeight: 34)
            .background(isOn ? theme.action : theme.surface, in: .capsule)
            .frame(minHeight: BighelpTokens.hitTarget)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// One quiet line over the list for a computer that doesn't answer; its last chats stay below.
struct ChatsInboxOfflineNote: View {
    let name: String
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(spacing: BighelpTokens.space8) {
            BighelpConnectionIndicator(phase: .disconnected)
            Text("\(name) isn't connected. Showing its last chats.")
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chats.note.\(name)")
    }
}

private extension Optional where Wrapped == FleetHostStatus {
    var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }
}
