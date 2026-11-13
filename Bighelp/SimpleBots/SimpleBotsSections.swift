import Foundation

/// A group chat on the Bots view: on the gateway in use (its catalog row, which opens it) or, with
/// every computer shown, on another gateway (the all-hosts copy of it).
struct SimpleBotsGroup: Identifiable, Equatable {
    /// Its row's ID in the home's order: the catalog row's with one gateway, `FleetGroup.id` with every computer shown.
    let id: String
    let roomID: String
    /// The gateway it's on. Its section, pin and hide are kept by it (`key`); nil when that isn't known.
    let hostID: UUID?
    let title: String
    /// Its members on its own gateway, for its faces.
    let members: [SimpleBotsBot]
    let preview: String?
    let updatedAt: Date
    /// On the gateway in use: its catalog row, once it has messages.
    var summary: SessionSummary? = nil
    /// On another gateway: the all-hosts copy.
    var fleetGroup: FleetGroup? = nil
    /// On the gateway in use (opened, set up and deleted there), with or without a catalog row.
    var isOnGatewayInUse = false

    /// Where its section, pin and hide are kept, as the all-hosts list names it (`FleetGroup.id`).
    var key: String? { hostID.map { FleetID.make($0, "group/" + roomID) } }
    var itemID: String { "group:" + id }

    /// A catalog row on the gateway in use. `listsByKey` (every computer shown) names the row by its gateway too.
    init?(_ summary: SessionSummary, hostID: UUID?, members: [SimpleBotsBot], listsByKey: Bool = false) {
        guard summary.kind == .botMode else { return nil }
        let room = summary.hostedRoomID ?? summary.id
        let key = hostID.map { FleetID.make($0, "group/" + room) }
        self.id = listsByKey ? key ?? summary.id : summary.id
        roomID = room
        self.hostID = hostID
        title = summary.title
        self.members = members
        preview = summary.preview
        updatedAt = summary.updatedAt
        self.summary = summary
        isOnGatewayInUse = true
    }

    /// A group chat on the gateway in use that has no messages yet, from Hermes' list of rooms.
    init(room: HermesBotModeRoomSummary, hostID: UUID?, members: [SimpleBotsBot], listsByKey: Bool = false) {
        let key = hostID.map { FleetID.make($0, "group/" + room.roomID) }
        id = listsByKey ? key ?? Self.catalogID(room.roomID) : Self.catalogID(room.roomID)
        roomID = room.roomID
        self.hostID = hostID
        title = room.name
        self.members = members
        preview = nil
        updatedAt = room.updatedAt
        isOnGatewayInUse = true
    }

    /// The catalog row a hosted room gets once it's opened (`openHostedGroup`).
    static func catalogID(_ roomID: String) -> String { "hermes-room:" + roomID }

    /// Another gateway's group chat, from the all-hosts copy.
    init(_ group: FleetGroup, members: [SimpleBotsBot]) {
        id = group.id
        roomID = group.roomID
        hostID = group.hostID
        title = group.name
        self.members = members
        preview = nil
        updatedAt = group.updatedAt
        fleetGroup = group
    }
}

/// One place on top of the home: the primary bot, a pinned bot or a pinned group chat.
enum SimpleBotsTopItem: Identifiable, Equatable {
    case bot(SimpleBotsBot)
    case group(SimpleBotsGroup)

    /// As the top's order keeps it: a bot's own ID, a group chat's row ID (`group:…`).
    var id: String {
        switch self {
        case .bot(let bot): bot.id
        case .group(let group): group.itemID
        }
    }

    var bot: SimpleBotsBot? {
        if case .bot(let bot) = self { return bot }
        return nil
    }

    var name: String {
        switch self {
        case .bot(let bot): bot.name
        case .group(let group): group.title
        }
    }
}

