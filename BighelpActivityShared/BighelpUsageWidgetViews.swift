import SwiftUI
import WidgetKit

/// What a size and style come to with the plans there are.
enum UsageWidgetLayout: Equatable {
    case ring, twoMeters, whatsLeft, fourPlans, fourPlanMeters, closest
    case onePlan, everyPlan, everyPlanRings, nextResets, sideBySide
    case dashboard, deepDive, columns
    case spending
}

extension UsageWidgetEntry {
    func layout(for family: WidgetFamily) -> UsageWidgetLayout {
        let onePlan = picksOnePlan || metered.count <= 1
        // Nothing with limits, but 30 days of cost: that's what there is to show.
        let spendingOnly = metered.isEmpty && snapshot.totals != nil
        switch family {
        case .systemSmall:
            switch styles.small {
            case .automatic: return spendingOnly ? .spending : onePlan ? .ring : .closest
            case .ring: return .ring
            case .twoMeters: return .twoMeters
            case .whatsLeft: return .whatsLeft
            case .fourPlans: return metered.count > 1 ? .fourPlans : .ring
            case .fourPlanMeters: return metered.count > 1 ? .fourPlanMeters : .twoMeters
            case .closest: return .closest
            case .spending: return .spending
            }
        case .systemMedium:
            switch styles.medium {
            case .automatic: return spendingOnly ? .spending : onePlan ? .onePlan : .everyPlan
            case .onePlan: return .onePlan
            case .everyPlan: return .everyPlan
            case .everyPlanRings: return metered.count > 1 ? .everyPlanRings : .onePlan
            case .nextResets: return metered.contains { nextReset($0) != nil } ? .nextResets : .everyPlan
            case .sideBySide: return metered.count > 1 ? .sideBySide : .onePlan
            case .spending: return .spending
            }
        case .systemLarge:
            switch styles.large {
            case .automatic: return spendingOnly ? .spending : onePlan ? .deepDive : .dashboard
            case .everyPlan: return .dashboard
            case .everyPlanRings: return metered.count > 1 ? .everyPlanRings : .deepDive
            case .onePlan: return .deepDive
            case .spending: return .spending
            }
        default:
            return spendingOnly ? .spending : .columns
        }
    }

    /// No numbers yet: why, or that they come on their own.
    var waiting: String { snapshot.note ?? "Your numbers show here once bighelp reads them." }

    /// Layouts about one plan; the rest show several.
    static func showsOnePlan(_ layout: UsageWidgetLayout) -> Bool {
        [.ring, .twoMeters, .whatsLeft, .onePlan, .deepDive].contains(layout)
    }
}

