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
    /// Multi-gateway: every other gateway's bots too; nil when it's off.
    var gateways: SimpleBotsGateways? = nil
}

/// Simple Bot mode's Multi-gateway: every gateway's bots in one home, the gateway in use's live and the
/// others' from the copies the all-hosts view keeps (those gateways stay connected meanwhile). Opening or
/// managing a bot on another gateway makes that gateway the one in use first.
@MainActor
struct SimpleBotsGateways {
    let selectedHostID: UUID?
    let bots: [SimpleBotsBot]
    let latest: [String: SimpleBotsLatest]
    /// Pinned bots on every gateway, by bot ID.
    let pinnedIDs: [String]
    /// The primary bot, kept on this device: it stays when another gateway comes into use.
    let primaryID: String?
    /// The gateways to filter by (Settings › Filter by Gateway); nil when that's off.
    let filter: [FleetHost]?
    let open: (FleetOpen, UUID) -> Void
    let setPinned: (SimpleBotsBot, Bool) -> Void
    let setPrimary: (SimpleBotsBot) -> Void
    let hide: (SimpleBotsBot) -> Void
    let refresh: () -> Void
}

/// A bot on the home: on the gateway in use (with its live profile) or, with Multi-gateway, on another
/// gateway (with the all-hosts copy of it).
struct SimpleBotsBot: Identifiable, Equatable {
    /// The profile ID with one gateway; the gateway and profile (`FleetID`) with Multi-gateway.
    let id: String
    let profileID: String
    /// Multi-gateway: the gateway it's on.
    var hostID: UUID? = nil
    let name: String
    let role: String
    var imageURL: URL? = nil
    var isDefault = false
    var isHidden = false
    /// On the gateway in use: its live profile.
    var profile: AgentProfile? = nil
    /// On another gateway: the all-hosts copy, which Pin and Hide go through.
    var fleetAgent: FleetAgent? = nil

    /// Its face's characters and marks on this device are kept per gateway (`CompanionSurfaceScope`).
    var faceScope: String? {
        guard fleetAgent != nil, let hostID else { return nil }
        return CompanionSurfaceScope.computer(hostID.uuidString)
    }

    init(id: String, profileID: String, hostID: UUID? = nil, name: String, role: String, imageURL: URL? = nil,
         isDefault: Bool = false, isHidden: Bool = false, profile: AgentProfile? = nil, fleetAgent: FleetAgent? = nil) {
        self.id = id; self.profileID = profileID; self.hostID = hostID; self.name = name; self.role = role
        self.imageURL = imageURL; self.isDefault = isDefault; self.isHidden = isHidden
        self.profile = profile; self.fleetAgent = fleetAgent
    }

    /// A bot on the gateway in use; `hostID` with Multi-gateway.
    init(_ profile: AgentProfile, hostID: UUID? = nil, imageURL: URL? = nil) {
        self.init(id: hostID.map { FleetID.make($0, profile.id) } ?? profile.id, profileID: profile.id, hostID: hostID,
                  name: profile.name, role: profile.role, imageURL: imageURL, isDefault: profile.isDefault,
                  isHidden: profile.placement?.isHidden == true, profile: profile)
    }

    /// A bot on another gateway, from the all-hosts copy.
    init(_ agent: FleetAgent, imageURL: URL?) {
        self.init(id: agent.id, profileID: agent.profileID, hostID: agent.hostID, name: agent.name, role: agent.role,
                  imageURL: imageURL, isDefault: agent.isDefault, isHidden: agent.isHidden, fleetAgent: agent)
    }
}

/// A bot's latest chat, for its row and its touch-and-hold preview.
struct SimpleBotsLatest: Equatable {
    var preview: String?
    var date: Date?
}

/// One row of the home list: a bot and its latest chat, or a group chat.
struct SimpleBotsItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case bot(SimpleBotsBot)
        case group(SessionSummary)
    }

    let kind: Kind
    let preview: String?
    let date: Date?
    let isPinned: Bool

    var id: String {
        switch kind {
        case .bot(let bot): "bot:" + bot.id
        case .group(let summary): "group:\(summary.id)"
        }
    }
}

