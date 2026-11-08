import Foundation
import Observation

// An agent's background work today, on its Dashboard (Bots mode): the subagents, background
// commands and scheduled task runs the plugin's `agents/today` reports (`native-agents-today-v1`),
// running ones first. Only what the computer says; nothing here starts or stops work.

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

    init(id: String, kind: Kind, title: String, state: State, startedAt: Date? = nil, endedAt: Date? = nil,
         detail: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.detail = detail
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
                  detail: row["detail"]?.string.flatMap { Self.oneLine($0, limit: Self.maximumDetailLength) })
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

/// The Today section's state for one bot: collapsed until the person opens it, so Feed, Ideas and
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

    private(set) var phase: Phase = .loading
    var isExpanded = false
    /// Bumps with each new connection, so the section's reads start over on it.
    private(set) var connection = 0
    @ObservationIgnored private var client: (any AgentBoardClient)?

    /// The board's connection, which the Dashboard follows. While it reconnects there is none, and
    /// what the section shows stays until the next one answers.
    func use(_ client: (any AgentBoardClient)?) {
        guard let client, client !== self.client else { return }
        self.client = client
        connection &+= 1
        if !client.supportsToday { phase = .unsupported } else if phase == .unsupported { phase = .loading }
    }

    var items: [AgentTodayItem] {
        if case .loaded(let items) = phase { return items }
        return []
    }

    var hasRunning: Bool { items.contains { $0.state == .running } }

    /// One read of today's work, from the start of this phone's day.
    func refresh(agentID: String, now: Date = .now, calendar: Calendar = .current) async {
        guard let client, client.supportsToday else { return }
        let asked = connection
        do {
            let items = try await client.today(agentID: agentID, since: calendar.startOfDay(for: now))
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

    private static func unsupported(_ error: WorkspaceClientError) -> Bool {
        if case .unavailable(.unsupportedOperation) = error { return true }
        if case .unavailable(.pluginRequired) = error { return true }
        return false
    }

    /// The header's short line: "2 running · 4 finished".
    static func summary(_ phase: Phase) -> String {
        switch phase {
        case .loading: return String(localized: "Loading…")
        case .unsupported: return String(localized: "Update the plugin to see it")
        case .failed: return String(localized: "Couldn't load")
        case .loaded(let items):
            let running = items.count { $0.state == .running }
            let finished = items.count - running
            switch (running, finished) {
            case (0, 0): return String(localized: "Nothing in the background yet")
            case (0, _): return String(localized: "\(finished) finished")
            case (_, 0): return String(localized: "\(running) running")
            default: return String(localized: "\(running) running · \(finished) finished")
            }
        }
    }
}
