import Foundation

/// What the computer in use says about group chats. Only it is asked: a group whose first bot is on
/// another computer is checked there when the shell makes it (`startFleetGroupChat`).
struct NewChatGroupRules: Equatable, Sendable {
    /// The computer in use. A bot without a `hostID` is on it.
    var hostInUse: UUID?
    /// `BotModeRoomStore.offersNewGroupChat` on the computer in use.
    var canMakeGroups: Bool
    /// `HermesBotModeCapabilities.seatableProfiles` on the computer in use. Hermes' older path
    /// doesn't list them and seats any bot: nil.
    var seatableProfiles: [String]? = nil

    func canSeat(_ profileID: String) -> Bool {
        seatableProfiles?.contains(profileID) ?? true
    }
}

/// New chat's To row, as rules: one bot is a chat, two to `BotModeRoom.maximumMembers` a group chat.
/// A group lives on its first bot's computer (as the all-hosts New chat made them); bots on other
/// computers join it through their own computers' RoomLink, as `createGroupChat(with:peers:)` does.
enum NewChatRecipients {
    enum Kind: Equatable, Sendable {
        case nobody, chat, group
    }

    /// Why a pick can't join the bots already in the To row: one plain line under it.
    enum Refusal: Equatable, Sendable {
        case full
        case noGroups
        case cannotSeat(names: [String])

        var message: String {
            switch self {
            case .full:
                String(localized: "A group chat holds up to \(BotModeRoom.maximumMembers) bots.")
            case .noGroups:
                String(localized: "Group chats need a newer Hermes on this computer.")
            case .cannotSeat(let names) where names.count == 1:
                String(localized: "\(names[0]) can’t join group chats on this computer.")
            case .cannotSeat(let names):
                String(localized: "\(ListFormatter.localizedString(byJoining: names)) can’t join group chats on this computer.")
            }
        }
    }

    static func kind(of picked: [SimpleBotsBot]) -> Kind {
        switch picked.count {
        case 0: .nobody
        case 1: .chat
        default: .group
        }
    }

    /// The computer a bot is on.
    static func computer(of bot: SimpleBotsBot, rules: NewChatGroupRules) -> UUID? {
        bot.hostID ?? rules.hostInUse
    }

    /// Why `bot` can't be added to `picked`; nil when it can (a first pick always can, for a chat).
    static func refusal(adding bot: SimpleBotsBot, to picked: [SimpleBotsBot],
                        rules: NewChatGroupRules) -> Refusal? {
        guard let first = picked.first, !picked.contains(where: { $0.id == bot.id }) else { return nil }
        guard picked.count < BotModeRoom.maximumMembers else { return .full }
        let home = computer(of: first, rules: rules)
        guard home == rules.hostInUse else { return nil }
        guard rules.canMakeGroups else { return .noGroups }
        // Hermes seats only its own bots; the others join as peers.
        let unseated = (picked + [bot])
            .filter { computer(of: $0, rules: rules) == home && !rules.canSeat($0.profileID) }
            .map(\.name)
        return unseated.isEmpty ? nil : .cannotSeat(names: unseated)
    }

    /// A tap on a bot in the people list: picked bots go, others join unless refused.
    static func toggling(_ bot: SimpleBotsBot, in picked: [SimpleBotsBot],
                         rules: NewChatGroupRules) -> (picked: [SimpleBotsBot], refusal: Refusal?) {
        if picked.contains(where: { $0.id == bot.id }) { return (removing(bot, from: picked), nil) }
        if let refusal = refusal(adding: bot, to: picked, rules: rules) { return (picked, refusal) }
        return (picked + [bot], nil)
    }

    static func removing(_ bot: SimpleBotsBot, from picked: [SimpleBotsBot]) -> [SimpleBotsBot] {
        picked.filter { $0.id != bot.id }
    }

    /// Whether a row shows as one that can join; a picked bot always can (a tap takes it out).
    static func canJoin(_ bot: SimpleBotsBot, picked: [SimpleBotsBot], rules: NewChatGroupRules) -> Bool {
        refusal(adding: bot, to: picked, rules: rules) == nil
    }

    /// A group's bots on its own computer, and those that join from other computers.
    static func split(_ picked: [SimpleBotsBot],
                      rules: NewChatGroupRules) -> (home: [SimpleBotsBot], peers: [SimpleBotsBot]) {
        guard let first = picked.first else { return ([], []) }
        let home = computer(of: first, rules: rules)
        return (picked.filter { computer(of: $0, rules: rules) == home },
                picked.filter { computer(of: $0, rules: rules) != home })
    }

    /// The bots on other computers, as `createGroupChat(with:peers:)` takes them.
    static func peerCandidates(_ picked: [SimpleBotsBot], rules: NewChatGroupRules,
                               hostName: (UUID) -> String) -> [HermesBotModePeerCandidate] {
        split(picked, rules: rules).peers.compactMap { bot in
            computer(of: bot, rules: rules).map {
                HermesBotModePeerCandidate(hostID: $0.uuidString, hostName: hostName($0),
                                           profileID: bot.profileID, name: bot.name)
            }
        }
    }

    // MARK: The people list

    /// One computer's bots in the people list. `host` is nil for bots on no listed computer.
    struct Section: Identifiable, Equatable {
        let host: FleetHost?
        let bots: [SimpleBotsBot]

        var id: String { host?.id.uuidString ?? "other" }
    }

    /// The bots by computer, in `hosts`' order; bots on a computer that isn't listed come last.
    /// The list shows a header for each only when there are two or more.
    static func sections(_ bots: [SimpleBotsBot], hosts: [FleetHost], rules: NewChatGroupRules) -> [Section] {
        let listed = Set(hosts.map(\.id))
        var byHost: [UUID: [SimpleBotsBot]] = [:]
        var other: [SimpleBotsBot] = []
        for bot in bots {
            if let host = computer(of: bot, rules: rules), listed.contains(host) {
                byHost[host, default: []].append(bot)
            } else {
                other.append(bot)
            }
        }
        var result = hosts.compactMap { host in byHost[host.id].map { Section(host: host, bots: $0) } }
        if !other.isEmpty { result.append(Section(host: nil, bots: other)) }
        return result
    }

    /// The To row's field filters by name or role.
    static func matches(_ bot: SimpleBotsBot, query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || bot.name.localizedCaseInsensitiveContains(term)
            || bot.role.localizedCaseInsensitiveContains(term)
    }

    /// Group chats match by their name or a member's.
    static func matches(_ group: SimpleBotsGroup, query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || group.title.localizedCaseInsensitiveContains(term)
            || group.members.contains { $0.name.localizedCaseInsensitiveContains(term) }
    }
}
