import AppIntents
import SwiftUI
import WidgetKit

/// What the Usage widget shows: the plans and limits Hermes found on the
/// computer, and what the agents used over the last 30 days (estimated cost,
/// tokens, the models they used most). The app writes it; the widget only reads it.
struct BighelpUsageSnapshot: Codable, Equatable, Sendable {
    /// One subscription or API account, with its limits as a share left.
    struct Plan: Codable, Equatable, Sendable, Identifiable {
        struct Limit: Codable, Equatable, Sendable {
            let label: String
            /// 0–100.
            let leftPercent: Double
            var resetsAt: Date?
        }

        /// A preformatted label and value, like "Balance" and "$25.00".
        struct Fact: Codable, Equatable, Sendable {
            let label: String
            let value: String
        }

        let id: String
        let name: String
        var plan: String?
        var limits: [Limit] = []
        var facts: [Fact] = []
        /// Why there are no numbers ("Sign in needed on your computer").
        var note: String?
        var inUse = false

        var tightest: Limit? { limits.min { $0.leftPercent < $1.leftPercent } }
    }

    struct Totals: Codable, Equatable, Sendable {
        var cost: Double
        /// What providers themselves reported charging (OpenRouter does).
        var billedCost: Double
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var sessions: Int

        var tokens: Int { inputTokens + outputTokens }
    }

    struct Model: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        var provider: String?
        let cost: Double
        let tokens: Int
    }

    struct Day: Codable, Equatable, Sendable {
        let date: Date
        let cost: Double
        let tokens: Int
    }

    /// Nil when they couldn't be read; empty when the computer has none set up.
    var plans: [Plan]?
    var plansNote: String?
    var days = 30
    var totals: Totals?
    var models: [Model] = []
    var daily: [Day] = []
    var generatedAt: Date = .distantPast

    static let empty = BighelpUsageSnapshot()
    static let kind = "BighelpUsageWidget"
    static let fileName = "bighelp-usage-widget-v1.json"
    static let maximumPlans = 12
    static let maximumModels = 5

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BighelpWidgetSnapshot.appGroup)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    static func load() -> BighelpUsageSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url), data.count <= 131_072,
              let value = try? JSONDecoder.bighelpWidget.decode(Self.self, from: data) else { return .empty }
        return value
    }

    func save() throws {
        guard let url = Self.fileURL else { return }
        try JSONEncoder.bighelpWidget.encode(self)
            .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    var hasData: Bool { totals != nil || plans != nil }

    static let url = URL(string: "loopdy://usage")!
}

// MARK: - Configuration

enum UsageWidgetContent: String, AppEnum {
    case overview, plans, cost, tokens, models

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Show")
    static let caseDisplayRepresentations: [UsageWidgetContent: DisplayRepresentation] = [
        .overview: DisplayRepresentation(title: "Overview", subtitle: "Cost, tokens and your tightest limit"),
        .plans: DisplayRepresentation(title: "Plans and limits", subtitle: "Subscriptions and API accounts"),
        .cost: DisplayRepresentation(title: "Estimated cost", subtitle: "The last 30 days"),
        .tokens: DisplayRepresentation(title: "Tokens", subtitle: "The last 30 days"),
        .models: DisplayRepresentation(title: "Top models", subtitle: "The five your agents used most"),
    ]
}

struct UsageWidgetPlan: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Plan")
    static let defaultQuery = UsageWidgetPlanQuery()
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct UsageWidgetPlanQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [UsageWidgetPlan] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [UsageWidgetPlan] {
        (BighelpUsageSnapshot.load().plans ?? []).map { UsageWidgetPlan(id: $0.id, name: $0.name) }
    }
}

struct UsageWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage"
    static let description = IntentDescription("Choose what to show: plans and limits, cost, tokens or top models.")

    @Parameter(title: "Show", default: .overview)
    var content: UsageWidgetContent

    @Parameter(title: "Plan", description: "For Plans and limits. Leave empty to show every plan.")
    var plan: UsageWidgetPlan?
}

