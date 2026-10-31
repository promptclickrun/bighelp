import SwiftUI
import WidgetKit

// MARK: - Medium

/// One plan: its tightest limit as a ring, every limit listed with its reset.
struct UsageOnePlanView: View {
    let entry: UsageWidgetEntry
    let plan: BighelpUsageSnapshot.Plan
    let ink: UsageWidgetInk

    var body: some View {
        let now = entry.date
        HStack(spacing: 16) {
            if let tightest = plan.tightest(at: now) {
                UsageWidgetRingBlock(plan: plan, limit: tightest, now: now, ink: ink, diameter: 118, lineWidth: 12,
                                     numberFont: .title.weight(.bold))
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    UsageWidgetPlanTitle(plan: plan, ink: ink)
                    Spacer(minLength: 0)
                    if entry.isStale {
                        Image(systemName: "clock").font(.caption2).foregroundStyle(ink.secondary)
                    }
                }
                Spacer(minLength: 6)
                ViewThatFits(in: .vertical) {
                    rows(3)
                    rows(2)
                    rows(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func rows(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(plan.limits.prefix(count).enumerated()), id: \.offset) { _, limit in
                UsageLimitRow(plan: plan, limit: limit, now: entry.date, ink: ink)
            }
        }
    }
}

/// A limit's name, reset and share over its meter.
struct UsageLimitRow: View {
    let plan: BighelpUsageSnapshot.Plan
    let limit: BighelpUsageSnapshot.Plan.Limit
    let now: Date
    let ink: UsageWidgetInk

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(UsageWidgetFormat.shortLabel(limit.label)).font(.caption.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.8).layoutPriority(1)
                Spacer(minLength: 4)
                trailing
            }
            UsageWidgetMeter(fraction: limit.hasReset(at: now) ? 0 : limit.usedPercent / 100,
                             color: ink.fill(plan, used: limit.usedPercent), track: ink.track)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limit.accessibilityText(plan: plan.name, at: now))
    }

    @ViewBuilder private var trailing: some View {
        if limit.hasReset(at: now) {
            Text("Reset").font(.caption.weight(.semibold)).foregroundStyle(ink.secondary)
        } else if limit.isFull(at: now), let resetsAt = limit.resetsAt {
            HStack(spacing: 3) {
                Image(systemName: "lock.fill").font(.caption2)
                UsageWidgetCountdown(until: resetsAt, now: now, font: .caption.weight(.bold))
            }
            .foregroundStyle(ink.alert)
        } else {
            ViewThatFits(in: .horizontal) {
                if let resetsAt = limit.resetsAt, resetsAt > now {
                    (Text(UsageWidgetFormat.moment(resetsAt, from: now) + " · ").foregroundStyle(ink.secondary)
                     + Text(UsageWidgetFormat.percent(limit.usedPercent)).fontWeight(.bold)
                        .foregroundStyle(ink.number(used: limit.usedPercent)))
                }
                Text(UsageWidgetFormat.percent(limit.usedPercent)).fontWeight(.bold)
                    .foregroundStyle(ink.number(used: limit.usedPercent))
            }
            .font(.caption)
            .monospacedDigit()
            .lineLimit(1)
        }
    }
}

/// One row per plan: its tightest limit, nearest its limit first.
struct UsageEveryPlanView: View {
    let entry: UsageWidgetEntry
    let ink: UsageWidgetInk

    private struct Columns: OptionSet {
        let rawValue: Int
        static let kind = Columns(rawValue: 1)
        static let resets = Columns(rawValue: 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI Usage").font(.subheadline.weight(.bold))
                Spacer(minLength: 4)
                Text(entry.isStale ? UsageWidgetFormat.updated(entry.snapshot.generatedAt, now: entry.date) : "resets in")
                    .font(.caption2).foregroundStyle(ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            ViewThatFits(in: .vertical) {
                grid(rows: 4, columns: [.kind, .resets])
                grid(rows: 4, columns: [.resets])
                grid(rows: 3, columns: [.resets])
                grid(rows: 2, columns: [])
                grid(rows: 1, columns: [])
            }
            Spacer(minLength: 0)
        }
    }