/// Which section each bot and group chat is in, and the sections in the person's order. Bots carry
/// theirs on their profiles (`AgentListPlacement`, as Hermes Desktop does); group chats' sections,
/// pins and hides are kept by the app (`FleetStore`), on the computers too (`bots.layout`).
struct SimpleBotsSectioning: Equatable {
    var sections: [FleetSection] = []
    /// By `SimpleBotsGroup.key`.
    var groupSections: [String: String] = [:]
    var pinnedGroups: [String] = []
    var hiddenGroups: Set<String> = []
    /// Sections with members only on computers the home doesn't show now: they stay off it until one
    /// of their members shows. An empty section shows.
    var elsewhere: Set<String> = []

    func section(of bot: SimpleBotsBot) -> FleetSection? {
        FleetSectioning.section(for: bot.placement, in: sections)
    }

    func section(of group: SimpleBotsGroup) -> FleetSection? {
        guard let key = group.key, let id = groupSections[key] else { return nil }
        return sections.first { $0.id == id }
    }

    func section(of kind: SimpleBotsItem.Kind) -> FleetSection? {
        switch kind {
        case .bot(let bot): section(of: bot)
        case .group(let group): section(of: group)
        }
    }

    func isHidden(_ group: SimpleBotsGroup) -> Bool { group.key.map(hiddenGroups.contains) ?? false }
    func isPinned(_ group: SimpleBotsGroup) -> Bool { group.key.map(pinnedGroups.contains) ?? false }

    /// The app's sections and group chats' choices. With `shown` (the gateways the home shows), a
    /// section whose members are all elsewhere stays off it.
    @MainActor
    init(fleet: FleetStore?, shown: Set<UUID>? = nil) {
        guard let fleet else { return }
        sections = fleet.sections
        groupSections = fleet.groupSectionIDs
        pinnedGroups = fleet.pinnedGroupIDs
        hiddenGroups = Set(fleet.hiddenGroupIDs)
        guard let shown else { return }
        let listed = Set(sections.map(\.id))
        for host in fleet.hosts where !shown.contains(host.id) {
            for agent in fleet.snapshots[host.id]?.agents ?? [] where !agent.isHidden {
                if let section = FleetSectioning.section(for: agent.placement, in: sections) { elsewhere.insert(section.id) }
            }
        }
        for (key, section) in groupSections where listed.contains(section) && !hiddenGroups.contains(key) {
            if let host = Self.host(ofGroupKey: key), !shown.contains(host) { elsewhere.insert(section) }
        }
    }

    init(sections: [FleetSection] = [], groupSections: [String: String] = [:], pinnedGroups: [String] = [],
         hiddenGroups: Set<String> = [], elsewhere: Set<String> = []) {
        self.sections = sections
        self.groupSections = groupSections
        self.pinnedGroups = pinnedGroups
        self.hiddenGroups = hiddenGroups
        self.elsewhere = elsewhere
    }

    /// The gateway in a group chat's key (`<host>/group/<room>`).
    static func host(ofGroupKey key: String) -> UUID? {
        key.split(separator: "/", maxSplits: 1).first.flatMap { UUID(uuidString: String($0)) }
    }
}

/// A section on the home: its bots and group chats on the computers shown, in the home's order.
struct SimpleBotsSectionCard: Identifiable, Equatable {
    let section: FleetSection
    let members: [SimpleBotsItem]
    var id: String { section.id }

    var botCount: Int { members.count(where: { if case .bot = $0.kind { true } else { false } }) }
    var groupCount: Int { members.count - botCount }

    /// The gateways its members are on, in the order they first show; more than one only with every computer shown.
    var hostIDs: [UUID] {
        var seen = Set<UUID>()
        return members.compactMap { item -> UUID? in
            switch item.kind {
            case .bot(let bot): bot.hostID
            case .group(let group): group.hostID
            }
        }.filter { seen.insert($0).inserted }
    }

    /// "2 bots, 1 group chat".
    var countText: String { Self.countText(bots: botCount, groups: groupCount) }