// MARK: - Timeline

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BighelpUsageSnapshot
    let palette: BighelpWidgetSnapshot
    let content: UsageWidgetContent
    let planID: String?

    var plans: [BighelpUsageSnapshot.Plan] {
        let plans = snapshot.plans ?? []
        guard let planID else { return plans }
        return plans.filter { $0.id == planID }
    }

    /// The limit closest to running out, across the plans shown.
    var tightest: (plan: BighelpUsageSnapshot.Plan, limit: BighelpUsageSnapshot.Plan.Limit)? {
        plans.compactMap { plan in plan.tightest.map { (plan, $0) } }.min { $0.1.leftPercent < $1.1.leftPercent }
    }

    static let preview: UsageWidgetEntry = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let daily = (0..<30).map { offset -> BighelpUsageSnapshot.Day in
            let wave = Double((offset * 7) % 11) + 3
            return .init(date: calendar.date(byAdding: .day, value: offset - 29, to: today) ?? today,
                         cost: wave * 1.9, tokens: Int(wave * 310_000))
        }
        return UsageWidgetEntry(
            date: .now,
            snapshot: BighelpUsageSnapshot(
                plans: [
                    .init(id: "claude", name: "Claude", plan: "Max", limits: [
                        .init(label: "Session (5 hours)", leftPercent: 62, resetsAt: .now.addingTimeInterval(5_400)),
                        .init(label: "Week", leftPercent: 41, resetsAt: .now.addingTimeInterval(172_800)),
                    ], inUse: true),
                    .init(id: "openrouter", name: "OpenRouter", facts: [.init(label: "Balance", value: "$18.40")]),
                ],
                totals: .init(cost: 214.37, billedCost: 0, inputTokens: 21_400_000, outputTokens: 6_100_000,
                              cacheReadTokens: 48_000_000, sessions: 132),
                models: [
                    .init(id: "a", name: "Opus 4.1", provider: "Anthropic", cost: 120.5, tokens: 9_800_000),
                    .init(id: "b", name: "GPT-5.6", provider: "OpenAI", cost: 61.2, tokens: 8_100_000),
                    .init(id: "c", name: "Hermes 4 405B", provider: "Nous Research", cost: 32.67, tokens: 9_600_000),
                ],
                daily: daily, generatedAt: .now),
            palette: .empty, content: .overview, planID: nil)
    }()
}

struct UsageWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry { .preview }

    func snapshot(for configuration: UsageWidgetIntent, in context: Context) async -> UsageWidgetEntry {
        let entry = entry(for: configuration)
        guard context.isPreview, !entry.snapshot.hasData else { return entry }
        let preview = UsageWidgetEntry.preview
        return UsageWidgetEntry(date: preview.date, snapshot: preview.snapshot, palette: preview.palette,
                                content: configuration.content, planID: nil)
    }

    func timeline(for configuration: UsageWidgetIntent, in context: Context) async -> Timeline<UsageWidgetEntry> {
        // The app reloads this when it reads new numbers; this is only a safety net.
        Timeline(entries: [entry(for: configuration)], policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    private func entry(for configuration: UsageWidgetIntent) -> UsageWidgetEntry {
        UsageWidgetEntry(date: .now, snapshot: BighelpUsageSnapshot.load(), palette: BighelpWidgetSnapshot.load(),
                         content: configuration.content, planID: configuration.plan?.id)
    }
}

// MARK: - Views

enum UsageWidgetFormat {
    static func cost(_ value: Double) -> String {
        if value >= 10_000 { return "$" + Int(value.rounded()).formatted(.number.notation(.compactName)) }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(value >= 1_000 ? 0 : 2)))
    }

    static func tokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// Red when nearly used up, amber when getting low.
    static func tint(left: Double, accent: Color) -> Color {
        if left < 15 { return Color(widgetHex: "E5624F") }
        if left < 40 { return Color(widgetHex: "E0A030") }
        return accent
    }
}

struct BighelpUsageWidgetView: View {
    let entry: UsageWidgetEntry
    /// Draws one size outside WidgetKit, for the app's own pictures of the widget.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.bighelpWidgetColors) private var colors

    private var family: WidgetFamily { familyOverride ?? widgetFamily }

    private var snapshot: BighelpUsageSnapshot { entry.snapshot }