    private func grid(rows: Int, columns: Columns) -> some View {
        let now = entry.date
        return ViewThatFits(in: .horizontal) {
            table(rows: rows, columns: columns, now: now)
            table(rows: rows, columns: columns.subtracting(.kind), now: now)
            table(rows: rows, columns: [], now: now)
        }
    }

    private func table(rows: Int, columns: Columns, now: Date) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 9, verticalSpacing: 9) {
            ForEach(entry.byRisk.prefix(rows)) { plan in
                if let limit = plan.tightest(at: now) {
                    GridRow(alignment: .center) {
                        HStack(spacing: 6) {
                            UsageWidgetLogo(plan: plan, size: 16, ink: ink)
                            Text(plan.name).font(.subheadline.weight(.semibold)).fixedSize()
                        }
                        if columns.contains(.kind) {
                            Text(UsageWidgetFormat.kindLabel(limit.label).uppercased())
                                .font(.caption2.weight(.semibold)).tracking(0.3).foregroundStyle(ink.secondary)
                                .fixedSize()
                        }
                        UsageWidgetMeter(fraction: limit.hasReset(at: now) ? 0 : limit.usedPercent / 100,
                                         color: ink.fill(plan, used: limit.usedPercent), track: ink.track)
                            .frame(minWidth: 40, idealWidth: 60, maxWidth: .infinity)
                        number(limit, now: now)
                            .gridColumnAlignment(.trailing)
                        if columns.contains(.resets) {
                            Group {
                                if let resetsAt = limit.resetsAt, resetsAt > now {
                                    Text(UsageWidgetFormat.countdown(to: resetsAt, from: now))
                                } else {
                                    Text(" ")
                                }
                            }
                            .font(.caption).monospacedDigit().foregroundStyle(ink.secondary).lineLimit(1)
                            .gridColumnAlignment(.trailing)
                        }
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
            UsageWidgetCountdown(until: resetsAt, now: now, font: .subheadline.weight(.bold))
                .foregroundStyle(ink.alert)
        } else {
            Text(UsageWidgetFormat.percent(limit.usedPercent)).font(.subheadline.weight(.bold)).monospacedDigit()
                .foregroundStyle(ink.number(used: limit.usedPercent)).lineLimit(1)
        }
    }
}

/// When each plan's next limit frees up, on a line from now.
struct UsageNextResetsView: View {
    let entry: UsageWidgetEntry
    let ink: UsageWidgetInk

    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 104

    private struct Mark: Identifiable {
        let plan: BighelpUsageSnapshot.Plan
        let limit: BighelpUsageSnapshot.Plan.Limit
        let date: Date
        var id: String { plan.id }
    }

    private var marks: [Mark] {
        entry.metered.compactMap { plan in entry.nextReset(plan).map { Mark(plan: plan, limit: $0.limit, date: $0.date) } }
            .sorted { $0.date < $1.date }
            .prefix(4).map { $0 }
    }

    /// Whole hours, or whole days past a day and a bit.
    private func axisEnd(_ last: Date) -> (end: Date, step: TimeInterval) {
        let span = last.timeIntervalSince(entry.date)
        let step: TimeInterval = span <= 8 * 3_600 ? 3_600 : span <= 30 * 3_600 ? 3 * 3_600 : 86_400
        let calendar = Calendar.current
        var end = calendar.dateInterval(of: step == 86_400 ? .day : .hour, for: last)?.end ?? last
        if end <= last { end = end.addingTimeInterval(step == 86_400 ? 86_400 : 3_600) }
        return (end, step)
    }

    var body: some View {
        let marks = marks
        let last = marks.last?.date ?? entry.date.addingTimeInterval(3_600)
        let axis = axisEnd(last)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Next resets").font(.subheadline.weight(.bold))
                Spacer(minLength: 4)
                Text("now → \(UsageWidgetFormat.moment(axis.end, from: entry.date))")
                    .font(.caption2).foregroundStyle(ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            GeometryReader { proxy in
                timeline(marks: marks, end: axis.end, step: axis.step, size: proxy.size)
            }
            .frame(height: 104)
            Spacer(minLength: 0)
        }
    }

    private func timeline(marks: [Mark], end: Date, step: TimeInterval, size: CGSize) -> some View {
        let inset: CGFloat = 6
        let width = size.width - inset * 2
        let span = max(end.timeIntervalSince(entry.date), 60)
        func x(_ date: Date) -> CGFloat { inset + width * CGFloat(min(1, max(0, date.timeIntervalSince(entry.date) / span))) }
        let midY = size.height / 2
        // A reset months away would draw hundreds of ticks; at most two dozen.
        let tickStep = max(step, span / 24)
        let ticks = stride(from: tickStep, to: span, by: tickStep).map { entry.date.addingTimeInterval($0) }
        // Two labels a side must fit across.
        let labelWidth = min(self.labelWidth, size.width / 2 - 4)
        let positions = labelPositions(marks.map { x($0.date) }, width: size.width, labelWidth: labelWidth)
        return ZStack(alignment: .topLeading) {
            Capsule().fill(ink.track).frame(width: width, height: 2).position(x: size.width / 2, y: midY)
            Capsule().fill(ink.secondary.opacity(0.6)).frame(width: 2, height: 10).position(x: inset, y: midY)
            ForEach(ticks, id: \.self) { tick in
                Capsule().fill(ink.secondary.opacity(0.45)).frame(width: 1.5, height: 7).position(x: x(tick), y: midY)
            }
            ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                Circle().fill(ink.fill(mark.plan, used: mark.limit.usedPercent))
                    .overlay(Circle().strokeBorder(ink.colors.canvas.opacity(ink.isFullColor ? 1 : 0), lineWidth: 2))
                    .frame(width: 13, height: 13)
                    .widgetAccentable()
                    .position(x: x(mark.date), y: midY)
                label(mark)
                    .frame(width: labelWidth)
                    .position(x: positions[index], y: index.isMultiple(of: 2) ? midY - 31 : midY + 31)
            }
        }
    }

    /// Labels sit at their marks, alternately above and below, nudged apart so none overlap.
    private func labelPositions(_ xs: [CGFloat], width: CGFloat, labelWidth: CGFloat) -> [CGFloat] {
        var placed = xs.map { min(max($0, labelWidth / 2), width - labelWidth / 2) }
        for side in 0..<2 {
            let indices = placed.indices.filter { $0 % 2 == side }
            for (previous, index) in zip(indices, indices.dropFirst()) where placed[index] - placed[previous] < labelWidth + 4 {
                placed[index] = min(placed[previous] + labelWidth + 4, width - labelWidth / 2)
            }
        }
        return placed
    }

    private func label(_ mark: Mark) -> some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                UsageWidgetLogo(plan: mark.plan, size: 13, ink: ink)
                Text(UsageWidgetFormat.countdown(to: mark.date, from: entry.date))
                    .font(.subheadline.weight(.bold)).monospacedDigit()
            }
            Text("\(UsageWidgetFormat.kindLabel(mark.limit.label)) · \(UsageWidgetFormat.percent(mark.limit.usedPercent))")
                .font(.caption2).foregroundStyle(ink.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mark.plan.name), \(UsageWidgetFormat.shortLabel(mark.limit.label)) resets in "
                            + UsageWidgetFormat.countdown(to: mark.date, from: entry.date))
    }
}

