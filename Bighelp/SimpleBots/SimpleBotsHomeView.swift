import Observation
import SwiftUI

/// What Bots mode's home needs from the shell.
@MainActor
struct SimpleBotsContext {
    let agents: AgentDirectoryStore
    let catalog: SessionCatalogStore
    let personName: String
    let personImageURL: URL?
    /// This computer, for things kept per computer (Mark Unread).
    let scope: String
    let canCreateBots: Bool
    let onOpenBot: (String) -> Void
    let onOpenSession: (SessionSummary) -> Void
    let onOpenSettings: () -> Void
    let onOpenProfile: (String) -> Void
    let onNewChat: (String) -> Void
    /// A model for a new bot, set up the way the shell creates agents; nil when this computer can't.
    let makeCreator: () -> AgentEditorModel?
    /// Multi-gateway: every other gateway's bots too; nil when it's off.
    var gateways: SimpleBotsGateways? = nil
    /// Which bots are working or need you, kept current while the home shows.
    var activity: BotChatActivityStore? = nil
    var activitySource: BotChatActivitySource? = nil
    /// The Unified Mode Toggle (Settings › Modes); nil while it's off.
    var modeSwitch: BighelpModeSwitch? = nil
    /// The sections, and group chats' pins and hides (`FleetStore`); nil leaves sections out.
    var fleet: FleetStore? = nil
    /// New Group Chat on the gateway in use; nil when it can't make group chats.
    var onNewGroupChat: (() -> Void)? = nil
    /// A group chat's settings on the gateway in use, by its room.
    var onGroupSettings: ((String) -> Void)? = nil
    /// Deletes a group chat on the gateway in use, by its room; nil when it can't.
    var onDeleteGroup: ((String) -> Void)? = nil
    /// A section's page, by the section's ID.
    var onOpenSection: ((String) -> Void)? = nil
    /// Hermes' group chats on the gateway in use, with or without messages, and how one opens by its room.
    var rooms: [HermesBotModeRoomSummary] = []
    var onOpenGroup: ((String) -> Void)? = nil
}

/// Bots mode's Multi-gateway: every gateway's bots in one home, the gateway in use's live and the
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
    /// Every gateway's group chats: the gateway in use's live, the others' from their copies.
    var groups: [SimpleBotsGroup] = []
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
    /// Its section (and whether it's hidden), as saved on its profile.
    var placement: AgentListPlacement? = nil
    /// On the gateway in use: its live profile.
    var profile: AgentProfile? = nil
    /// On another gateway: the all-hosts copy, which Pin and Hide go through.
    var fleetAgent: FleetAgent? = nil

    /// On the gateway in use, though shown from its all-hosts copy until its agents are known.
    var isOnGatewayInUse = false

    /// Where its Bot Chat's state is kept: by profile on the gateway in use, by `FleetID` on another.
    var activityKey: String {
        fleetAgent == nil || isOnGatewayInUse ? BotChatActivityStore.liveKey(profileID) : id
    }

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
        placement = profile?.placement ?? fleetAgent?.placement
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
        case group(SimpleBotsGroup)
    }

    let kind: Kind
    let preview: String?
    let date: Date?
    let isPinned: Bool

    var id: String {
        switch kind {
        case .bot(let bot): "bot:" + bot.id
        case .group(let group): group.itemID
        }
    }

    var name: String {
        switch kind {
        case .bot(let bot): bot.name
        case .group(let group): group.title
        }
    }

    /// The gateway it's on, when known.
    var hostID: UUID? {
        switch kind {
        case .bot(let bot): bot.hostID
        case .group(let group): group.hostID
        }
    }
}

/// Who's on the home screen, and in what order.
enum SimpleBotsHomeProjection {
    struct Home: Equatable {
        var primary: SimpleBotsBot?
        /// Pinned bots beside the primary one, in their pin order.
        var pinned: [SimpleBotsBot] = []
        /// Pinned group chats on top, after the pinned bots.
        var pinnedGroups: [SimpleBotsGroup] = []
        /// Bots and group chats in no section that aren't on top.
        var rows: [SimpleBotsItem]
        /// The primary bot, pinned bots and pinned group chats in the order the person dragged them into.
        var top: [SimpleBotsTopItem] = []
        /// Each bot's latest chat, by bot ID.
        var latest: [String: SimpleBotsLatest] = [:]
        /// Each section with its members on top or in the list, in the person's order. A section with
        /// members only elsewhere stays off; with no sections, none.
        var sections: [SimpleBotsSectionCard] = []

        var primaryPreview: String? { primary.flatMap { latest[$0.id]?.preview } }
        /// Pins on top beside the primary bot: bots and group chats.
        var pinCount: Int { pinned.count + pinnedGroups.count }
    }

    /// The bots on top, all the same size: the primary one and pinned ones, three to a row, two rows.
    static let topLimit = 6
    static let topPerRow = 3

