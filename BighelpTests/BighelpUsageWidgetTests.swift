import Foundation
import Testing
import WidgetKit
@testable import Bighelp

/// The Usage widget's rules: what it keeps from the plugin, the colors a share
/// turns, which layout each size and style comes to, and when it redraws.
@MainActor
struct BighelpUsageWidgetTests {
    typealias Plan = BighelpUsageSnapshot.Plan

    @Test func snapshotsWrittenBeforeLogosAndCountsStillRead() throws {
        let saved = """
        {"plans":[{"id":"claude","name":"Claude","plan":"Max","limits":[{"label":"Week","leftPercent":59}],
        "facts":[],"inUse":true}],"days":30,"models":[],"daily":[],"generatedAt":815000000}
        """
        let snapshot = try JSONDecoder.bighelpWidget.decode(BighelpUsageSnapshot.self, from: Data(saved.utf8))
        let plan = try #require(snapshot.plans?.first)
        #expect(plan.limits.first?.usedPercent == 41)
        #expect(plan.logo == nil && plan.tint == nil && plan.limits.first?.detail == nil)
    }

    @Test func plansKeepThePluginsCountTheirLogoAndColor() {
        func provider(_ id: String, _ name: String, detail: String? = nil) -> ProviderUsage {
            ProviderUsage(id: id, name: name, status: .ok, message: nil, plan: "Pro", detectedVia: [], activeInHermes: false,
                          windows: [.init(label: "Premium requests", usedPercent: 80.8, resetsAt: nil, detail: detail)],
                          facts: [], manageURL: nil, approximate: false)
        }
        let report = ProviderUsageReport(agentID: "default", fetchedAt: nil, cached: false, providers: [
            provider("copilot", "GitHub Copilot", detail: "1,212 of 1,500 used"), provider("codex-hermes", "Codex (Hermes)"),
            provider("hermes-acme", "Acme"),
        ])
        let plans = UsageWidgetPublisher.plans(report, hidden: [])
        #expect(plans[0].limits[0].detail == "1,212 of 1,500 used")
        #expect(plans.map(\.logo) == ["ProviderLogoGitHubCopilot", "ProviderLogoCodex", nil])
        #expect(plans.map(\.tint) == ["8957E5", "6A7DFF", nil], "A provider with no color of its own takes the app's")
    }

    @Test func amberFrom80PercentAndRedOnceUsedUp() {
        #expect(UsageWidgetFormat.level(used: 79.4) == .normal)
        #expect(UsageWidgetFormat.level(used: 79.6) == .high, "Shows as 80%")
        #expect(UsageWidgetFormat.level(used: 99.4) == .high)
        #expect(UsageWidgetFormat.level(used: 99.6) == .full, "Shows as 100%")
        let full = Plan.Limit(label: "Week", leftPercent: 0, resetsAt: now.addingTimeInterval(60))
        #expect(full.isFull(at: now))
        #expect(!full.isFull(at: now.addingTimeInterval(61)), "Past its reset it's no longer used up")
    }

    @Test func aLimitPastItsResetNoLongerCountsAsTheTightest() {
        let reset = Plan.Limit(label: "Session (5 hours)", leftPercent: 0, resetsAt: now.addingTimeInterval(-60))
        let week = Plan.Limit(label: "Week", leftPercent: 60, resetsAt: now.addingTimeInterval(86_400))
        let claude = plan("claude", limits: [reset, week])
        let codex = plan("codex", limits: [.init(label: "Week", leftPercent: 50, resetsAt: nil)])
        #expect(claude.tightest(at: now) == week)
        let entry = UsageWidgetEntry(date: now, snapshot: snapshot([claude, codex]), palette: .empty)
        #expect(entry.closest?.plan.id == "codex")
        #expect(entry.byRisk.map(\.id) == ["codex", "claude"])
        #expect(entry.nextReset(claude)?.limit == week)
    }

    @Test func automaticFitsTheSizeToThePlansThereAre() {
        let one = UsageWidgetEntry(date: now, snapshot: snapshot([plan("claude")]), palette: .empty)
        #expect(layouts(one) == [.ring, .onePlan, .deepDive, .columns])

        let two = UsageWidgetEntry(date: now, snapshot: snapshot([plan("claude"), plan("codex")]), palette: .empty)
        #expect(layouts(two) == [.closest, .everyPlan, .dashboard, .columns])

        var picked = two
        picked.planID = "codex"
        #expect(layouts(picked) == [.ring, .onePlan, .deepDive, .columns])
        #expect(picked.chosen?.id == "codex")

        var balances = snapshot([plan("openrouter", limits: [])])
        balances.totals = .init(cost: 12, billedCost: 0, inputTokens: 1, outputTokens: 1, cacheReadTokens: 0, sessions: 1)
        let spending = UsageWidgetEntry(date: now, snapshot: balances, palette: .empty)
        #expect(layouts(spending) == [.spending, .spending, .spending, .spending], "Nothing to meter: the 30 days show")
    }

