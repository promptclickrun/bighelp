import Foundation

/// A host set up on this phone, by the names this phone's stores use for it.
struct BotsAppStateHost: Equatable, Sendable {
    /// This phone's own ID for it (the host registry's), different on every device.
    let hostKey: String
    /// Its sign-ins' cache scopes (`WorkspaceOwner.cacheScopeID`): Bots mode's order and the voices are kept by these.
    let scopes: [String]
    /// Where its bots' faces are kept on this phone (`CompanionSurfaceScope.computer`).
    let faceScope: String
    let isSelected: Bool
}

/// What this phone keeps of `bots.layout` and `bots.settings`, read from its stores at once.
struct BotsPhoneState: Equatable {
    /// `SimpleBotsOrderStore.orders`: list and `top|` scopes, per sign-in and `multi-gateway`.
    var orders: [String: [String]] = [:]
    var sections: [FleetSection] = []
    /// A group chat's section, by `FleetGroup.id`.
    var groupSections: [String: String] = [:]
    /// Group chats pinned on Bots mode's home and ones hidden from it, by `FleetGroup.id`.
    var pinnedGroups: [String] = []
    var hiddenGroups: [String] = []
    /// Multi-gateway's primary bot (`FleetID`).
    var primary: String?
    /// `AgentVoiceChoices`, by its entry keys.
    var voices: [String: AgentVoiceChoices.Choice] = [:]
    /// `SimpleBotMarkStore`, `PetAvatarStore` and `CompanionStore`, by `CompanionStore.agentKey`.
    var marks: [String: SimpleBotMark] = [:]
    var pets: [String: String] = [:]
    var characters: [String: CompanionAppearance] = [:]
    /// Each sign-in's pinned bots, unpinned ones and primary bot (`AgentDirectoryStore`), by scope.
    var pins: [String: AgentDirectoryStore.SavedPins] = [:]
}

/// Bots mode's choices as the computers keep them (`native-app-state-v1`), named so every device
/// means the same thing: a bot is `<computer ID>/<profile ID>` and a group chat `<computer ID>/<room
/// ID>`, by the ID each computer's plugin makes for itself. The host ID this phone makes is its own,
/// so it never leaves the phone. Hosts without a computer ID (their plugin doesn't keep app state)
/// keep their choices on this phone only. Bots' own sections, pins and hides stay on each bot's
/// profile (`AgentListPlacement`), where Hermes Desktop reads them.
///
/// `bots.layout` (v1): `sections` [{id, name}], `groupSections` {group: section}, `home` {computer:
/// {list, top, pinned, unpinned, primary}} for one gateway's home (pins and the primary bot are this
/// app's own, kept on the phone per sign-in, not on the profiles), `multiGatewayHome` {list, top},
/// `primary` (Multi-gateway's), and `pinnedGroups` and `hiddenGroups` [`<computer>/<room>`]. List and top items
/// are `bot/<computer>/<profile>` and `group/<computer>/<room>`.
///
/// `bots.settings` (v1): `bots` {bot: {voice, mark, pet, character}}.
@MainActor
enum BotsAppState {
    static let layoutKey = "bots.layout"
    static let settingsKey = "bots.settings"
    static let keys = [layoutKey, settingsKey]
    static let version = 1

    static let layoutShape = AppStateShape.object([
        "sections": .leaf(fields: ["id", "name"]),
        "groupSections": .map(.leaf()),
        "home": .map(.object(["list": .leaf(), "top": .leaf(), "pinned": .leaf(), "unpinned": .leaf(),
                              "primary": .leaf()])),
        "multiGatewayHome": .object(["list": .leaf(), "top": .leaf()]),
        "primary": .leaf(),
        "pinnedGroups": .leaf(),
        "hiddenGroups": .leaf(),
    ])

    static let settingsShape = AppStateShape.object([
        "bots": .map(.object([
            "voice": .leaf(fields: ["mode", "liveProvider", "liveVoices"]),
            "mark": .leaf(fields: ["shape", "color"]),
            "pet": .leaf(),
            "character": .leaf(fields: characterFields),
        ])),
    ])

    static let characterFields = ["character", "colorHex", "matchesTheme", "eyeStyle", "eyeColorHex", "topper",
                                  "pattern", "vibe", "colorway", "usesCharacterColors", "bitEyes", "bitMouth",
                                  "bitAccessory", "showsCheeks", "catalogAvatar"]