    /// One gateway's home, from its live agents and chats. `groupHost` is the gateway's ID, which
    /// group chats' sections, pins and hides go by.
    static func home(profiles: [AgentProfile], primaryID: String?, pinnedIDs: [String],
                     summaries: [SessionSummary], order: [String] = [], topOrder: [String] = [],
                     picture: (AgentProfile) -> URL? = { _ in nil }, groupHost: UUID? = nil,
                     rooms: [HermesBotModeRoomSummary] = [], sectioning: SimpleBotsSectioning = .init()) -> Home {
        let bots = profiles.map { SimpleBotsBot($0, imageURL: picture($0)) }
        return home(bots: bots,
                    primaryID: primary(profiles.map { SimpleBotsBot($0) }, primaryID: primaryID)?.id,
                    pinnedIDs: pinnedIDs, latest: latestChats(summaries, bots: profiles.map { ($0.id, $0.id) }),
                    groups: groups(summaries, rooms: rooms, hostID: groupHost, bots: bots), order: order,
                    topOrder: topOrder, sectioning: sectioning)
    }

    /// The gateway in use's group chats, with their members' faces: the catalog's (with their latest
    /// message), then Hermes' rooms with no messages yet, so a group chat just made shows at once.
    /// `listsByKey`: Multi-gateway, where each row is named by its gateway too.
    static func groups(_ summaries: [SessionSummary], rooms: [HermesBotModeRoomSummary] = [], hostID: UUID?,
                       bots: [SimpleBotsBot], listsByKey: Bool = false) -> [SimpleBotsGroup] {
        let listed = summaries.compactMap { summary in
            let members = summary.agentIDs.compactMap { id in bots.first { $0.profileID == id } }
            return SimpleBotsGroup(summary, hostID: hostID, members: members, listsByKey: listsByKey)
        }
        let known = Set(listed.map(\.roomID))
        let quiet = rooms.filter { $0.canOpen && !known.contains($0.roomID) }.map { room in
            SimpleBotsGroup(room: room, hostID: hostID,
                            members: room.members.compactMap { member in bots.first { $0.profileID == member.profile } },
                            listsByKey: listsByKey)
        }
        return listed + quiet
    }

    /// The primary bot leads the top, with up to five pinned bots and group chats after it in
    /// their order. The list under them: bots and group chats in no section, in the order
    /// the person dragged them, any not placed yet first; without an order, other
    /// pinned bots and group chats, then the rest by their latest chat (bots
    /// without one last, by name). Hidden bots and group chats stay off the home. Each section
    /// holds its members, on top or not.
    static func home(bots: [SimpleBotsBot], primaryID: String?, pinnedIDs: [String],
                     latest: [String: SimpleBotsLatest], groups: [SimpleBotsGroup],
                     order: [String] = [], topOrder: [String] = [],
                     sectioning: SimpleBotsSectioning = .init()) -> Home {
        let shown = bots.filter { !$0.isHidden }
        let shownGroups = groups.filter { !sectioning.isHidden($0) }
        let primary = shown.first { $0.id == primaryID }
        let pinned = Array(shownPins(shown, primaryID: primary?.id, pinnedIDs: pinnedIDs).prefix(topLimit - 1))
        let pinnedGroups = Array(sectioning.pinnedGroups.compactMap { key in shownGroups.first { $0.key == key } }
            .prefix(topLimit - 1 - pinned.count))
        var items: [SimpleBotsItem] = []
        for bot in shown {
            let chat = latest[bot.id]
            items.append(SimpleBotsItem(kind: .bot(bot), preview: chat?.preview, date: chat?.date,
                                        isPinned: pinnedIDs.contains(bot.id)))
        }
        for group in shownGroups {
            items.append(SimpleBotsItem(kind: .group(group), preview: group.preview, date: group.updatedAt,
                                        isPinned: sectioning.isPinned(group)))
        }
        items = sorted(items, order: order, pinnedIDs: pinnedIDs)
        let onTop = Set([primary?.id].compactMap { $0 }.map { "bot:" + $0 } + pinned.map { "bot:" + $0.id }
            + pinnedGroups.map(\.itemID))
        let rows = items.filter { !onTop.contains($0.id) && sectioning.section(of: $0.kind) == nil }
        let sections = sectioning.sections.compactMap { section -> SimpleBotsSectionCard? in
            let members = items.filter { sectioning.section(of: $0.kind)?.id == section.id }
            guard !members.isEmpty || !sectioning.elsewhere.contains(section.id) else { return nil }
            return SimpleBotsSectionCard(section: section, members: members)
        }
        // On top: the dragged order, then any not placed yet (the primary bot first, then new pins).
        let rank = Dictionary(topOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let unplaced = (primary.map { [$0] } ?? []).map(SimpleBotsTopItem.bot) + pinned.map(SimpleBotsTopItem.bot)
            + pinnedGroups.map(SimpleBotsTopItem.group)
        let top = unplaced.enumerated().sorted { left, right in
            switch (rank[left.element.id], rank[right.element.id]) {
            case let (l?, r?): l < r
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): left.offset < right.offset
            }
        }.map(\.element)
        return Home(primary: primary, pinned: pinned, pinnedGroups: pinnedGroups, rows: rows, top: top, latest: latest,
                    sections: sections)
    }

