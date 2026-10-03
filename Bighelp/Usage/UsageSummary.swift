import Foundation

/// Cost and tokens together; tokens are uncached input plus output.
struct UsageAmount: Equatable, Sendable {
    var cost: Double
    var tokens: Int

    static let zero = UsageAmount(cost: 0, tokens: 0)

    static func + (lhs: UsageAmount, rhs: UsageAmount) -> UsageAmount {
        UsageAmount(cost: lhs.cost + rhs.cost, tokens: lhs.tokens + rhs.tokens)
    }

    static func += (lhs: inout UsageAmount, rhs: UsageAmount) { lhs = lhs + rhs }

    func value(_ metric: UsageMetric) -> Double { metric == .cost ? cost : Double(tokens) }
}

enum UsageRange: Int, CaseIterable, Identifiable, Sendable {
    case week = 7, month = 30, quarter = 90

    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String { "\(rawValue) days" }
}

enum UsageMetric: String, CaseIterable, Identifiable, Sendable {
    case cost, tokens

    var id: String { rawValue }
    var title: String { self == .cost ? "Cost" : "Tokens" }
}

/// The Usage page's numbers: every agent on every computer read, added up per
/// day, per model, per agent and per computer. Built from what the hosts
/// reported and nothing else.
struct UsageSummary: Equatable, Sendable {
    struct Point: Equatable, Sendable, Identifiable {
        let date: Date
        let day: String
        var amount: UsageAmount
        var sessions: Int
        var id: String { day }
    }

    struct Row: Equatable, Sendable, Identifiable {
        enum Kind: Equatable, Sendable { case model, agent, host }

        let id: String
        let kind: Kind
        let title: String
        /// The computer an agent is on (with several), or a model's provider.
        var detail: String?
        var amount = UsageAmount.zero
        var sessions = 0
        /// Cached input as a share of all input; nil when the host didn't say.
        var cacheShare: Double?
        /// Why this computer's numbers are missing.
        var failure: String?
        fileprivate var input = 0
        fileprivate var cacheRead: Int?
    }

    struct Totals: Equatable, Sendable {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var cost = 0.0
        /// What providers themselves reported charging (OpenRouter does).
        var billedCost = 0.0
        var sessions = 0
        var apiCalls = 0
        /// Only when every agent's plugin reported them.
        var messages: Int?
        var activeDays = 0

        var processedTokens: Int { inputTokens + outputTokens }
        var cacheShare: Double? {
            let all = inputTokens + cacheReadTokens
            return all > 0 ? Double(cacheReadTokens) / Double(all) : nil
        }
        var tokensPerActiveDay: Int? { activeDays > 0 ? processedTokens / activeDays : nil }
    }

    let points: [Point]
    let totals: Totals
    /// Sessions started on each weekday, Monday first.
    let weekdays: [Int]
    /// Sessions started in each hour, midnight first; nil unless every agent's plugin reported them.
    let hours: [Int]?
    /// Some agent's plugin can't report hours yet.
    let hoursNeedPlugin: Bool
    let models: [Row]
    let agents: [Row]
    let hosts: [Row]
    let isMultiHost: Bool
    private let daily: [String: [String: UsageAmount]]
    private let providerUse: [String: [String: UsageAmount]]

