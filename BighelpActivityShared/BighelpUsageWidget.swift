import AppIntents
import SwiftUI
import WidgetKit

/// What the Usage widget shows: the plans and limits Hermes found on the
/// computer, and what the agents used over the last 30 days (estimated cost,
/// tokens, the models they used most). Each gateway has its own; the app writes
/// them and the widget only reads them.
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
        /// The provider's name, or the one the person gave the plan (`named`).
        var name: String
        var plan: String?
        var limits: [Limit] = []
        var facts: [Fact] = []
        /// Why there are no numbers ("Sign in needed on your computer").
        var note: String?
        var inUse = false
        /// What its name is saved under (`BighelpPlanNames`): one key for a provider, whatever id the host
        /// gave it this time.
        var key: String?

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
    /// Why there are no numbers yet ("Couldn't reach this host."), while none were ever read.
    var note: String?
    var generatedAt: Date = .distantPast

    static let empty = BighelpUsageSnapshot()
    static let kind = "BighelpUsageWidget"
    /// The demo's numbers: it has no gateway IDs.
    static let fileName = "bighelp-usage-widget-v1.json"
    static let gatewayFilePrefix = "bighelp-usage-widget-v1-"
    static let maximumPlans = 12
    static let maximumModels = 5

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BighelpWidgetSnapshot.appGroup)
    }

    /// A gateway's file, by its ID in bighelp (a UUID); nil is the demo's.
    static func fileURL(gateway: String?, in directory: URL? = directory) -> URL? {
        let name: String
        if let gateway {
            guard let id = UUID(uuidString: gateway) else { return nil }
            name = gatewayFilePrefix + id.uuidString + ".json"
        } else {
            name = fileName
        }
        return directory?.appendingPathComponent(name, isDirectory: false)
    }

    static func load(gateway: String?, in directory: URL? = directory) -> BighelpUsageSnapshot {
        guard let url = fileURL(gateway: gateway, in: directory), let data = try? Data(contentsOf: url),
              data.count <= 131_072,
              let value = try? JSONDecoder.bighelpWidget.decode(Self.self, from: data) else { return .empty }
        return value
    }

    func save(gateway: String?, in directory: URL? = Self.directory) throws {
        guard let url = Self.fileURL(gateway: gateway, in: directory) else { return }
        try JSONEncoder.bighelpWidget.encode(self)
            .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// What a widget set to `gateway` shows, with the names given to its plans; nil follows the gateway in use.
    static func shown(gateway: String?) -> BighelpUsageSnapshot {
        let id = gateway ?? BighelpWidgetGatewayList.inUseID()
        return load(gateway: id).named(gateway: id, names: BighelpPlanNames.saved)
    }

    /// The plans under the names given to them on this gateway.
    func named(gateway: String?, names: String) -> BighelpUsageSnapshot {
        var copy = self
        copy.plans = plans?.map { plan in
            var plan = plan
            if let name = BighelpPlanNames.name(of: plan.key ?? plan.id, gateway: gateway, in: names) { plan.name = name }
            return plan
        }
        return copy
    }

    var hasData: Bool { totals != nil || plans != nil }

    static let url = URL(string: "loopdy://usage")!
}

/// Names people give their plans in Usage, for each gateway: the same provider can be another account on
/// another computer. Kept in the app group, so the widgets show a name as soon as it's saved.
enum BighelpPlanNames {
    static let key = "bighelp.plan-names.v1"
    static let maximumLength = 40