/// Two plans side by side: rings inside rings, the first limit inside.
struct UsageSideBySideView: View {
    let entry: UsageWidgetEntry
    let ink: UsageWidgetInk

    private var pair: [BighelpUsageSnapshot.Plan] {
        let first = entry.chosen.flatMap { $0.limits.isEmpty ? nil : $0 } ?? entry.metered[0]
        return [first] + entry.metered.filter { $0.id != first.id }.prefix(1)
    }

    var body: some View {
        let pair = pair
        HStack(spacing: 0) {
            ForEach(Array(pair.enumerated()), id: \.element.id) { index, plan in
                if index > 0 {
                    Rectangle().fill(ink.divider).frame(width: 1).padding(.vertical, 4).padding(.horizontal, 10)
                }
                half(plan).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func half(_ plan: BighelpUsageSnapshot.Plan) -> some View {
        let now = entry.date
        let shown = Array(plan.limits.prefix(2))
        return HStack(spacing: 10) {
            ZStack {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, limit in
                    let ring = shown.count - 1 - index
                    UsageWidgetRing(fraction: limit.hasReset(at: now) ? 0 : limit.usedPercent / 100,
                                    color: ink.fill(plan, used: limit.usedPercent).opacity(ring == 0 ? 1 : 0.75),
                                    track: ink.track, lineWidth: 7)
                        .padding(CGFloat(ring) * 10)
                }
                if shown.contains(where: { $0.isFull(at: now) }) {
                    Image(systemName: "lock.fill").font(.callout).foregroundStyle(ink.alert).widgetAccentable()
                } else {
                    UsageWidgetLogo(plan: plan, size: 22, ink: ink)
                }
            }
            .frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 1) {
                Text(plan.name).font(.headline).lineLimit(1).minimumScaleFactor(0.75)
                ForEach(Array(shown.enumerated()), id: \.offset) { _, limit in
                    Text(UsageWidgetFormat.kindLabel(limit.label).uppercased())
                        .font(.caption2.weight(.semibold)).tracking(0.3).foregroundStyle(ink.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .padding(.top, 3)
                    if limit.hasReset(at: now) {
                        Text("Reset").font(.headline).foregroundStyle(ink.secondary)
                    } else if limit.isFull(at: now), let resetsAt = limit.resetsAt {
                        UsageWidgetCountdown(until: resetsAt, now: now, font: .headline).foregroundStyle(ink.alert)
                    } else {
                        UsageWidgetPercent(value: limit.usedPercent, font: .title3.weight(.bold), signFont: .title3.weight(.bold),
                                           color: ink.number(used: limit.usedPercent))
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shown.map { $0.accessibilityText(plan: plan.name, at: now) }.joined(separator: "; "))
    }
}

// MARK: - Large

/// Every plan and every limit, with a word on the one closest to its limit.
struct UsageDashboardView: View {
    let entry: UsageWidgetEntry
    let ink: UsageWidgetInk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI Usage").font(.headline)
                Spacer(minLength: 4)
                Text(UsageWidgetFormat.updated(entry.snapshot.generatedAt, now: entry.date))
                    .font(.caption).foregroundStyle(ink.secondary).lineLimit(1)
            }
            .padding(.bottom, 8)
            ViewThatFits(in: .vertical) {
                sections(plans: 6, limits: 3)
                sections(plans: 4, limits: 3)
                sections(plans: 4, limits: 2)
                sections(plans: 4, limits: 1)
                sections(plans: 3, limits: 1)
                sections(plans: 2, limits: 1)
            }
            Spacer(minLength: 0)
        }
    }

    /// Plans with limits first; the rest show their balance.
    private var ordered: [BighelpUsageSnapshot.Plan] {
        entry.metered + entry.plans.filter { $0.limits.isEmpty && !$0.facts.isEmpty }
    }

    private func sections(plans count: Int, limits: Int) -> some View {
        let shown = Array(ordered.prefix(count))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, plan in
                if index > 0 { Rectangle().fill(ink.divider).frame(height: 1).padding(.vertical, 8) }
                section(plan, limits: limits)
            }
            if let callout {
                Rectangle().fill(ink.divider).frame(height: 1).padding(.vertical, 8)
                callout
            }
        }
    }