    static func countText(bots: Int, groups: Int) -> String {
        let botText = bots == 1 ? String(localized: "1 bot") : String(localized: "\(bots) bots")
        let groupText = groups == 1 ? String(localized: "1 group chat") : String(localized: "\(groups) group chats")
        switch (bots, groups) {
        case (0, 0): return String(localized: "Empty")
        case (_, 0): return botText
        case (0, _): return groupText
        default: return String(localized: "\(botText), \(groupText)")
        }
    }
}

/// The Bots view's sections, changed from the home, a section's page or the sheets: bots' sections are
/// saved on each bot's own computer (its live profile on the gateway in use, its all-hosts copy on
/// another), group chats' in the app (`FleetStore`). Members go by their row IDs (`SimpleBotsItem.id`).
@MainActor
struct SimpleBotsSectionEditor {
    let fleet: FleetStore
    /// Every bot whose section can change from here, hidden ones too.
    let bots: [SimpleBotsBot]
    let groups: [SimpleBotsGroup]
    /// Saves a bot's placement on its own computer.
    let save: @MainActor (SimpleBotsBot, AgentListPlacement) async throws -> Void

    var sectioning: SimpleBotsSectioning { SimpleBotsSectioning(fleet: fleet) }

    /// Row IDs of a section's bots and group chats.
    func memberIDs(of sectionID: String) -> Set<String> {
        let sectioning = sectioning
        return Set(bots.filter { sectioning.section(of: $0)?.id == sectionID }.map { "bot:" + $0.id }
            + groups.filter { sectioning.section(of: $0)?.id == sectionID }.map(\.itemID))
    }

    /// A new section with these members; one that has the name already takes them instead.
    @discardableResult
    func create(named name: String, members: Set<String>) async -> FleetSection? {
        guard let section = fleet.createSection(named: name) else { return nil }
        await setMembers(of: section.id, to: memberIDs(of: section.id).union(members))
        return section
    }

    func rename(_ sectionID: String, to name: String) async {
        await fleet.renameSection(sectionID, to: name, members: sectionMembers(of: sectionID))
    }

    /// Deletes the section only: its bots and group chats move to No section.
    func delete(_ sectionID: String) async {
        _ = fleet.deleteSection(sectionID, members: sectionMembers(of: sectionID))
        await fleet.waitForSectionUnfiling(sectionID)
    }

    /// Files `members` here and takes the rest out. A bot is in one section at a time, so one from
    /// another section moves.
    func setMembers(of sectionID: String, to members: Set<String>) async {
        let sectioning = sectioning
        for group in groups {
            guard let key = group.key else { continue }
            let isIn = sectioning.section(of: group)?.id == sectionID
            if members.contains(group.itemID) != isIn { fleet.file(groupKey: key, in: isIn ? nil : sectionID) }
        }
        for bot in bots {
            let isIn = sectioning.section(of: bot)?.id == sectionID
            guard members.contains("bot:" + bot.id) != isIn else { continue }
            try? await fleet.file(member(bot), in: isIn ? nil : sectionID)
        }
    }

    /// Move to Section: into `sectionID`, or No section (nil).
    func move(_ kind: SimpleBotsItem.Kind, to sectionID: String?) async {
        switch kind {
        case .bot(let bot):
            try? await fleet.file(member(bot), in: sectionID)
        case .group(let group):
            if let key = group.key { fleet.file(groupKey: key, in: sectionID) }
        }
    }

    private func member(_ bot: SimpleBotsBot) -> FleetSectionMember {
        FleetSectionMember(id: bot.id, placement: bot.placement) { placement in try await save(bot, placement) }
    }

