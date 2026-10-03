import Foundation
import Observation

/// Reads every computer the Usage page covers: the one in use, or all of them
/// while All hosts is on. A computer that can't be read comes back with why.
@MainActor
protocol UsageReading: AnyObject {
    func read(days: Int, refresh: Bool) async -> [HostUsage]
}

/// The Usage page: one read per range, kept for five minutes, with what's on
/// screen kept while a refresh runs or fails. One store per app; it starts over
/// for another computer or sign-in.
@MainActor @Observable
final class UsageStore {
    enum State: Equatable {
        case idle, loading, loaded
        case unavailable(String)
    }

    private(set) var state: State = .idle
    private(set) var range: UsageRange = .month
    private(set) var metric: UsageMetric = .cost
    /// The model, agent or computer the chart shows (a `UsageSummary.Row` id).
    var focus: String?
    private(set) var hosts: [HostUsage] = []
    private(set) var summary: UsageSummary?
    private(set) var updatedAt: Date?
    private(set) var isRefreshing = false
    /// Observed, so the menu shows Usage once a computer is connected.
    private(set) var isAvailable = false

    @ObservationIgnored private var reader: (any UsageReading)?
    @ObservationIgnored private var scope: AnyHashable?
    @ObservationIgnored private var cache: [UsageRange: (hosts: [HostUsage], at: Date)] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var choseMetric = false
    @ObservationIgnored private let now: () -> Date
    private static let freshFor: TimeInterval = 5 * 60

    init(now: @escaping () -> Date = { .now }) { self.now = now }

    /// The same scope keeps the reader's results and whatever is on screen.
    func configure(reader: (any UsageReading)?, scope: AnyHashable?) {
        self.reader = reader
        isAvailable = reader != nil
        guard reader == nil || scope != self.scope else { return }
        self.scope = reader == nil ? nil : scope
        generation += 1
        cache = [:]
        hosts = []
        summary = nil
        focus = nil
        updatedAt = nil
        isRefreshing = false
        state = .idle
    }

    func choose(_ metric: UsageMetric) {
        choseMetric = true
        self.metric = metric
    }

    func select(_ range: UsageRange) async {
        guard range != self.range || summary == nil else { return }
        self.range = range
        if let cached = cache[range] {
            show(cached.hosts, at: cached.at)
            if now().timeIntervalSince(cached.at) < Self.freshFor { return }
        }
        await load(refresh: false)
    }

    func load(refresh: Bool) async {
        guard let reader else {
            state = .unavailable("Connect to a computer to see usage.")
            return
        }
        if !refresh, let cached = cache[range], now().timeIntervalSince(cached.at) < Self.freshFor {
            show(cached.hosts, at: cached.at)
            return
        }
        generation += 1
        let current = generation
        let range = range
        if summary == nil { state = .loading }
        isRefreshing = true
        let hosts = await reader.read(days: range.days, refresh: refresh)
        guard current == generation else { return }
        isRefreshing = false
        let readSomething = hosts.contains { !$0.agents.isEmpty }
        if !readSomething, let failure = hosts.lazy.compactMap(\.failure).first {
            // Nothing came back: keep what's on screen, or say why.
            state = .unavailable(summary == nil ? failure : "Couldn't refresh. Showing the last result.")
            return
        }
        let at = now()
        cache[range] = (hosts, at)
        guard range == self.range else { return }
        show(hosts, at: at)
    }

    private func show(_ hosts: [HostUsage], at: Date) {
        self.hosts = hosts
        let summary = UsageSummary(hosts: hosts, days: range.days, today: at)
        self.summary = summary
        updatedAt = at
        state = .loaded
        if let focus, summary.row(focus) == nil { self.focus = nil }
        // Plans and subscriptions report no cost; Tokens has something to show.
        if !choseMetric {
            metric = summary.totals.cost == 0 && summary.totals.processedTokens > 0 ? .tokens : .cost
        }
    }
}