    /// Bounds far above real use, so one value stays well under the plugin's 64 KB.
    static let maximumListItems = 128
    static let maximumBots = 128

    static let multiGatewayScope = "multi-gateway"
    private static let topPrefix = "top|"
    private static let roomPrefix = "hermes-room:"

    /// The computers each host is, by this phone's host IDs.
    struct Names {
        let hosts: [BotsAppStateHost]
        let computerIDs: [String: String]

        func computer(hostKey: String) -> String? { computerIDs[hostKey] }
        func computer(scope: String) -> String? {
            hosts.first { $0.scopes.contains(scope) }.flatMap { computerIDs[$0.hostKey] }
        }
        func computer(faceScope: String) -> String? {
            hosts.first { $0.faceScope == faceScope }.flatMap { computerIDs[$0.hostKey] }
        }
        /// The hosts that are this computer here: usually one, two when it's set up twice.
        func hosts(of computer: String) -> [BotsAppStateHost] {
            hosts.filter { computerIDs[$0.hostKey] == computer }.sorted { $0.isSelected && !$1.isSelected }
        }
        var selectedComputer: String? { hosts.first(where: \.isSelected).flatMap { computerIDs[$0.hostKey] } }
        /// Computers with a host on this phone, in host order, once each.
        var computers: [String] {
            var seen = Set<String>()
            return hosts.compactMap { computerIDs[$0.hostKey] }.filter { seen.insert($0).inserted }
        }
    }

    // MARK: The phone's choices, as the computers keep them

    /// `bots.layout` from what this phone has, for every computer it can name.
    static func layout(_ phone: BotsPhoneState, names: Names) -> BighelpJSONValue {
        var value: [String: BighelpJSONValue] = [
            "sections": .array(phone.sections.map { .object(["id": .string($0.id), "name": .string($0.name)]) }),
        ]
        let known = Set(phone.sections.map(\.id))
        var groups: [String: BighelpJSONValue] = [:]
        for (group, section) in phone.groupSections.sorted(by: { $0.key < $1.key }) where known.contains(section) {
            guard let parsed = fleetGroup(group), let computer = names.computer(hostKey: parsed.host) else { continue }
            groups[computer + "/" + parsed.room] = .string(section)
        }
        if !groups.isEmpty { value["groupSections"] = .object(groups) }
        for (field, keys) in [("pinnedGroups", phone.pinnedGroups), ("hiddenGroups", phone.hiddenGroups)] {
            let portable = keys.compactMap { key in
                fleetGroup(key).flatMap { group in names.computer(hostKey: group.host).map { $0 + "/" + group.room } }
            }
            if !portable.isEmpty { value[field] = list(portable) }
        }
        var home: [String: BighelpJSONValue] = [:]
        for computer in names.computers {
            let scopes = names.hosts(of: computer).flatMap(\.scopes)
            var parts: [String: BighelpJSONValue] = [:]
            for (part, prefix) in [("list", ""), ("top", topPrefix)] {
                let items = scopes.lazy.map {
                    (phone.orders[prefix + $0] ?? []).compactMap { portableItem($0, computer: computer, top: part == "top") }
                }
                    .first { !$0.isEmpty } ?? []
                if !items.isEmpty { parts[part] = list(items) }
            }
            if let pins = scopes.lazy.compactMap({ phone.pins[$0] }).first(where: { $0 != AgentDirectoryStore.SavedPins() }) {
                let bot = { (profile: String) in isName(profile) ? computer + "/" + profile : nil }
                if !pins.pinned.isEmpty { parts["pinned"] = list(pins.pinned.compactMap(bot)) }
                if !pins.unpinned.isEmpty { parts["unpinned"] = list(pins.unpinned.compactMap(bot)) }
                if let primary = pins.primary.flatMap(bot) { parts["primary"] = .string(primary) }
            }
            if !parts.isEmpty { home[computer] = .object(parts) }
        }
        if !home.isEmpty { value["home"] = .object(home) }
        var multi: [String: BighelpJSONValue] = [:]
        for (part, scope) in [("list", multiGatewayScope), ("top", topPrefix + multiGatewayScope)] {
            let items = (phone.orders[scope] ?? []).compactMap { portableMultiItem($0, names: names, top: part == "top") }
            if !items.isEmpty { multi[part] = list(items) }
        }
        if !multi.isEmpty { value["multiGatewayHome"] = .object(multi) }
        if let primary = phone.primary.flatMap({ portableBot(fleetID: $0, names: names) }) {
            value["primary"] = .string(primary)
        }
        return .object(value)
    }

