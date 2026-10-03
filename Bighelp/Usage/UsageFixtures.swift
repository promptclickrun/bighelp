import Foundation

/// Made-up usage for the demo and UI tests: a few weeks of agents at work,
/// most of it in the last ten days, on made-up models. Same numbers every run.
@MainActor
final class DemoUsageReader: UsageReading {
    private let hostID: String
    private let hostName: String
    private let agents: @MainActor () -> [(id: String, name: String)]
    private let fleet: FleetStore?

    init(hostID: String, hostName: String, agents: @escaping @MainActor () -> [(id: String, name: String)],
         fleet: FleetStore?) {
        self.hostID = hostID
        self.hostName = hostName
        self.agents = agents
        self.fleet = fleet
    }

    func read(days: Int, refresh: Bool) async -> [HostUsage] {
        let agents = self.agents()
        var hosts = [HostUsage(id: hostID, name: hostName, agents: (agents.isEmpty ? [("default", "Ada")] : agents)
            .prefix(6).enumerated().map { index, agent in
                AgentUsage(id: agent.id, name: agent.name, report: UsageFixtures.report(seed: index, days: days))
            })]
        if let fleet {
            for host in fleet.hosts where host.id.uuidString != hostID {
                hosts.append(await fleet.reader.usage(host.id, name: host.name, days: days, refresh: refresh))
            }
        }
        return hosts
    }
}

enum UsageFixtures {
    private struct Model {
        let name: String
        let provider: String
        /// Dollars per million tokens; zero for a subscription.
        let price: Double
        let cacheShare: Double
    }

    private static let models = [
        Model(name: "claude-opus-5-5", provider: "anthropic", price: 9.5, cacheShare: 0.97),
        Model(name: "claude-sonnet-5", provider: "anthropic", price: 3.1, cacheShare: 0.94),
        Model(name: "openai/gpt-6.1-sol", provider: "openrouter", price: 1.7, cacheShare: 0.9),
        Model(name: "gpt-6-astra", provider: "openai-codex", price: 0, cacheShare: 0.78),
        Model(name: "meta/muse-spark-1.3", provider: "openrouter", price: 0.1, cacheShare: 0.22),
    ]

    /// Each agent leans on its own models.
    private static let mixes: [[Double]] = [
        [0.30, 0.25, 0.10, 0.30, 0.05],
        [0.05, 0.40, 0.15, 0.40, 0.00],
        [0.00, 0.10, 0.30, 0.50, 0.10],
        [0.20, 0.20, 0.00, 0.60, 0.00],
    ]

    private static let hourWeights = [11, 3, 2, 1, 1, 2, 5, 16, 28, 32, 36, 38, 36, 38, 40, 42, 44, 46, 52, 56, 60, 54, 40, 24]

    static func report(seed: Int, days: Int, today: Date = .now, calendar: Calendar = .current) -> HermesUsageReport {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let mix = mixes[seed % mixes.count]
        let scale = [1.0, 0.55, 0.3, 0.2][seed % 4]
        let end = calendar.startOfDay(for: today)

        var dayRows: [HermesUsageReport.Day] = []
        var modelRows = models.map { HermesUsageReport.Model(name: $0.name, provider: $0.provider, cacheReadTokens: 0) }
        var modelDays: [HermesUsageReport.Activity.ModelDay] = []
        var hours = Array(repeating: 0.0, count: 24)
        var messages = 0
        for back in stride(from: days - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -back, to: end) else { continue }
            // Quieter weeks earlier, a busy last ten days, and the odd day off.
            let wave = Double((back * 37 + seed * 11) % 11) / 10
            let busy = back < 10 ? 2.2 + wave : 0.35 + wave * 0.6
            if (back + seed) % 6 == 5 { continue }
            let tokens = Int(busy * 3_400_000 * scale)
            let sessions = max(1, Int(busy * 6 * scale))
            let key = formatter.string(from: date)
            var row = HermesUsageReport.Day(day: key)
            for (index, model) in models.enumerated() where mix[index] > 0 {
                let modelTokens = Int(Double(tokens) * mix[index])
                let input = modelTokens * 97 / 100
                let output = modelTokens - input
                let cache = Int(Double(input) * model.cacheShare / (1 - model.cacheShare))
                let cost = Double(modelTokens) / 1_000_000 * model.price
                row.inputTokens += input
                row.outputTokens += output
                row.cacheReadTokens += cache
                row.estimatedCost += cost
                modelRows[index].inputTokens += input
                modelRows[index].outputTokens += output
                modelRows[index].cacheReadTokens = (modelRows[index].cacheReadTokens ?? 0) + cache
                modelRows[index].estimatedCost += cost
                modelRows[index].sessions += max(1, Int(Double(sessions) * mix[index]))
                modelDays.append(.init(day: key, model: model.name, tokens: modelTokens, cost: cost))
            }
            row.sessions = sessions
            row.apiCalls = sessions * 9
            dayRows.append(row)
            messages += sessions * 14
            let total = hourWeights.reduce(0, +)
            for hour in 0..<24 { hours[hour] += Double(sessions * hourWeights[(hour + seed) % 24]) / Double(total) }
        }
        var totals = HermesUsageReport.Totals()
        for day in dayRows {
            totals.inputTokens += day.inputTokens
            totals.outputTokens += day.outputTokens
            totals.cacheReadTokens += day.cacheReadTokens
            totals.estimatedCost += day.estimatedCost
            totals.sessions += day.sessions
            totals.apiCalls += day.apiCalls
        }
        return HermesUsageReport(days: dayRows, models: modelRows.filter { $0.inputTokens > 0 }, totals: totals,
                                 activity: .init(hours: hours.map { Int($0.rounded()) }, messages: messages, modelDays: modelDays))
    }
}