struct BighelpUsageWidgetView: View {
    let entry: UsageWidgetEntry
    /// Draws one size outside WidgetKit, for the app's own pictures of the widget.
    var familyOverride: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.bighelpWidgetColors) private var colors
    @Environment(\.colorScheme) private var scheme
    @Environment(\.usageWidgetTintPreview) private var tintPreview

    private var family: WidgetFamily { familyOverride ?? widgetFamily }
    private var ink: UsageWidgetInk { UsageWidgetInk(colors: colors, scheme: scheme, tintPreview: tintPreview) }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(BighelpWidgetSnapshot.link(BighelpUsageSnapshot.url, onGateway: entry.hostID))
    }

    @ViewBuilder private var content: some View {
        if family.isAccessory {
            #if os(iOS)
            UsageLockScreenView(entry: entry, family: family, ink: ink)
            #endif
        } else if !entry.snapshot.hasData {
            UsageWidgetMessage(text: entry.waiting, ink: ink)
        } else {
            let layout = entry.layout(for: family)
            if layout == .spending {
                UsageSpendingView(entry: entry, family: family, ink: ink)
            } else if let message = plansMessage(layout) {
                UsageWidgetMessage(text: message, ink: ink)
            } else if UsageWidgetEntry.showsOnePlan(layout), let plan = entry.chosen, plan.limits.isEmpty {
                UsagePlanFactsView(plans: [plan], ink: ink)
            } else if !UsageWidgetEntry.showsOnePlan(layout), entry.metered.isEmpty {
                UsagePlanFactsView(plans: entry.plans, ink: ink)
            } else {
                limits(layout)
            }
        }
    }

    /// Why there's nothing to draw: the plugin can't read plans, or the computer has none.
    private func plansMessage(_ layout: UsageWidgetLayout) -> String? {
        guard let plans = entry.snapshot.plans else {
            return entry.snapshot.plansNote ?? entry.snapshot.note ?? "Your plans show here once bighelp reads them."
        }
        return plans.isEmpty ? "No plans found on your computer." : nil
    }

    @ViewBuilder private func limits(_ layout: UsageWidgetLayout) -> some View {
        switch layout {
        case .ring, .twoMeters, .whatsLeft:
            if let plan = entry.chosen {
                if let full = plan.tightest(at: entry.date), full.isFull(at: entry.date) {
                    UsageLimitReachedView(plan: plan, limit: full, now: entry.date, ink: ink)
                } else {
                    UsageSmallPlanView(layout: layout, plan: plan, entry: entry, ink: ink)
                }
            }
        case .closest:
            if let closest = entry.closest {
                if closest.limit.isFull(at: entry.date) {
                    UsageLimitReachedView(plan: closest.plan, limit: closest.limit, now: entry.date, ink: ink)
                } else {
                    UsageClosestView(entry: entry, plan: closest.plan, limit: closest.limit, ink: ink)
                }
            }
        case .fourPlans: UsageFourPlansView(entry: entry, ink: ink)
        case .fourPlanMeters: UsagePlanMetersView(entry: entry, ink: ink)
        case .everyPlanRings: UsagePlanRingsView(entry: entry, ink: ink, large: family == .systemLarge)
        case .onePlan: if let plan = entry.chosen { UsageOnePlanView(entry: entry, plan: plan, ink: ink) }
        case .everyPlan: UsageEveryPlanView(entry: entry, ink: ink)
        case .nextResets: UsageNextResetsView(entry: entry, ink: ink)
        case .sideBySide: UsageSideBySideView(entry: entry, ink: ink)
        case .dashboard: UsageDashboardView(entry: entry, ink: ink)
        case .deepDive: if let plan = entry.chosen { UsageDeepDiveView(entry: entry, plan: plan, ink: ink) }
        case .columns: UsageColumnsView(entry: entry, ink: ink)
        case .spending: EmptyView()
        }
    }
}

// MARK: - Shared pieces