    private func section(_ plan: BighelpUsageSnapshot.Plan, limits: Int) -> some View {
        let now = entry.date
        let rows: [BighelpUsageSnapshot.Plan.Limit] = limits == 1 ? plan.tightest(at: now).map { [$0] } ?? []
            : Array(plan.limits.prefix(limits))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                UsageWidgetPlanTitle(plan: plan, ink: ink)
                Spacer(minLength: 4)
                if let next = entry.nextReset(plan) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise").font(.caption2.weight(.semibold))
                        Text(UsageWidgetFormat.moment(next.date, from: now)).font(.caption)
                    }
                    .foregroundStyle(ink.secondary).lineLimit(1)
                }
            }
            if rows.isEmpty, let fact = plan.facts.first {
                HStack {
                    Text(fact.label).foregroundStyle(ink.secondary)
                    Spacer(minLength: 4)
                    Text(fact.value).fontWeight(.semibold)
                }
                .font(.caption)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, limit in
                    GridRow {
                        Text(UsageWidgetFormat.shortLabel(limit.label)).font(.caption).foregroundStyle(ink.secondary)
                            .lineLimit(2).frame(maxWidth: 110, alignment: .leading)
                        UsageWidgetMeter(fraction: limit.hasReset(at: now) ? 0 : limit.usedPercent / 100,
                                         color: ink.fill(plan, used: limit.usedPercent), track: ink.track)
                        number(limit, now: now).gridColumnAlignment(.trailing)
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

    /// The plan nearest its limit, once it's at 80% or more.
    private var callout: AnyView? {
        guard let (plan, limit) = entry.closest, !limit.hasReset(at: entry.date),
              UsageWidgetFormat.level(used: limit.usedPercent) != .normal else { return nil }
        let now = entry.date
        var rest = limit.isFull(at: now) ? " is at its limit" : " at \(UsageWidgetFormat.percent(limit.usedPercent))"
        if let resetsAt = limit.resetsAt, resetsAt > now {
            rest += limit.isFull(at: now) ? " until \(UsageWidgetFormat.moment(resetsAt, from: now))"
                : ", resets \(UsageWidgetFormat.moment(resetsAt, from: now))"
        }
        return AnyView(
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(ink.fill(plan, used: limit.usedPercent)).frame(width: 7, height: 7).widgetAccentable()
                (Text(plan.name).fontWeight(.semibold) + Text(rest).foregroundStyle(ink.secondary))
                    .font(.caption).lineLimit(2)
            }
        )
    }
}

