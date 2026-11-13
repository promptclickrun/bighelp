import Foundation
import Observation

// An agent's background work of the last days, on its Dashboard as Activities, by day:
// the subagents, background commands and, when the person asks, the routines (scheduled task runs)
// the plugin's `agents/today` reports (`native-agents-today-v1`), running ones first. Only what the
// computer says; nothing here starts or stops work.

/// One piece of an agent's background work today.
struct AgentTodayItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case subagent, command, scheduled }
    enum State: String, Sendable { case running, done, failed, stopped, unknown }

    static let feature = "native-agents-today-v1"
    static let maximumItems = 100
    static let maximumTitleLength = 120
    static let maximumDetailLength = 140

    let id: String
    let kind: Kind
    let title: String
    let state: State
    let startedAt: Date?
    let endedAt: Date?
    /// One line from the host: a finished subagent's summary, or why it failed.
    let detail: String?
    /// A `message_agent` message: the agent it went to, as the host names it, and where it is with that
    /// agent. Hermes runs its wait as a background command; this is what that command is for.
    var message: Message?

    struct Message: Equatable, Sendable {
        let agentID: String
        let agentName: String
        /// Nil when the agent asked has no receipt for it (an older plugin, a receipt Hermes cleaned up).
        let state: AgentDelivery.State?
        let toolName: String?
    }

    init(id: String, kind: Kind, title: String, state: State, startedAt: Date? = nil, endedAt: Date? = nil,
         detail: String? = nil, message: Message? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.detail = detail
        self.message = message
    }

    /// Leniently: a row this build can't read is left out, never the whole list. An unknown state
    /// reads as unknown, never as done.
    init?(json value: BighelpJSONValue) {
        guard let row = value.object, let id = row["id"]?.string, !id.isEmpty, id.utf8.count <= 512,
              let kind = row["kind"]?.string.flatMap(Kind.init(rawValue:)),
              let title = row["title"]?.string.flatMap({ Self.oneLine($0, limit: Self.maximumTitleLength) })
        else { return nil }
        self.init(id: id, kind: kind, title: title,
                  state: row["state"]?.string.flatMap(State.init(rawValue:)) ?? .unknown,
                  startedAt: row["startedAt"]?.number.flatMap(Self.date),
                  endedAt: row["endedAt"]?.number.flatMap(Self.date),
                  detail: row["detail"]?.string.flatMap { Self.oneLine($0, limit: Self.maximumDetailLength) },
                  message: Self.message(row))
    }

    private static func message(_ row: [String: BighelpJSONValue]) -> Message? {
        guard let agent = row["agentId"]?.string, AgentTalkIdentity.isProfileID(agent) else { return nil }
        let name = row["agentName"]?.string.flatMap { oneLine($0, limit: 80) } ?? agent
        let delivery = row["delivery"]?.object
        let tool = delivery?["tool"]?.string.flatMap { ChatToolNames.plainName($0) == nil ? nil : $0 }
        return Message(agentID: agent, agentName: name,
                       state: delivery?["state"]?.string.flatMap(AgentDelivery.State.init(rawValue:)), toolName: tool)
    }

    /// The host's list, running first, then newest first; duplicates and unreadable rows left out.
    static func list(_ rows: [BighelpJSONValue]) -> [AgentTodayItem] {
        var seen: Set<String> = []
        let items = rows.prefix(maximumItems).compactMap(AgentTodayItem.init(json:)).filter { seen.insert($0.id).inserted }
        return items.sorted { lhs, rhs in
            if (lhs.state == .running) != (rhs.state == .running) { return lhs.state == .running }
            return (lhs.sortDate ?? .distantPast) > (rhs.sortDate ?? .distantPast)
        }
    }

    private var sortDate: Date? { state == .running ? startedAt : endedAt ?? startedAt }

    private static func oneLine(_ text: String, limit: Int) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let collapsed = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }

    /// Epoch seconds within reason: a bad clock on either side shows no time rather than a wrong one.
    private static func date(_ seconds: Double) -> Date? {
        guard seconds.isFinite, seconds > 1_000_000_000, seconds < 10_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// The Activities section's state for one bot: collapsed until the person opens it, so Feed, Ideas and
/// Goals stay where they were.
@MainActor
@Observable
final class AgentTodayModel {
    enum Phase: Equatable {
        case loading
        case loaded([AgentTodayItem])
        /// The computer's plugin predates the route.
        case unsupported
        case failed
    }

    static let runningInterval: Duration = .seconds(10)
    static let quietInterval: Duration = .seconds(60)
    /// The profile's ⋯ › Show routines: scheduled task runs in Activities. Off by default.
    static let showsRoutinesKey = "bighelp.dashboard.activities.show-routines"
    /// Today and the six days before it.
    static let dayCount = 7

    private(set) var phase: Phase = .loading
    var isExpanded = false
    /// Bumps with each new connection, so the section's reads start over on it.
    private(set) var connection = 0
    /// The board connection, which an item's read-out reads through too.
    @ObservationIgnored private(set) var client: (any AgentBoardClient)?
    @ObservationIgnored private var scope: String?
    /// Plugin 3.47.0 takes at most 48 hours back: it gets today and yesterday.
    @ObservationIgnored private var windowDays = dayCount

    /// The board's connection, which the Dashboard follows. While it reconnects there is none, and
    /// what the section shows stays until the next one answers; another computer starts over.
    func use(_ client: (any AgentBoardClient)?, scope: String) {
        guard let client, client !== self.client else { return }
        self.client = client
        connection &+= 1
        windowDays = Self.dayCount
        if !client.supportsToday {
            phase = .unsupported
        } else if phase == .unsupported || scope != self.scope {
            phase = .loading
        }
        self.scope = scope
    }

    var items: [AgentTodayItem] {
        if case .loaded(let items) = phase { return items }
        return []
    }

    var hasRunning: Bool { items.contains { $0.state == .running } }

    /// One read of the last days' work, from the start of this phone's day six days ago.
    func refresh(agentID: String, now: Date = .now, calendar: Calendar = .current) async {
        guard let client, client.supportsToday else { return }
        let asked = connection
        do {
            let items: [AgentTodayItem]
            do {
                items = try await client.today(agentID: agentID, since: Self.since(days: windowDays, now: now, calendar: calendar))
            } catch WorkspaceClientError.rejected where windowDays > 2 {
                // An older plugin refuses more than 48 hours: today and yesterday, from now on.
                windowDays = 2
                items = try await client.today(agentID: agentID, since: Self.since(days: 2, now: now, calendar: calendar))
            }
            guard asked == connection else { return }
            if phase != .loaded(items) { phase = .loaded(items) }
        } catch is CancellationError {
            return
        } catch {
            guard asked == connection else { return }
            // What it showed stays through a passing failure; only a first read says it failed.
            if case .loaded = phase { return }
            phase = (error as? WorkspaceClientError).map(Self.unsupported) == true ? .unsupported : .failed
        }
    }

    static func since(days: Int, now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: today) ?? today
    }

    /// One day of Activities: "Today", "Yesterday", "Wednesday", "Oct 30".
    struct Day: Identifiable, Equatable {
        let id: Date
        let title: String
        let items: [AgentTodayItem]
    }

    /// The items to show: routines only when the person asked for them.
    static func visible(_ items: [AgentTodayItem], showsRoutines: Bool) -> [AgentTodayItem] {
        showsRoutines ? items : items.filter { $0.kind != .scheduled }
    }

    /// The items by day, newest day first. Running work is today's.
    static func days(_ items: [AgentTodayItem], now: Date = .now, calendar: Calendar = .current) -> [Day] {
        let today = calendar.startOfDay(for: now)
        var byDay: [Date: [AgentTodayItem]] = [:]
        for item in items {
            let when = item.state == .running ? now : (item.endedAt ?? item.startedAt ?? now)
            byDay[calendar.startOfDay(for: when), default: []].append(item)
        }
        return byDay.keys.sorted(by: >).map { day in
            Day(id: day, title: title(for: day, today: today, calendar: calendar), items: byDay[day] ?? [])
        }
    }

    private static func title(for day: Date, today: Date, calendar: Calendar) -> String {
        let back = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch back {
        case ...0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        case 2...6: return day.formatted(.dateTime.weekday(.wide))
        default: return day.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private static func unsupported(_ error: WorkspaceClientError) -> Bool {
        if case .unavailable(.unsupportedOperation) = error { return true }
        if case .unavailable(.pluginRequired) = error { return true }
        return false
    }

    /// The header's short line: "2 running · 4 done today".
    static func summary(_ phase: Phase, showsRoutines: Bool, now: Date = .now, calendar: Calendar = .current) -> String {
        switch phase {
        case .loading: return String(localized: "Loading…")
        case .unsupported: return String(localized: "Update the plugin to see it")
        case .failed: return String(localized: "Couldn't load")
        case .loaded(let all):
            let items = visible(all, showsRoutines: showsRoutines)
            let running = items.count { $0.state == .running }
            let today = items.count { item in
                item.state != .running && calendar.isDate(item.endedAt ?? item.startedAt ?? .distantPast, inSameDayAs: now)
            }
            switch (running, today) {
            case (0, 0): return items.isEmpty ? String(localized: "Nothing yet") : String(localized: "Nothing today")
            case (0, _): return String(localized: "\(today) done today")
            case (_, 0): return String(localized: "\(running) running")
            default: return String(localized: "\(running) running · \(today) done today")
            }
        }
    }
}
