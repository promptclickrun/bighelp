import Foundation
import Testing
@testable import Bighelp

/// The Usage page's numbers: Hermes' own analytics (`/api/analytics/usage` and
/// `/api/analytics/models` per agent, plus the plugin's activity), read leniently,
/// then combined across agents and computers. Every number here is made up.
@MainActor
struct UsageSummaryTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Oct 3, 2026, midday UTC: a Saturday.
    private static let today = Date(timeIntervalSince1970: 1_791_028_800)

    private static func day(_ day: String, input: Int, output: Int, cache: Int = 0, cost: Double,
                            sessions: Int, calls: Int = 0) -> BighelpJSONValue {
        .object([
            "day": .string(day), "input_tokens": .integer(input), "output_tokens": .integer(output),
            "cache_read_tokens": .integer(cache), "reasoning_tokens": .integer(0),
            "estimated_cost": .number(cost), "actual_cost": .integer(0),
            "sessions": .integer(sessions), "api_calls": .integer(calls),
        ])
    }

    private static func usage(_ days: [BighelpJSONValue], models: [(String, Int, Int, Double, Int)] = [],
                              totals: [String: BighelpJSONValue]? = nil, period: Int = 7) -> [String: BighelpJSONValue] {
        var payload: [String: BighelpJSONValue] = [
            "daily": .array(days),
            "by_model": .array(models.map { name, input, output, cost, sessions in
                .object(["model": .string(name), "input_tokens": .integer(input), "output_tokens": .integer(output),
                         "estimated_cost": .number(cost), "sessions": .integer(sessions), "api_calls": .integer(0)])
            }),
            "period_days": .integer(period),
            "skills": .object([:]), "tools": .array([]),
        ]
        if let totals { payload["totals"] = .object(totals) }
        return payload
    }

    private static func report(_ days: [BighelpJSONValue], models: [(String, Int, Int, Double, Int)] = [],
                               modelsRoute: [String: BighelpJSONValue]? = nil,
                               activity: [String: BighelpJSONValue]? = nil) throws -> HermesUsageReport {
        try HermesUsageReport(usage: usage(days, models: models), models: modelsRoute, activity: activity)
    }

    // MARK: Reading Hermes

    @Test func readsHermesAnalyticsLeniently() throws {
        let usage = Self.usage([
            Self.day("2026-10-01", input: 1_000, output: 200, cache: 9_000, cost: 1.25, sessions: 2, calls: 5),
            // SUM() over nothing is null; a newer Hermes may add keys.
            .object(["day": .string("2026-10-02"), "input_tokens": .null, "output_tokens": .integer(50),
                     "estimated_cost": .null, "sessions": .integer(1), "something_new": .string("ignored")]),
            .object(["day": .string("not a day"), "input_tokens": .integer(99)]),
            .string("not a row"),
        ], models: [("claude-opus-5-5", 800, 150, 1.0, 2)],
           totals: ["total_input": .integer(1_000), "total_output": .integer(250), "total_estimated_cost": .number(1.25),
                    "total_sessions": .integer(3)])
        let report = try HermesUsageReport(usage: usage, models: nil, activity: nil)

        #expect(report.days.map(\.day) == ["2026-10-01", "2026-10-02"], "Rows without a day are skipped")
        #expect(report.days[1].inputTokens == 0 && report.days[1].estimatedCost == 0, "Nulls read as nothing used")
        #expect(report.totals.inputTokens == 1_000 && report.totals.outputTokens == 250)
        #expect(report.totals.cacheReadTokens == 9_000, "A total the host left out is added up from its days")
        #expect(report.totals.apiCalls == 5)
        #expect(report.models.map(\.name) == ["claude-opus-5-5"])
        #expect(report.models[0].provider == nil && report.models[0].cacheReadTokens == nil,
                "The usage route's models carry no provider or cache")
        #expect(report.activity == nil)
        #expect(throws: WorkspaceClientError.self) { try HermesUsageReport(usage: ["nothing": .null], models: nil, activity: nil) }
    }

    @Test func theModelsRouteAddsProvidersAndCacheReads() throws {
        let models: [String: BighelpJSONValue] = [
            "models": .array([
                .object(["model": .string("claude-opus-5-5"), "provider": .string("anthropic"),
                         "input_tokens": .integer(800), "output_tokens": .integer(150), "cache_read_tokens": .integer(7_200),
                         "estimated_cost": .number(1.0), "actual_cost": .integer(0), "sessions": .integer(2),
                         "capabilities": .object(["supports_tools": .boolean(true)])]),
                .object(["model": .string(""), "input_tokens": .integer(1)]),
            ]),
            "totals": .object([:]), "period_days": .integer(7),
        ]
        let report = try Self.report([Self.day("2026-10-01", input: 800, output: 150, cost: 1, sessions: 2)],
                                     models: [("claude-opus-5-5", 800, 150, 1.0, 2)], modelsRoute: models)
        #expect(report.models.count == 1, "A model without a name is skipped")
        #expect(report.models[0].provider == "anthropic")
        #expect(report.models[0].cacheReadTokens == 7_200)
    }

    @Test func pluginActivityNeedsAllTwentyFourHours() throws {
        var hours = Array(repeating: BighelpJSONValue.integer(0), count: 24)
        hours[20] = .integer(6)
        let activity: [String: BighelpJSONValue] = [
            "hours": .array(hours), "messages": .integer(48),
            "modelDays": .array([
                .object(["day": .string("2026-10-01"), "model": .string("claude-opus-5-5"),
                         "tokens": .integer(950), "cost": .number(1.0)]),
                .object(["day": .string("bad"), "model": .string("x"), "tokens": .integer(1)]),
            ]),
        ]
        let report = try Self.report([Self.day("2026-10-01", input: 800, output: 150, cost: 1, sessions: 2)],
                                     activity: activity)
        #expect(report.activity?.hours?[20] == 6)
        #expect(report.activity?.messages == 48)
        #expect(report.activity?.modelDays?.count == 1)

        var cut = activity
        cut["truncated"] = .boolean(true)
        let truncated = try Self.report([], activity: cut)
        #expect(truncated.activity?.modelDays == nil, "A cut list would chart a model short")
        #expect(truncated.activity?.hours?[20] == 6, "Hours still count")

        let short = try Self.report([], activity: ["hours": .array([.integer(1)])])
        #expect(short.activity?.hours == nil, "A partial day of hours is left out, not padded")
    }

    // MARK: Combining

    /// Home has two agents, Studio one, Office couldn't be reached.
    private func fleet() throws -> [HostUsage] {
        let opusModels: [String: BighelpJSONValue] = ["models": .array([
            .object(["model": .string("claude-opus-5-5"), "provider": .string("anthropic"),
                     "input_tokens": .integer(1_000), "output_tokens": .integer(500), "cache_read_tokens": .integer(9_000),
                     "estimated_cost": .number(4.0), "sessions": .integer(3)]),
        ])]
        let ada = try Self.report([
            Self.day("2026-09-28", input: 600, output: 300, cache: 5_400, cost: 2.5, sessions: 2),
            Self.day("2026-10-03", input: 400, output: 200, cache: 3_600, cost: 1.5, sessions: 1),
        ], modelsRoute: opusModels)
        let bo = try Self.report([
            Self.day("2026-10-02", input: 2_000, output: 1_000, cost: 0, sessions: 4),
        ], models: [("gpt-6-astra", 2_000, 1_000, 0, 4)])
        let studioModels: [String: BighelpJSONValue] = ["models": .array([
            .object(["model": .string("claude-opus-5-5"), "provider": .string("anthropic"),
                     "input_tokens": .integer(300), "output_tokens": .integer(100), "cache_read_tokens": .integer(0),
                     "estimated_cost": .number(1.0), "sessions": .integer(1)]),
        ])]
        let cy = try Self.report([Self.day("2026-10-03", input: 300, output: 100, cost: 1.0, sessions: 1)],
                                 modelsRoute: studioModels)
        return [
            HostUsage(id: "home", name: "Home Hermes", agents: [
                AgentUsage(id: "ada", name: "Ada", report: ada), AgentUsage(id: "bo", name: "Bo", report: bo),
            ]),
            HostUsage(id: "studio", name: "Studio Mac", agents: [AgentUsage(id: "cy", name: "Cy", report: cy)]),
            HostUsage(id: "office", name: "Office Linux", failure: "Couldn't reach this host."),
        ]
    }

    @Test func combinesAgentsAndComputersIntoOneSetOfTotals() throws {
        let summary = UsageSummary(hosts: try fleet(), days: 7, today: Self.today, calendar: Self.calendar)

        #expect(summary.totals.cost == 5.0)
        #expect(summary.totals.inputTokens == 3_300 && summary.totals.outputTokens == 1_600)
        #expect(summary.totals.processedTokens == 4_900, "Uncached input plus output")
        #expect(summary.totals.cacheReadTokens == 9_000)
        #expect(summary.totals.sessions == 8)
        #expect(summary.totals.activeDays == 3)
        #expect(summary.totals.messages == nil, "Messages need every agent's activity")
        let share = try #require(summary.totals.cacheShare)
        #expect(abs(share - 9_000.0 / 12_300.0) < 0.000_1, "Cached input as a share of all input")

        // One bar a day for the range, oldest first, with the days nobody worked at zero.
        #expect(summary.points.count == 7)
        #expect(summary.points.first?.day == "2026-09-27" && summary.points.last?.day == "2026-10-03")
        #expect(summary.points.last?.amount == UsageAmount(cost: 2.5, tokens: 1_000))
        #expect(summary.points[0].amount == .zero)

        #expect(summary.isMultiHost)
        #expect(summary.hosts.map(\.title) == ["Home Hermes", "Studio Mac", "Office Linux"])
        #expect(summary.hosts[0].amount == UsageAmount(cost: 4.0, tokens: 4_500))
        #expect(summary.hosts[2].failure == "Couldn't reach this host.", "A computer that can't be read says so")
        #expect(summary.agents.map(\.title) == ["Ada", "Cy", "Bo"], "Most expensive first")
        #expect(summary.agents.map(\.detail) == ["Home Hermes", "Studio Mac", "Home Hermes"])

        // The same model on two computers is one row.
        let opus = try #require(summary.models.first { $0.title == "claude-opus-5-5" })
        #expect(opus.amount == UsageAmount(cost: 5.0, tokens: 1_900))
        #expect(opus.sessions == 4)
        #expect(summary.models.first { $0.title == "gpt-6-astra" }?.cacheShare == nil,
                "Without the models route there's no cache to show")
    }

    @Test func oneComputerHasNoComputerBreakdown() throws {
        let home = try fleet()[0]
        let summary = UsageSummary(hosts: [home], days: 7, today: Self.today, calendar: Self.calendar)
        #expect(!summary.isMultiHost)
        #expect(summary.agents.map(\.detail) == [nil, nil], "One computer: agents don't repeat its name")
    }

    @Test func weekdaysCountSessionsMondayFirst() throws {
        let summary = UsageSummary(hosts: try fleet(), days: 7, today: Self.today, calendar: Self.calendar)
        // Sep 28 is a Monday (2), Oct 2 a Friday (4), Oct 3 a Saturday (1 + 1).
        #expect(summary.weekdays == [2, 0, 0, 0, 4, 2, 0])
    }

    @Test func hoursShowOnlyWhenEveryAgentReportsThem() throws {
        var hours = Array(repeating: BighelpJSONValue.integer(1), count: 24)
        hours[9] = .integer(5)
        let withHours = try Self.report([Self.day("2026-10-03", input: 10, output: 5, cost: 0.1, sessions: 1)],
                                         activity: ["hours": .array(hours), "messages": .integer(12)])
        let without = try Self.report([Self.day("2026-10-03", input: 10, output: 5, cost: 0.1, sessions: 1)])

        let both = UsageSummary(hosts: [HostUsage(id: "home", name: "Home", agents: [
            AgentUsage(id: "a", name: "A", report: withHours), AgentUsage(id: "b", name: "B", report: withHours),
        ])], days: 7, today: Self.today, calendar: Self.calendar)
        #expect(both.hours?[9] == 10)
        #expect(both.totals.messages == 24)
        #expect(!both.hoursNeedPlugin)

        let mixed = UsageSummary(hosts: [HostUsage(id: "home", name: "Home", agents: [
            AgentUsage(id: "a", name: "A", report: withHours), AgentUsage(id: "b", name: "B", report: without),
        ])], days: 7, today: Self.today, calendar: Self.calendar)
        #expect(mixed.hours == nil, "Half the hours would be wrong, so none show")
        #expect(mixed.hoursNeedPlugin, "and the page asks for the plugin update")
        #expect(mixed.totals.messages == nil)
    }

    @Test func aFocusChartsOnlyWhatTheHostReportedPerDay() throws {
        let summary = UsageSummary(hosts: try fleet(), days: 7, today: Self.today, calendar: Self.calendar)
        let ada = try #require(summary.agents.first { $0.title == "Ada" })
        let series = try #require(summary.series(for: ada.id))
        #expect(series.count == summary.points.count)
        #expect(series.last == UsageAmount(cost: 1.5, tokens: 600))
        let studio = try #require(summary.hosts.first { $0.title == "Studio Mac" })
        #expect(summary.series(for: studio.id)?.last == UsageAmount(cost: 1.0, tokens: 400))
        let opus = try #require(summary.models.first)
        #expect(summary.series(for: opus.id) == nil, "Models chart only with the plugin's model days")
        #expect(summary.series(for: "nothing") == nil)
    }

    @Test func modelDaysFromThePluginChartAModel() throws {
        let activity: [String: BighelpJSONValue] = [
            "hours": .array(Array(repeating: .integer(0), count: 24)),
            "modelDays": .array([
                .object(["day": .string("2026-10-02"), "model": .string("gpt-6-astra"),
                         "tokens": .integer(300), "cost": .number(0.5)]),
            ]),
        ]
        let report = try Self.report([Self.day("2026-10-02", input: 200, output: 100, cost: 0.5, sessions: 1)],
                                     models: [("gpt-6-astra", 200, 100, 0.5, 1)], activity: activity)
        let summary = UsageSummary(hosts: [HostUsage(id: "home", name: "Home", agents: [
            AgentUsage(id: "a", name: "A", report: report)])], days: 7, today: Self.today, calendar: Self.calendar)
        let model = try #require(summary.models.first)
        #expect(summary.series(for: model.id)?[5] == UsageAmount(cost: 0.5, tokens: 300))
    }

    @Test func emptyHostsStillGiveAWholeRangeOfZeroes() {
        let summary = UsageSummary(hosts: [HostUsage(id: "home", name: "Home")], days: 30,
                                   today: Self.today, calendar: Self.calendar)
        #expect(summary.points.count == 30)
        #expect(summary.totals.processedTokens == 0 && summary.totals.cacheShare == nil)
        #expect(summary.totals.tokensPerActiveDay == nil)
        #expect(summary.models.isEmpty && summary.agents.isEmpty)
    }

    // MARK: Plans and limits against Hermes

    @Test func aProviderCardShowsWhatTheAgentsUsedThroughIt() throws {
        let summary = UsageSummary(hosts: try fleet(), days: 7, today: Self.today, calendar: Self.calendar)
        func provider(_ id: String, _ name: String) -> ProviderUsage {
            ProviderUsage(id: id, name: name, status: .ok, message: nil, plan: nil, detectedVia: [],
                          activeInHermes: true, windows: [], facts: [], manageURL: nil, approximate: false)
        }
        // A Claude plan pays for Hermes' anthropic models on that computer only.
        #expect(summary.agentsUse(of: provider("claude", "Claude"), hostID: "home")
                == UsageAmount(cost: 4.0, tokens: 1_500))
        #expect(summary.agentsUse(of: provider("claude", "Claude"), hostID: "studio")
                == UsageAmount(cost: 1.0, tokens: 400))
        #expect(summary.agentsUse(of: provider("openrouter", "OpenRouter"), hostID: "home") == nil,
                "Nothing used through it: no line")
    }

    @Test func formatsNumbersTheWayTheMockupReads() {
        #expect(UsageFormat.money(261.02) == "$261.02")
        #expect(UsageFormat.money(0) == "$0")
        #expect(UsageFormat.money(0.004) == "<$0.01")
        #expect(UsageFormat.short(280_978_097) == "281M")
        #expect(UsageFormat.short(1_515_747) == "1.5M")
        #expect(UsageFormat.short(13_000) == "13K")
        #expect(UsageFormat.short(512) == "512")
        #expect(UsageFormat.percent(0.866) == "87%")
    }
}