/// Who's on the home screen, and in what order.
enum SimpleBotsHomeProjection {
    struct Home: Equatable {
        var primary: SimpleBotsBot?
        /// Pinned bots beside the primary one, in their pin order.
        var pinned: [SimpleBotsBot] = []
        var rows: [SimpleBotsItem]
        /// The primary and pinned bots in the order the person dragged them into.
        var top: [SimpleBotsBot] = []
        /// Each bot's latest chat, by bot ID.
        var latest: [String: SimpleBotsLatest] = [:]

        var primaryPreview: String? { primary.flatMap { latest[$0.id]?.preview } }
    }

    /// The bots on top, all the same size: the primary one and pinned ones, three to a row, two rows.
    static let topLimit = 6
    static let topPerRow = 3

    /// One gateway's home, from its live agents and chats.
    static func home(profiles: [AgentProfile], primaryID: String?, pinnedIDs: [String],
                     summaries: [SessionSummary], order: [String] = [], topOrder: [String] = [],
                     picture: (AgentProfile) -> URL? = { _ in nil }) -> Home {
        home(bots: profiles.map { SimpleBotsBot($0, imageURL: picture($0)) },
             primaryID: primary(profiles.map { SimpleBotsBot($0) }, primaryID: primaryID)?.id,
             pinnedIDs: pinnedIDs, latest: latestChats(summaries, bots: profiles.map { ($0.id, $0.id) }),
             groups: summaries.filter { $0.kind == .botMode }, order: order, topOrder: topOrder)
    }

