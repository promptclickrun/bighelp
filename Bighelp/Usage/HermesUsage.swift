import Foundation

/// One agent's usage for a period, as its computer's Hermes reports it: the
/// dashboard's `GET /api/analytics/usage` (days, totals), `GET /api/analytics/models`
/// (providers and cache reads per model) and, with the bighelp plugin, its
/// `usage/activity` route (hours of the day, messages, models per day).
///
/// Hermes counts by when a session started, per agent (each profile keeps its own
/// sessions). Hosts differ, so everything is read leniently: an unknown key is
/// ignored, a missing number is nothing used, a missing part hides its row.
struct HermesUsageReport: Equatable, Sendable {
    struct Day: Equatable, Sendable {
        /// The host's calendar day, "2026-10-03".
        let day: String
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var reasoningTokens = 0
        var estimatedCost = 0.0
        var actualCost = 0.0
        var sessions = 0
        var apiCalls = 0
    }

    struct Model: Equatable, Sendable {
        let name: String
        /// Who billed it ("anthropic", "openrouter"); the usage route doesn't say.
        let provider: String?
        var inputTokens = 0
        var outputTokens = 0
        /// Nil when the host didn't report cache reads for it.
        var cacheReadTokens: Int?
        var estimatedCost = 0.0
        var actualCost = 0.0
        var sessions = 0
    }

    struct Totals: Equatable, Sendable {
        var inputTokens = 0
        var outputTokens = 0
        var cacheReadTokens = 0
        var reasoningTokens = 0
        var estimatedCost = 0.0
        var actualCost = 0.0
        var sessions = 0
        var apiCalls = 0
    }

    /// What only the plugin knows (feature `native-usage-activity-v1`).
    struct Activity: Equatable, Sendable {
        struct ModelDay: Equatable, Sendable {
            let day: String
            let model: String
            let tokens: Int
            let cost: Double
        }

        /// Sessions started in each hour of the host's day, midnight first. Nil
        /// unless all 24 came.
        let hours: [Int]?
        let messages: Int?
        /// Nil when the plugin's list was cut short.
        let modelDays: [ModelDay]?
    }

    var days: [Day]
    var models: [Model]
    var totals: Totals
    var activity: Activity?
}

extension HermesUsageReport {
    typealias Object = [String: BighelpJSONValue]

    /// `usage` is required; `models` and `activity` add what they know.
    init(usage: Object, models modelsRoute: Object?, activity: Object?) throws {
        let dailyRows = usage["daily"]?.array
        let totalsRow = usage["totals"]?.object
        guard dailyRows != nil || totalsRow != nil else { throw WorkspaceClientError.invalidResponse }

        let days = (dailyRows ?? []).prefix(800).compactMap { value -> Day? in
            guard let row = value.object, let day = Self.day(row["day"]) else { return nil }
            return Day(day: day,
                       inputTokens: Self.count(row["input_tokens"]), outputTokens: Self.count(row["output_tokens"]),
                       cacheReadTokens: Self.count(row["cache_read_tokens"]),
                       reasoningTokens: Self.count(row["reasoning_tokens"]),
                       estimatedCost: Self.money(row["estimated_cost"]), actualCost: Self.money(row["actual_cost"]),
                       sessions: Self.count(row["sessions"]), apiCalls: Self.count(row["api_calls"]))
        }
        self.days = days

        // A total the host left out is added up from its days.
        func total(_ key: String, _ day: (Day) -> Int) -> Int {
            totalsRow?[key].flatMap(Self.optionalCount) ?? days.reduce(0) { $0 + day($1) }
        }
        func totalMoney(_ key: String, _ day: (Day) -> Double) -> Double {
            totalsRow?[key].flatMap(Self.optionalMoney) ?? days.reduce(0) { $0 + day($1) }
        }
        totals = Totals(
            inputTokens: total("total_input", \.inputTokens), outputTokens: total("total_output", \.outputTokens),
            cacheReadTokens: total("total_cache_read", \.cacheReadTokens),
            reasoningTokens: total("total_reasoning", \.reasoningTokens),
            estimatedCost: totalMoney("total_estimated_cost", \.estimatedCost),
            actualCost: totalMoney("total_actual_cost", \.actualCost),
            sessions: total("total_sessions", \.sessions), apiCalls: total("total_api_calls", \.apiCalls)
        )

        // The models route knows providers and cache reads; the usage route's list is the fallback.
        if let rows = modelsRoute?["models"]?.array {
            models = Self.models(rows, hasDetail: true)
        } else {
            models = Self.models(usage["by_model"]?.array ?? [], hasDetail: false)
        }

        self.activity = activity.map(Self.activity)
    }

