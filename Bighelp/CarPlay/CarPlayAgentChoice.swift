import Foundation

/// An agent as CarPlay's picker sees it: a name and whether it's the default.
/// Plain values, so the choice rules are testable without the car.
struct CarPlayAgent: Equatable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool

    init(id: String, name: String, isDefault: Bool) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }

    init(_ profile: AgentProfile) {
        self.init(id: profile.id, name: profile.name, isDefault: profile.isDefault)
    }
}

/// One line in the car's agent list. Names only; never message text.
struct CarPlayAgentRow: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    /// "Current", "Default", both, or nothing.
    let detail: String?
    let isCurrent: Bool
}

enum CarPlayAgentChoice {
    /// Apple lets a CarPlay list show 12 items.
    static let maximumListed = 12

    /// The agent to talk to: the one asked for while it still exists, else the
    /// host's usual choice (`fallbackID`, which honors the primary agent), else
    /// the default. Nil when the host has no agents to pick from.
    static func resolve(requestedID: String?, in agents: [CarPlayAgent], fallbackID: String? = nil) -> CarPlayAgent? {
        if let requestedID, let match = agents.first(where: { $0.id == requestedID }) { return match }
        if let fallbackID, let match = agents.first(where: { $0.id == fallbackID }) { return match }
        return agents.first(where: \.isDefault)
    }

    /// The list for the car, cut to `limit`. The current agent always stays in
    /// it: when the cut would drop it, it takes the last place.
    static func rows(for agents: [CarPlayAgent], currentID: String?, limit: Int = maximumListed) -> [CarPlayAgentRow] {
        let limit = max(1, limit)
        var shown = Array(agents.prefix(limit))
        if let currentID, !shown.contains(where: { $0.id == currentID }),
           let current = agents.first(where: { $0.id == currentID }) {
            shown[shown.count - 1] = current
        }
        return shown.map { agent in
            let isCurrent = agent.id == currentID
            let notes = [isCurrent ? "Current" : nil, agent.isDefault ? "Default" : nil].compactMap { $0 }
            return CarPlayAgentRow(
                id: agent.id, title: agent.name,
                detail: notes.isEmpty ? nil : notes.joined(separator: " · "), isCurrent: isCurrent)
        }
    }
}

/// The agent last picked in the car, saved on this device.
struct CarPlayAgentPreference {
    static let key = "bighelp.carplay.agentID"
    static let maximumIDLength = 128

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var agentID: String? {
        get {
            guard let value = defaults.string(forKey: Self.key) else { return nil }
            return Self.clean(value)
        }
        nonmutating set {
            if let newValue, let clean = Self.clean(newValue) {
                defaults.set(clean, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }

    private static func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.utf8.count > maximumIDLength ? nil : trimmed
    }
}

/// Which chat a car connection is in. Talk after a pause goes on in the same
/// chat with the same agent; a new connection (a new value of this) or another
/// agent starts a new one.
struct CarPlayChatContinuity: Equatable {
    private(set) var sessionID: String?
    private(set) var agentID: String?

    /// The chat to go on in, or nil when `agentID` needs a new one.
    func reusableSessionID(for agentID: String) -> String? {
        self.agentID == agentID ? sessionID : nil
    }

    mutating func remember(sessionID: String, agentID: String) {
        self.sessionID = sessionID
        self.agentID = agentID
    }
}
