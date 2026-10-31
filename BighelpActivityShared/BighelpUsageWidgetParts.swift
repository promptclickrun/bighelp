import SwiftUI
import WidgetKit

enum UsageWidgetFormat {
    static func cost(_ value: Double) -> String {
        if value >= 10_000 { return "$" + Int(value.rounded()).formatted(.number.notation(.compactName)) }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(value >= 1_000 ? 0 : 2)))
    }

    static func tokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }

    static func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    /// Amber from 80% used, red once used up.
    enum Level { case normal, high, full }

    static func level(used: Double) -> Level {
        let shown = used.rounded()
        return shown >= 100 ? .full : shown >= 80 ? .high : .normal
    }

    /// "Session (5 hours)" reads "Session", "Week" reads "Weekly".
    static func shortLabel(_ label: String) -> String {
        var text = label.replacingOccurrences(of: " (5 hours)", with: "")
        for (word, adjective) in [("Week", "Weekly"), ("Day", "Daily"), ("Month", "Monthly")] {
            if text == word { text = adjective } else if text.hasSuffix(" · " + word) {
                text = String(text.dropLast(word.count)) + adjective
            }
        }
        return text
    }

    /// A word or two where room is short: "Session", "Weekly", "Sonnet wk", "Monthly".
    static func kindLabel(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("month") || lower == "premium requests" { return "Monthly" }
        if lower.hasSuffix(" week"), !lower.contains("·") { return String(label.dropLast(4)) + "wk" }
        return shortLabel(label)
    }

    /// Two or three letters for the Lock Screen's meters.
    static func tinyLabel(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("5 hours") || lower.hasPrefix("session") { return "5h" }
        if lower == "week" || lower == "weekly" { return "Wk" }
        if lower == "day" || lower == "daily" { return "Day" }
        if lower.contains("month") || lower == "premium requests" { return "Mo" }
        return String(label.split(separator: " ").first?.prefix(4) ?? "")
    }

    /// "1h 28m", "48m", "1d 22h".
    static func countdown(to date: Date, from now: Date) -> String {
        let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        let hours = minutes / 60, days = hours / 24
        if days >= 1 { return hours % 24 == 0 ? "\(days)d" : "\(days)d \(hours % 24)h" }
        if hours >= 1 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    /// "3:40 PM" today, "Mon 9 AM" this week, "Nov 3" after that.
    static func moment(_ date: Date, from now: Date, calendar: Calendar = .current) -> String {
        let onHour = calendar.component(.minute, from: date) == 0
        let time = onHour ? date.formatted(.dateTime.hour()) : date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if date.timeIntervalSince(now) < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "Updated 2:12 PM", or the day for older numbers.
    static func updated(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? "Updated \(date.formatted(.dateTime.hour().minute()))"
            : "Updated \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }
}

/// The colors a usage view draws with. Provider colors, amber and red are for the
/// full-color look; tinted, clear and Lock Screen widgets draw one ink, so the
/// meters, the lock and the countdown carry the meaning there.
struct UsageWidgetInk {
    let colors: BighelpWidgetColors
    let scheme: ColorScheme
    /// Render tests' stand-in for the system tint; WidgetKit tints accentable parts itself.
    var tintPreview: Color? = nil

    var isFullColor: Bool { colors.isFullColor }
    var primary: Color { colors.primary }
    var secondary: Color { colors.secondary }

    func brand(_ plan: BighelpUsageSnapshot.Plan) -> Color {
        guard isFullColor else { return tintPreview ?? colors.primary }
        return plan.tint.map(Color.init(widgetHex:)) ?? colors.accent
    }

    /// A meter's fill: the provider's color until it runs high.
    func fill(_ plan: BighelpUsageSnapshot.Plan, used: Double) -> Color {
        guard isFullColor else { return tintPreview ?? colors.primary }
        switch UsageWidgetFormat.level(used: used) {
        case .full: return red
        case .high: return amber
        case .normal: return brand(plan)
        }
    }

    /// A percentage's text.
    func number(used: Double) -> Color {
        guard isFullColor else { return colors.primary }
        switch UsageWidgetFormat.level(used: used) {
        case .full: return red
        case .high: return amberText
        case .normal: return colors.primary
        }
    }

    var track: Color { colors.primary.opacity(isFullColor ? (scheme == .dark ? 0.14 : 0.09) : 0.25) }
    var divider: Color { colors.primary.opacity(isFullColor ? 0.1 : 0.2) }
    var alert: Color { isFullColor ? red : colors.primary }
    private var amber: Color { Color(widgetHex: scheme == .dark ? "FF9F0A" : "F59500") }
    /// Amber dark enough to read on a light page.
    private var amberText: Color { Color(widgetHex: scheme == .dark ? "FF9F0A" : "C46A00") }
    private var red: Color { Color(widgetHex: scheme == .dark ? "FF453A" : "E0352B") }
}

private struct UsageWidgetTintPreviewKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}

extension EnvironmentValues {
    var usageWidgetTintPreview: Color? {
        get { self[UsageWidgetTintPreviewKey.self] }
        set { self[UsageWidgetTintPreviewKey.self] = newValue }
    }
}

/// The provider's bundled logo, or its initial in its color.
struct UsageWidgetLogo: View {
    let plan: BighelpUsageSnapshot.Plan
    let size: CGFloat
    let ink: UsageWidgetInk

    var body: some View {
        Group {
            if let name = plan.logo, UIImage(named: name) != nil {
                if ink.isFullColor {
                    Image(name).resizable().scaledToFit()
                } else {
                    Image(name).renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(ink.brand(plan))
                }
            } else {
                Text(String(plan.name.first ?? "•").uppercased())
                    .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                    .foregroundStyle(ink.brand(plan))
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}

/// A ring filled to a share, from the top, clockwise.
struct UsageWidgetRing: View {
    let fraction: Double
    let color: Color
    let track: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// A rounded meter filled to a share, on a faint track.
struct UsageWidgetMeter: View {
    let fraction: Double
    let color: Color
    let track: Color
    var height: CGFloat = 6

    var body: some View {
        Capsule()
            .fill(track)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(color)
                        .frame(width: fraction > 0 ? max(height, proxy.size.width * min(1, fraction)) : 0)
                        .widgetAccentable()
                }
            }
            .accessibilityHidden(true)
    }
}

/// "62%" with a smaller percent sign.
struct UsageWidgetPercent: View {
    let value: Double
    let font: Font
    let signFont: Font
    let color: Color

    var body: some View {
        (Text("\(Int(value.rounded()))").font(font) + Text("%").font(signFont))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// How long until a used-up limit frees up: a countdown, or a still time with Reduce Motion.
struct UsageWidgetCountdown: View {
    let until: Date
    let now: Date
    let font: Font

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion || until <= now {
                Text(UsageWidgetFormat.countdown(to: until, from: now))
            } else {
                Text(timerInterval: now...until, countsDown: true)
            }
        }
        .font(font)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// The logo, the provider's name and, when it fits, its plan.
struct UsageWidgetPlanTitle: View {
    let plan: BighelpUsageSnapshot.Plan
    let ink: UsageWidgetInk
    var font: Font = .subheadline.weight(.semibold)
    var logo: CGFloat = 16
    var showsPlan = true

    var body: some View {
        HStack(spacing: 6) {
            UsageWidgetLogo(plan: plan, size: logo, ink: ink)
            ViewThatFits(in: .horizontal) {
                if showsPlan, let name = plan.plan {
                    (Text(plan.name) + Text(" ") + Text(name).foregroundStyle(ink.secondary).fontWeight(.regular))
                        .lineLimit(1)
                }
                Text(plan.name).lineLimit(1)
                Text(plan.name).lineLimit(2).minimumScaleFactor(0.8)
            }
            .font(font)
        }
        .accessibilityElement(children: .combine)
    }
}

extension BighelpUsageSnapshot.Plan.Limit {
    func accessibilityText(plan: String, at date: Date) -> String {
        var parts = [plan, UsageWidgetFormat.shortLabel(label)]
        if hasReset(at: date) {
            parts.append("reset")
        } else {
            parts.append("\(UsageWidgetFormat.percent(usedPercent)) used")
            if let resetsAt { parts.append("resets \(UsageWidgetFormat.moment(resetsAt, from: date))") }
        }
        return parts.joined(separator: ", ")
    }
}

/// A rounded bar filled to a share, on a faint track (the Workflows widget's too).
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