    /// `bots.settings` from what this phone has, for every computer it can name.
    static func settings(_ phone: BotsPhoneState, names: Names) -> BighelpJSONValue {
        var bots: [String: [String: BighelpJSONValue]] = [:]
        func add(_ field: String, _ value: BighelpJSONValue?, computer: String?, agentID: String) {
            guard let computer, let value, !agentID.isEmpty else { return }
            let bot = computer + "/" + agentID
            guard bots[bot] != nil || bots.count < maximumBots, bots[bot]?[field] == nil else { return }
            bots[bot, default: [:]][field] = value
        }
        for (entry, choice) in phone.voices.sorted(by: { $0.key < $1.key }) {
            guard let parts = AgentVoiceChoices.entryParts(entry) else { continue }
            add("voice", json(choice), computer: names.computer(scope: parts.computer), agentID: parts.agentID)
        }
        func faces<T>(_ values: [String: T], _ field: String, _ encode: (T) -> BighelpJSONValue?) {
            for (key, value) in values.sorted(by: { $0.key < $1.key }) {
                guard let parts = CompanionStore.agentKeyParts(key) else { continue }
                add(field, encode(value), computer: names.computer(faceScope: parts.scope), agentID: parts.agentID)
            }
        }
        faces(phone.marks, "mark") { json($0) }
        faces(phone.pets, "pet") { .string($0) }
        faces(phone.characters, "character") { json($0) }
        return .object(["bots": .object(bots.mapValues(BighelpJSONValue.object))])
    }

    // MARK: The computers' choices, on this phone

    /// The phone's choices with `layout` in place of what it had for each computer it can name.
    /// Choices for hosts it can't name, and order items it can't name, stay where they were.
    static func applying(layout value: BighelpJSONValue?, to phone: BotsPhoneState, names: Names) -> BotsPhoneState {
        guard let value = value?.object else { return phone }
        var next = phone
        var seen = Set<String>()
        next.sections = (value["sections"]?.array ?? []).compactMap { row -> FleetSection? in
            guard let fields = row.object, let id = fields["id"]?.string, !id.isEmpty, id.utf8.count <= 128,
                  let name = fields["name"]?.string.flatMap(FleetSection.cleanName), seen.insert(id).inserted
            else { return nil }
            return FleetSection(id: id, name: name)
        }.prefix(FleetSection.maximumCount).map { $0 }
        let known = Set(next.sections.map(\.id))
        next.groupSections = phone.groupSections.filter { group, section in
            known.contains(section) && fleetGroup(group).map { names.computer(hostKey: $0.host) == nil } ?? true
        }
        for (group, section) in value["groupSections"]?.object ?? [:] {
            guard let section = section.string, known.contains(section),
                  let pair = split(group) else { continue }
            for host in names.hosts(of: pair.first) {
                guard let hostID = UUID(uuidString: host.hostKey) else { continue }
                next.groupSections[FleetID.make(hostID, "group/" + pair.rest)] = section
            }
        }
        for (field, path) in [("pinnedGroups", \BotsPhoneState.pinnedGroups), ("hiddenGroups", \BotsPhoneState.hiddenGroups)] {
            // Ones on hosts this phone can't name stay; the value has the rest.
            var keys = phone[keyPath: path].filter { key in fleetGroup(key).map { names.computer(hostKey: $0.host) == nil } ?? true }
            for group in strings(value[field]) {
                guard let pair = split(group) else { continue }
                for host in names.hosts(of: pair.first) {
                    guard let hostID = UUID(uuidString: host.hostKey) else { continue }
                    let key = FleetID.make(hostID, "group/" + pair.rest)
                    if !keys.contains(key) { keys.append(key) }
                }
            }
            next[keyPath: path] = keys
        }
        let home = value["home"]?.object ?? [:]
        for computer in names.computers {
            let parts = home[computer]?.object ?? [:]
            for host in names.hosts(of: computer) {
                for scope in host.scopes {
                    for (part, prefix) in [("list", ""), ("top", topPrefix)] {
                        let top = part == "top"
                        let items = strings(parts[part]).compactMap { phoneItem($0, computer: computer, top: top) }
                        let merged = keepingUnnamed(phone.orders[prefix + scope] ?? [], placed: items) {
                            portableItem($0, computer: computer, top: top) == nil
                        }
                        next.orders[prefix + scope] = merged.isEmpty ? nil : merged
                    }
                    let profile = { (bot: String) in split(bot).flatMap { $0.0 == computer ? $0.1 : nil } }
                    next.pins[scope] = AgentDirectoryStore.SavedPins(
                        pinned: strings(parts["pinned"]).compactMap(profile),
                        unpinned: strings(parts["unpinned"]).compactMap(profile),
                        primary: parts["primary"]?.string.flatMap(profile))
                }
            }
        }
        let multi = value["multiGatewayHome"]?.object ?? [:]
        for (part, scope) in [("list", multiGatewayScope), ("top", topPrefix + multiGatewayScope)] {
            let top = part == "top"
            let items = strings(multi[part]).compactMap { phoneMultiItem($0, names: names, top: top) }
            let merged = keepingUnnamed(phone.orders[scope] ?? [], placed: items) {
                portableMultiItem($0, names: names, top: top) == nil
            }
            next.orders[scope] = merged.isEmpty ? nil : merged
        }
        if let primary = value["primary"]?.string, let pair = split(primary),
           let host = names.hosts(of: pair.first).first, let hostID = UUID(uuidString: host.hostKey) {
            next.primary = FleetID.make(hostID, pair.rest)
        } else if value["primary"]?.string == nil, phone.primary.flatMap({ portableBot(fleetID: $0, names: names) }) != nil {
            next.primary = nil
        }
        return next
    }

