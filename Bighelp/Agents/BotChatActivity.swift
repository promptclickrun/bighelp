import Foundation
import Observation
import SwiftUI

/// What an agent's Bot Chat is doing, as its computer says. Unknown is nil, never `.idle`:
/// a screen shows nothing rather than a guess.
enum BotChatActivity: Equatable, Sendable {
    case idle
    /// On a turn; the Hermes tool it's running, when the host names one.
    case working(tool: String?)
    /// Waiting on the person: an approval or a question. It wins over working.
    case waiting

    var isBusy: Bool { self != .idle }

    /// The kind of work, for the face's pose and badge.
    var activityKind: AgentActivityKind {
        switch self {
        case .idle: .idle
        case .waiting: .waiting
        case .working(let tool?): AgentActivityKind(toolName: tool)
        case .working(nil): .thinking
        }
    }

    var liveState: AgentLiveState {
        switch self {
        case .idle: .idle
        case .working: .thinking
        case .waiting: .nudge
        }
    }

    /// The short line a row shows in place of the latest message.
    var line: String? {
        switch self {
        case .idle: nil
        case .waiting: "Needs you"
        case .working(let tool?): AgentActivityKind(toolName: tool).label + "…"
        case .working(nil): "Working…"
        }
    }

    /// What VoiceOver says after the bot's name.
    var accessibilityLabel: String? {
        switch self {
        case .idle: nil
        case .waiting: "Needs you"
        case .working(let tool?): AgentActivityKind(toolName: tool).label
        case .working(nil): "Working"
        }
    }

    /// Two signals for one bot: needing the person wins, then working, then idle; unknown gives way.
    static func merged(_ first: BotChatActivity?, _ second: BotChatActivity?) -> BotChatActivity? {
        switch (first, second) {
        case (.waiting?, _), (_, .waiting?): .waiting
        case (.working?, _): first
        case (_, .working?): second
        case (.idle?, _), (_, .idle?): .idle
        default: nil
        }
    }
}

extension FleetActivity {
    /// An all-hosts copy's state, for a bot on another gateway.
    var botChatActivity: BotChatActivity {
        switch self {
        case .working: .working(tool: nil)
        case .waiting: .waiting
        }
    }
}

/// Reads every agent's Bot Chat state on the gateway in use in one request.
@MainActor
protocol BotChatActivityReading: AnyObject {
    /// By profile ID, the agents the host answered for; an agent it left out is unknown.
    /// Nil when the host can't say (an older plugin, no connection, a failed read).
    func activity(agentIDs: [String]) async -> [String: BotChatActivity]?
}

/// Where the store reads from, given by the screen that shows it.
@MainActor
struct BotChatActivitySource {
    /// The gateway in use, while it's connected.
    struct Live {
        /// The computer and sign-in (`WorkspaceOwner.cacheScopeID`). A late answer for another is dropped.
        let scope: String
        /// Changes when the person signs in again; an answer from before is dropped.
        let signIn: WorkspaceSignIn?
        let agentIDs: [String]
        /// The plugin's batched route; nil when the host doesn't list it (an older plugin).
        let reader: (any BotChatActivityReading)?
        /// Without the route: what stock Hermes tells the app (its Bot Chats it knows to be running).
        let fallback: @MainActor () -> [String: BotChatActivity]
    }

    var live: @MainActor () -> Live?
    /// Multi-gateway: the other gateways' bots from their all-hosts copies, by `FleetID`. Only fresh
    /// copies: an old one says nothing.
    var others: @MainActor () -> [String: BotChatActivity] = { [:] }
    /// Multi-gateway: reads again the copies older than a minute (`FleetStore.refresh`), so the other
    /// gateways stay current while the home shows.
    var refreshOthers: @MainActor () -> Void = {}
}

/// The signals the store uses when the plugin's route can't answer.
@MainActor
enum BotChatActivitySignals {
    /// The gateway in use without the route: the Bot Chats the app knows to be running.
    static func botChats(_ records: [SessionRecord]) -> [String: BotChatActivity] {
        var result: [String: BotChatActivity] = [:]
        for record in records where record.isBotChat && record.isActive { result[record.agentIDs[0]] = .working(tool: nil) }
        return result
    }

    /// Every gateway's bots from its all-hosts copy, by `FleetID`, while that copy is fresh: its Bot
    /// Chat where its plugin said, else what Hermes said of its chats. An older copy says nothing.
    static func fleet(_ snapshots: [UUID: FleetSnapshot], now: Date,
                      freshness: TimeInterval = FleetStore.freshness) -> [String: BotChatActivity] {
        var result: [String: BotChatActivity] = [:]
        for snapshot in snapshots.values {
            let age = now.timeIntervalSince(snapshot.refreshedAt)
            guard age >= -freshness, age < freshness else { continue }
            for agent in snapshot.agents {
                result[agent.id] = agent.botChat?.activity ?? agent.activity?.botChatActivity ?? .idle
            }
        }
        return result
    }
}

/// Each bot's Bot Chat state, for Bots mode and the Agents screen. While a screen that shows
/// it is open and the app is active, it reads the gateway in use once per tick, in one request,
/// quicker while something works; nothing runs otherwise, and what's shown is cleared then, since
/// it would go stale. Each bot's state is observed on its own, so a row redraws only when its own
/// state changes.
@MainActor
@Observable
final class BotChatActivityStore {
    @MainActor
    @Observable
    final class Cell {
        fileprivate(set) var value: BotChatActivity?
    }