    var body: some View {
        Group {
            if family.isAccessory {
                accessory
            } else {
                VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 10) {
                    header
                    if !snapshot.hasData {
                        Spacer(minLength: 0)
                        Text("Open Usage in bighelp to see your numbers here.")
                            .font(.caption).foregroundStyle(colors.secondary)
                        Spacer(minLength: 0)
                    } else {
                        content
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .widgetURL(BighelpUsageSnapshot.url)
    }

    private var title: String {
        switch entry.content {
        case .overview: "Usage"
        case .plans: entry.planID.flatMap { id in entry.plans.first { $0.id == id }?.name } ?? "Plans"
        case .cost: "Estimated cost"
        case .tokens: "Tokens"
        case .models: "Top models"
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.caption.weight(.bold)).foregroundStyle(colors.accent)
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
            if entry.content != .plans, snapshot.totals != nil {
                Text("\(snapshot.days) days").font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch entry.content {
        case .overview: overview
        case .plans: plans
        case .cost: amount(isCost: true)
        case .tokens: amount(isCost: false)
        case .models: models
        }
    }

    // MARK: Overview

    @ViewBuilder private var overview: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 4) {
                totalsBlock(large: true)
                Spacer(minLength: 0)
                if let tightest = entry.tightest { limitRow(tightest.plan, tightest.limit, compact: true) }
            }
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    totalsBlock(large: true)
                    Spacer(minLength: 0)
                    dailyBars(cost: true, count: 30).frame(height: 28)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(planLimits.prefix(2), id: \.key) { item in limitRow(item.plan, item.limit, compact: false) }
                    if planLimits.isEmpty { plansFallback }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                totalsBlock(large: true)
                dailyBars(cost: true, count: 30).frame(height: 44)
                if !planLimits.isEmpty { sectionTitle("Limits") }
                ForEach(planLimits.prefix(3), id: \.key) { item in limitRow(item.plan, item.limit, compact: false) }
                if !snapshot.models.isEmpty { sectionTitle("Top models") }
                modelRows(limit: 3)
                Spacer(minLength: 0)
            }
        }
    }