    @Test func stylesThatNeedTwoPlansFallBackWithOne() {
        var entry = UsageWidgetEntry(date: now, snapshot: snapshot([plan("claude", limits: [
            .init(label: "Week", leftPercent: 50, resetsAt: nil),
        ])]), palette: .empty)
        entry.styles = UsageWidgetStyles(small: .fourPlans, medium: .sideBySide)
        #expect(entry.layout(for: .systemSmall) == .ring)
        #expect(entry.layout(for: .systemMedium) == .onePlan)
        entry.styles.medium = .nextResets
        #expect(entry.layout(for: .systemMedium) == .everyPlan, "No reset ahead to put on the line")
    }

    @Test func withoutAPickTheOneHermesUsesIsShown() {
        var codex = plan("codex")
        codex.inUse = true
        let entry = UsageWidgetEntry(date: now, snapshot: snapshot([plan("claude"), codex]), palette: .empty)
        #expect(entry.chosen?.id == "codex")
    }

    @Test func theTimelineRedrawsEveryFiveMinutesAndAtEachReset() {
        let soon = now.addingTimeInterval(1_234), later = now.addingTimeInterval(7_200)
        let dates = UsageWidgetProvider.dates(from: now, snapshot: snapshot([plan("claude", limits: [
            .init(label: "Session (5 hours)", leftPercent: 0, resetsAt: soon),
            .init(label: "Week", leftPercent: 40, resetsAt: later),
        ])]))
        #expect(dates.first == now && dates.last == now.addingTimeInterval(3_600))
        #expect(dates.contains(soon) && !dates.contains(later))
        #expect(dates.count == 14)
    }

    @Test func oldNumbersAreMarked() {
        var stale = snapshot([plan("claude")])
        stale.generatedAt = now.addingTimeInterval(-4 * 3_600)
        #expect(UsageWidgetEntry(date: now, snapshot: stale, palette: .empty).isStale)
        #expect(!UsageWidgetEntry(date: now, snapshot: snapshot([plan("claude")]), palette: .empty).isStale)
    }

    @Test func labelsAndTimesReadShort() {
        #expect(UsageWidgetFormat.shortLabel("Session (5 hours)") == "Session")
        #expect(UsageWidgetFormat.shortLabel("Week") == "Weekly")
        #expect(UsageWidgetFormat.shortLabel("Spark · Week") == "Spark · Weekly")
        #expect(UsageWidgetFormat.shortLabel("Sonnet week") == "Sonnet week")
        #expect(UsageWidgetFormat.kindLabel("Premium requests") == "Monthly")
        #expect(UsageWidgetFormat.kindLabel("Sonnet week") == "Sonnet wk")
        #expect(UsageWidgetFormat.kindLabel("Session (5 hours)") == "Session")
        #expect(UsageWidgetFormat.tinyLabel("Session (5 hours)") == "5h")
        #expect(UsageWidgetFormat.tinyLabel("Week") == "Wk")
        #expect(UsageWidgetFormat.tinyLabel("Premium requests") == "Mo")
        #expect(UsageWidgetFormat.countdown(to: now.addingTimeInterval(5_280), from: now) == "1h 28m")
        #expect(UsageWidgetFormat.countdown(to: now.addingTimeInterval(165_600), from: now) == "1d 22h")
        #expect(UsageWidgetFormat.countdown(to: now.addingTimeInterval(2_880), from: now) == "48m")
        #expect(UsageWidgetFormat.countdown(to: now.addingTimeInterval(3_600), from: now) == "1h")
        #expect(UsageWidgetFormat.countdown(to: now.addingTimeInterval(20), from: now) == "1m")
    }

    // MARK: Helpers

    private let now = Date(timeIntervalSince1970: 1_793_456_000)

    private func plan(_ id: String, limits: [Plan.Limit]? = nil) -> Plan {
        Plan(id: id, name: id.capitalized, plan: "Pro",
             limits: limits ?? [.init(label: "Week", leftPercent: 50, resetsAt: now.addingTimeInterval(86_400))])
    }

    private func snapshot(_ plans: [Plan]) -> BighelpUsageSnapshot {
        BighelpUsageSnapshot(plans: plans, generatedAt: now)
    }

    private func layouts(_ entry: UsageWidgetEntry) -> [UsageWidgetLayout] {
        [WidgetFamily.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge].map { entry.layout(for: $0) }
    }
}