/// One plan in detail: its first two limits as rings, the rest listed, then its facts.
struct UsageDeepDiveView: View {
    let entry: UsageWidgetEntry
    let plan: BighelpUsageSnapshot.Plan
    let ink: UsageWidgetInk

    var body: some View {
        let now = entry.date
        let rings = Array(plan.limits.prefix(2))
        let rest = Array(plan.limits.dropFirst(2))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                UsageWidgetPlanTitle(plan: plan, ink: ink, font: .headline, logo: 20)
                Spacer(minLength: 4)
                Text(UsageWidgetFormat.updated(entry.snapshot.generatedAt, now: now))
                    .font(.caption).foregroundStyle(ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 10)
            HStack(alignment: .top, spacing: 8) {
                ForEach(Array(rings.enumerated()), id: \.offset) { _, limit in
                    VStack(spacing: 4) {
                        UsageWidgetRingBlock(plan: plan, limit: limit, now: now, ink: ink, diameter: 116, lineWidth: 12,
                                             numberFont: .title.weight(.bold), showsLabel: false)
                            .padding(.bottom, 4)
                        Text(UsageWidgetFormat.shortLabel(limit.label)).font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.center).lineLimit(2)
                        if let resetsAt = limit.resetsAt, resetsAt > now {
                            Text("Resets \(UsageWidgetFormat.moment(resetsAt, from: now))")
                                .font(.caption).foregroundStyle(ink.secondary).lineLimit(1)
                        }
                        if let detail = limit.detail {
                            Text(detail).font(.caption).foregroundStyle(ink.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            Spacer(minLength: 10)
            if !rest.isEmpty || !plan.facts.isEmpty {
                Rectangle().fill(ink.divider).frame(height: 1).padding(.bottom, 10)
                ViewThatFits(in: .vertical) {
                    details(rest: rest, facts: plan.facts.count)
                    details(rest: Array(rest.prefix(2)), facts: 0)
                    details(rest: Array(rest.prefix(1)), facts: 0)
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func details(rest: [BighelpUsageSnapshot.Plan.Limit], facts: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rest.enumerated()), id: \.offset) { _, limit in
                UsageLimitRow(plan: plan, limit: limit, now: entry.date, ink: ink)
            }
            if facts > 0 {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(plan.facts.prefix(3).enumerated()), id: \.offset) { _, fact in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(fact.value).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                            Text(fact.label).font(.caption).foregroundStyle(ink.secondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

// MARK: - Extra large

/// iPad: one column per plan with every limit and its next reset.
struct UsageColumnsView: View {
    let entry: UsageWidgetEntry
    let ink: UsageWidgetInk

    var body: some View {
        let shown = Array(entry.metered.prefix(4))
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI Usage").font(.title3.weight(.bold))
                Spacer(minLength: 8)
                Text("\(shown.count) \(shown.count == 1 ? "plan" : "plans") · "
                     + UsageWidgetFormat.updated(entry.snapshot.generatedAt, now: entry.date))
                    .font(.subheadline).foregroundStyle(ink.secondary).lineLimit(1)
            }
            ViewThatFits(in: .vertical) {
                columns(shown, limits: 3)
                columns(shown, limits: 2)
                columns(shown, limits: 1)
            }
            Spacer(minLength: 0)
        }
    }

    private func columns(_ plans: [BighelpUsageSnapshot.Plan], limits: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                if index > 0 { Rectangle().fill(ink.divider).frame(width: 1) }
                column(plan, limits: limits)
                    .padding(.leading, index > 0 ? 16 : 0)
                    .padding(.trailing, index < plans.count - 1 ? 16 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func column(_ plan: BighelpUsageSnapshot.Plan, limits: Int) -> some View {
        let now = entry.date
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                UsageWidgetLogo(plan: plan, size: 18, ink: ink)
                VStack(alignment: .leading, spacing: 1) {
                    Text(plan.name).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                    if let name = plan.plan {
                        Text(name).font(.subheadline).foregroundStyle(ink.secondary).lineLimit(1)
                    }
                }
            }
            if let tightest = plan.tightest(at: now) {
                UsageWidgetRingBlock(plan: plan, limit: tightest, now: now, ink: ink, diameter: 92, lineWidth: 10,
                                     numberFont: .title2.weight(.bold))
                    .frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(plan.limits.prefix(limits).enumerated()), id: \.offset) { _, limit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(UsageWidgetFormat.shortLabel(limit.label)).lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 4)
                            Text(limit.hasReset(at: now) ? "Reset" : UsageWidgetFormat.percent(limit.usedPercent))
                                .fontWeight(.semibold).monospacedDigit()
                                .foregroundStyle(limit.hasReset(at: now) ? ink.secondary : ink.number(used: limit.usedPercent))
                        }
                        .font(.caption)
                        UsageWidgetMeter(fraction: limit.hasReset(at: now) ? 0 : limit.usedPercent / 100,
                                         color: ink.fill(plan, used: limit.usedPercent), track: ink.track, height: 5)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(limit.accessibilityText(plan: plan.name, at: now))
                }
            }
            Spacer(minLength: 0)
            if let next = entry.nextReset(plan) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Next reset").font(.caption).foregroundStyle(ink.secondary)
                    Text("\(UsageWidgetFormat.countdown(to: next.date, from: now)) · \(UsageWidgetFormat.moment(next.date, from: now))")
                        .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
    }
}

// MARK: - Cost and tokens

/// The last 30 days on the computer: estimated cost, tokens, a bar a day and the top models.
struct UsageSpendingView: View {
    let entry: UsageWidgetEntry
    let family: WidgetFamily
    let ink: UsageWidgetInk

    private var snapshot: BighelpUsageSnapshot { entry.snapshot }

    var body: some View {
        if let totals = snapshot.totals {
            switch family {
            case .systemSmall: small(totals)
            case .systemMedium: medium(totals)
            default: large(totals)
            }
        } else {
            UsageWidgetMessage(text: entry.waiting, ink: ink)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text("Estimated cost").font(.subheadline.weight(.semibold)).fixedSize()
                Spacer(minLength: 4)
                Text("\(snapshot.days) days").font(.caption2).foregroundStyle(ink.secondary).fixedSize()
            }
            Text("Estimated cost").font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    private func amounts(_ totals: BighelpUsageSnapshot.Totals) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(UsageWidgetFormat.cost(totals.cost)).font(.title.weight(.bold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text("\(UsageWidgetFormat.tokens(totals.tokens)) tokens").font(.caption).foregroundStyle(ink.secondary)
                .lineLimit(1)
        }
    }

    private func small(_ totals: BighelpUsageSnapshot.Totals) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 4)
            amounts(totals)
            Spacer(minLength: 6)
            bars(count: 14).frame(height: 28)
        }
    }

    private func medium(_ totals: BighelpUsageSnapshot.Totals) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Spacer(minLength: 4)
                amounts(totals)
                Spacer(minLength: 6)
                bars(count: 30).frame(height: 30)
            }
            .frame(maxWidth: .infinity)
            if !snapshot.models.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Top models").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 6)
                    modelRows(limit: 3)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func large(_ totals: BighelpUsageSnapshot.Totals) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Spacer(minLength: 6)
            amounts(totals)
            if totals.billedCost > 0 {
                Text("Billed \(UsageWidgetFormat.cost(totals.billedCost))").font(.caption).foregroundStyle(ink.secondary)
            }
            Spacer(minLength: 10)
            bars(count: 30).frame(height: 84)
            if !snapshot.models.isEmpty {
                Rectangle().fill(ink.divider).frame(height: 1).padding(.vertical, 10)
                Text("Top models").font(.subheadline.weight(.semibold)).padding(.bottom, 8)
                ViewThatFits(in: .vertical) {
                    modelRows(limit: 5)
                    modelRows(limit: 3)
                    modelRows(limit: 1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// One bar a day, the latest on the right; real numbers only.
    private func bars(count: Int) -> some View {
        let values = snapshot.daily.suffix(count).map(\.cost)
        let peak = max(values.max() ?? 0, .leastNonzeroMagnitude)
        return GeometryReader { proxy in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(value > 0 ? ink.colors.accent : ink.track)
                        .frame(height: max(2, proxy.size.height * value / peak))
                        .widgetAccentable(value > 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }

    private func modelRows(limit: Int) -> some View {
        let useCost = snapshot.models.contains { $0.cost > 0 }
        let models = Array(snapshot.models.sorted { useCost ? $0.cost > $1.cost : $0.tokens > $1.tokens }.prefix(limit))
        let peak = max(models.map { useCost ? $0.cost : Double($0.tokens) }.max() ?? 0, .leastNonzeroMagnitude)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(models) { model in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(model.name).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        Text(useCost ? UsageWidgetFormat.cost(model.cost) : UsageWidgetFormat.tokens(model.tokens))
                            .font(.caption).monospacedDigit().foregroundStyle(ink.secondary).lineLimit(1)
                    }
                    UsageWidgetMeter(fraction: (useCost ? model.cost : Double(model.tokens)) / peak,
                                     color: ink.colors.accent, track: ink.track, height: 5)
                }
            }
        }
    }
}