    init(hosts usage: [HostUsage], days: Int, today: Date = .now, calendar: Calendar = .current) {
        let reports = usage.flatMap { host in host.agents.map { (host, $0) } }
        isMultiHost = usage.count > 1

        // Days: the whole range, oldest first, and any day the host reported outside it.
        var byDay: [String: (amount: UsageAmount, sessions: Int)] = [:]
        var totals = Totals()
        for (_, agent) in reports {
            for day in agent.report.days {
                var entry = byDay[day.day] ?? (.zero, 0)
                entry.amount += UsageAmount(cost: day.estimatedCost, tokens: day.inputTokens + day.outputTokens)
                entry.sessions += day.sessions
                byDay[day.day] = entry
            }
            let total = agent.report.totals
            totals.inputTokens += total.inputTokens
            totals.outputTokens += total.outputTokens
            totals.cacheReadTokens += total.cacheReadTokens
            totals.cost += total.estimatedCost
            totals.billedCost += total.actualCost
            totals.sessions += total.sessions
            totals.apiCalls += total.apiCalls
        }
        totals.activeDays = byDay.values.filter { $0.amount.tokens > 0 || $0.sessions > 0 }.count
        points = Self.points(byDay: byDay, days: days, today: today, calendar: calendar)

        var weekdays = Array(repeating: 0, count: 7)
        for point in points {
            let weekday = calendar.component(.weekday, from: point.date) // 1 is Sunday
            weekdays[(weekday + 5) % 7] += point.sessions
        }
        self.weekdays = weekdays

        let activities = reports.map(\.1.report.activity)
        let everyHour = !reports.isEmpty && activities.allSatisfy { $0?.hours != nil }
        hours = everyHour ? activities.reduce(into: Array(repeating: 0, count: 24)) { sum, activity in
            for (hour, count) in (activity?.hours ?? []).enumerated() { sum[hour] += count }
        } : nil
        hoursNeedPlugin = !reports.isEmpty && !everyHour
        if !reports.isEmpty, activities.allSatisfy({ $0?.messages != nil }) {
            totals.messages = activities.reduce(0) { $0 + ($1?.messages ?? 0) }
        }
        self.totals = totals

        // Rows, with what each reported per day so one can be charted.
        var daily: [String: [String: UsageAmount]] = [:]
        var agents: [Row] = []
        var hostRows: [Row] = []
        var models: [String: Row] = [:]
        var providerUse: [String: [String: UsageAmount]] = [:]
        let modelDaysKnown = !reports.isEmpty && activities.allSatisfy { $0?.modelDays != nil }
        for host in usage {
            var hostRow = Row(id: "host:\(host.id)", kind: .host, title: host.name, failure: host.failure)
            if host.failure == nil, !host.unreadAgents.isEmpty {
                hostRow.failure = host.unreadAgents.count == 1
                    ? "\(host.unreadAgents[0])'s usage couldn't be read."
                    : "\(host.unreadAgents.count) agents' usage couldn't be read."
            }
            for agent in host.agents {
                let report = agent.report
                var row = Row(id: "agent:\(host.id)/\(agent.id)", kind: .agent, title: agent.name,
                              detail: isMultiHost ? host.name : nil)
                for day in report.days {
                    let amount = UsageAmount(cost: day.estimatedCost, tokens: day.inputTokens + day.outputTokens)
                    daily[row.id, default: [:]][day.day, default: .zero] += amount
                    daily[hostRow.id, default: [:]][day.day, default: .zero] += amount
                }
                row.amount = UsageAmount(cost: report.totals.estimatedCost,
                                         tokens: report.totals.inputTokens + report.totals.outputTokens)
                row.sessions = report.totals.sessions
                row.input = report.totals.inputTokens
                row.cacheRead = report.totals.cacheReadTokens
                row.cacheShare = Self.share(cacheRead: row.cacheRead, input: row.input)
                hostRow.amount += row.amount
                hostRow.sessions += row.sessions
                agents.append(row)

                for model in report.models {
                    let id = "model:\(model.name)"
                    var modelRow = models[id] ?? Row(id: id, kind: .model, title: model.name, detail: model.provider)
                    if modelRow.detail == nil { modelRow.detail = model.provider }
                    let amount = UsageAmount(cost: model.estimatedCost, tokens: model.inputTokens + model.outputTokens)
                    modelRow.amount += amount
                    modelRow.sessions += model.sessions
                    modelRow.input += model.inputTokens
                    if let cache = model.cacheReadTokens { modelRow.cacheRead = (modelRow.cacheRead ?? 0) + cache }
                    models[id] = modelRow
                    if let provider = model.provider {
                        providerUse[host.id, default: [:]][UsageProviderFamily.key(provider), default: .zero] += amount
                    }
                }
                if modelDaysKnown {
                    for modelDay in report.activity?.modelDays ?? [] {
                        daily["model:\(modelDay.model)", default: [:]][modelDay.day, default: .zero]
                            += UsageAmount(cost: modelDay.cost, tokens: modelDay.tokens)
                    }
                }
            }
            hostRows.append(hostRow)
        }
        func ranked(_ rows: [Row]) -> [Row] {
            rows.sorted { ($0.amount.cost, $0.amount.tokens) > ($1.amount.cost, $1.amount.tokens) }
        }
        self.agents = ranked(agents)
        self.models = ranked(models.values.map { row in
            var row = row
            row.cacheShare = Self.share(cacheRead: row.cacheRead, input: row.input)
            return row
        })
        self.hosts = hostRows
        // A model is charted only when every agent said what it used per day.
        self.daily = modelDaysKnown ? daily : daily.filter { !$0.key.hasPrefix("model:") }
        self.providerUse = providerUse
    }