    private func totalsBlock(large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if let totals = snapshot.totals {
                Text(UsageWidgetFormat.cost(totals.cost))
                    .font(large ? .title2.weight(.bold) : .headline).monospacedDigit()
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text("\(UsageWidgetFormat.tokens(totals.tokens)) tokens")
                    .font(.caption).foregroundStyle(colors.secondary).lineLimit(1)
            } else {
                Text("No usage read yet").font(.caption).foregroundStyle(colors.secondary)
            }
        }
    }

    // MARK: Plans

    private struct PlanLimit {
        let plan: BighelpUsageSnapshot.Plan
        let limit: BighelpUsageSnapshot.Plan.Limit
        var key: String { plan.id + "/" + limit.label }
    }

    /// Each plan's tightest limit, the tightest first.
    private var planLimits: [PlanLimit] {
        entry.plans.compactMap { plan in plan.tightest.map { PlanLimit(plan: plan, limit: $0) } }
            .sorted { $0.limit.leftPercent < $1.limit.leftPercent }
    }

    @ViewBuilder private var plans: some View {
        let shown = entry.plans
        if shown.isEmpty {
            plansFallback
            Spacer(minLength: 0)
        } else if family == .systemSmall || shown.count == 1 {
            planCard(shown[0], limit: family == .systemSmall ? 2 : family == .systemMedium ? 2 : 4)
            Spacer(minLength: 0)
        } else {
            let perPlan = family == .systemMedium ? 1 : 2
            let planCount = family == .systemMedium ? 2 : 4
            VStack(alignment: .leading, spacing: family == .systemMedium ? 8 : 12) {
                ForEach(shown.prefix(planCount)) { plan in planCard(plan, limit: perPlan) }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var plansFallback: some View {
        Text(snapshot.plansNote ?? (snapshot.plans == nil
             ? "Open Usage in bighelp to see your plans here."
             : "No plans found on your computer."))
            .font(.caption).foregroundStyle(colors.secondary)
    }

    private func planCard(_ plan: BighelpUsageSnapshot.Plan, limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(plan.name).font(.caption.weight(.semibold)).lineLimit(1)
                if let name = plan.plan {
                    Text(name).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                }
            }
            if !plan.limits.isEmpty {
                ForEach(Array(plan.limits.prefix(limit).enumerated()), id: \.offset) { _, item in
                    limitBar(item)
                }
            } else if let fact = plan.facts.first {
                Text("\(fact.label) \(fact.value)").font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
            } else if let note = plan.note {
                Text(note).font(.caption2).foregroundStyle(colors.secondary).lineLimit(2)
            }
        }
    }

    private func limitBar(_ limit: BighelpUsageSnapshot.Plan.Limit) -> some View {
        let tint = UsageWidgetFormat.tint(left: limit.leftPercent, accent: colors.accent)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(limit.label).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(UsageWidgetFormat.percent(limit.leftPercent)) left")
                    .font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(tint).lineLimit(1)
            }
            UsageWidgetBar(fraction: limit.leftPercent / 100, tint: tint)
        }
    }

    private func limitRow(_ plan: BighelpUsageSnapshot.Plan, _ limit: BighelpUsageSnapshot.Plan.Limit,
                          compact: Bool) -> some View {
        let tint = UsageWidgetFormat.tint(left: limit.leftPercent, accent: colors.accent)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(compact ? plan.name : "\(plan.name) · \(limit.label)")
                    .font(.caption2.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(UsageWidgetFormat.percent(limit.leftPercent) + " left")
                    .font(.caption2.monospacedDigit()).foregroundStyle(tint).lineLimit(1)
            }
            UsageWidgetBar(fraction: limit.leftPercent / 100, tint: tint)
        }
    }

    // MARK: Cost and tokens

    @ViewBuilder private func amount(isCost: Bool) -> some View {
        if let totals = snapshot.totals {
            VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 8) {
                Text(isCost ? UsageWidgetFormat.cost(totals.cost) : UsageWidgetFormat.tokens(totals.tokens))
                    .font(.title.weight(.bold)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                Text(isCost ? costDetail(totals) : tokenDetail(totals))
                    .font(.caption2).foregroundStyle(colors.secondary).lineLimit(2)
                Spacer(minLength: 0)
                dailyBars(cost: isCost, count: family == .systemSmall ? 14 : 30)
                    .frame(height: family == .systemLarge ? 110 : family == .systemMedium ? 34 : 26)
                if family == .systemLarge, !snapshot.models.isEmpty {
                    sectionTitle("Top models")
                    modelRows(limit: 5, byCost: isCost)
                }
            }
        } else {
            Text("Open Usage in bighelp to see your numbers here.").font(.caption).foregroundStyle(colors.secondary)
            Spacer(minLength: 0)
        }
    }

    private func costDetail(_ totals: BighelpUsageSnapshot.Totals) -> String {
        var parts = ["Estimated by Hermes"]
        if totals.billedCost > 0 { parts.append("billed \(UsageWidgetFormat.cost(totals.billedCost))") }
        return parts.joined(separator: " · ")
    }

    private func tokenDetail(_ totals: BighelpUsageSnapshot.Totals) -> String {
        "In \(UsageWidgetFormat.tokens(totals.inputTokens)) · Out \(UsageWidgetFormat.tokens(totals.outputTokens))"
    }

    /// One bar a day, the latest on the right; real numbers only.
    private func dailyBars(cost: Bool, count: Int) -> some View {
        let days = Array(snapshot.daily.suffix(count))
        let values = days.map { cost ? $0.cost : Double($0.tokens) }
        let peak = max(values.max() ?? 0, .leastNonzeroMagnitude)
        return GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(colors.accent.opacity(value > 0 ? 0.85 : 0.2))
                        .frame(height: max(2, proxy.size.height * value / peak))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    // MARK: Models

    @ViewBuilder private var models: some View {
        if snapshot.models.isEmpty {
            Text(snapshot.totals == nil ? "Open Usage in bighelp to see your numbers here." : "No model use in the last \(snapshot.days) days.")
                .font(.caption).foregroundStyle(colors.secondary)
            Spacer(minLength: 0)
        } else {
            VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 6) {
                modelRows(limit: family == .systemSmall ? 3 : family == .systemMedium ? 3 : 5)
                Spacer(minLength: 0)
            }
        }
    }

    private func modelRows(limit: Int, byCost: Bool? = nil) -> some View {
        let useCost = byCost ?? snapshot.models.contains { $0.cost > 0 }
        let models = Array(snapshot.models.sorted { useCost ? $0.cost > $1.cost : $0.tokens > $1.tokens }.prefix(limit))
        let peak = max(models.map { useCost ? $0.cost : Double($0.tokens) }.max() ?? 0, .leastNonzeroMagnitude)
        return VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 6) {
            ForEach(models) { model in
                let value = useCost ? model.cost : Double(model.tokens)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(model.name).font(.caption2.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(useCost ? UsageWidgetFormat.cost(model.cost) : UsageWidgetFormat.tokens(model.tokens))
                            .font(.caption2.monospacedDigit()).foregroundStyle(colors.secondary).lineLimit(1)
                    }
                    if family != .systemSmall {
                        UsageWidgetBar(fraction: value / peak, tint: colors.accent)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption2.weight(.bold)).tracking(0.4).foregroundStyle(colors.secondary)
    }

    // MARK: Lock Screen

    @ViewBuilder private var accessory: some View {
        #if os(iOS)
        if family == .accessoryCircular {
            if entry.content == .plans || entry.content == .overview, let tightest = entry.tightest {
                Gauge(value: tightest.limit.leftPercent, in: 0...100) {
                    Text(tightest.plan.name)
                } currentValueLabel: {
                    Text(UsageWidgetFormat.percent(tightest.limit.leftPercent)).font(.caption.monospacedDigit())
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .widgetAccentable()
            } else if let totals = snapshot.totals {
                VStack(spacing: 0) {
                    Text(entry.content == .tokens ? UsageWidgetFormat.tokens(totals.tokens) : UsageWidgetFormat.cost(totals.cost))
                        .font(.caption.weight(.bold).monospacedDigit()).minimumScaleFactor(0.5).lineLimit(1)
                    Text("\(snapshot.days)d").font(.caption2)
                }
                .widgetAccentable()
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.title2).widgetAccentable()
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                switch entry.content {
                case .plans:
                    if let tightest = entry.tightest {
                        Text("\(tightest.plan.name) · \(UsageWidgetFormat.percent(tightest.limit.leftPercent)) left")
                            .font(.headline).lineLimit(1).widgetAccentable()
                        Text(tightest.limit.label).font(.caption).lineLimit(1)
                        ProgressView(value: tightest.limit.leftPercent / 100)
                    } else {
                        Text("No limits to show").font(.caption)
                    }
                case .models:
                    Text(snapshot.models.first?.name ?? "No model use yet").font(.headline).lineLimit(1).widgetAccentable()
                    if let model = snapshot.models.first {
                        Text("Most used · \(UsageWidgetFormat.cost(model.cost))").font(.caption).lineLimit(1)
                    }
                default:
                    if let totals = snapshot.totals {
                        Text(entry.content == .tokens ? "\(UsageWidgetFormat.tokens(totals.tokens)) tokens"
                             : UsageWidgetFormat.cost(totals.cost))
                            .font(.headline).lineLimit(1).widgetAccentable()
                        Text(entry.content == .tokens ? "Last \(snapshot.days) days"
                             : "\(UsageWidgetFormat.tokens(totals.tokens)) tokens · \(snapshot.days) days")
                            .font(.caption).lineLimit(1)
                    } else {
                        Text("Open Usage in bighelp").font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        EmptyView()
        #endif
    }
}

/// A rounded bar filled to a share, on a faint track.
struct UsageWidgetBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, fraction)))
                    .widgetAccentable()
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

struct BighelpUsageWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: BighelpUsageSnapshot.kind, intent: UsageWidgetIntent.self,
                               provider: UsageWidgetProvider()) { entry in
            BighelpWidgetScaffold(snapshot: entry.palette) {
                BighelpUsageWidgetView(entry: entry)
            }
        }
        .configurationDisplayName("Usage")
        .description("Plans and limits, estimated cost, tokens or top models. Pick what to show.")
        .supportedFamilies(Self.families)
        .bighelpWidgetPlacement()
    }

    private static var families: [WidgetFamily] {
        #if os(visionOS)
        [.systemSmall, .systemMedium, .systemLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular]
        #endif
    }
}