    /// The phone's choices with `settings` in place of what it had for each computer it can name.
    static func applying(settings value: BighelpJSONValue?, to phone: BotsPhoneState, names: Names) -> BotsPhoneState {
        guard let value = value?.object else { return phone }
        var next = phone
        let named = Set(names.computers)
        next.voices = phone.voices.filter { entry, _ in
            AgentVoiceChoices.entryParts(entry).flatMap { names.computer(scope: $0.computer) }.map(named.contains) != true
        }
        func unnamed<T>(_ values: [String: T]) -> [String: T] {
            values.filter { key, _ in
                CompanionStore.agentKeyParts(key).flatMap { names.computer(faceScope: $0.scope) }.map(named.contains) != true
            }
        }
        next.marks = unnamed(phone.marks)
        next.pets = unnamed(phone.pets)
        next.characters = unnamed(phone.characters)
        for (bot, row) in (value["bots"]?.object ?? [:]).sorted(by: { $0.key < $1.key }).prefix(maximumBots) {
            guard let pair = split(bot), named.contains(pair.first), let fields = row.object else { continue }
            let agentID = pair.rest
            for host in names.hosts(of: pair.first) {
                let face = CompanionStore.agentKey(agentScope: host.faceScope, agentID: agentID)
                if let voice = fields["voice"].flatMap({ decode(AgentVoiceChoices.Choice.self, $0) }), !voice.isEmpty {
                    for scope in host.scopes { next.voices[AgentVoiceChoices.entryKey(computer: scope, agentID: agentID)] = voice }
                }
                if let mark = fields["mark"].flatMap({ decode(SimpleBotMark.self, $0) }) { next.marks[face] = mark }
                if let pet = fields["pet"]?.string, !pet.isEmpty, pet.utf8.count <= 128 { next.pets[face] = pet }
                if let look = fields["character"].flatMap({ decode(CompanionAppearance.self, $0) }) { next.characters[face] = look }
            }
        }
        return next
    }

    // MARK: Names

    /// A one-gateway home's item (`bot:<profile>`, `group:hermes-room:<room>`; on top, bots' bare
    /// profile IDs and pinned group chats' items) by the computer.
    static func portableItem(_ item: String, computer: String, top: Bool = false) -> String? {
        if let room = item.stripping("group:")?.stripping(roomPrefix), isName(room) { return "group/\(computer)/\(room)" }
        if top { return isName(item) && !item.contains("/") && !item.hasPrefix("group:") ? "bot/\(computer)/\(item)" : nil }
        if let profile = item.stripping("bot:"), isName(profile) { return "bot/\(computer)/\(profile)" }
        return nil
    }