    /// The primary bot leads the top, with up to five pinned bots after it in
    /// their order. The list under them: bots and group chats in the order
    /// the person dragged them, any not placed yet first; without an order, other
    /// pinned bots and group chats, then the rest by their latest chat (bots
    /// without one last, by name). Hidden bots stay off the home.
    static func home(bots: [SimpleBotsBot], primaryID: String?, pinnedIDs: [String],
                     latest: [String: SimpleBotsLatest], groups: [SessionSummary],
                     order: [String] = [], topOrder: [String] = []) -> Home {
        let shown = bots.filter { !$0.isHidden }
        let primary = shown.first { $0.id == primaryID }
        let pinned = Array(shownPins(shown, primaryID: primary?.id, pinnedIDs: pinnedIDs).prefix(topLimit - 1))
        let onTop = Set(pinned.map(\.id))
        var rows: [SimpleBotsItem] = []
        for bot in shown where bot.id != primary?.id && !onTop.contains(bot.id) {
            let chat = latest[bot.id]
            rows.append(SimpleBotsItem(kind: .bot(bot), preview: chat?.preview, date: chat?.date,
                                       isPinned: pinnedIDs.contains(bot.id)))
        }
        for summary in groups {
            rows.append(SimpleBotsItem(kind: .group(summary), preview: summary.preview, date: summary.updatedAt,
                                       isPinned: summary.isPinned))
        }
        let placed = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        rows.sort { left, right in
            switch (placed[left.id], placed[right.id]) {
            case let (l?, r?): return l < r
            case (nil, .some): return true
            case (.some, nil): return false
            case (nil, nil): break
            }
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
        // On top: the dragged order, then any bot not placed yet (the primary one first, then new pins).
        let rank = Dictionary(topOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let top = ((primary.map { [$0] } ?? []) + pinned).enumerated().sorted { left, right in
            switch (rank[left.element.id], rank[right.element.id]) {
            case let (l?, r?): l < r
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): left.offset < right.offset
            }
        }.map(\.element)
        return Home(primary: primary, pinned: pinned, rows: rows, top: top, latest: latest)
    }

    /// Each bot's latest direct chat; `bots` pairs each bot's ID with its profile ID.
    static func latestChats(_ summaries: [SessionSummary], bots: [(id: String, profileID: String)]) -> [String: SimpleBotsLatest] {
        var newest: [String: SessionSummary] = [:]
        for summary in summaries where summary.kind == .direct && summary.agentIDs.count == 1 {
            let agent = summary.agentIDs[0]
            if (newest[agent]?.updatedAt ?? .distantPast) < summary.updatedAt { newest[agent] = summary }
        }
        var latest: [String: SimpleBotsLatest] = [:]
        for bot in bots {
            guard let chat = newest[bot.profileID] else { continue }
            latest[bot.id] = SimpleBotsLatest(preview: chat.preview, date: chat.updatedAt)
        }
        return latest
    }

    /// The bots on top in rows of three.
    static func topRows(_ bots: [SimpleBotsBot]) -> [[SimpleBotsBot]] {
        stride(from: 0, to: bots.count, by: topPerRow).map { Array(bots[$0..<min($0 + topPerRow, bots.count)]) }
    }

    /// Whether `id` can join the pinned bots. Only pins the home shows count: the
    /// primary bot (pinned as the default agent), hidden bots and bots this
    /// computer no longer has share the Agents screen's list but take no room here.
    static func canPin(_ id: String, profiles: [AgentProfile], primaryID: String?, pinnedIDs: [String]) -> Bool {
        let bots = profiles.map { SimpleBotsBot($0) }
        return canPin(id, bots: bots, primaryID: primary(bots, primaryID: primaryID)?.id, pinnedIDs: pinnedIDs)
    }

    static func canPin(_ id: String, bots: [SimpleBotsBot], primaryID: String?, pinnedIDs: [String]) -> Bool {
        let shown = bots.filter { !$0.isHidden }
        guard id != primaryID, !pinnedIDs.contains(id), shown.contains(where: { $0.id == id }) else { return false }
        return shownPins(shown, primaryID: primaryID, pinnedIDs: pinnedIDs).count < topLimit - 1
    }

    /// `ids` with `moved` in `target`'s place, the rest shifting toward where it was. A drag
    /// over another row moves it there at once, so the list opens up under the finger.
    static func moving(_ moved: String, to target: String, in ids: [String]) -> [String] {
        guard moved != target, let from = ids.firstIndex(of: moved), let to = ids.firstIndex(of: target) else { return ids }
        var result = ids
        result.remove(at: from)
        result.insert(moved, at: to)
        return result
    }

    /// The picked bot, else the default one, else the first.
    static func primary(_ bots: [SimpleBotsBot], primaryID: String?) -> SimpleBotsBot? {
        let shown = bots.filter { !$0.isHidden }
        return shown.first { $0.id == primaryID } ?? shown.first(where: \.isDefault) ?? shown.first
    }

    private static func shownPins(_ shown: [SimpleBotsBot], primaryID: String?, pinnedIDs: [String]) -> [SimpleBotsBot] {
        var seen = Set<String>()
        return pinnedIDs.compactMap { id in
            guard id != primaryID, seen.insert(id).inserted else { return nil }
            return shown.first { $0.id == id }
        }
    }
}

/// The order the person dragged Simple Bot mode's list into, per computer.
@MainActor
@Observable
final class SimpleBotsOrderStore {
    static let shared = SimpleBotsOrderStore()
    private static let key = "bighelp.simple-bots.order"

    private(set) var orders: [String: [String]]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        orders = defaults.dictionary(forKey: Self.key) as? [String: [String]] ?? [:]
    }

    func order(scope: String) -> [String] { orders[scope] ?? [] }

    func set(_ order: [String], scope: String) {
        guard orders[scope] != order else { return }
        orders[scope] = Array(order.prefix(512))
        defaults.set(orders, forKey: Self.key)
    }
}

private extension SimpleBotsItem {
    func pinOrder(_ pinnedIDs: [String]) -> Int? {
        guard isPinned else { return nil }
        if case .bot(let bot) = kind { return pinnedIDs.firstIndex(of: bot.id) }
        return pinnedIDs.count
    }