    /// One shared instance: a screen watching it redraws only for writes made through the same one.
    /// UserDefaults is thread-safe.
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: BighelpWidgetSnapshot.appGroup)
    static var saved: String { defaults?.string(forKey: key) ?? "" }

    /// A plan's name on a gateway, from the saved names; nil keeps the provider's.
    static func name(of plan: String, gateway: String?, in names: String) -> String? {
        let name = decode(names)[gateway ?? ""]?[plan]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    /// A plan's name as typed, for a field bound to it: it can end in a space while someone types.
    static func typed(of plan: String, gateway: String?, in names: String) -> String {
        decode(names)[gateway ?? ""]?[plan] ?? ""
    }

    /// The saved names with one plan's set; a blank name goes back to the provider's. Kept as typed, so a
    /// field bound to it can end in a space.
    static func setting(_ name: String, of plan: String, gateway: String?, in names: String) -> String {
        var all = decode(names)
        let gateway = gateway ?? ""
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        all[gateway, default: [:]][plan] = trimmed.isEmpty ? nil : String(name.prefix(maximumLength))
        if all[gateway]?.isEmpty == true { all[gateway] = nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard !all.isEmpty, let data = try? encoder.encode(all) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func decode(_ names: String) -> [String: [String: String]] {
        guard !names.isEmpty, names.utf8.count <= 65_536 else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: Data(names.utf8))) ?? [:]
    }
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

/// How Plans and limits draws each plan.
enum UsageWidgetStyle: String, AppEnum {
    case bars, barsWithLimits, rings, dials, stackedRings

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Style")
    static let caseDisplayRepresentations: [UsageWidgetStyle: DisplayRepresentation] = [
        .bars: DisplayRepresentation(title: "Bars", subtitle: "One line for each plan"),
        .barsWithLimits: DisplayRepresentation(title: "Bars with every limit", subtitle: "Each plan with all its limits"),
        .rings: DisplayRepresentation(title: "Rings"),
        .dials: DisplayRepresentation(title: "Dials"),
        .stackedRings: DisplayRepresentation(title: "Stacked rings", subtitle: "A plan's first limit outside, its second inside"),
    ]

    var isGauge: Bool { self == .rings || self == .dials }
}

struct UsageWidgetPlan: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Plan")
    static let defaultQuery = UsageWidgetPlanQuery()
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// The plans on the widget's gateway.
struct UsageWidgetPlanQuery: EntityQuery {
    @IntentParameterDependency<UsageWidgetIntent>(\.$gateway) private var intent

    func entities(for identifiers: [String]) async throws -> [UsageWidgetPlan] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [UsageWidgetPlan] {
        (BighelpUsageSnapshot.shown(gateway: intent?.gateway.hostID).plans ?? [])
            .map { UsageWidgetPlan(id: $0.id, name: $0.name) }
    }
}

struct UsageWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage"
    static let description = IntentDescription(
        "Choose a gateway and what to show: plans and limits, cost, tokens or top models.")

    @Parameter(title: "Gateway")
    var gateway: BighelpWidgetGateway?

    @Parameter(title: "Show", default: .overview)
    var content: UsageWidgetContent

    @Parameter(title: "Style", default: .bars)
    var style: UsageWidgetStyle

    @Parameter(title: "Plans", description: "Leave it empty to show every plan.",
               size: [.systemSmall: 4, .systemMedium: 6, .systemLarge: 8])
    var plans: [UsageWidgetPlan]?

    // Style only draws Plans and limits.
    static var parameterSummary: some ParameterSummary {
        When(\.$content, .equalTo, .plans) {
            Summary {
                \.$gateway
                \.$content
                \.$style
                \.$plans
            }
        } otherwise: {
            Summary {
                \.$gateway
                \.$content
                \.$plans
            }
        }
    }
}

// MARK: - Timeline

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BighelpUsageSnapshot
    let palette: BighelpWidgetSnapshot
    let content: UsageWidgetContent
    var style: UsageWidgetStyle = .bars
    /// The plans chosen, in their order; none shows every plan.
    var planIDs: [String] = []
    /// The chosen gateway; nil follows the one in use. A tap opens Usage there.
    var hostID: String? = nil

    var plans: [BighelpUsageSnapshot.Plan] {
        let plans = snapshot.plans ?? []
        guard !planIDs.isEmpty else { return plans }
        return planIDs.compactMap { id in plans.first { $0.id == id } }
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
                    .init(id: "codex", name: "Codex", plan: "Pro", limits: [
                        .init(label: "Session (5 hours)", leftPercent: 88, resetsAt: .now.addingTimeInterval(10_800)),
                        .init(label: "Week", leftPercent: 23, resetsAt: .now.addingTimeInterval(345_600)),
                    ]),
                    .init(id: "gemini", name: "Gemini", plan: "AI Pro", limits: [
                        .init(label: "Day", leftPercent: 12, resetsAt: .now.addingTimeInterval(21_600)),
                    ]),
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
            palette: .empty, content: .overview)
    }()
}

