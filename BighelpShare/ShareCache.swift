import Foundation

struct ShareAgent: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
}

struct ShareChat: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var title: String
}

/// The agents and their last chats, kept in the app group the notification extension
/// already reads.
///
/// The sheet is opened cold, on whatever network the phone happens to have, so the first
/// screen has to paint before the computer answers. The extension writes this itself after
/// every live read: the app does not have to learn that the share sheet exists for the
/// second share onward to be instant.
struct ShareCache {
    static let suite = "group.app.loopdy.mobile.buzzkit"
    static let maximumAgents = 128
    static let maximumChats = 12

    private static var defaults: UserDefaults? { UserDefaults(suiteName: suite) }

    static func agents() -> [ShareAgent] {
        guard let data = defaults?.data(forKey: "bighelp.share.agents"),
              data.count <= 262_144,
              let agents = try? JSONDecoder().decode([ShareAgent].self, from: data) else { return [] }
        return agents
    }

    static func store(agents: [ShareAgent]) {
        guard agents.count <= maximumAgents, let data = try? JSONEncoder().encode(agents) else { return }
        defaults?.set(data, forKey: "bighelp.share.agents")
    }

    static func chats(for agent: String) -> [ShareChat] {
        guard let data = defaults?.data(forKey: key(agent)), data.count <= 262_144,
              let chats = try? JSONDecoder().decode([ShareChat].self, from: data) else { return [] }
        return chats
    }

    static func store(chats: [ShareChat], for agent: String) {
        guard chats.count <= maximumChats, let data = try? JSONEncoder().encode(chats) else { return }
        defaults?.set(data, forKey: key(agent))
    }

    /// The one that was used last, so a repeat share starts where the last one ended.
    static var lastAgent: String? {
        get { defaults?.string(forKey: "bighelp.share.last-agent") }
        nonmutating set { defaults?.set(newValue, forKey: "bighelp.share.last-agent") }
    }

    private static func key(_ agent: String) -> String {
        "bighelp.share.chats." + agent.prefix(64)
    }
}