    /// In the order the person dragged them, any not placed yet first; without an order, pinned
    /// ones, then by their latest chat (none last, by name).
    static func sorted(_ items: [SimpleBotsItem], order: [String], pinnedIDs: [String]) -> [SimpleBotsItem] {
        var rows = items
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
                default: return left.name.localizedStandardCompare(right.name) == .orderedAscending
                }
            }
        }
        return rows
    }

    /// `ids` in this order where they were in `order`, the rest of it kept: a section's page rearranges
    /// its members within the home's one order. Ones `order` doesn't have yet lead.
    static func placing(_ ids: [String], in order: [String]) -> [String] {
        let moved = Set(ids)
        var queue = ids.filter { order.contains($0) }[...]
        let new = ids.filter { !order.contains($0) }
        return new + order.map { moved.contains($0) ? queue.popFirst() ?? $0 : $0 }
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
    static func topRows<Item>(_ items: [Item]) -> [[Item]] {
        stride(from: 0, to: items.count, by: topPerRow).map { Array(items[$0..<min($0 + topPerRow, items.count)]) }
    }

    /// Whether `id` can join the pinned bots. Only pins the home shows count: the
    /// primary bot (pinned as the default agent), hidden bots and bots this
    /// computer no longer has share the Agents screen's list but take no room here.
    static func canPin(_ id: String, profiles: [AgentProfile], primaryID: String?, pinnedIDs: [String],
                       pinnedGroups: Int = 0) -> Bool {
        let bots = profiles.map { SimpleBotsBot($0) }
        return canPin(id, bots: bots, primaryID: primary(bots, primaryID: primaryID)?.id, pinnedIDs: pinnedIDs,
                      pinnedGroups: pinnedGroups)
    }

    /// `pinnedGroups`: group chats pinned on top, which share the room.
    static func canPin(_ id: String, bots: [SimpleBotsBot], primaryID: String?, pinnedIDs: [String],
                       pinnedGroups: Int = 0) -> Bool {
        let shown = bots.filter { !$0.isHidden }
        guard id != primaryID, !pinnedIDs.contains(id), shown.contains(where: { $0.id == id }) else { return false }
        return shownPins(shown, primaryID: primaryID, pinnedIDs: pinnedIDs).count + pinnedGroups < topLimit - 1
    }

    /// Whether a group chat can join the top: room left beside the primary bot.
    static func canPin(_ group: SimpleBotsGroup, home: Home) -> Bool {
        group.key != nil && !home.pinnedGroups.contains { $0.id == group.id } && home.pinCount < topLimit - 1
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

/// The order the person dragged Bots mode's list into, per computer.
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
    case search, create

    var id: String {
        switch self {
        case .search: "search"
        case .create: "create"
        }
    }
}

/// Bots mode's home: your circle top left, search and + top right, the
/// primary bot large in the middle, then the sections and every other bot and
/// group chat with its latest message. With `sectionID`, a section's page: its
/// members, as the home lists them.
@MainActor
struct SimpleBotsHomeView: View {
    let context: SimpleBotsContext
    var sectionID: String? = nil

    @State private var sheet: SimpleBotsSheet?
    @State private var hideError: String?
    /// Rearrange: the order being arranged, kept only when the person taps Save.
    @State var arranging: SimpleBotsArrangement?
    @State var sectionPrompt: SimpleBotsSectionPrompt?
    /// Delete Group Chat asks first.
    @State var deletingGroup: SimpleBotsGroup?
    /// While rearranging: the row or top bot under the finger ("top:" before a top bot's id), where it
    /// started, how far it has moved, and where each one sits.
    @State private var dragging: String?
    @State private var dragStart: CGRect = .zero
    @State private var dragTranslation: CGSize = .zero
    @State private var frames: [String: CGRect] = [:]
    private static let arrangeSpace = "simple-bots.arrange"
    let unread = SimpleBotsUnreadStore.shared
    let order = SimpleBotsOrderStore.shared
    /// Filter by Gateway: the gateway shown (its ID), or every one (empty).
    @AppStorage("bighelp.simple-bots.gateway-filter.shown") private var shownGateway = ""
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) var dismiss
    @BighelpThemeReader var theme

    var home: SimpleBotsHomeProjection.Home {
        let order = arranging?.list ?? self.order.order(scope: listScope)
        let topOrder = arranging?.top ?? self.order.order(scope: topScope)
        // A section's page rearranges its members: the home's order around them stays.
        let listOrder = sectionID == nil ? order : SimpleBotsHomeProjection.placing(order, in: self.order.order(scope: listScope))
        guard let gateways = context.gateways else {
            return SimpleBotsHomeProjection.home(
                profiles: context.agents.profiles, primaryID: context.agents.primaryAgentID,
                pinnedIDs: context.agents.pinnedAgentIDs,
                summaries: context.catalog.recentSummaries(includeCronSessions: false),
                order: listOrder, topOrder: topOrder, picture: { context.agents.avatarURL(for: $0) },
                groupHost: groupHost, rooms: context.rooms, sectioning: sectioning)
        }
        let shown = filteredGateway
        return SimpleBotsHomeProjection.home(
            bots: gateways.bots.filter { shown == nil || $0.hostID == shown }, primaryID: gateways.primaryID,
            pinnedIDs: gateways.pinnedIDs, latest: gateways.latest,
            groups: gateways.groups.filter { shown == nil || $0.hostID == shown }, order: listOrder, topOrder: topOrder,
            sectioning: sectioning)
    }

    /// The gateway in use, which its group chats' sections, pins and hides go by.
    var groupHost: UUID? { context.fleet?.selectedHostID }

    /// With one gateway, or one picked in Filter by Gateway, a section whose members are all on
    /// other gateways stays off the home.
    var sectioning: SimpleBotsSectioning {
        let shown: Set<UUID>? = context.gateways == nil ? Set([groupHost].compactMap { $0 }) : filteredGateway.map { [$0] }
        return SimpleBotsSectioning(fleet: context.fleet, shown: shown)
    }

    /// The gateway Filter by Gateway shows, while that's on and it's still set up.
    var filteredGateway: UUID? {
        guard let hosts = context.gateways?.filter, let id = UUID(uuidString: shownGateway),
              hosts.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    /// The order is one across gateways with Multi-gateway on, and per gateway without it.
    var listScope: String { context.gateways == nil ? context.scope : "multi-gateway" }
    var topScope: String { "top|" + listScope }

    // MARK: Acting on a bot (on another gateway with Multi-gateway)

    private func unreadKey(_ bot: SimpleBotsBot) -> (id: String, scope: String) {
        context.gateways == nil ? (bot.profileID, context.scope) : (bot.id, "multi-gateway")
    }

    /// Its Bot Chat, when Hermes keeps that chat's read state (`SimpleBotsReadState`); on the gateway in use only.
    private func hermesBotChat(_ bot: SimpleBotsBot) -> SessionRecord? {
        guard bot.fleetAgent == nil || bot.isOnGatewayInUse else { return nil }
        return SimpleBotsReadState.botChat(bot.profileID, in: context.catalog.records)
    }

    func isUnread(_ bot: SimpleBotsBot) -> Bool {
        if let chat = hermesBotChat(bot) { return chat.isUnread == true }
        let key = unreadKey(bot)
        return unread.isUnread(key.id, scope: key.scope)
    }

    private func setUnread(_ bot: SimpleBotsBot, _ value: Bool) {
        if let chat = hermesBotChat(bot) {
            markOnHermes(chat.id, value)
            return
        }
        let key = unreadKey(bot)
        unread.set(value, id: key.id, scope: key.scope)
    }

    func markOnHermes(_ id: String, _ value: Bool) {
        Task { @MainActor in try? await context.catalog.setSessionUnread(id: id, unread: value) }
    }

    /// On its own gateway: `local` with one gateway, else the gateway comes into use (if it isn't) first.
    func act(_ bot: SimpleBotsBot, _ open: FleetOpen, local: () -> Void) {
        if let gateways = context.gateways, let host = bot.hostID { gateways.open(open, host) } else { local() }
    }

    func openBot(_ bot: SimpleBotsBot) {
        // This device's mark; Hermes' clears once the chat shows (`BighelpVisibleChats`).
        let key = unreadKey(bot)
        unread.set(false, id: key.id, scope: key.scope)
        act(bot, .agent(profileID: bot.profileID)) { context.onOpenBot(bot.profileID) }
    }

    private func isPinned(_ bot: SimpleBotsBot) -> Bool {
        context.gateways?.pinnedIDs.contains(bot.id) ?? context.agents.isPinned(bot.profileID)
    }

    private func setPinned(_ bot: SimpleBotsBot, _ pinned: Bool, home: SimpleBotsHomeProjection.Home) {
        if let gateways = context.gateways { gateways.setPinned(bot, pinned); return }
        if pinned {
            _ = context.agents.pinAgent(bot.profileID, limit: SimpleBotsHomeProjection.topLimit - 1,
                                        counting: home.pinCount)
        } else {
            _ = context.agents.unpinAgent(bot.profileID)
        }
    }

    var body: some View {
        let home = home
        Group {
            if let sectionID {
                sectionPage(home, sectionID: sectionID)
            } else if arranging == nil {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !home.top.isEmpty {
                            topRow(home)
                        } else if home.rows.isEmpty && home.sections.isEmpty {
                            emptyHome
                        }
                        if !home.sections.isEmpty {
                            sectionGrid(home)
                        }
                        ForEach(home.rows) { item in
                            row(item, home: home)
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
                arrangeList(home, rows: home.rows, showsTop: true)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header(home) }
        .background(theme.canvas.ignoresSafeArea())
        .botChatActivityUpdates(context.activity, source: context.activitySource, isActive: scenePhase == .active)
        .bighelpSheet(item: $sheet) { sheet in sheetView(sheet) }
        .alert("Couldn't hide this bot", isPresented: Binding(get: { hideError != nil },
                                                             set: { if !$0 { hideError = nil } })) {
            Button("OK") { hideError = nil }
        } message: { Text(hideError ?? "") }
        .modifier(SimpleBotsSectionPrompts(prompt: $sectionPrompt, model: sectionsModel))
        .modifier(SimpleBotsGroupDeletion(group: $deletingGroup, delete: context.onDeleteGroup))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(sectionID == nil ? "simple-bots.home" : "simple-bots.section.page")
    }

    @ViewBuilder
    private func header(_ home: SimpleBotsHomeProjection.Home) -> some View {
        if arranging != nil { arrangeHeader } else if let sectionID { sectionHeader(sectionID, home: home) } else { homeHeader }
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

    @ViewBuilder
    private var homeHeader: some View {
        if let modeSwitch = context.modeSwitch {
            modeHeader(modeSwitch)
        } else {
            classicHeader
        }
    }

    /// With the Unified Mode Toggle: you, the mode pill and New on one row; Search (and Filter by
    /// Gateway, to its right) on the row under it, so the pill keeps the middle to itself.
    private func modeHeader(_ modeSwitch: BighelpModeSwitch) -> some View {
        VStack(spacing: BighelpTokens.space12) {
            ZStack {
                HStack {
                    SimpleBotsPersonButton(name: context.personName, imageURL: context.personImageURL,
                                           action: context.onOpenSettings)
                    Spacer()
                    newButton
                }
                BighelpModePill(modeSwitch: modeSwitch)
            }
            HStack(spacing: BighelpTokens.space8) {
                Button { sheet = .search } label: {
                    HStack(spacing: BighelpTokens.space8) {
                        Image(systemName: "magnifyingglass")
                        Text("Search bots")
                        Spacer(minLength: 0)
                    }
                    .font(.bighelp(.body))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, BighelpTokens.space12)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(.rect)
                }
                .bighelpPlainButtonStyle(.rounded(12))
                .accessibilityLabel("Search bots")
                .accessibilityIdentifier("simple-bots.search")
                if let gateways = context.gateways?.filter {
                    gatewayFilterButton(gateways)
                }
            }
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.top, BighelpTokens.space4)
        .padding(.bottom, BighelpTokens.space8)
        .background { SimpleBotsHeaderFade() }
    }

    private var classicHeader: some View {
        HStack(spacing: BighelpTokens.space8) {
            SimpleBotsPersonButton(name: context.personName, imageURL: context.personImageURL,
                                   action: context.onOpenSettings)
            Spacer()
            if let gateways = context.gateways?.filter {
                gatewayFilterButton(gateways)
            }
            SimpleBotsCircleButton(systemImage: "magnifyingglass", label: "Search bots",
                                   identifier: "simple-bots.search") { sheet = .search }
            newButton
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.top, BighelpTokens.space4)
        .padding(.bottom, BighelpTokens.space8)
        .background { SimpleBotsHeaderFade() }
    }

    /// New Bot, New Group Chat and New Section; each only where it can work.
    @ViewBuilder
    private var newButton: some View {
        let items = SimpleBotsNewItem.available(canCreateBots: context.canCreateBots,
                                                canCreateGroups: context.onNewGroupChat != nil,
                                                hasSections: context.fleet != nil)
        if !items.isEmpty {
            Menu {
                ForEach(items) { item in
                    Button(item.title, systemImage: item.systemImage) { startNew(item) }
                        .accessibilityIdentifier("simple-bots.new.\(item.rawValue)")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.bighelp(.title3, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: BighelpTokens.hitTarget, height: BighelpTokens.hitTarget)
                    .contentShape(.circle)
                    .bighelpNavigationGlass(in: Circle(), isInteractive: true)
            }
            .menuOrder(.fixed)
            .buttonStyle(.plain)
            .accessibilityLabel("Add")
            .accessibilityIdentifier("simple-bots.new")
        }
    }

    private func startNew(_ item: SimpleBotsNewItem) {
        switch item {
        case .bot: sheet = .create
        case .groupChat: context.onNewGroupChat?()
        case .section: sectionPrompt = .new(picked: [])
        }
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
        .accessibilityValue(shown.flatMap { id in gateways.first { $0.id == id }?.name }
                            ?? String(localized: "All Gateways"))
        .accessibilityIdentifier("simple-bots.gateway-filter")
    }

    /// The primary bot and the pinned ones, all the same size and in the order the person dragged
    /// them into: one large, else two or three across, six at most in two rows.
    private func topRow(_ home: SimpleBotsHomeProjection.Home) -> some View {
        let items = home.top
        let across = min(items.count, SimpleBotsHomeProjection.topPerRow)
        let size: CGFloat = across == 1 ? 104 : across == 2 ? 92 : 76
        return VStack(spacing: BighelpTokens.space24) {
            ForEach(Array(SimpleBotsHomeProjection.topRows(items).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: BighelpTokens.space12) {
                    ForEach(row) { item in
                        Group {
                            switch (item, arranging == nil) {
                            case (.bot(let bot), true):
                                topTile(bot, isPrimary: bot.id == home.primary?.id, size: size, home: home)
                            case (.group(let group), true):
                                topGroupTile(group, size: size, home: home)
                            case (_, false):
                                arrangeableTile(item, isPrimary: item.id == home.primary?.id, size: size, top: items)
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
                SimpleBotLiveFace(bot: bot, size: size, blinks: true, activity: context.activity)
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
        .menuOrder(.fixed)
        .accessibilityLabel(isPrimary ? "\(bot.name), your primary bot" : "\(bot.name), pinned")
        .modifier(SimpleBotActivityValue(key: bot.activityKey, activity: context.activity))
        .accessibilityHint("Opens its chat")
        .accessibilityIdentifier(isPrimary ? "simple-bots.primary" : "simple-bots.pinned.\(bot.id)")
    }

    private func canPin(_ bot: SimpleBotsBot, home: SimpleBotsHomeProjection.Home) -> Bool {
        if let gateways = context.gateways {
            return SimpleBotsHomeProjection.canPin(bot.id, bots: gateways.bots, primaryID: home.primary?.id,
                                                   pinnedIDs: gateways.pinnedIDs, pinnedGroups: home.pinnedGroups.count)
        }
        return SimpleBotsHomeProjection.canPin(bot.profileID, profiles: context.agents.profiles,
                                               primaryID: context.agents.primaryAgentID,
                                               pinnedIDs: context.agents.pinnedAgentIDs,
                                               pinnedGroups: home.pinnedGroups.count)
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

    /// `hostName`: a section page's rows name their computer when it spans several.
    @ViewBuilder
    func row(_ item: SimpleBotsItem, home: SimpleBotsHomeProjection.Home, hostName: String? = nil) -> some View {
        switch item.kind {
        case .bot(let bot):
            Button {
                openBot(bot)
            } label: {
                SimpleBotsRowLabel(
                    face: AnyView(botFace(bot, size: 56)),
                    title: bot.name, role: [bot.role, hostName].compactMap { $0?.isEmpty == false ? $0 : nil }
                        .joined(separator: " · "),
                    preview: item.preview, date: item.date,
                    isUnread: isUnread(bot), isPinned: item.isPinned,
                    activityKey: bot.activityKey, activity: context.activity)
            }
            .buttonStyle(.plain)
            .contextMenu {
                botMenu(bot, isPrimary: bot.id == home.primary?.id, home: home)
            } preview: {
                SimpleBotsPreview(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL, message: item.preview)
                    .companionScope(bot.faceScope)
            }
            .menuOrder(.fixed)
            .modifier(SimpleBotActivityValue(key: bot.activityKey, activity: context.activity))
            .accessibilityIdentifier("simple-bots.bot.\(bot.id)")
        case .group(let group):
            Button {
                openGroup(group)
            } label: {
                SimpleBotsRowLabel(face: AnyView(SimpleBotsGroupFace(members: group.members, size: 56)),
                                   title: group.title, role: hostName,
                                   preview: item.preview, date: item.date,
                                   isUnread: isUnread(group), isPinned: item.isPinned)
            }
            .buttonStyle(.plain)
            .contextMenu {
                groupMenu(group, home: home)
            } preview: {
                SimpleBotsGroupPreview(group: group)
            }
            .menuOrder(.fixed)
            .accessibilityIdentifier("simple-bots.group.\(group.id)")
        }
    }

    private func botFace(_ bot: SimpleBotsBot, size: CGFloat) -> some View {
        SimpleBotLiveFace(bot: bot, size: size, activity: context.activity)
    }

    /// With Multi-gateway each action works on the bot's own gateway.
    @ViewBuilder
    private func botMenu(_ bot: SimpleBotsBot, isPrimary: Bool, home: SimpleBotsHomeProjection.Home) -> some View {
        let actions = SimpleBotsMenuAction.bot(isPrimary: isPrimary, isPinned: isPinned(bot), canPin: canPin(bot, home: home),
                                               canFile: context.fleet != nil, isUnread: isUnread(bot))
        ForEach(actions, id: \.self) { action in
            if action.startsGroup { Divider() }
            switch action {
            case .newChat:
                Button("New Chat", systemImage: "square.and.pencil") {
                    act(bot, .newChat(profileID: bot.profileID)) { context.onNewChat(bot.profileID) }
                }
            case .pin: Button("Pin", systemImage: "pin") { setPinned(bot, true, home: home) }
            case .unpin: Button("Unpin", systemImage: "pin.slash") { setPinned(bot, false, home: home) }
            case .rearrange: rearrangeButton
            case .moveToSection: moveToSectionMenu(.bot(bot))
            case .markRead: Button("Mark Read", systemImage: "message") { setUnread(bot, false) }
            case .markUnread: Button("Mark Unread", systemImage: "message.badge") { setUnread(bot, true) }
            case .botProfile:
                Button("Bot Profile", systemImage: "person.crop.circle") {
                    act(bot, .botProfile(profileID: bot.profileID)) { context.onOpenProfile(bot.profileID) }
                }
            case .hide:
                Button("Hide", systemImage: "eye.slash", role: .destructive) {
                    if let gateways = context.gateways, bot.profile == nil { gateways.hide(bot) }
                    else if let profile = bot.profile { hide(profile) }
                }
            case .groupSettings, .deleteGroupChat: EmptyView()
            }
        }
    }

    /// Turns on dragging for every bot and group chat, until Save or Cancel. On a section's page, for
    /// its members.
    var rearrangeButton: some View {
        Button("Rearrange", systemImage: "arrow.up.arrow.down") {
            let home = home
            let rows = sectionID.flatMap { id in home.sections.first { $0.id == id }?.members } ?? home.rows
            withAnimation(.snappy) {
                arranging = SimpleBotsArrangement(list: rows.map(\.id), top: home.top.map(\.id))
            }
        }
    }

    private func saveArrangement() {
        guard let arranging else { return }
        if sectionID == nil {
            order.set(arranging.list, scope: listScope)
            order.set(arranging.top, scope: topScope)
        } else {
            order.set(SimpleBotsHomeProjection.placing(arranging.list, in: order.order(scope: listScope)), scope: listScope)
        }
        withAnimation(.snappy) { self.arranging = nil }
    }

    /// Rearranging: the top bots drag among themselves; the list is a list in edit mode, with the
    /// system's reorder handles, so it scrolls and moves the way lists do everywhere.
    func arrangeList(_ home: SimpleBotsHomeProjection.Home, rows: [SimpleBotsItem], showsTop: Bool) -> some View {
        let ids = rows.map(\.id)
        return List {
            Group {
                if showsTop, !home.top.isEmpty { topRow(home) }
                // A computer whose plugin can't keep the order: it stays on this device only.
                Text(BotsAppStateSync.shared.phoneOnlyScopes.contains(context.scope)
                     ? "Drag your bots and group chats into the order you want, then tap Save. To keep this order on your other devices too, update the bighelp plugin on this computer." as LocalizedStringKey
                     : "Drag your bots and group chats into the order you want, then tap Save.")
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
            ForEach(rows) { item in
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
        case .group(let group):
            label = SimpleBotsRowLabel(face: AnyView(SimpleBotsGroupFace(members: group.members, size: 56)),
                                       title: group.title, preview: item.preview, date: nil, isUnread: false,
                                       isPinned: item.isPinned)
            identifier = "simple-bots.group.\(group.id)"
        }
        return label
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
            .accessibilityAction(named: "Move up") { step(item.id, by: -1, in: ids, top: false) }
            .accessibilityAction(named: "Move down") { step(item.id, by: 1, in: ids, top: false) }
    }

    /// A bot or group chat on top while rearranging: still, with no menu or chat, and it drags among
    /// the others on top.
    private func arrangeableTile(_ item: SimpleBotsTopItem, isPrimary: Bool, size: CGFloat,
                                 top: [SimpleBotsTopItem]) -> some View {
        let ids = top.map(\.id), key = "top:\(item.id)"
        return VStack(spacing: BighelpTokens.space12) {
            switch item {
            case .bot(let bot):
                SimpleBotFace(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL,
                              size: size, blinks: false)
                    .companionScope(bot.faceScope)
            case .group(let group):
                SimpleBotsGroupFace(members: group.members, size: size, limit: 3)
            }
            Text(item.name)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
        .gesture(arrangeDrag(key, peers: ids.map { "top:\($0)" }) { target in
            arranging?.top = SimpleBotsHomeProjection.moving(item.id, to: String(target.dropFirst(4)), in: ids)
        })
        .arrangeLift(key, dragging: dragging, offset: dragOffset(key), space: Self.arrangeSpace) { frames[key] = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(isPrimary ? "simple-bots.primary" : "simple-bots.pinned.\(item.id)")
        .accessibilityHint("Drag to change its place")
        .accessibilityAction(named: "Move left") { step(item.id, by: -1, in: ids, top: true) }
        .accessibilityAction(named: "Move right") { step(item.id, by: 1, in: ids, top: true) }
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

    func unreadButton(_ group: SimpleBotsGroup) -> some View {
        let unreadNow = isUnread(group)
        return Button(unreadNow ? "Mark Read" : "Mark Unread", systemImage: unreadNow ? "message" : "message.badge") {
            setUnread(group, !unreadNow)
        }
    }

    private func hide(_ profile: AgentProfile) {
        var placement = profile.placement ?? AgentListPlacement()
        placement.isHidden = true
        Task { @MainActor in
            do {
                try await context.agents.setPlacement(placement, profileID: profile.id)
            } catch {
                hideError = String(localized: "This computer didn't save that. Try again in a moment.")
            }
        }
    }

    var unreadDot: some View {
        Circle().fill(theme.information).frame(width: 9, height: 9).accessibilityLabel("Unread")
    }

    @ViewBuilder
    private func sheetView(_ sheet: SimpleBotsSheet) -> some View {
        switch sheet {
        case .search:
            SimpleBotsSearchView(context: context, hiddenGroups: hiddenGroups, sections: sectionsModel, onOpen: { id in
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
        }
    }
}

/// A home row: the face, the name and what the bot does over the latest message, and its time.
/// While the bot's Bot Chat works or needs you, that takes the latest message's line.
struct SimpleBotsRowLabel: View {
    let face: AnyView
    let title: String
    var role: String?
    let preview: String?
    let date: Date?
    let isUnread: Bool
    let isPinned: Bool
    var activityKey: String? = nil
    var activity: BotChatActivityStore? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @BighelpThemeReader private var theme

    /// Read here, so only this row redraws when its bot's state changes.
    private var busy: BotChatActivity? {
        guard let activityKey, let value = activity?.activity(activityKey), value.isBusy else { return nil }
        return value
    }

    var body: some View {
        HStack(spacing: BighelpTokens.space16) {
            face.frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                if typeSize.isAccessibilitySize {
                    // The largest text sizes: each part on a line of its own, so none is cut off.
                    HStack(spacing: BighelpTokens.space8) {
                        titleText.lineLimit(3)
                        pin
                        Spacer(minLength: BighelpTokens.space8)
                        unreadDot
                    }
                    rolePill
                    dateText
                } else {
                    HStack(spacing: BighelpTokens.space8) {
                        titleText
                            .lineLimit(1)
                            .layoutPriority(1)
                        // The name always shows in full; the role gives way first.
                        rolePill
                        pin
                        Spacer(minLength: BighelpTokens.space8)
                        dateText
                        unreadDot
                    }
                }
                if let busy, let line = busy.line {
                    Text(line)
                        .font(.bighelp(.body, weight: .medium))
                        .foregroundStyle(busy == .waiting ? BighelpBrand.ember : theme.action)
                        .lineLimit(1)
                        // The row says it as its value.
                        .accessibilityHidden(true)
                } else if let preview = preview.map(SessionPreviewText.plain), !preview.isEmpty {
                    Text(preview)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                }
            }
        }
        .padding(.horizontal, BighelpTokens.space20)
        .padding(.vertical, BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View {
        Text(title)
            .font(.bighelp(.title3, weight: isUnread ? .semibold : .medium))
            .foregroundStyle(theme.primaryText)
    }

    @ViewBuilder
    private var rolePill: some View {
        if let role = role?.trimmingCharacters(in: .whitespacesAndNewlines), !role.isEmpty {
            Text(role)
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .padding(.horizontal, BighelpTokens.space8)
                .padding(.vertical, 3)
                .background(theme.secondaryText.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel(role)
        }
    }

    @ViewBuilder
    private var pin: some View {
        if isPinned {
            Image(systemName: "pin.fill")
                .font(.bighelp(.caption2))
                .foregroundStyle(theme.tertiaryText)
                .accessibilityLabel("Pinned")
        }
    }

    @ViewBuilder
    private var dateText: some View {
        if let date {
            Text(SessionRow.compactTimestamp(date))
                .font(.bighelp(.subheadline))
                .foregroundStyle(theme.tertiaryText)
        }
    }

    @ViewBuilder
    private var unreadDot: some View {
        if isUnread {
            Circle().fill(theme.information).frame(width: 9, height: 9).accessibilityLabel("Unread")
        }
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
        // A preview is drawn outside the app's own colors; the system's match Bots mode.
        .background(Color(uiColor: .systemBackground))
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

/// A bot's face with its Bot Chat state, read here so only this face redraws when it changes.
struct SimpleBotLiveFace: View {
    let bot: SimpleBotsBot
    let size: CGFloat
    var blinks = false
    let activity: BotChatActivityStore?

    var body: some View {
        SimpleBotFace(agentID: bot.profileID, name: bot.name, imageURL: bot.imageURL, size: size,
                      blinks: blinks, activity: activity?.activity(bot.activityKey))
            .companionScope(bot.faceScope)
    }
}

/// VoiceOver says what a bot is doing after its name: the row's, tile's or result's value.
struct SimpleBotActivityValue: ViewModifier {
    let key: String
    let activity: BotChatActivityStore?

    func body(content: Content) -> some View {
        content.accessibilityValue(activity?.activity(key)?.accessibilityLabel ?? "")
    }
}

