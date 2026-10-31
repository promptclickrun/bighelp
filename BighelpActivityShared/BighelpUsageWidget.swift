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
            /// The plugin's own count, like "1,212 of 1,500 used". Older snapshots have none.
            var detail: String? = nil

            var usedPercent: Double { max(0, min(100, 100 - leftPercent)) }

            /// Past its reset the saved share no longer says anything.
            func hasReset(at date: Date) -> Bool { resetsAt.map { $0 <= date } ?? false }

            /// Used up: shows as 100%, until it resets.
            func isFull(at date: Date) -> Bool { !hasReset(at: date) && usedPercent.rounded() >= 100 }
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
        /// A provider logo bundled with the app and the widgets ("ProviderLogoClaude"); none draws an initial.
        var logo: String? = nil
        /// How much larger than its canvas the logo draws, so every mark looks one size, as in the app.
        var logoScale: Double? = nil
        /// The provider's own color, "RRGGBB"; none takes the app's accent.
        var tint: String? = nil
        /// What its name is saved under (`BighelpPlanNames`): one key for a provider, whatever id the host
        /// gave it this time. Older snapshots have none.
        var key: String? = nil

        var tightest: Limit? { limits.min { $0.leftPercent < $1.leftPercent } }

        /// The limit closest to running out at a time; ones that reset since count last.
        func tightest(at date: Date) -> Limit? {
            limits.max { Self.risk($0, at: date) < Self.risk($1, at: date) }
        }

        static func risk(_ limit: Limit, at date: Date) -> Double {
            limit.hasReset(at: date) ? -1 : limit.usedPercent
        }
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
        return encode(all)
    }

    /// Forgets the names given on gateways taken out of bighelp.
    static func keep(gateways ids: Set<String>, in defaults: UserDefaults? = defaults) {
        guard let defaults else { return }
        var all = decode(defaults.string(forKey: key) ?? "")
        let gone = all.keys.filter { UUID(uuidString: $0) != nil && !ids.contains($0) }
        guard !gone.isEmpty else { return }
        for id in gone { all[id] = nil }
        defaults.set(encode(all), forKey: key)
    }

    private static func decode(_ names: String) -> [String: [String: String]] {
        guard !names.isEmpty, names.utf8.count <= 65_536 else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: Data(names.utf8))) ?? [:]
    }

    private static func encode(_ all: [String: [String: String]]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard !all.isEmpty, let data = try? encoder.encode(all) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Configuration

/// Each size has its own styles; the configuration shows only the size's own list.
enum UsageSmallStyle: String, AppEnum {
    case automatic, ring, twoMeters, whatsLeft, fourPlans, fourPlanMeters, closest, spending

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Style")
    static let caseDisplayRepresentations: [UsageSmallStyle: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(title: "Automatic", subtitle: "One plan, or the one closest to its limit"),
        .ring: DisplayRepresentation(title: "Ring", subtitle: "One plan's tightest limit"),
        .twoMeters: DisplayRepresentation(title: "Two meters", subtitle: "One plan's first two limits"),
        .whatsLeft: DisplayRepresentation(title: "What's left", subtitle: "How much of one plan is left"),
        .fourPlans: DisplayRepresentation(title: "Four plans as rings", subtitle: "Each plan's tightest limit"),
        .fourPlanMeters: DisplayRepresentation(title: "Four plans as meters", subtitle: "Each plan's tightest limit"),
        .closest: DisplayRepresentation(title: "Closest to limit", subtitle: "The plan nearest its limit"),
        .spending: DisplayRepresentation(title: "Cost and tokens", subtitle: "The last 30 days"),
    ]
}

enum UsageMediumStyle: String, AppEnum {
    case automatic, onePlan, everyPlan, everyPlanRings, nextResets, sideBySide, spending

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Style")
    static let caseDisplayRepresentations: [UsageMediumStyle: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(title: "Automatic", subtitle: "One plan, or every plan"),
        .onePlan: DisplayRepresentation(title: "One plan", subtitle: "Every limit with its reset"),
        .everyPlan: DisplayRepresentation(title: "Every plan as meters", subtitle: "Each plan's tightest limit, nearest first"),
        .everyPlanRings: DisplayRepresentation(title: "Every plan as rings", subtitle: "Each plan's tightest limit, nearest first"),
        .nextResets: DisplayRepresentation(title: "Next resets", subtitle: "When each plan's limit frees up"),
        .sideBySide: DisplayRepresentation(title: "Side by side", subtitle: "Two plans and their limits"),
        .spending: DisplayRepresentation(title: "Cost and tokens", subtitle: "The last 30 days"),
    ]
}

enum UsageLargeStyle: String, AppEnum {
    case automatic, everyPlan, everyPlanRings, onePlan, spending

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Style")
    static let caseDisplayRepresentations: [UsageLargeStyle: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(title: "Automatic", subtitle: "Every plan, or one plan in detail"),
        .everyPlan: DisplayRepresentation(title: "Every plan as meters", subtitle: "Every limit of every plan"),
        .everyPlanRings: DisplayRepresentation(title: "Every plan as rings", subtitle: "Each plan's tightest limit"),
        .onePlan: DisplayRepresentation(title: "One plan", subtitle: "Its limits as rings"),
        .spending: DisplayRepresentation(title: "Cost and tokens", subtitle: "The last 30 days and top models"),
    ]
}

/// The Lock Screen's rectangle.
enum UsageLockStyle: String, AppEnum {
    case automatic, onePlan, everyPlan, nextReset

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Style")
    static let caseDisplayRepresentations: [UsageLockStyle: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(title: "Automatic", subtitle: "One plan, or every plan"),
        .onePlan: DisplayRepresentation(title: "One plan", subtitle: "Two of its limits"),
        .everyPlan: DisplayRepresentation(title: "Every plan", subtitle: "Three plans' tightest limits"),
        .nextReset: DisplayRepresentation(title: "Next reset", subtitle: "The next limit to free up"),
    ]
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
        "Choose a gateway, a style, and the plans to show.")

    @Parameter(title: "Gateway")
    var gateway: BighelpWidgetGateway?

    @Parameter(title: "Style", default: .automatic)
    var smallStyle: UsageSmallStyle

    @Parameter(title: "Style", default: .automatic)
    var mediumStyle: UsageMediumStyle

    @Parameter(title: "Style", default: .automatic)
    var largeStyle: UsageLargeStyle

    @Parameter(title: "Style", default: .automatic)
    var lockStyle: UsageLockStyle

    @Parameter(title: "Plans", description: "Leave it empty to show every plan. Styles about one plan show the first.",
               size: [.systemSmall: 4, .systemMedium: 4, .systemLarge: 6, .systemExtraLarge: 6])
    var plans: [UsageWidgetPlan]?

    /// The one plan a widget could show before Plans took several. Left out of the summary, so it no longer
    /// shows; a widget set to a plan then keeps it until Plans is set.
    @Parameter(title: "Plan")
    var plan: UsageWidgetPlan?

    /// The plans to show, in their order; none shows every plan.
    var planIDs: [String] {
        let picked = (plans ?? []).map(\.id)
        return picked.isEmpty ? plan.map { [$0.id] } ?? [] : picked
    }

    static var parameterSummary: some ParameterSummary {
        Switch(.widgetFamily) {
            Case(.systemSmall) {
                Summary {
                    \.$gateway
                    \.$smallStyle
                    \.$plans
                }
            }
            Case(.systemMedium) {
                Summary {
                    \.$gateway
                    \.$mediumStyle
                    \.$plans
                }
            }
            Case(.systemLarge) {
                Summary {
                    \.$gateway
                    \.$largeStyle
                    \.$plans
                }
            }
            Case(.accessoryRectangular) {
                Summary {
                    \.$gateway
                    \.$lockStyle
                    \.$plans
                }
            }
            DefaultCase {
                Summary {
                    \.$gateway
                    \.$plans
                }
            }
        }
    }
}