/// A plain message where numbers would be.
struct UsageWidgetMessage: View {
    let text: String
    let ink: UsageWidgetInk

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.subheadline.weight(.bold)).foregroundStyle(ink.colors.accent).widgetAccentable()
                Text("Usage").font(.subheadline.weight(.semibold))
            }
            Spacer(minLength: 0)
            Text(text).font(.caption).foregroundStyle(ink.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Plans with no limits to draw: their balance or why they have none.
struct UsagePlanFactsView: View {
    let plans: [BighelpUsageSnapshot.Plan]
    let ink: UsageWidgetInk

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(plans.prefix(3)) { plan in
                VStack(alignment: .leading, spacing: 3) {
                    UsageWidgetPlanTitle(plan: plan, ink: ink)
                    if let fact = plan.facts.first {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(fact.label).foregroundStyle(ink.secondary)
                            Spacer(minLength: 4)
                            Text(fact.value).fontWeight(.semibold)
                        }
                        .font(.caption)
                    } else if let note = plan.note {
                        Text(note).font(.caption).foregroundStyle(ink.secondary).lineLimit(2)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A limit's ring with its share in the middle; a lock and the countdown once used up.
struct UsageWidgetRingBlock: View {
    let plan: BighelpUsageSnapshot.Plan
    let limit: BighelpUsageSnapshot.Plan.Limit
    let now: Date
    let ink: UsageWidgetInk
    let diameter: CGFloat
    var lineWidth: CGFloat = 10
    var numberFont: Font = .title2.weight(.bold)
    var showsLabel = true

    var body: some View {
        ZStack {
            UsageWidgetRing(fraction: limit.hasReset(at: now) ? 0 : limit.usedPercent / 100,
                            color: ink.fill(plan, used: limit.usedPercent), track: ink.track, lineWidth: lineWidth)
            center
                .padding(lineWidth + 4)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement()
        .accessibilityLabel(limit.accessibilityText(plan: plan.name, at: now))
    }

    @ViewBuilder private var center: some View {
        if limit.hasReset(at: now) {
            Text("Reset").font(.subheadline.weight(.semibold)).foregroundStyle(ink.secondary)
        } else if limit.isFull(at: now) {
            VStack(spacing: 1) {
                Image(systemName: "lock.fill").font(.headline).foregroundStyle(ink.alert)
                if let resetsAt = limit.resetsAt {
                    UsageWidgetCountdown(until: resetsAt, now: now, font: .caption.weight(.bold))
                }
            }
        } else {
            // With large text the label goes before it runs into the ring.
            ViewThatFits {
                VStack(spacing: 0) {
                    percent
                    if showsLabel {
                        Text(UsageWidgetFormat.kindLabel(limit.label))
                            .font(.caption2).foregroundStyle(ink.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                percent
            }
        }
    }

    private var percent: some View {
        UsageWidgetPercent(value: limit.usedPercent, font: numberFont, signFont: numberFont,
                           color: ink.number(used: limit.usedPercent))
    }
}

/// "Resets 3:40 PM", with the time standing out.
struct UsageResetLine: View {
    let prefix: String
    let date: Date
    let now: Date
    let ink: UsageWidgetInk
    var font: Font = .footnote

    var body: some View {
        (Text(prefix + " ").foregroundStyle(ink.secondary)
         + Text(UsageWidgetFormat.moment(date, from: now)).foregroundStyle(ink.primary).fontWeight(.medium))
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// The plan's name, with when the numbers were read once they're hours old.
struct UsageSmallTitle: View {
    let plan: BighelpUsageSnapshot.Plan
    let entry: UsageWidgetEntry
    let ink: UsageWidgetInk
    var title: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            UsageWidgetLogo(plan: plan, size: 16, ink: ink)
            Text(title ?? plan.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 2)
            if entry.isStale {
                Image(systemName: "clock").font(.caption2).foregroundStyle(ink.secondary)
                    .accessibilityLabel(UsageWidgetFormat.updated(entry.snapshot.generatedAt, now: entry.date))
            }
        }
    }
}

// MARK: - Small

/// Ring, Two meters and What's left: one plan.
struct UsageSmallPlanView: View {
    let layout: UsageWidgetLayout
    let plan: BighelpUsageSnapshot.Plan
    let entry: UsageWidgetEntry
    let ink: UsageWidgetInk

    @ScaledMetric(relativeTo: .largeTitle) private var bigNumber: CGFloat = 46

    private var now: Date { entry.date }
    private var tightest: BighelpUsageSnapshot.Plan.Limit? { plan.tightest(at: now) }

    var body: some View {
        switch layout {
        case .twoMeters: twoMeters
        case .whatsLeft: whatsLeft
        default: ring
        }
    }

    private var ring: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsageSmallTitle(plan: plan, entry: entry, ink: ink)
            Spacer(minLength: 4)
            if let tightest {
                UsageWidgetRingBlock(plan: plan, limit: tightest, now: now, ink: ink, diameter: 88, lineWidth: 9)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 4)
                if let resetsAt = tightest.resetsAt, resetsAt > now {
                    UsageResetLine(prefix: "Resets", date: resetsAt, now: now, ink: ink)
                }
            }
        }
    }

    private var twoMeters: some View {
        let shown = Array(plan.limits.prefix(2))
        return VStack(alignment: .leading, spacing: 0) {
            UsageSmallTitle(plan: plan, entry: entry, ink: ink)
            Spacer(minLength: 4)
            ForEach(Array(shown.enumerated()), id: \.offset) { index, limit in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(UsageWidgetFormat.kindLabel(limit.label).uppercased())
                            .font(.caption2.weight(.semibold)).tracking(0.4).foregroundStyle(ink.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Spacer(minLength: 2)
                        meterNumber(limit)
                    }
                    UsageWidgetMeter(fraction: limit.hasReset(at: now) ? 0 : limit.usedPercent / 100,
                                     color: ink.fill(plan, used: limit.usedPercent), track: ink.track, height: 7)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(limit.accessibilityText(plan: plan.name, at: now))
                if index < shown.count - 1 { Spacer(minLength: 6) }
            }
            Spacer(minLength: 4)
            if let last = shown.last(where: { ($0.resetsAt ?? .distantPast) > now }), let resetsAt = last.resetsAt {
                ViewThatFits(in: .horizontal) {
                    UsageResetLine(prefix: "\(UsageWidgetFormat.kindLabel(last.label)) resets", date: resetsAt, now: now,
                                   ink: ink, font: .caption)
                        .fixedSize()
                    UsageResetLine(prefix: "Resets", date: resetsAt, now: now, ink: ink, font: .caption)
                }
            }
        }
    }

    @ViewBuilder private func meterNumber(_ limit: BighelpUsageSnapshot.Plan.Limit) -> some View {
        if limit.hasReset(at: now) {
            Text("Reset").font(.subheadline.weight(.semibold)).foregroundStyle(ink.secondary)
        } else {
            UsageWidgetPercent(value: limit.usedPercent, font: .title2.weight(.bold), signFont: .subheadline.weight(.bold),
                               color: ink.number(used: limit.usedPercent))
        }
    }

    private var whatsLeft: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let tightest {
                UsageSmallTitle(plan: plan, entry: entry, ink: ink,
                                title: UsageWidgetFormat.shortLabel(tightest.label))
                Spacer(minLength: 2)
                if tightest.hasReset(at: now) {
                    Text("Reset").font(.title.weight(.bold))
                } else {
                    UsageWidgetPercent(value: tightest.leftPercent, font: .system(size: bigNumber, weight: .bold),
                                       signFont: .title2.weight(.bold), color: ink.primary)
                }
                Text("left on \(plan.name)").font(.subheadline).lineLimit(2).minimumScaleFactor(0.8)
                Spacer(minLength: 6)
                UsageWidgetMeter(fraction: tightest.hasReset(at: now) ? 0 : tightest.usedPercent / 100,
                                 color: ink.fill(plan, used: tightest.usedPercent), track: ink.track, height: 7)
                if let resetsAt = tightest.resetsAt, resetsAt > now {
                    UsageResetLine(prefix: "Resets", date: resetsAt, now: now, ink: ink, font: .caption)
                        .padding(.top, 7)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A plan's limit used up: the lock, the plan's other limits, and the countdown to its reset.
struct UsageLimitReachedView: View {
    let plan: BighelpUsageSnapshot.Plan
    let limit: BighelpUsageSnapshot.Plan.Limit
    let now: Date
    let ink: UsageWidgetInk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The lock says it too, so "LIMIT" goes before the name is cut short.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    UsageWidgetLogo(plan: plan, size: 16, ink: ink)
                    Text(plan.name).font(.subheadline.weight(.semibold)).fixedSize()
                    Spacer(minLength: 2)
                    Text("LIMIT").font(.caption.weight(.bold)).foregroundStyle(ink.alert).fixedSize()
                }
                HStack(spacing: 6) {
                    UsageWidgetLogo(plan: plan, size: 16, ink: ink)
                    Text(plan.name).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                ZStack {
                    UsageWidgetRing(fraction: 1, color: ink.alert, track: ink.track, lineWidth: 7)
                    Image(systemName: "lock.fill").font(.headline).foregroundStyle(ink.alert).widgetAccentable()
                }
                .frame(width: 50, height: 50)
                // Whole lines only: a plan's other limits drop out before any is cut short.
                ViewThatFits(in: .horizontal) {
                    status(others: 2).fixedSize()
                    status(others: 1).fixedSize()
                    status(others: 0).fixedSize()
                    VStack(alignment: .leading, spacing: 0) {
                        Text(UsageWidgetFormat.kindLabel(limit.label)).fontWeight(.semibold)
                        Text("full").fontWeight(.semibold)
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                }
                .font(.caption)
                .foregroundStyle(ink.secondary)
            }
            Spacer(minLength: 4)
            if let resetsAt = limit.resetsAt {
                Text("Back in").font(.caption).foregroundStyle(ink.secondary)
                UsageWidgetCountdown(until: resetsAt, now: now, font: .title.weight(.bold))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func status(others count: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(UsageWidgetFormat.kindLabel(limit.label)) full").fontWeight(.semibold)
            ForEach(Array(others.prefix(count).enumerated()), id: \.offset) { _, other in
                Text("\(UsageWidgetFormat.kindLabel(other.label)) \(UsageWidgetFormat.percent(other.usedPercent))")
            }
        }
    }

    private var others: [BighelpUsageSnapshot.Plan.Limit] {
        plan.limits.filter { $0 != limit && !$0.hasReset(at: now) }
    }

    private var accessibilityText: String {
        var text = "\(plan.name), \(UsageWidgetFormat.shortLabel(limit.label)) limit reached"
        if let resetsAt = limit.resetsAt { text += ", back at \(UsageWidgetFormat.moment(resetsAt, from: now))" }
        return text
    }
}

/// Up to four plans, each its tightest limit.
struct UsageFourPlansView: View {
    let entry: UsageWidgetEntry
    let ink: UsageWidgetInk

    var body: some View {
        let shown = Array(entry.metered.prefix(4))
        let rows = stride(from: 0, to: shown.count, by: 2).map { Array(shown[$0..<min($0 + 2, shown.count)]) }
        VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row) { plan in
                        UsagePlanRingCell(entry: entry, plan: plan, ink: ink).frame(width: 50)
                            .frame(maxWidth: .infinity)
                    }
                    if row.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

/// One plan's tightest limit as a ring with its logo (a lock once it's used up), the share under it, and on
/// wider sizes the plan's name.
struct UsagePlanRingCell: View {
    let entry: UsageWidgetEntry
    let plan: BighelpUsageSnapshot.Plan
    let ink: UsageWidgetInk
    var showsName = false
    /// The most the ring takes; it shrinks to fit a smaller widget.
    var ringSize: CGFloat = 58

    var body: some View {
        let now = entry.date
        let limit = plan.tightest(at: now)
        let used = limit.map { $0.hasReset(at: now) ? 0 : $0.usedPercent } ?? 0
        let full = limit?.isFull(at: now) ?? false
        return VStack(spacing: 3) {
            ZStack {
                UsageWidgetRing(fraction: used / 100, color: ink.fill(plan, used: used), track: ink.track, lineWidth: 6)
                if full {
                    Image(systemName: "lock.fill").font(.callout).foregroundStyle(ink.alert).widgetAccentable()
                } else {
                    UsageWidgetLogo(plan: plan, size: 21, ink: ink)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: ringSize, maxHeight: ringSize)
            Group {
                if full, let resetsAt = limit?.resetsAt {
                    UsageWidgetCountdown(until: resetsAt, now: now, font: .caption.weight(.bold))
                        .foregroundStyle(ink.alert)
                } else if let limit, limit.hasReset(at: now) {
                    Text("Reset").font(.caption.weight(.semibold)).foregroundStyle(ink.secondary)
                } else {
                    Text(UsageWidgetFormat.percent(used)).font(.caption.weight(.bold)).monospacedDigit()
                        .foregroundStyle(ink.number(used: used))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if showsName {
                Text(plan.name).font(.caption2.weight(.semibold)).foregroundStyle(ink.secondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limit?.accessibilityText(plan: plan.name, at: now) ?? plan.name)
    }
}

/// Every plan as rings: each plan's tightest limit, nearest its limit first (or in the order picked).
struct UsagePlanRingsView: View {
    let entry: UsageWidgetEntry
    let ink: UsageWidgetInk
    let large: Bool

    var body: some View {
        let columns = large ? 3 : 4
        let shown = Array(entry.byRisk.prefix(large ? 6 : 4))
        let rows = stride(from: 0, to: shown.count, by: columns).map { Array(shown[$0..<min($0 + columns, shown.count)]) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI Usage").font(large ? .headline : .subheadline.weight(.bold))
                Spacer(minLength: 4)
                if entry.isStale {
                    Text(UsageWidgetFormat.updated(entry.snapshot.generatedAt, now: entry.date))
                        .font(.caption2).foregroundStyle(ink.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: large ? 14 : 6)
            VStack(spacing: large ? 20 : 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row) { plan in
                            UsagePlanRingCell(entry: entry, plan: plan, ink: ink, showsName: true, ringSize: large ? 84 : 58)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(row.count..<columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Up to four plans as meters: each plan's tightest limit, nearest its limit first (or in the order picked).
struct UsagePlanMetersView: View {
    let entry: UsageWidgetEntry
    let ink: UsageWidgetInk

    var body: some View {
        let now = entry.date
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .vertical) {
                rows(4, now: now)
                rows(3, now: now)
                rows(2, now: now)
            }
            Spacer(minLength: 0)
        }
    }

    private func rows(_ count: Int, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entry.byRisk.prefix(count)) { plan in
                if let limit = plan.tightest(at: now) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            UsageWidgetLogo(plan: plan, size: 12, ink: ink)
                            Text(plan.name).font(.caption.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 2)
                            number(limit, now: now)
                        }
                        UsageWidgetMeter(fraction: limit.hasReset(at: now) ? 0 : limit.usedPercent / 100,
                                         color: ink.fill(plan, used: limit.usedPercent), track: ink.track, height: 5)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(limit.accessibilityText(plan: plan.name, at: now))
                }
            }
        }
    }

    @ViewBuilder private func number(_ limit: BighelpUsageSnapshot.Plan.Limit, now: Date) -> some View {
        if limit.hasReset(at: now) {
            Text("Reset").font(.caption.weight(.semibold)).foregroundStyle(ink.secondary)
        } else if limit.isFull(at: now), let resetsAt = limit.resetsAt {
            UsageWidgetCountdown(until: resetsAt, now: now, font: .caption.weight(.bold)).foregroundStyle(ink.alert)
        } else {
            Text(UsageWidgetFormat.percent(limit.usedPercent)).font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(ink.number(used: limit.usedPercent)).lineLimit(1)
        }
    }
}

/// Whichever plan is nearest its limit, with the runner-up underneath.
struct UsageClosestView: View {
    let entry: UsageWidgetEntry
    let plan: BighelpUsageSnapshot.Plan
    let limit: BighelpUsageSnapshot.Plan.Limit
    let ink: UsageWidgetInk

    @ScaledMetric(relativeTo: .largeTitle) private var bigNumber: CGFloat = 42

    var body: some View {
        let now = entry.date
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                Text("CLOSEST TO LIMIT")
                Text("CLOSEST")
            }
            .font(.caption2.weight(.semibold)).tracking(0.5).foregroundStyle(ink.secondary).lineLimit(1)
            UsageWidgetPlanTitle(plan: plan, ink: ink, font: .headline, logo: 18, showsPlan: false)
                .padding(.top, 3)
            Spacer(minLength: 2)
            if limit.hasReset(at: now) {
                Text("Reset").font(.title.weight(.bold))
            } else {
                UsageWidgetPercent(value: limit.usedPercent, font: .system(size: bigNumber, weight: .bold),
                                   signFont: .system(size: bigNumber, weight: .bold),
                                   color: ink.number(used: limit.usedPercent))
            }
            if let detail = limit.detail {
                Text(detail).font(.caption).foregroundStyle(ink.secondary).lineLimit(1).minimumScaleFactor(0.75)
            }
            Spacer(minLength: 4)
            // The runner-up goes before the reset time is cut short.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    resetLine.fixedSize()
                    Spacer(minLength: 2)
                    if let runnerUp {
                        UsageWidgetLogo(plan: runnerUp.plan, size: 13, ink: ink)
                        Text(UsageWidgetFormat.percent(runnerUp.limit.usedPercent))
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(ink.number(used: runnerUp.limit.usedPercent))
                            .fixedSize()
                    }
                }
                resetLine
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var resetLine: some View {
        if let resetsAt = limit.resetsAt, resetsAt > entry.date {
            UsageResetLine(prefix: "Resets", date: resetsAt, now: entry.date, ink: ink, font: .caption)
        }
    }

    private var runnerUp: (plan: BighelpUsageSnapshot.Plan, limit: BighelpUsageSnapshot.Plan.Limit)? {
        entry.byRisk.first { $0.id != plan.id }
            .flatMap { other in other.tightest(at: entry.date).flatMap { $0.hasReset(at: entry.date) ? nil : (other, $0) } }
    }
}