struct UsageWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry { .preview }

    func snapshot(for configuration: UsageWidgetIntent, in context: Context) async -> UsageWidgetEntry {
        let entry = entry(for: configuration)
        guard context.isPreview, !entry.snapshot.hasData else { return entry }
        let preview = UsageWidgetEntry.preview
        return UsageWidgetEntry(date: preview.date, snapshot: preview.snapshot, palette: preview.palette,
                                content: configuration.content, style: configuration.style)
    }

    func timeline(for configuration: UsageWidgetIntent, in context: Context) async -> Timeline<UsageWidgetEntry> {
        // The app reloads this when it reads new numbers, also from the background; this is only a safety net.
        Timeline(entries: [entry(for: configuration)], policy: .after(.now.addingTimeInterval(60 * 60)))
    }

    private func entry(for configuration: UsageWidgetIntent) -> UsageWidgetEntry {
        let hostID = configuration.gateway?.hostID
        return UsageWidgetEntry(date: .now, snapshot: .shown(gateway: hostID), palette: .load(gateway: hostID),
                                content: configuration.content, style: configuration.style,
                                planIDs: (configuration.plans ?? []).map(\.id), hostID: hostID)
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
                    // Four gauges fill a small widget on their own.
                    if !(family == .systemSmall && entry.content == .plans && entry.style.isGauge && snapshot.hasData) {
                        header
                    }
                    if !snapshot.hasData {
                        Spacer(minLength: 0)
                        Text(waiting).font(.caption).foregroundStyle(colors.secondary)
                        Spacer(minLength: 0)
                    } else {
                        content
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .widgetURL(BighelpWidgetSnapshot.link(BighelpUsageSnapshot.url, onGateway: entry.hostID))
    }

    /// No numbers yet: why, or that they come on their own.
    private var waiting: String { snapshot.note ?? "Your numbers show here once bighelp reads them." }

    private var title: String {
        switch entry.content {
        case .overview: "Usage"
        case .plans: entry.planIDs.count == 1 ? entry.plans.first?.name ?? "Plans" : "Plans"
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
        } else {
            switch entry.style {
            case .bars: planLines(shown)
            case .barsWithLimits: planCards(shown)
            case .rings, .dials: gauges(shown, dials: entry.style == .dials)
            case .stackedRings: stackedRings(shown)
            }
            Spacer(minLength: 0)
        }
    }

    /// Bars: one line for each plan, its tightest limit.
    @ViewBuilder private func planLines(_ shown: [BighelpUsageSnapshot.Plan]) -> some View {
        let lines = Array(shown.prefix(family == .systemSmall ? 4 : family == .systemMedium ? 6 : 8))
        if family == .systemMedium, lines.count > 3 {
            let left = (lines.count + 1) / 2
            HStack(alignment: .top, spacing: 14) {
                planLineColumn(Array(lines.prefix(left)))
                planLineColumn(Array(lines.dropFirst(left)))
            }
        } else {
            planLineColumn(lines)
        }
    }

    private func planLineColumn(_ lines: [BighelpUsageSnapshot.Plan]) -> some View {
        VStack(alignment: .leading, spacing: family == .systemLarge ? 10 : 7) {
            ForEach(lines) { plan in
                if let limit = plan.tightest {
                    limitRow(plan, limit, compact: family != .systemLarge)
                } else {
                    HStack(spacing: 4) {
                        Text(plan.name).font(.caption2.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 2)
                        // A narrow line keeps the balance itself, not its label.
                        Text(family == .systemLarge ? Self.withoutLimits(plan) : plan.facts.first?.value ?? plan.note ?? "")
                            .font(.caption2).monospacedDigit().foregroundStyle(colors.secondary)
                            .lineLimit(1).layoutPriority(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A plan with no limits: its balance, or why there are no numbers.
    private static func withoutLimits(_ plan: BighelpUsageSnapshot.Plan) -> String {
        plan.facts.first.map { "\($0.label) \($0.value)" } ?? plan.note ?? ""
    }

    /// Bars with every limit: each plan with its limits, and when they reset where there's room.
    @ViewBuilder private func planCards(_ shown: [BighelpUsageSnapshot.Plan]) -> some View {
        if shown.count == 1 {
            planCard(shown[0], limit: family == .systemLarge ? 4 : 2, showsReset: family != .systemSmall)
        } else if family == .systemSmall {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(shown.prefix(2)) { plan in planCard(plan, limit: 1, showsReset: false) }
            }
        } else {
            let rows = Self.rows(Array(shown.prefix(family == .systemMedium ? 2 : 4)), columns: 2)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(row) { plan in
                            planCard(plan, limit: 2, showsReset: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if row.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                    }
                }
            }
        }
    }

    private static func rows<Item>(_ items: [Item], columns: Int) -> [[Item]] {
        stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
    }

    /// Rings or dials: each plan's tightest limit, the share left in the middle.
    private func gauges(_ shown: [BighelpUsageSnapshot.Plan], dials: Bool) -> some View {
        let columns = family == .systemSmall ? 2 : family == .systemMedium ? 4 : 3
        let size: CGFloat = switch family {
        case .systemSmall: dials ? 66 : 52
        case .systemMedium: dials ? 74 : 62
        default: dials ? 80 : 62
        }
        let rows = Self.rows(Array(shown.prefix(family == .systemLarge ? 8 : 4)), columns: columns)
        return VStack(spacing: family == .systemLarge ? 14 : family == .systemSmall ? 8 : 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(row) { plan in gaugeTile(plan, dial: dials, size: size).frame(maxWidth: .infinity) }
                    ForEach(row.count..<columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                }
            }
        }
        .padding(.top, family == .systemMedium ? 4 : 0)
    }

    private func gaugeTile(_ plan: BighelpUsageSnapshot.Plan, dial: Bool, size: CGFloat) -> some View {
        let limit = plan.tightest
        let tint = limit.map { UsageWidgetFormat.tint(left: $0.leftPercent, accent: colors.accent) } ?? colors.secondary
        let fraction = (limit?.leftPercent ?? 0) / 100
        let line: CGFloat = family == .systemSmall ? 6 : 6.5
        let middle = limit.map { UsageWidgetFormat.percent($0.leftPercent) } ?? plan.facts.first?.value ?? "–"
        return VStack(spacing: 2) {
            ZStack(alignment: dial ? .bottom : .center) {
                if dial {
                    UsageWidgetDial(fraction: fraction, tint: tint, lineWidth: line)
                } else {
                    UsageWidgetRing(fraction: fraction, tint: tint, lineWidth: line)
                }
                Text(middle)
                    .font(family == .systemSmall ? .caption.weight(.bold) : .callout.weight(.bold))
                    .monospacedDigit().foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.5)
                    .padding(.horizontal, line + 3)
            }
            .frame(width: size, height: dial ? size / 2 + line / 2 + 1 : size)
            Text(plan.name).font(.caption2.weight(.semibold)).lineLimit(1)
            if family != .systemSmall, let detail = gaugeDetail(plan) {
                Text(detail).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(plan))
    }

    /// Under a gauge: its limit, and on a large widget when it resets.
    private func gaugeDetail(_ plan: BighelpUsageSnapshot.Plan) -> String? {
        guard let limit = plan.tightest else { return plan.facts.first?.label ?? plan.note }
        guard family == .systemLarge, let resetsAt = limit.resetsAt else { return limit.label }
        return limit.label + " · " + resetsAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    private static func spoken(_ plan: BighelpUsageSnapshot.Plan) -> String {
        let limits = plan.limits.map { "\($0.label), \(UsageWidgetFormat.percent($0.leftPercent)) left" }
        return ([plan.name] + (limits.isEmpty ? [withoutLimits(plan)] : limits)).joined(separator: ", ")
    }

    /// Stacked rings: a plan's first limit outside, its second inside.
    @ViewBuilder private func stackedRings(_ shown: [BighelpUsageSnapshot.Plan]) -> some View {
        if family == .systemLarge {
            let rows = Self.rows(Array(shown.prefix(6)), columns: 2)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .center, spacing: 12) {
                        ForEach(row) { plan in
                            HStack(spacing: 10) {
                                stacked(plan, size: 56)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(plan.name).font(.caption2.weight(.semibold)).lineLimit(1)
                                    // The share first: a long limit name ("Session (5 hours)") can't push it out.
                                    ForEach(Array(plan.limits.prefix(2).enumerated()), id: \.offset) { _, limit in
                                        HStack(spacing: 3) {
                                            Text(UsageWidgetFormat.percent(limit.leftPercent))
                                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                                .foregroundStyle(UsageWidgetFormat.tint(left: limit.leftPercent, accent: colors.accent))
                                                .fixedSize()
                                            Text(limit.label).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                                        }
                                    }
                                    if plan.limits.isEmpty {
                                        Text(Self.withoutLimits(plan)).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Self.spoken(plan))
                        }
                        if row.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
                    }
                }
            }
        } else {
            let count = family == .systemSmall ? 2 : 3
            HStack(alignment: .top, spacing: 8) {
                ForEach(shown.prefix(count)) { plan in
                    VStack(spacing: 3) {
                        stacked(plan, size: family == .systemSmall ? 60 : 66)
                        Text(plan.name).font(.caption2.weight(.semibold)).lineLimit(1)
                        Text(plan.limits.isEmpty ? Self.withoutLimits(plan)
                             : plan.limits.prefix(2).map { UsageWidgetFormat.percent($0.leftPercent) }.joined(separator: " · "))
                            .font(.caption2.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(plan.tightest.map { UsageWidgetFormat.tint(left: $0.leftPercent, accent: colors.accent) }
                                             ?? colors.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.spoken(plan))
                }
                ForEach(min(shown.count, count)..<count, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
            }
            .padding(.top, 2)
        }
    }

    private func stacked(_ plan: BighelpUsageSnapshot.Plan, size: CGFloat) -> some View {
        let line: CGFloat = size >= 60 ? 6 : 5.5
        func ring(_ limit: BighelpUsageSnapshot.Plan.Limit?) -> UsageWidgetRing {
            UsageWidgetRing(fraction: (limit?.leftPercent ?? 0) / 100,
                            tint: limit.map { UsageWidgetFormat.tint(left: $0.leftPercent, accent: colors.accent) } ?? colors.secondary,
                            lineWidth: line)
        }
        return ZStack {
            ring(plan.limits.first)
            if plan.limits.count > 1 { ring(plan.limits[1]).padding(line + 2.5) }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var plansFallback: some View {
        Text(snapshot.plansNote ?? (snapshot.plans == nil
             ? snapshot.note ?? "Your plans show here once bighelp reads them."
             : "No plans found on your computer."))
            .font(.caption).foregroundStyle(colors.secondary)
    }

    private func planCard(_ plan: BighelpUsageSnapshot.Plan, limit: Int, showsReset: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(plan.name).font(.caption.weight(.semibold)).lineLimit(1)
                if let name = plan.plan {
                    Text(name).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                }
            }
            if !plan.limits.isEmpty {
                ForEach(Array(plan.limits.prefix(limit).enumerated()), id: \.offset) { _, item in
                    limitBar(item, showsReset: showsReset)
                }
            } else if let fact = plan.facts.first {
                Text("\(fact.label) \(fact.value)").font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
            } else if let note = plan.note {
                Text(note).font(.caption2).foregroundStyle(colors.secondary).lineLimit(2)
            }
        }
    }

    private func limitBar(_ limit: BighelpUsageSnapshot.Plan.Limit, showsReset: Bool) -> some View {
        let tint = UsageWidgetFormat.tint(left: limit.leftPercent, accent: colors.accent)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(limit.label).font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(UsageWidgetFormat.percent(limit.leftPercent)) left")
                    .font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(tint).lineLimit(1)
            }
            UsageWidgetBar(fraction: limit.leftPercent / 100, tint: tint)
            if showsReset, let resetsAt = limit.resetsAt {
                Text("Resets \(resetsAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2).foregroundStyle(colors.secondary).lineLimit(1)
            }
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
            Text(waiting).font(.caption).foregroundStyle(colors.secondary)
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
            Text(snapshot.totals == nil ? waiting : "No model use in the last \(snapshot.days) days.")
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
                        Text("No numbers yet").font(.caption)
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

/// A ring filled clockwise from the top to a share, on a faint track.
struct UsageWidgetRing: View {
    let fraction: Double
    let tint: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            if fraction > 0 {
                Circle().trim(from: 0, to: min(1, fraction))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentable()
            }
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// A half ring over its middle, filled left to right to a share. Drawn as a whole circle's top half.
struct UsageWidgetDial: View {
    let fraction: Double
    let tint: Color
    let lineWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                arc(1).stroke(tint.opacity(0.18), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                if fraction > 0 {
                    arc(fraction).stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .widgetAccentable()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.width)
        }
        .clipped()
        .accessibilityHidden(true)
    }

    /// From nine o'clock over the top: a circle's path starts at three and runs clockwise.
    private func arc(_ share: Double) -> some Shape {
        Circle().inset(by: lineWidth / 2).trim(from: 0.5, to: 0.5 + 0.5 * min(1, share))
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
        .description("Plans and limits, estimated cost, tokens or top models. Pick a gateway and what to show.")
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