    /// One row's amounts on each of `points`' days; nil when the host didn't
    /// report that row per day.
    func series(for rowID: String) -> [UsageAmount]? {
        guard let days = daily[rowID] else { return nil }
        return points.map { days[$0.day] ?? .zero }
    }

    func row(_ id: String) -> Row? {
        models.first { $0.id == id } ?? agents.first { $0.id == id } ?? hosts.first { $0.id == id }
    }

    /// What one computer's agents used through a provider's plan or key, by the
    /// provider Hermes billed. Nil when they didn't use it.
    func agentsUse(of provider: ProviderUsage, hostID: String) -> UsageAmount? {
        let amount = providerUse[hostID]?[UsageProviderFamily.key(provider.id, name: provider.name)]
        guard let amount, amount.tokens > 0 || amount.cost > 0 else { return nil }
        return amount
    }

    private static func share(cacheRead: Int?, input: Int) -> Double? {
        guard let cacheRead, cacheRead + input > 0 else { return nil }
        return Double(cacheRead) / Double(cacheRead + input)
    }

    private static func points(byDay: [String: (amount: UsageAmount, sessions: Int)], days: Int,
                               today: Date, calendar: Calendar) -> [Point] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let end = calendar.startOfDay(for: today)
        var start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: end) ?? end
        var last = end
        // Hermes' cutoff is "days × 24 hours ago", so the oldest day can be partly in.
        for key in byDay.keys {
            guard let date = formatter.date(from: key) else { continue }
            if date < start, let earliest = calendar.date(byAdding: .day, value: -1, to: start), date >= earliest {
                start = date
            }
            if date > last, let latest = calendar.date(byAdding: .day, value: 1, to: end), date <= latest { last = date }
        }
        var result: [Point] = []
        var date = start
        while date <= last, result.count < 400 {
            let key = formatter.string(from: date)
            result.append(Point(date: date, day: key, amount: byDay[key]?.amount ?? .zero,
                                sessions: byDay[key]?.sessions ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return result
    }
}

/// Which plan a model's usage counts against: the plugin's provider ids
/// (`claude`, `codex-hermes`) and Hermes' billing providers (`anthropic`,
/// `openai-codex`) meet at their brand. A Claude plan pays for Anthropic models.
enum UsageProviderFamily {
    static func key(_ id: String, name: String = "") -> String {
        let base = ProviderUsagePresentation.logoProviderID(id.lowercased())
        switch AIProviderBrandRegistry.resolve(id: base, name: name) {
        case .anthropic, .claude: return "anthropic"
        case .custom: return base.filter { $0.isLetter || $0.isNumber }
        case let brand: return String(describing: brand)
        }
    }
}

/// Numbers the way the page shows them.
enum UsageFormat {
    static func money(_ value: Double) -> String {
        if value <= 0 { return "$0" }
        if value < 0.01 { return "<$0.01" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// The chart's top line: "$53", "$0.85".
    static func axisMoney(_ value: Double) -> String {
        value >= 10 ? value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
            : value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    static func count(_ value: Int) -> String { value.formatted(.number) }

    /// "281M", "1.5M", "13K".
    static func short(_ value: Int) -> String {
        let number = Double(value)
        for (limit, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where number >= limit {
            let scaled = number / limit
            if suffix == "K" || scaled >= 100 { return "\(Int(scaled.rounded()))\(suffix)" }
            return scaled.formatted(.number.precision(.fractionLength(0...1))) + suffix
        }
        return "\(value)"
    }

    static func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    static func value(_ amount: UsageAmount, _ metric: UsageMetric) -> String {
        metric == .cost ? money(amount.cost) : count(amount.tokens)
    }
}