    var sortName: String {
        switch kind {
        case .bot(let bot): bot.name
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
    /// Rearrange: the order being arranged, kept only when the person taps Save.
    @State private var arranging: SimpleBotsArrangement?
    /// While rearranging: the row or top bot under the finger ("top:" before a top bot's id), where it
    /// started, how far it has moved, and where each one sits.
    @State private var dragging: String?
    @State private var dragStart: CGRect = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var frames: [String: CGRect] = [:]
    private static let arrangeSpace = "simple-bots.arrange"
    private let unread = SimpleBotsUnreadStore.shared
    private let order = SimpleBotsOrderStore.shared
    /// Filter by Gateway: the gateway shown (its ID), or every one (empty).
    @AppStorage("bighelp.simple-bots.gateway-filter.shown") private var shownGateway = ""
    @BighelpThemeReader private var theme

    private var home: SimpleBotsHomeProjection.Home {
        let order = arranging?.list ?? self.order.order(scope: listScope)
        let topOrder = arranging?.top ?? self.order.order(scope: topScope)
        guard let gateways = context.gateways else {
            return SimpleBotsHomeProjection.home(
                profiles: context.agents.profiles, primaryID: context.agents.primaryAgentID,
                pinnedIDs: context.agents.pinnedAgentIDs,
                summaries: context.catalog.recentSummaries(includeCronSessions: false),
                order: order, topOrder: topOrder, picture: { context.agents.avatarURL(for: $0) })
        }
        let shown = filteredGateway
        let groups = shown == nil || shown == gateways.selectedHostID
            ? context.catalog.recentSummaries(includeCronSessions: false).filter { $0.kind == .botMode } : []
        return SimpleBotsHomeProjection.home(
            bots: gateways.bots.filter { shown == nil || $0.hostID == shown }, primaryID: gateways.primaryID,
            pinnedIDs: gateways.pinnedIDs, latest: gateways.latest, groups: groups, order: order, topOrder: topOrder)
    }

    /// The gateway Filter by Gateway shows, while that's on and it's still set up.
    private var filteredGateway: UUID? {
        guard let hosts = context.gateways?.filter, let id = UUID(uuidString: shownGateway),
              hosts.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// The order is one across gateways with Multi-gateway on, and per gateway without it.
    private var listScope: String { context.gateways == nil ? context.scope : "multi-gateway" }
    private var topScope: String { "top|" + listScope }

    // MARK: Acting on a bot (on another gateway with Multi-gateway)

    private func unreadKey(_ bot: SimpleBotsBot) -> (id: String, scope: String) {
        context.gateways == nil ? (bot.profileID, context.scope) : (bot.id, "multi-gateway")
    }

    private func isUnread(_ bot: SimpleBotsBot) -> Bool {
        let key = unreadKey(bot)
        return unread.isUnread(key.id, scope: key.scope)
    }

    private func setUnread(_ bot: SimpleBotsBot, _ value: Bool) {
        let key = unreadKey(bot)
        unread.set(value, id: key.id, scope: key.scope)
    }

    /// On its own gateway: `local` with one gateway, else the gateway comes into use (if it isn't) first.
    private func act(_ bot: SimpleBotsBot, _ open: FleetOpen, local: () -> Void) {
        if let gateways = context.gateways, let host = bot.hostID { gateways.open(open, host) } else { local() }
    }

    private func openBot(_ bot: SimpleBotsBot) {
        setUnread(bot, false)
        act(bot, .agent(profileID: bot.profileID)) { context.onOpenBot(bot.profileID) }
    }

    private func isPinned(_ bot: SimpleBotsBot) -> Bool {
        context.gateways?.pinnedIDs.contains(bot.id) ?? context.agents.isPinned(bot.profileID)
    }

    private func setPinned(_ bot: SimpleBotsBot, _ pinned: Bool, home: SimpleBotsHomeProjection.Home) {
        if let gateways = context.gateways { gateways.setPinned(bot, pinned); return }
        if pinned {
            _ = context.agents.pinAgent(bot.profileID, limit: SimpleBotsHomeProjection.topLimit - 1,
                                        counting: home.pinned.count)
        } else {
            _ = context.agents.unpinAgent(bot.profileID)
        }
    }

    var body: some View {
        let home = home
        Group {
            if arranging == nil {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !home.top.isEmpty {
                            topRow(home)
                        } else if home.rows.isEmpty {
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
                // Multi-gateway: the other gateways' bots are read again here (at most once a minute).
                .task(id: context.gateways != nil) { context.gateways?.refresh() }
                .refreshable { if let gateways = context.gateways { gateways.refresh() } }
            } else {
                arrangeList(home)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .background(theme.canvas.ignoresSafeArea())
        .bighelpSheet(item: $sheet) { sheet in sheetView(sheet) }
        .alert("Couldn't hide this bot", isPresented: Binding(get: { hideError != nil },
                                                             set: { if !$0 { hideError = nil } })) {
            Button("OK") { hideError = nil }
        } message: { Text(hideError ?? "") }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("simple-bots.home")
    }

    @ViewBuilder
    private var header: some View {
        if arranging != nil { arrangeHeader } else { homeHeader }
    }

    /// While rearranging: Cancel and Save, nothing else.
    private var arrangeHeader: some View {
        HStack {
            Button("Cancel") { withAnimation(.snappy) { arranging = nil } }
                .font(.bighelp(.body))
                .foregroundStyle(.primary)
                .frame(minHeight: BighelpTokens.hitTarget)
                .accessibilityIdentifier("simple-bots.rearrange.cancel")
            Spacer()
            Text("Rearrange")
                .font(.bighelp(.headline))
            Spacer()
            Button {
                saveArrangement()
            } label: {
                Text("Save")
                    .font(.bighelp(.body, weight: .semibold))
                    .foregroundStyle(theme.actionForeground)
                    .padding(.horizontal, BighelpTokens.space16)
                    .frame(minHeight: 36)
                    .background(theme.action, in: Capsule())
                    .frame(minHeight: BighelpTokens.hitTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("simple-bots.rearrange.save")
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.top, BighelpTokens.space4)
        .padding(.bottom, BighelpTokens.space8)
        .background { SimpleBotsHeaderFade() }
    }

    private var homeHeader: some View {
        HStack(spacing: BighelpTokens.space8) {
            SimpleBotsPersonButton(name: context.personName, imageURL: context.personImageURL,
                                   action: context.onOpenSettings)
            Spacer()
            if let gateways = context.gateways?.filter {
                gatewayFilterButton(gateways)
            }
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

    /// Filter by Gateway: every gateway's bots, or one gateway's.
    private func gatewayFilterButton(_ gateways: [FleetHost]) -> some View {
        let shown = filteredGateway
        return Menu {
            Button {
                shownGateway = ""
            } label: {
                if shown == nil { Label("All Gateways", systemImage: "checkmark") } else { Text("All Gateways") }
            }
            Divider()
            ForEach(gateways) { gateway in
                Button {
                    shownGateway = gateway.id.uuidString
                } label: {
                    if shown == gateway.id { Label(gateway.name, systemImage: "checkmark") } else { Text(gateway.name) }
                }
            }
        } label: {
            Image(systemName: shown == nil ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
                .font(.bighelp(.title3, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                .contentShape(.circle)
                .bighelpNavigationGlass(in: Circle(), isInteractive: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Filter by gateway")
        .accessibilityValue(shown.flatMap { id in gateways.first { $0.id == id }?.name } ?? "All Gateways")
        .accessibilityIdentifier("simple-bots.gateway-filter")
    }

    /// The primary bot and the pinned ones, all the same size and in the order the person dragged
    /// them into: one large, else two or three across, six at most in two rows.
    private func topRow(_ home: SimpleBotsHomeProjection.Home) -> some View {
        let bots = home.top
        let across = min(bots.count, SimpleBotsHomeProjection.topPerRow)
        let size: CGFloat = across == 1 ? 104 : across == 2 ? 92 : 76
        return VStack(spacing: BighelpTokens.space24) {
            ForEach(Array(SimpleBotsHomeProjection.topRows(bots).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: BighelpTokens.space12) {
                    ForEach(row) { bot in
                        let isPrimary = bot.id == home.primary?.id
                        Group {
                            if arranging == nil {
                                topTile(bot, isPrimary: isPrimary, size: size, home: home)
                            } else {
                                arrangeableTile(bot, isPrimary: isPrimary, size: size, top: bots)
                            }
                        }
                        // A short last row keeps the columns of the full one.
                        .frame(maxWidth: across == 3 ? 112 : .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                .zIndex(row.contains { "top:\($0.id)" == dragging } ? 1 : 0)
            }
        }
        .coordinateSpace(.named(Self.arrangeSpace))
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.top, BighelpTokens.space24)
        .padding(.bottom, BighelpTokens.space32)
    }

    private func topTile(_ bot: SimpleBotsBot, isPrimary: Bool, size: CGFloat,
                         home: SimpleBotsHomeProjection.Home) -> some View {
        Button {
            openBot(bot)
        } label: {
            VStack(spacing: BighelpTokens.space12) {
                SimpleBotFace(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL,
                              size: size, isPrimary: isPrimary, blinks: true)
                    .companionScope(bot.faceScope)
                HStack(spacing: BighelpTokens.space4) {
                    Text(bot.name)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                    if isUnread(bot) { unreadDot }
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            botMenu(bot, isPrimary: isPrimary, home: home)
        } preview: {
            SimpleBotsPreview(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL,
                              message: home.latest[bot.id]?.preview)
                .companionScope(bot.faceScope)
        }
        .accessibilityLabel(isPrimary ? "\(bot.name), your primary bot" : "\(bot.name), pinned")
        .accessibilityHint("Opens its chat")
        .accessibilityIdentifier(isPrimary ? "simple-bots.primary" : "simple-bots.pinned.\(bot.id)")
    }

    private func canPin(_ bot: SimpleBotsBot, home: SimpleBotsHomeProjection.Home) -> Bool {
        if let gateways = context.gateways {
            return SimpleBotsHomeProjection.canPin(bot.id, bots: gateways.bots, primaryID: home.primary?.id,
                                                   pinnedIDs: gateways.pinnedIDs)
        }
        return SimpleBotsHomeProjection.canPin(bot.profileID, profiles: context.agents.profiles,
                                               primaryID: context.agents.primaryAgentID,
                                               pinnedIDs: context.agents.pinnedAgentIDs)
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
        case .bot(let bot):
            Button {
                openBot(bot)
            } label: {
                SimpleBotsRowLabel(
                    face: AnyView(botFace(bot, size: 56)),
                    title: bot.name, role: bot.role, preview: item.preview, date: item.date,
                    isUnread: isUnread(bot), isPinned: item.isPinned)
            }
            .buttonStyle(.plain)
            .contextMenu {
                botMenu(bot, isPrimary: false, home: home)
            } preview: {
                SimpleBotsPreview(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL, message: item.preview)
                    .companionScope(bot.faceScope)
            }
            .accessibilityIdentifier("simple-bots.bot.\(bot.id)")
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
                rearrangeButton
            }
            .accessibilityIdentifier("simple-bots.group.\(summary.id)")
        }
    }

    private func botFace(_ bot: SimpleBotsBot, size: CGFloat) -> some View {
        SimpleBotFace(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL, size: size)
            .companionScope(bot.faceScope)
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

    /// A bot's menu. With Multi-gateway each action works on the bot's own gateway: pins and the
    /// primary bot are kept per bot whichever gateway it's on, and the rest bring its gateway into use.
    @ViewBuilder
    private func botMenu(_ bot: SimpleBotsBot, isPrimary: Bool, home: SimpleBotsHomeProjection.Home) -> some View {
        let unreadNow = isUnread(bot)
        Button(unreadNow ? "Mark Read" : "Mark Unread", systemImage: unreadNow ? "message" : "message.badge") {
            setUnread(bot, !unreadNow)
        }
        if isPinned(bot), !isPrimary {
            Button("Unpin", systemImage: "pin.slash") { setPinned(bot, false, home: home) }
        } else if !isPrimary, canPin(bot, home: home) {
            Button("Pin", systemImage: "pin") { setPinned(bot, true, home: home) }
        }
        if isPrimary {
            if context.gateways == nil {
                Button("Replace Primary Bot…", systemImage: "arrow.left.arrow.right") { sheet = .primary }
            }
        } else {
            Button("Make Primary Bot", systemImage: "star") {
                if let gateways = context.gateways { gateways.setPrimary(bot) }
                else { _ = context.agents.setPrimaryAgent(bot.profileID) }
            }
        }
        rearrangeButton
        Menu("More", systemImage: "ellipsis") {
            Button("Bot Profile", systemImage: "person.crop.circle") {
                act(bot, .botProfile(profileID: bot.profileID)) { context.onOpenProfile(bot.profileID) }
            }
            Button("New Chat", systemImage: "square.and.pencil") {
                act(bot, .newChat(profileID: bot.profileID)) { context.onNewChat(bot.profileID) }
            }
            Button("Routines", systemImage: "clock") {
                act(bot, .routines(profileID: bot.profileID)) { context.onRoutines(bot.profileID) }
            }
            if !isPrimary {
                Divider()
                Button("Hide", systemImage: "eye.slash", role: .destructive) {
                    if let gateways = context.gateways, bot.profile == nil { gateways.hide(bot) }
                    else if let profile = bot.profile { hide(profile) }
                }
            }
        }
    }

    /// Turns on dragging for every bot and group chat, until Save or Cancel.
    private var rearrangeButton: some View {
        Button("Rearrange", systemImage: "arrow.up.arrow.down") {
            let home = home
            withAnimation(.snappy) {
                arranging = SimpleBotsArrangement(list: home.rows.map(\.id), top: home.top.map(\.id))
            }
        }
    }

    private func saveArrangement() {
        guard let arranging else { return }
        order.set(arranging.list, scope: listScope)
        order.set(arranging.top, scope: topScope)
        withAnimation(.snappy) { self.arranging = nil }
    }

    /// Rearranging: the top bots drag among themselves; the list is a list in edit mode, with the
    /// system's reorder handles, so it scrolls and moves the way lists do everywhere.
    private func arrangeList(_ home: SimpleBotsHomeProjection.Home) -> some View {
        let ids = home.rows.map(\.id)
        return List {
            Group {
                if !home.top.isEmpty { topRow(home) }
                Text("Drag your bots and group chats into the order you want, then tap Save.")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, BighelpTokens.space32)
                    .padding(.bottom, BighelpTokens.space16)
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            ForEach(home.rows) { item in
                arrangeableRow(item, ids: ids)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(theme.canvas)
            }
            .onMove { from, to in
                var moved = ids
                moved.move(fromOffsets: from, toOffset: to)
                withAnimation(.snappy) { arranging?.list = moved }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        // A top bot being dragged keeps the list still.
        .scrollDisabled(dragging != nil)
    }

    /// A list row while rearranging: no menu and no chat; the list adds its reorder handle.
    private func arrangeableRow(_ item: SimpleBotsItem, ids: [String]) -> some View {
        let label: SimpleBotsRowLabel
        let identifier: String
        switch item.kind {
        case .bot(let bot):
            label = SimpleBotsRowLabel(face: AnyView(botFace(bot, size: 56)), title: bot.name, role: bot.role,
                                       preview: item.preview, date: nil, isUnread: false, isPinned: item.isPinned)
            identifier = "simple-bots.bot.\(bot.id)"
        case .group(let summary):
            label = SimpleBotsRowLabel(face: AnyView(groupFaces(summary)), title: summary.title,
                                       preview: item.preview, date: nil, isUnread: false, isPinned: item.isPinned)
            identifier = "simple-bots.group.\(summary.id)"
        }
        return label
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
            .accessibilityAction(named: "Move up") { step(item.id, by: -1, in: ids, top: false) }
            .accessibilityAction(named: "Move down") { step(item.id, by: 1, in: ids, top: false) }
    }

    /// A bot on top while rearranging: still, with no menu or chat, and it drags among the top bots.
    private func arrangeableTile(_ bot: SimpleBotsBot, isPrimary: Bool, size: CGFloat, top: [SimpleBotsBot]) -> some View {
        let ids = top.map(\.id), key = "top:\(bot.id)"
        return VStack(spacing: BighelpTokens.space12) {
            SimpleBotFace(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL,
                          size: size, isPrimary: isPrimary, blinks: false)
                .companionScope(bot.faceScope)
            Text(bot.name)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .gesture(arrangeDrag(key, peers: ids.map { "top:\($0)" }) { target in
            arranging?.top = SimpleBotsHomeProjection.moving(bot.id, to: String(target.dropFirst(4)), in: ids)
        })
        .arrangeLift(key, dragging: dragging, offset: dragOffset(key), space: Self.arrangeSpace) { frames[key] = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(isPrimary ? "simple-bots.primary" : "simple-bots.pinned.\(bot.id)")
        .accessibilityHint("Drag to change its place")
        .accessibilityAction(named: "Move left") { step(bot.id, by: -1, in: ids, top: true) }
        .accessibilityAction(named: "Move right") { step(bot.id, by: 1, in: ids, top: true) }
    }

    /// Follows the finger; passing over another of `peers` moves the dragged one into its place.
    private func arrangeDrag(_ key: String, peers: [String], move: @escaping (String) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.arrangeSpace))
            .onChanged { value in
                if dragging != key {
                    dragging = key
                    dragStart = frames[key] ?? .zero
                }
                dragTranslation = value.translation
                let center = CGPoint(x: dragStart.midX + value.translation.width,
                                     y: dragStart.midY + value.translation.height)
                if let target = peers.first(where: { $0 != key && frames[$0]?.contains(center) == true }) {
                    withAnimation(.snappy) { move(target) }
                }
            }
            .onEnded { _ in
                withAnimation(.snappy) {
                    dragging = nil
                    dragTranslation = .zero
                }
            }
    }

    /// Keeps the dragged one under the finger while the others move around it.
    private func dragOffset(_ key: String) -> CGSize {
        guard dragging == key, let current = frames[key] else { return .zero }
        return CGSize(width: dragStart.minX + dragTranslation.width - current.minX,
                      height: dragStart.minY + dragTranslation.height - current.minY)
    }

    /// VoiceOver's Move actions: one place at a time.
    private func step(_ id: String, by offset: Int, in ids: [String], top: Bool) {
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        let moved = SimpleBotsHomeProjection.moving(id, to: ids[index + offset], in: ids)
        withAnimation(.snappy) {
            if top { arranging?.top = moved } else { arranging?.list = moved }
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

/// A home row: the face, the name and what the bot does over the latest message, and its time.
private struct SimpleBotsRowLabel: View {
    let face: AnyView
    let title: String
    var role: String?
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
                        .layoutPriority(1)
                    if let role = role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
                        // The name always shows in full; the role gives way first.
                        Text(role)
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(1)
                            .padding(.horizontal, BighelpTokens.space8)
                            .padding(.vertical, 3)
                            .background(theme.secondaryText.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .accessibilityLabel(role)
                    }
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

/// The order the person is arranging: the list's rows and the top's bots.
struct SimpleBotsArrangement: Equatable {
    var list: [String]
    var top: [String]
}

private extension View {
    /// The lift while it's dragged, and where an arrangeable row or bot sits. Measured outside the
    /// offset and scale, so following the finger never moves where it's said to sit.
    func arrangeLift(_ key: String, dragging: String?, offset shift: CGSize, space: String,
                     frame: @escaping (CGRect) -> Void) -> some View {
        offset(shift)
            .scaleEffect(dragging == key ? 1.04 : 1)
            .shadow(color: .black.opacity(dragging == key ? 0.25 : 0), radius: 12, y: 6)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frame($0) }
            .zIndex(dragging == key ? 1 : 0)
    }
}

private extension View {
    /// A bot on another gateway draws its characters and marks from that gateway's.
    @ViewBuilder
    func companionScope(_ scope: String?) -> some View {
        if let scope { environment(\.companionAgentScope, scope) } else { self }
    }
}
