import SwiftUI
import WidgetKit

#if os(iOS)
/// The Lock Screen: a line over the clock, a rectangle with meters or the next reset, and a gauge.
/// One ink throughout, so a used-up limit shows as a lock rather than a color.
struct UsageLockScreenView: View {
    let entry: UsageWidgetEntry
    let family: WidgetFamily
    let ink: UsageWidgetInk

    typealias Plan = BighelpUsageSnapshot.Plan
    typealias Limit = BighelpUsageSnapshot.Plan.Limit

    private var now: Date { entry.date }

    var body: some View {
        switch family {
        case .accessoryInline: inline
        case .accessoryCircular: circular
        default: rectangular
        }
    }

    /// The picked plan's tightest limit, else whichever is nearest its limit.
    private var focus: (plan: Plan, limit: Limit)? {
        if !entry.planIDs.isEmpty, let plan = entry.chosen, let limit = plan.tightest(at: now) { return (plan, limit) }
        return entry.closest
    }

    // MARK: Inline

    @ViewBuilder private var inline: some View {
        if let (plan, limit) = focus {
            ViewThatFits {
                Label { Text(inlineText(plan, limit, long: true)) } icon: { inlineIcon(plan) }
                Label { Text(inlineText(plan, limit, long: false)) } icon: { inlineIcon(plan) }
            }
        } else {
            Label("Usage", systemImage: "gauge.with.dots.needle.33percent")
        }
    }

    private func inlineText(_ plan: Plan, _ limit: Limit, long: Bool) -> String {
        // Without its logo the line names the plan.
        let name = hasLogo(plan) ? "" : plan.name + " "
        if limit.hasReset(at: now) { return name.isEmpty ? "Reset" : name + "reset" }
        let share = limit.isFull(at: now) ? (name.isEmpty ? "Full" : "full") : UsageWidgetFormat.percent(limit.usedPercent)
        guard long, let resetsAt = limit.resetsAt, resetsAt > now else { return name + share }
        return name + "\(share) until \(UsageWidgetFormat.moment(resetsAt, from: now))"
    }