struct UsageWidgetStyles: Equatable, Sendable {
    var small = UsageSmallStyle.automatic
    var medium = UsageMediumStyle.automatic
    var large = UsageLargeStyle.automatic
    var lock = UsageLockStyle.automatic
}

// MARK: - Timeline

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: BighelpUsageSnapshot
    let palette: BighelpWidgetSnapshot
    var styles = UsageWidgetStyles()
    /// The plans picked, in their order; none shows every plan.
    var planIDs: [String] = []
    /// The chosen gateway; nil follows the one in use. A tap opens Usage there.
    var hostID: String? = nil

    typealias Plan = BighelpUsageSnapshot.Plan
    typealias Limit = BighelpUsageSnapshot.Plan.Limit

    /// The picked plans in their order (one the computer no longer has drops out), else every plan.
    var plans: [Plan] {
        let all = snapshot.plans ?? []
        guard !planIDs.isEmpty else { return all }
        return planIDs.compactMap { id in all.first { $0.id == id } }
    }

    /// Exactly one plan picked, and the computer has it: styles about one plan show it.
    var picksOnePlan: Bool { planIDs.count == 1 && !plans.isEmpty }

    /// The plans with limits to draw, in the app's order (the one Hermes uses first).
    var metered: [Plan] { plans.filter { !$0.limits.isEmpty } }

    /// The first plan picked, else the one Hermes uses, else the first with limits.
    var chosen: Plan? {
        if !planIDs.isEmpty, let picked = plans.first { return picked }
        return metered.first(where: \.inUse) ?? metered.first ?? plans.first
    }

    /// Plans with limits, the one nearest its limit first; picked plans keep the order they were picked in.
    var byRisk: [Plan] {
        guard planIDs.isEmpty else { return metered }
        return metered.enumerated().sorted { lhs, rhs in
            let left = risk(lhs.element), right = risk(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    /// The limit closest to running out, across every plan.
    var closest: (plan: Plan, limit: Limit)? {
        byRisk.first.flatMap { plan in plan.tightest(at: date).map { (plan, $0) } }
    }

    func risk(_ plan: Plan) -> Double { plan.tightest(at: date).map { Plan.risk($0, at: date) } ?? -2 }

    /// The plan's next reset still ahead.
    func nextReset(_ plan: Plan) -> (limit: Limit, date: Date)? {
        plan.limits.compactMap { limit in limit.resetsAt.flatMap { $0 > date ? (limit, $0) : nil } }
            .min { $0.1 < $1.1 }
    }

    /// Hours old: the shares may have moved since.
    var isStale: Bool { date.timeIntervalSince(snapshot.generatedAt) > 3 * 3_600 }

    /// Made-up plans for the widget gallery before bighelp has read any.
    static let preview: UsageWidgetEntry = {
        let calendar = Calendar.current
        let now = Date.now
        let today = calendar.startOfDay(for: now)
        let daily = (0..<30).map { offset -> BighelpUsageSnapshot.Day in
            let wave = Double((offset * 7) % 11) + 3
            return .init(date: calendar.date(byAdding: .day, value: offset - 29, to: today) ?? today,
                         cost: wave * 1.9, tokens: Int(wave * 310_000))
        }
        return UsageWidgetEntry(
            date: now,
            snapshot: BighelpUsageSnapshot(
                plans: [
                    .init(id: "sol", name: "Sol", plan: "Max", limits: [
                        .init(label: "Session (5 hours)", leftPercent: 38, resetsAt: now.addingTimeInterval(5_280)),
                        .init(label: "Week", leftPercent: 59, resetsAt: now.addingTimeInterval(241_200)),
                    ], inUse: true, tint: "D97757"),
                    .init(id: "luna", name: "Luna", plan: "Pro", limits: [
                        .init(label: "Session (5 hours)", leftPercent: 77, resetsAt: now.addingTimeInterval(9_780)),
                        .init(label: "Week", leftPercent: 27, resetsAt: now.addingTimeInterval(165_600)),
                    ], tint: "10A37F"),
                    .init(id: "nova", name: "Nova", plan: "Plus", limits: [
                        .init(label: "Monthly credits", leftPercent: 19, resetsAt: now.addingTimeInterval(17_280),
                              detail: "1,212 of 1,500 used"),
                    ], tint: "8957E5"),
                ],
                totals: .init(cost: 214.37, billedCost: 0, inputTokens: 21_400_000, outputTokens: 6_100_000,
                              cacheReadTokens: 48_000_000, sessions: 132),
                models: [
                    .init(id: "a", name: "Sol 6", provider: "Sol", cost: 120.5, tokens: 9_800_000),
                    .init(id: "b", name: "Luna 6", provider: "Luna", cost: 61.2, tokens: 8_100_000),
                    .init(id: "c", name: "Nova 4", provider: "Nova", cost: 32.67, tokens: 9_600_000),
                ],
                daily: daily, generatedAt: now),
            palette: .empty)
    }()
}

struct UsageWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry { .preview }

    func snapshot(for configuration: UsageWidgetIntent, in context: Context) async -> UsageWidgetEntry {
        let hostID = configuration.gateway?.hostID
        let entry = entry(for: configuration, at: .now, snapshot: .shown(gateway: hostID), palette: .load(gateway: hostID))
        guard context.isPreview, !entry.snapshot.hasData else { return entry }
        var preview = UsageWidgetEntry.preview
        preview.styles = entry.styles
        return preview
    }

    func timeline(for configuration: UsageWidgetIntent, in context: Context) async -> Timeline<UsageWidgetEntry> {
        // The app reloads this when it reads new numbers, also from the background. Until then the
        // entries keep the countdowns current and switch a limit back on as it resets.
        let hostID = configuration.gateway?.hostID
        let snapshot = BighelpUsageSnapshot.shown(gateway: hostID), palette = BighelpWidgetSnapshot.load(gateway: hostID)
        let entries = Self.dates(from: .now, snapshot: snapshot)
            .map { entry(for: configuration, at: $0, snapshot: snapshot, palette: palette) }
        return Timeline(entries: entries, policy: .atEnd)
    }

    /// Every five minutes for an hour, and each reset in that hour.
    static func dates(from now: Date, snapshot: BighelpUsageSnapshot) -> [Date] {
        let end = now.addingTimeInterval(3_600)
        let steps = (0...12).map { now.addingTimeInterval(Double($0) * 300) }
        let resets = (snapshot.plans ?? []).flatMap(\.limits).compactMap(\.resetsAt).filter { $0 > now && $0 < end }
        return Array(Set(steps + resets)).sorted()
    }

    private func entry(for configuration: UsageWidgetIntent, at date: Date, snapshot: BighelpUsageSnapshot,
                       palette: BighelpWidgetSnapshot) -> UsageWidgetEntry {
        UsageWidgetEntry(date: date, snapshot: snapshot, palette: palette,
                         styles: UsageWidgetStyles(small: configuration.smallStyle, medium: configuration.mediumStyle,
                                                   large: configuration.largeStyle, lock: configuration.lockStyle),
                         planIDs: configuration.planIDs, hostID: configuration.gateway?.hostID)
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
        .description("How much of each plan's limits you've used, and when they reset. Pick a gateway and a style.")
        .supportedFamilies(Self.families)
        .bighelpWidgetPlacement()
    }

    private static var families: [WidgetFamily] {
        #if os(visionOS)
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        #else
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
         .accessoryInline, .accessoryRectangular, .accessoryCircular]
        #endif
    }
}