    private static func models(_ rows: [BighelpJSONValue], hasDetail: Bool) -> [Model] {
        rows.prefix(200).compactMap { value -> Model? in
            guard let row = value.object, let name = text(row["model"], limit: 160) else { return nil }
            return Model(name: name, provider: hasDetail ? text(row["provider"], limit: 80) : nil,
                         inputTokens: count(row["input_tokens"]), outputTokens: count(row["output_tokens"]),
                         cacheReadTokens: hasDetail ? optionalCount(row["cache_read_tokens"] ?? .null) : nil,
                         estimatedCost: money(row["estimated_cost"]), actualCost: money(row["actual_cost"]),
                         sessions: count(row["sessions"]))
        }
    }

    private static func activity(_ object: Object) -> Activity {
        let hours = object["hours"]?.array.flatMap { values -> [Int]? in
            let counts = values.compactMap(optionalCount)
            return values.count == 24 && counts.count == 24 ? counts : nil
        }
        let modelDays = (object["modelDays"]?.array ?? []).prefix(4_000).compactMap { value -> Activity.ModelDay? in
            guard let row = value.object, let day = day(row["day"]), let model = text(row["model"], limit: 160)
            else { return nil }
            return .init(day: day, model: model, tokens: count(row["tokens"]), cost: money(row["cost"]))
        }
        return Activity(hours: hours, messages: object["messages"].flatMap(optionalCount),
                        modelDays: object["truncated"]?.boolean == true ? nil : modelDays)
    }

    // MARK: Lenient values

    /// "2026-10-03" and nothing else.
    static func day(_ value: BighelpJSONValue?) -> String? {
        guard let text = value?.string, text.utf8.count == 10 else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        return text
    }

    private static func count(_ value: BighelpJSONValue?) -> Int { value.flatMap(optionalCount) ?? 0 }
    private static func money(_ value: BighelpJSONValue?) -> Double { value.flatMap(optionalMoney) ?? 0 }

    /// Whole, non-negative and sane; anything else is unknown.
    private static func optionalCount(_ value: BighelpJSONValue) -> Int? {
        guard let number = value.number, number.isFinite, number >= 0, number < 1e15 else { return nil }
        return Int(number.rounded())
    }

    private static func optionalMoney(_ value: BighelpJSONValue) -> Double? {
        guard let number = value.number, number.isFinite, number >= 0, number < 1e9 else { return nil }
        return number
    }

    private static func text(_ value: BighelpJSONValue?, limit: Int) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }
}

/// One agent's part of a computer's usage.
struct AgentUsage: Equatable, Sendable {
    let id: String
    let name: String
    let report: HermesUsageReport
}

/// Everything read from one computer: its agents' usage and its plans and
/// limits. A computer that couldn't be read says why.
struct HostUsage: Equatable, Sendable {
    enum Limits: Equatable, Sendable {
        case loaded(ProviderUsageReport)
        /// The computer's bighelp plugin predates provider usage.
        case needsPluginUpdate
        case unavailable(String)
    }

    let id: String
    let name: String
    var agents: [AgentUsage] = []
    /// Agents whose usage couldn't be read; the rest still show.
    var unreadAgents: [String] = []
    var failure: String?
    /// Nil for the computer in use: Limits come from `ProviderUsageStore` there.
    var limits: Limits?
}