    /// The logo drawn small: the line takes an image at its own size, and the art is 512 points.
    private func inlineIcon(_ plan: Plan) -> Image {
        guard let name = plan.logo, let logo = UIImage(named: name) else {
            return Image(systemName: "gauge.with.dots.needle.33percent")
        }
        let size = CGSize(width: 14, height: 14)
        let scale = plan.logoScale ?? 1
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        let small = UIGraphicsImageRenderer(size: size).image { _ in
            logo.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                 width: drawn.width, height: drawn.height))
        }
        return Image(uiImage: small).renderingMode(.template)
    }

    private func hasLogo(_ plan: Plan) -> Bool { plan.logo.map { UIImage(named: $0) != nil } ?? false }

    // MARK: Circular

    @ViewBuilder private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let (plan, limit) = focus {
                let used = limit.hasReset(at: now) ? 0 : limit.usedPercent
                ZStack {
                    Circle().trim(from: 0, to: 0.75)
                        .stroke(ink.primary.opacity(0.3), style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    Circle().trim(from: 0, to: 0.75 * used / 100)
                        .stroke(ink.primary, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                        .widgetAccentable()
                }
                .rotationEffect(.degrees(135))
                .padding(4)
                VStack(spacing: 0) {
                    if limit.isFull(at: now) {
                        Image(systemName: "lock.fill").font(.system(size: 13, weight: .semibold))
                        if let resetsAt = limit.resetsAt {
                            Text(UsageWidgetFormat.countdown(to: resetsAt, from: now))
                                .font(.system(size: 11, weight: .semibold)).minimumScaleFactor(0.6)
                        }
                    } else {
                        UsageWidgetLogo(plan: plan, size: 14, ink: ink)
                        Text(limit.hasReset(at: now) ? "–" : "\(Int(used.rounded()))")
                            .font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit()
                            .minimumScaleFactor(0.6)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 8)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(limit.accessibilityText(plan: plan.name, at: now))
            } else {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.title3).widgetAccentable()
            }
        }
    }

    // MARK: Rectangular

    @ViewBuilder private var rectangular: some View {
        Group {
            if entry.metered.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Usage").font(.headline)
                    Text(!entry.snapshot.hasData ? "No numbers yet"
                         : entry.snapshot.plans == nil && entry.snapshot.plansNote != nil ? "Update the bighelp plugin"
                         : "No plans with limits")
                        .font(.caption).lineLimit(2)
                }
            } else {
                switch rectangularStyle {
                case .nextReset: nextReset
                case .everyPlan: everyPlan
                default: onePlan
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rectangularStyle: UsageLockStyle {
        guard entry.styles.lock == .automatic else { return entry.styles.lock }
        return entry.picksOnePlan || entry.metered.count == 1 ? .onePlan : .everyPlan
    }

    @ViewBuilder private var onePlan: some View {
        if let plan = entry.chosen.flatMap({ $0.limits.isEmpty ? nil : $0 }) ?? entry.metered.first {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    UsageWidgetLogo(plan: plan, size: 13, ink: ink)
                    Text(plan.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                ForEach(Array(plan.limits.prefix(2).enumerated()), id: \.offset) { _, limit in
                    HStack(spacing: 6) {
                        Text(UsageWidgetFormat.tinyLabel(limit.label)).font(.caption2.weight(.medium))
                            .frame(width: 22, alignment: .leading)
                        meterRow(plan, limit)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(limit.accessibilityText(plan: plan.name, at: now))
                }
            }
        }
    }

    private var everyPlan: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entry.byRisk.prefix(3)) { plan in
                if let limit = plan.tightest(at: now) {
                    HStack(spacing: 6) {
                        UsageWidgetLogo(plan: plan, size: 12, ink: ink)
                        meterRow(plan, limit)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(limit.accessibilityText(plan: plan.name, at: now))
                }
            }
        }
    }

    private func meterRow(_ plan: Plan, _ limit: Limit) -> some View {
        HStack(spacing: 6) {
            UsageWidgetMeter(fraction: limit.hasReset(at: now) ? 0 : limit.usedPercent / 100,
                             color: ink.primary, track: ink.primary.opacity(0.3), height: 5)
            Group {
                if limit.hasReset(at: now) {
                    Text("Reset")
                } else if limit.isFull(at: now) {
                    HStack(spacing: 2) {
                        Image(systemName: "lock.fill")
                        if let resetsAt = limit.resetsAt { Text(UsageWidgetFormat.moment(resetsAt, from: now)) }
                    }
                } else {
                    Text(UsageWidgetFormat.percent(limit.usedPercent))
                }
            }
            .font(.caption2.weight(.semibold)).monospacedDigit().lineLimit(1)
            .frame(minWidth: 30, alignment: .trailing)
        }
    }

    @ViewBuilder private var nextReset: some View {
        let next = entry.metered.compactMap { plan in entry.nextReset(plan).map { (plan, $0.limit, $0.date) } }
            .min { $0.2 < $1.2 }
        if let (plan, limit, date) = next {
            VStack(alignment: .leading, spacing: 0) {
                Text("NEXT RESET").font(.caption2.weight(.semibold)).tracking(0.4).opacity(0.75)
                HStack(spacing: 5) {
                    UsageWidgetLogo(plan: plan, size: 16, ink: ink)
                    Text(UsageWidgetFormat.countdown(to: date, from: now))
                        .font(.title3.weight(.bold)).monospacedDigit().widgetAccentable()
                }
                Text("\(plan.name) \(UsageWidgetFormat.kindLabel(limit.label).lowercased()) · \(UsageWidgetFormat.moment(date, from: now))")
                    .font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .accessibilityElement(children: .combine)
        } else {
            everyPlan
        }
    }
}
#endif
