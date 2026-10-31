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
        #expect(plans.map(\.key) == ["copilot", "codex-hermes", "hermes-acme"].map(ProviderUsagePreferences.key(for:)))
        #expect(plans[1].key == ProviderUsagePreferences.key(for: "codex"),
                "Names are found by the provider's own key, whatever id the host gave it")
        #expect(plans.map { $0.logoScale.map { ($0 * 100).rounded() / 100 } } == [nil, 1.3, nil],
                "Codex's mark draws larger, as in the app")
    }

    /// The app sizes some marks up (`officialArtworkGeometry`); the widget does the same, so every logo looks one size.
    @Test func logosTakeTheAppsOpticalSize() throws {
        #expect(UsageWidgetPublisher.logoScale(.anthropic) == nil)
        #expect(try abs(#require(UsageWidgetPublisher.logoScale(.codex)) - 1.3) < 0.001)
        #expect(try abs(#require(UsageWidgetPublisher.logoScale(.openAI)) - 2.5) < 0.001)
    }

    /// A used-up weekly limit counts down as "2d 22h", not a timer past 24 hours.
    @Test func onlyALimitBackWithinADayCountsDownLive() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(UsageWidgetCountdown.ticks(until: now.addingTimeInterval(5 * 3600), now: now, reduceMotion: false))
        #expect(!UsageWidgetCountdown.ticks(until: now.addingTimeInterval(70 * 3600), now: now, reduceMotion: false))
        #expect(!UsageWidgetCountdown.ticks(until: now.addingTimeInterval(5 * 3600), now: now, reduceMotion: true))
        #expect(!UsageWidgetCountdown.ticks(until: now.addingTimeInterval(-60), now: now, reduceMotion: false))
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
        picked.planIDs = ["codex"]
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

    @Test func severalPickedPlansShowInTheOrderPicked() {
        let calm = plan("claude", limits: [.init(label: "Week", leftPercent: 90, resetsAt: nil)])
        let busy = plan("codex", limits: [.init(label: "Week", leftPercent: 10, resetsAt: nil)])
        var entry = UsageWidgetEntry(date: now, snapshot: snapshot([calm, busy, plan("gemini")]), palette: .empty)
        #expect(entry.byRisk.map(\.id) == ["codex", "gemini", "claude"], "Unpicked: nearest its limit first")
        entry.planIDs = ["claude", "gone", "codex"]
        #expect(entry.plans.map(\.id) == ["claude", "codex"], "A plan the computer no longer has drops out")
        #expect(entry.byRisk.map(\.id) == ["claude", "codex"], "Picked: the order picked")
        #expect(entry.chosen?.id == "claude", "Styles about one plan show the first")
        #expect(layouts(entry) == [.closest, .everyPlan, .dashboard, .columns])
    }

    @Test func everySizeHasMetersAndRingsForSeveralPlans() {
        var entry = UsageWidgetEntry(date: now, snapshot: snapshot([plan("claude"), plan("codex")]), palette: .empty)
        entry.styles = UsageWidgetStyles(small: .fourPlanMeters, medium: .everyPlanRings, large: .everyPlanRings)
        #expect(layouts(entry).prefix(3) == [.fourPlanMeters, .everyPlanRings, .everyPlanRings])
        entry.planIDs = ["codex"]
        #expect(layouts(entry).prefix(3) == [.twoMeters, .onePlan, .deepDive], "One plan picked: its own view")
    }

    @Test func aWidgetSetToOnePlanBeforeKeepsIt() {
        var intent = UsageWidgetIntent()
        intent.plan = UsageWidgetPlan(id: "claude", name: "Claude")
        #expect(intent.planIDs == ["claude"])
        intent.plans = [UsageWidgetPlan(id: "codex", name: "Codex"), UsageWidgetPlan(id: "claude", name: "Claude")]
        #expect(intent.planIDs == ["codex", "claude"], "Plans, once set, wins")
    }

    // MARK: Plan names

    @Test func planNamesAreKeptForEachGateway() {
        let home = UUID().uuidString, studio = UUID().uuidString
        var names = BighelpPlanNames.setting("Personal Claude", of: "claude", gateway: home, in: "")
        names = BighelpPlanNames.setting("Work Claude", of: "claude", gateway: studio, in: names)
        #expect(BighelpPlanNames.name(of: "claude", gateway: home, in: names) == "Personal Claude")
        #expect(BighelpPlanNames.name(of: "claude", gateway: studio, in: names) == "Work Claude",
                "The same provider is another account on another computer")
        #expect(BighelpPlanNames.name(of: "codex", gateway: home, in: names) == nil)

        names = BighelpPlanNames.setting("Personal ", of: "claude", gateway: home, in: names)
        #expect(BighelpPlanNames.typed(of: "claude", gateway: home, in: names) == "Personal ", "A field keeps what's typed")
        #expect(BighelpPlanNames.name(of: "claude", gateway: home, in: names) == "Personal")
        names = BighelpPlanNames.setting("   ", of: "claude", gateway: home, in: names)
        #expect(BighelpPlanNames.name(of: "claude", gateway: home, in: names) == nil, "Blank goes back to the provider's name")
        #expect(BighelpPlanNames.name(of: "claude", gateway: studio, in: names) == "Work Claude")
        names = BighelpPlanNames.setting(String(repeating: "x", count: 80), of: "claude", gateway: studio, in: names)
        #expect(BighelpPlanNames.name(of: "claude", gateway: studio, in: names)?.count == BighelpPlanNames.maximumLength)
    }

    @Test func widgetsShowTheNamesGivenOnTheirGateway() {
        let home = UUID().uuidString, studio = UUID().uuidString
        let names = BighelpPlanNames.setting("Personal Claude", of: "claude", gateway: home, in: "")
        // The host can call a provider by another id; the key it's named under stays.
        let snapshot = BighelpUsageSnapshot(plans: [Plan(id: "claude-hermes", name: "Claude", key: "claude"),
                                                    Plan(id: "codex", name: "Codex")])
        #expect(snapshot.named(gateway: home, names: names).plans?.map(\.name) == ["Personal Claude", "Codex"])
        #expect(snapshot.named(gateway: studio, names: names).plans?.map(\.name) == ["Claude", "Codex"])
    }

    @Test func aRemovedGatewaysNamesAreForgotten() throws {
        let suite = "usage-names-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let home = UUID().uuidString, gone = UUID().uuidString
        var names = BighelpPlanNames.setting("Personal Claude", of: "claude", gateway: home, in: "")
        names = BighelpPlanNames.setting("Old Claude", of: "claude", gateway: gone, in: names)
        names = BighelpPlanNames.setting("Demo Claude", of: "claude", gateway: "current", in: names)
        defaults.set(names, forKey: BighelpPlanNames.key)
        BighelpPlanNames.keep(gateways: [home], in: defaults)
        let kept = defaults.string(forKey: BighelpPlanNames.key) ?? ""
        #expect(BighelpPlanNames.name(of: "claude", gateway: home, in: kept) == "Personal Claude")
        #expect(BighelpPlanNames.name(of: "claude", gateway: gone, in: kept) == nil)
        #expect(BighelpPlanNames.name(of: "claude", gateway: "current", in: kept) == "Demo Claude",
                "Only gateways bighelp lists can be gone")
    }

    @Test func aRenameReachesFilesFromBeforePlansHadKeys() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "usage-names-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let home = UUID().uuidString
        // The release before wrote plans without a key; the host calls this one "codex-hermes".
        let old = #"{"days":30,"generatedAt":0,"models":[],"daily":[],"plans":[{"id":"codex-hermes","name":"Codex","limits":[],"facts":[],"inUse":false}]}"#
        let url = try #require(BighelpUsageSnapshot.fileURL(gateway: home, in: folder))
        try Data(old.utf8).write(to: url)
        #expect(BighelpUsageSnapshot.load(gateway: home, in: folder).plans?.first?.key == nil, "Old files still read")
        UsageWidgetPublisher.namesChanged(directory: folder)
        let key = try #require(BighelpUsageSnapshot.load(gateway: home, in: folder).plans?.first?.key)
        #expect(key == ProviderUsagePreferences.key(for: "codex-hermes"))
        let names = BighelpPlanNames.setting("Work Codex", of: key, gateway: home, in: "")
        #expect(BighelpUsageSnapshot.load(gateway: home, in: folder).named(gateway: home, names: names).plans?.first?.name
                == "Work Codex")
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