    /// Rename and Delete reach every member: these bots, and the ones on the computers the home
    /// doesn't show now, through their all-hosts copies. Left alone there, a deleted section would
    /// come back from them.
    private func sectionMembers(of sectionID: String) -> [FleetSectionMember] {
        let sectioning = sectioning
        let shown = bots.filter { sectioning.section(of: $0)?.id == sectionID }.map(member)
        let selected = fleet.selectedHostID
        let elsewhere = fleet.agents().filter { agent in
            sectioning.section(of: SimpleBotsBot(agent, imageURL: nil))?.id == sectionID && !bots.contains { bot in
                bot.id == agent.id || (bot.hostID == nil && agent.hostID == selected && bot.profileID == agent.profileID)
            }
        }
        return shown + elsewhere.map(fleet.sectionMember)
    }
}

/// A touch-and-hold action on the Bots view, in the order its menu shows them.
enum SimpleBotsMenuAction: Hashable {
    case newChat, pin, unpin, rearrange, moveToSection, markRead, markUnread, botProfile, groupSettings
    /// A divider comes before these.
    case hide, deleteGroupChat

    /// New Chat, Pin (Unpin when pinned), Rearrange, Move to Section, Mark Read or Unread, Bot
    /// Profile, then Hide. The primary bot has no Pin or Hide.
    static func bot(isPrimary: Bool, isPinned: Bool, canPin: Bool, canFile: Bool, isUnread: Bool) -> [Self] {
        var actions: [Self] = [.newChat]
        if isPinned, !isPrimary { actions.append(.unpin) } else if !isPrimary, canPin { actions.append(.pin) }
        actions.append(.rearrange)
        if canFile { actions.append(.moveToSection) }
        actions += [isUnread ? .markRead : .markUnread, .botProfile]
        if !isPrimary { actions.append(.hide) }
        return actions
    }

    /// Like a bot's: Pin (Unpin when pinned), Rearrange, Move to Section, Mark Read or Unread, Group
    /// Settings, then Hide and Delete Group Chat. Each only where it can work.
    static func group(isPinned: Bool, canPin: Bool, canFile: Bool, isUnread: Bool, hasSettings: Bool,
                      canHide: Bool, canDelete: Bool) -> [Self] {
        var actions: [Self] = []
        if isPinned { actions.append(.unpin) } else if canPin { actions.append(.pin) }
        actions.append(.rearrange)
        if canFile { actions.append(.moveToSection) }
        actions.append(isUnread ? .markRead : .markUnread)
        if hasSettings { actions.append(.groupSettings) }
        if canHide { actions.append(.hide) }
        if canDelete { actions.append(.deleteGroupChat) }
        return actions
    }

    var startsGroup: Bool { self == .hide || self == .deleteGroupChat }
}

#if DEBUG
/// `-test-bot-sections`: demo mode's sections, for UI tests and screenshots. Home life holds Jordan
/// and the Household team (`-preview-agent-groups`) on Home Hermes; Work holds Mina on Home Hermes
/// and Sage and the Launch crew on Studio Mac, so with one computer shown it shows only Mina.
enum SimpleBotsDemoSections {
    static let argument = "-test-bot-sections"
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    static let work = FleetSection(id: "sec-demo-work", name: "Work")
    static let homeLife = FleetSection(id: "sec-demo-home", name: "Home life")

    /// The demo bots' own sections, as their profiles carry them.
    static func placement(for profileID: String) -> AgentListPlacement? {
        switch profileID {
        case "home": AgentListPlacement(sectionID: homeLife.id, sectionName: homeLife.name)
        case "travel", "reviewer": AgentListPlacement(sectionID: work.id, sectionName: work.name)
        default: nil
        }
    }

    @MainActor
    static func seed(_ fleet: FleetStore) {
        fleet.sections = [work, homeLife]
        fleet.groupSectionIDs = [FleetID.make(FleetFixtureReader.homeID, "group/demo-agent-group"): homeLife.id,
                                 FleetID.make(FleetFixtureReader.studioID, "group/studio-launch"): work.id]
        fleet.saveSections()
    }
}
#endif