    /// The route takes at most this many agents in one request.
    nonisolated static let maximumAgents = 64
    static let busyInterval: Duration = .seconds(3)
    static let idleInterval: Duration = .seconds(6)
    static let othersRefreshInterval: Duration = .seconds(FleetStore.freshness)

    /// Bumps when a bot gets its first state, so a row that found none reads again.
    private var generation = 0
    @ObservationIgnored private var cells: [String: Cell] = [:]
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var source: BotChatActivitySource?
    @ObservationIgnored private(set) var liveScope: String?
    @ObservationIgnored private var lastOthersRefresh: ContinuousClock.Instant?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    /// A bot on the gateway in use, by profile ID.
    nonisolated static func liveKey(_ profileID: String) -> String { "live|" + profileID }

    /// A bot on the gateway in use by profile ID, or on another gateway by its `FleetID`.
    func activity(_ key: String) -> BotChatActivity? {
        // A bot gets its cell on the first read; until then its row waits on the generation.
        _ = generation
        return cells[key]?.value
    }

    /// The gateway in use's bots that are busy, by profile ID (the Agents screen).
    func liveActivities() -> [String: BotChatActivity] {
        _ = generation
        var result: [String: BotChatActivity] = [:]
        for (key, cell) in cells where key.hasPrefix("live|") {
            if let value = cell.value, value.isBusy { result[String(key.dropFirst(5))] = value }
        }
        return result
    }

    /// Keeps the states current while the calling screen shows them: call it from the screen's
    /// `.task` while it's on screen and the app is active. Returns when that task is cancelled.
    func watch(_ source: BotChatActivitySource) async {
        use(source)
        viewers += 1
        if loop == nil { loop = Task { [weak self] in await self?.run() } }
        // Until the screen goes: a never-ending wait that ends with the task.
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3_600)) }
        viewers -= 1
        guard viewers == 0 else { return }
        loop?.cancel()
        loop = nil
        self.source = nil
        clear { _ in true }
    }

    /// Where the next tick reads from: the screen shown last's source.
    func use(_ source: BotChatActivitySource) { self.source = source }

    private func run() async {
        while !Task.isCancelled {
            let busy = await tick()
            guard !Task.isCancelled else { return }
            try? await sleep(busy ? Self.busyInterval : Self.idleInterval)
        }
    }

    /// One read. True when a bot is working or needs the person.
    @discardableResult
    func tick() async -> Bool {
        guard let source else { return false }
        var values: [String: BotChatActivity] = [:]
        if let current = source.live() {
            if current.scope != liveScope {
                clear { $0.hasPrefix("live|") }
                liveScope = current.scope
            }
            let ids = Array(current.agentIDs.prefix(Self.maximumAgents))
            if let reader = current.reader {
                let answer = await reader.activity(agentIDs: ids)
                guard !Task.isCancelled, let now = self.source?.live() else { return false }
                // Another computer or sign-in since it was asked: the answer isn't for what's on screen.
                guard now.scope == current.scope, now.signIn == current.signIn else { return true }
                // An agent the host left out, or a failed read, is unknown: it shows nothing.
                for id in ids { if let value = answer?[id] { values[Self.liveKey(id)] = value } }
            } else {
                let busy = current.fallback()
                for id in ids { values[Self.liveKey(id)] = busy[id] ?? .idle }
            }
        } else if liveScope != nil {
            liveScope = nil
        }
        // Other gateways' copies are read again at most once a minute, however often this ticks.
        let now = ContinuousClock.now
        if lastOthersRefresh.map({ now - $0 >= Self.othersRefreshInterval }) ?? true {
            lastOthersRefresh = now
            source.refreshOthers()
        }
        for (key, value) in source.others() where !key.hasPrefix("live|") { values[key] = value }
        var added = false
        for (key, cell) in cells where values[key] == nil && cell.value != nil { cell.value = nil }
        for (key, value) in values {
            if let cell = cells[key] {
                if cell.value != value { cell.value = value }
            } else {
                let cell = Cell()
                cell.value = value
                cells[key] = cell
                added = true
            }
        }
        // Bounded: bots no longer shown anywhere go once there are many.
        if cells.count > Self.maximumCells {
            cells = cells.filter { $0.value.value != nil }
            added = true
        }
        if added { generation &+= 1 }
        return values.values.contains(where: \.isBusy)
    }

    static let maximumCells = 512

    private func clear(_ matching: (String) -> Bool) {
        for (key, cell) in cells where matching(key) && cell.value != nil { cell.value = nil }
    }
}

/// Keeps a store current while its screen is on screen and the app is active; nothing runs otherwise.
private struct BotChatActivityUpdates: ViewModifier {
    let store: BotChatActivityStore?
    let source: BotChatActivitySource?
    let isActive: Bool

    func body(content: Content) -> some View {
        content.task(id: store != nil && source != nil && isActive) {
            guard isActive, let store, let source else { return }
            await store.watch(source)
        }
    }
}

extension View {
    func botChatActivityUpdates(_ store: BotChatActivityStore?, source: BotChatActivitySource?,
                                isActive: Bool) -> some View {
        modifier(BotChatActivityUpdates(store: store, source: source, isActive: isActive))
    }
}