    static func phoneItem(_ item: String, computer: String, top: Bool = false) -> String? {
        let parts = item.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[1] == computer, isName(parts[2]) else { return nil }
        switch parts[0] {
        case "bot": return (top ? "" : "bot:") + parts[2]
        case "group": return "group:" + roomPrefix + parts[2]
        default: return nil
        }
    }

    /// A Multi-gateway home's item (`bot:<host>/<profile>`, `group:<host>/group/<room>`; on top, bots'
    /// bare `FleetID`s and pinned group chats' items) by the computer. Orders saved before group chats
    /// were named by their gateway have `group:hermes-room:<room>` for the gateway in use.
    static func portableMultiItem(_ item: String, names: Names, top: Bool = false) -> String? {
        if let group = item.stripping("group:") {
            if let room = group.stripping(roomPrefix), isName(room), let computer = names.selectedComputer {
                return "group/\(computer)/\(room)"
            }
            return fleetGroup(group).flatMap { group in
                names.computer(hostKey: group.host).map { "group/\($0)/\(group.room)" }
            }
        }
        if top { return portableBot(fleetID: item, names: names).map { "bot/" + $0 } }
        if let bot = item.stripping("bot:") {
            return portableBot(fleetID: bot, names: names).map { "bot/" + $0 }
        }
        return nil
    }

    static func phoneMultiItem(_ item: String, names: Names, top: Bool = false) -> String? {
        let parts = item.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3, isName(parts[2]) else { return nil }
        switch parts[0] {
        case "bot":
            guard let host = names.hosts(of: parts[1]).first, let hostID = UUID(uuidString: host.hostKey) else { return nil }
            return (top ? "" : "bot:") + FleetID.make(hostID, parts[2])
        case "group":
            guard let host = names.hosts(of: parts[1]).first, let hostID = UUID(uuidString: host.hostKey) else { return nil }
            return "group:" + FleetID.make(hostID, "group/" + parts[2])
        default:
            return nil
        }
    }

    /// `<host>/<profile>` (a `FleetID`) as `<computer>/<profile>`.
    static func portableBot(fleetID: String, names: Names) -> String? {
        guard let pair = split(fleetID), isName(pair.rest), let hostID = UUID(uuidString: pair.first),
              let computer = names.computer(hostKey: hostID.uuidString) else { return nil }
        return computer + "/" + pair.rest
    }

    /// `FleetGroup.id` (`<host>/group/<room>`) as its host key and room.
    private static func fleetGroup(_ id: String) -> (host: String, room: String)? {
        let parts = id.split(separator: "/", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[1] == "group", let host = UUID(uuidString: parts[0]), isName(parts[2]) else { return nil }
        return (host.uuidString, parts[2])
    }

    private static func split(_ value: String) -> (first: String, rest: String)? {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, isName(parts[1]) else { return nil }
        return (parts[0], parts[1])
    }

    /// A profile or room ID: short, one line.
    private static func isName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// `placed` in its order, with the items it can't hold (`unnamed`) kept after the item they followed.
    static func keepingUnnamed(_ old: [String], placed: [String], unnamed: (String) -> Bool) -> [String] {
        var result = placed
        var seen = Set(placed)
        var anchor: String?
        for item in old {
            if unnamed(item), seen.insert(item).inserted {
                let index = anchor.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
                result.insert(item, at: index)
            }
            if seen.contains(item) { anchor = item }
        }
        return result
    }

    // MARK: Values

    private static func list(_ items: [String]) -> BighelpJSONValue {
        var seen = Set<String>()
        return .array(items.filter { seen.insert($0).inserted }.prefix(maximumListItems).map(BighelpJSONValue.string))
    }

    private static func strings(_ value: BighelpJSONValue?) -> [String] {
        (value?.array ?? []).prefix(maximumListItems).compactMap(\.string)
    }

    private static func json<T: Encodable>(_ value: T) -> BighelpJSONValue? {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(BighelpJSONValue.self, from: $0) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: BighelpJSONValue) -> T? {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

private extension String {
    func stripping(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
