import Charts
import SwiftUI

/// The big number and its chart: cost or tokens per day for the range, or one
/// model, agent or computer against everything else. Tap a bar for its day.
struct UsageHeroCard: View {
    let store: UsageStore
    let summary: UsageSummary
    @Binding var selectedDay: String?
    @BighelpThemeReader private var theme

    private struct Segment: Identifiable {
        let id: String
        let date: Date
        let value: Double
        let isFocus: Bool
        let isRest: Bool
        let isDimmed: Bool
        let label: String
        let valueText: String
    }

    private var metric: UsageMetric { store.metric }
    private var palette: UsagePalette { UsagePalette(theme: theme) }
    private var focusRow: UsageSummary.Row? { store.focus.flatMap(summary.row) }
    private var focusSeries: [UsageAmount]? { store.focus.flatMap(summary.series(for:)) }
    private var selectedIndex: Int? { selectedDay.flatMap { day in summary.points.firstIndex { $0.day == day } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                HStack(spacing: BighelpTokens.space12) {
                    Text(heroLabel)
                        .font(.bighelp(.subheadline))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    UsagePillPicker(options: UsageMetric.allCases.map { ($0, $0.title) }, selection: metric,
                                    compact: true, label: "Measure", identifier: "usage.metric") { picked in
                        selectedDay = nil
                        store.choose(picked)
                    }
                    .fixedSize()
                }
                Text(heroValue)
                    .font(.bighelp(.largeTitle).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityIdentifier("usage.hero.value")
                Text(heroNote)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            if let focusRow { focusChip(focusRow) }
            chart
            if let focusRow, focusSeries != nil { legend(focusRow) }
        }
        .usageCard(theme, padding: EdgeInsets(top: 18, leading: 18, bottom: 14, trailing: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage.hero")
    }

    // MARK: Words

    private var rangeText: String { "the last \(store.range.days) days" }

    private var heroLabel: String {
        if let index = selectedIndex {
            return summary.points[index].date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return metric == .cost ? "Estimated cost" : "Processed tokens"
    }

    private var total: UsageAmount {
        UsageAmount(cost: summary.totals.cost, tokens: summary.totals.processedTokens)
    }

    private var heroAmount: UsageAmount {
        if let index = selectedIndex {
            return focusSeries?[index] ?? summary.points[index].amount
        }
        if let focusRow { return focusSeries?.reduce(.zero, +) ?? focusRow.amount }
        return total
    }

    private var heroValue: String { UsageFormat.value(heroAmount, metric) }

    private var heroNote: String {
        if selectedIndex != nil { return "Tap the bar again for \(rangeText)" }
        if let focusRow {
            let whole = total.value(metric)
            let share = whole > 0 ? focusRow.amount.value(metric) / whole : 0
            let part = "\(UsageFormat.percent(share)) of \(metric == .cost ? "cost" : "tokens") over \(rangeText)"
            return focusSeries == nil ? part + ". Update the bighelp plugin to chart it by day." : part
        }
        if metric == .tokens { return "Uncached input plus output" }
        if summary.totals.billedCost > 0 {
            return "Estimated by Hermes. Providers billed \(UsageFormat.money(summary.totals.billedCost))."
        }
        return "Estimated by Hermes from your agents' sessions"
    }

    // MARK: Focus

    private func focusChip(_ row: UsageSummary.Row) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            RoundedRectangle(cornerRadius: 3).fill(palette.bar).frame(width: 10, height: 10)
            Text(row.title)
                .font(.bighelp(.footnote).weight(.semibold))
                .lineLimit(1)
            Button {
                selectedDay = nil
                store.focus = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .contentShape(.circle)
            }
            .bighelpPlainButtonStyle(.circle)
            .bighelpIconLabel("Show everything")
            .accessibilityIdentifier("usage.focus.clear")
        }
        .foregroundStyle(theme.action)
        .padding(.leading, BighelpTokens.space12)
        .padding(.trailing, BighelpTokens.space4)
        .frame(minHeight: 32)
        .background(Capsule().fill(palette.wash))
    }

    private func legend(_ row: UsageSummary.Row) -> some View {
        HStack(spacing: 14) {
            swatch(palette.bar, row.title)
            swatch(palette.ghost, "Everything else")
        }
        .font(.bighelp(.footnote))
        .foregroundStyle(theme.tertiaryText)
        .accessibilityElement(children: .combine)
    }

    private func swatch(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
            Text(title).lineLimit(1)
        }
    }

    // MARK: Chart

    private var segments: [Segment] {
        let points = summary.points
        let focus = focusSeries
        return points.enumerated().flatMap { index, point -> [Segment] in
            let whole = point.amount.value(metric)
            let dimmed = selectedIndex != nil && selectedIndex != index
            let label = point.date.formatted(.dateTime.weekday(.wide).month(.wide).day())
            guard let focus else {
                return [Segment(id: point.day, date: point.date, value: whole, isFocus: true, isRest: false,
                                isDimmed: dimmed, label: label, valueText: UsageFormat.value(point.amount, metric))]
            }
            let part = focus[index].value(metric)
            return [
                Segment(id: point.day + ".focus", date: point.date, value: part, isFocus: true, isRest: false,
                        isDimmed: dimmed, label: label, valueText: UsageFormat.value(focus[index], metric)),
                Segment(id: point.day + ".rest", date: point.date, value: max(0, whole - part), isFocus: false,
                        isRest: true, isDimmed: dimmed, label: label, valueText: ""),
            ]
        }
    }

    private var maxValue: Double {
        summary.points.map { $0.amount.value(metric) }.max() ?? 0
    }

    private var axisLabels: (String, String, String) {
        let points = summary.points
        func text(_ index: Int) -> String {
            points.indices.contains(index) ? points[index].date.formatted(.dateTime.month(.abbreviated).day()) : ""
        }
        return (text(0), points.count > 2 ? text(points.count / 2) : "", text(points.count - 1))
    }

    private var chart: some View {
        VStack(spacing: BighelpTokens.space8) {
            HStack {
                Spacer()
                Text(metric == .cost ? UsageFormat.axisMoney(maxValue) : UsageFormat.short(Int(maxValue)))
                    .font(.bighelp(.caption))
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryText)
                    .accessibilityHidden(true)
            }
            Chart {
                ForEach(segments) { segment in
                    BarMark(x: .value("Day", segment.date, unit: .day), y: .value(metric.title, segment.value))
                        .foregroundStyle(segment.isRest ? palette.ghost : palette.bar)
                        .opacity(segment.isDimmed ? 0.38 : 1)
                        .cornerRadius(2)
                        .accessibilityLabel(segment.label)
                        .accessibilityValue(segment.valueText)
                        .accessibilityHidden(segment.isRest)
                }
                if maxValue > 0 {
                    RuleMark(y: .value("Highest", maxValue))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(palette.grid)
                        .accessibilityHidden(true)
                }
                RuleMark(y: .value("Zero", 0))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(theme.border)
                    .accessibilityHidden(true)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(maxValue, 0.000_001))
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(.rect)
                        .onTapGesture { location in pick(at: location, proxy: proxy, geometry: geometry) }
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 150)
            .accessibilityIdentifier("usage.chart")
            HStack {
                Text(axisLabels.0)
                Spacer()
                Text(axisLabels.1)
                Spacer()
                Text(axisLabels.2)
            }
            .font(.bighelp(.caption))
            .monospacedDigit()
            .foregroundStyle(theme.tertiaryText)
            .accessibilityHidden(true)
        }
    }

    private func pick(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plot = proxy.plotFrame else { return }
        let x = location.x - geometry[plot].origin.x
        guard let date: Date = proxy.value(atX: x),
              let point = summary.points.min(by: {
                  abs($0.date.addingTimeInterval(43_200).timeIntervalSince(date))
                      < abs($1.date.addingTimeInterval(43_200).timeIntervalSince(date))
              }) else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            selectedDay = selectedDay == point.day ? nil : point.day
        }
    }
}

// MARK: - Totals

struct UsageTotalsSection: View {
    let summary: UsageSummary
    @BighelpThemeReader private var theme

    var body: some View {
        let totals = summary.totals
        VStack(alignment: .leading, spacing: 0) {
            UsageCaption(title: "Totals")
            VStack(spacing: 0) {
                row("Processed tokens",
                    totals.tokensPerActiveDay.map { "\(UsageFormat.count($0)) per active day" } ?? "Uncached input plus output",
                    UsageFormat.count(totals.processedTokens), id: "processed")
                if let share = totals.cacheShare {
                    divider
                    row("Cached input", "Read from the cache, not sent again",
                        UsageFormat.count(totals.cacheReadTokens), id: "cached")
                    divider
                    cacheRate(share)
                }
                divider
                row("Input", "uncached", UsageFormat.count(totals.inputTokens), id: "input")
                divider
                row("Output", "written by your agents", UsageFormat.count(totals.outputTokens), id: "output")
                divider
                if let messages = totals.messages {
                    row("Messages", "across \(UsageFormat.count(totals.sessions)) sessions",
                        UsageFormat.count(messages), id: "messages")
                } else {
                    row("Sessions", "\(UsageFormat.count(totals.apiCalls)) model calls",
                        UsageFormat.count(totals.sessions), id: "sessions")
                }
            }
            .usageCard(theme, padding: EdgeInsets(top: 2, leading: 18, bottom: 2, trailing: 18))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage.totals")
    }

    private var divider: some View { Rectangle().fill(theme.separator).frame(height: 1) }

    private func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
            Text(detail).font(.bighelp(.footnote)).monospacedDigit().foregroundStyle(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.bighelp(.title3).weight(.bold))
            .monospacedDigit()
            .foregroundStyle(theme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private func row(_ title: String, _ detail: String, _ amount: String, id: String) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            label(title, detail)
            value(amount)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage.totals.\(id)")
    }

    private func cacheRate(_ share: Double) -> some View {
        HStack(spacing: BighelpTokens.space12) {
            label("Cache hit rate", "of all input came from the cache")
            HStack(spacing: BighelpTokens.space8) {
                ZStack {
                    Circle().stroke(UsagePalette(theme: theme).ghost, lineWidth: 4)
                    Circle().trim(from: 0, to: min(max(share, 0), 1))
                        .stroke(UsagePalette(theme: theme).bar, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
                value(UsageFormat.percent(share))
            }
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage.totals.cache-rate")
    }
}

// MARK: - When you use it

struct UsageWhenSection: View {
    let summary: UsageSummary
    @State private var weekday: Int?
    @State private var hour: Int?
    @BighelpThemeReader private var theme

    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    var body: some View {
        if summary.weekdays.contains(where: { $0 > 0 }) {
            VStack(alignment: .leading, spacing: 0) {
                UsageCaption(title: "When you use it")
                VStack(alignment: .leading, spacing: 22) {
                    weekdayChart
                    Rectangle().fill(theme.separator).frame(height: 1)
                    if let hours = summary.hours {
                        hourChart(hours)
                    } else if summary.hoursNeedPlugin {
                        Text("Update the bighelp plugin to see the hours you use it.")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.tertiaryText)
                            .accessibilityIdentifier("usage.hours.update-plugin")
                    }
                }
                .usageCard(theme, padding: EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("usage.when")
        }
    }

    private func sessions(_ count: Int) -> String { count == 1 ? "1 session" : "\(UsageFormat.count(count)) sessions" }

    private func header(_ title: String, busiest: Bool, value: String) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Text(title).font(.bighelp(.headline)).foregroundStyle(theme.primaryText).lineLimit(1)
            if busiest { UsageBadge(text: "Busiest") }
            Spacer(minLength: BighelpTokens.space8)
            Text(value).font(.bighelp(.subheadline)).monospacedDigit().foregroundStyle(theme.secondaryText)
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
    }

    private var weekdayChart: some View {
        let counts = summary.weekdays
        let busiest = counts.indices.max { counts[$0] < counts[$1] } ?? 0
        let selected = weekday ?? busiest
        let palette = UsagePalette(theme: theme)
        return VStack(alignment: .leading, spacing: 10) {
            header(Self.weekdays[selected], busiest: selected == busiest, value: sessions(counts[selected]))
            Chart {
                ForEach(counts.indices, id: \.self) { index in
                    BarMark(x: .value("Day", Self.weekdays[index]), y: .value("Sessions", counts[index]), width: .ratio(0.82))
                        .foregroundStyle(palette.bar)
                        .opacity(index == selected ? 1 : 0.32)
                        .cornerRadius(6)
                        .accessibilityLabel(Self.weekdays[index])
                        .accessibilityValue(sessions(counts[index]))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(.rect)
                        .onTapGesture { location in
                            guard let plot = proxy.plotFrame,
                                  let name: String = proxy.value(atX: location.x - geometry[plot].origin.x),
                                  let index = Self.weekdays.firstIndex(of: name) else { return }
                            withAnimation(.easeOut(duration: 0.18)) { weekday = index }
                        }
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 74)
            HStack(spacing: 0) {
                ForEach(counts.indices, id: \.self) { index in
                    Text(String(Self.weekdays[index].prefix(1)))
                        .font(.bighelp(.caption).weight(index == selected ? .bold : .medium))
                        .foregroundStyle(index == selected ? theme.primaryText : theme.tertiaryText)
                        .frame(maxWidth: .infinity)
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier("usage.weekdays")
    }

    private func hourName(_ hour: Int) -> String {
        "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
    }

    private func hourChart(_ counts: [Int]) -> some View {
        let busiest = counts.indices.max { counts[$0] < counts[$1] } ?? 0
        let selected = hour ?? busiest
        let top = max(counts.max() ?? 0, 1)
        let palette = UsagePalette(theme: theme)
        return VStack(alignment: .leading, spacing: 10) {
            header(hourName(selected), busiest: selected == busiest && counts[busiest] > 0, value: sessions(counts[selected]))
            Chart {
                ForEach(counts.indices, id: \.self) { index in
                    // An empty hour keeps a sliver in the track color so the day reads as 24 hours.
                    BarMark(x: .value("Hour", String(index)), y: .value("Sessions", max(Double(counts[index]), Double(top) * 0.04)),
                            width: .ratio(0.86))
                        .foregroundStyle(counts[index] == 0 ? palette.ghost : palette.bar)
                        .opacity(index == selected || counts[index] == 0 ? 1 : 0.32)
                        .cornerRadius(2)
                        .accessibilityLabel(hourName(index))
                        .accessibilityValue(sessions(counts[index]))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(.rect)
                        .onTapGesture { location in
                            guard let plot = proxy.plotFrame,
                                  let name: String = proxy.value(atX: location.x - geometry[plot].origin.x),
                                  let index = Int(name) else { return }
                            withAnimation(.easeOut(duration: 0.18)) { hour = index }
                        }
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 64)
            HStack(spacing: 0) {
                ForEach(["12 AM", "6 AM", "12 PM", "6 PM"], id: \.self) { label in
                    Text(label).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.bighelp(.caption))
            .foregroundStyle(theme.tertiaryText)
            .accessibilityHidden(true)
        }
        .accessibilityIdentifier("usage.hours")
    }
}

// MARK: - By model, agent and computer

/// Ranked rows with their share. Tap one to chart it; tap again for everything.
struct UsageBreakdownSection: View {
    let title: String
    let rows: [UsageSummary.Row]
    let summary: UsageSummary
    let store: UsageStore
    let identifier: String
    /// Shows each row's computer (agents with All hosts on).
    let showsDetail: Bool
    @State private var showsAll = false
    @BighelpThemeReader private var theme

    private static let shortList = 5

    var body: some View {
        if !rows.isEmpty {
            let ranked = ranked
            let shown = showsAll ? ranked : Array(ranked.prefix(Self.shortList))
                + ranked.dropFirst(Self.shortList).filter { $0.id == store.focus }
            VStack(alignment: .leading, spacing: 0) {
                UsageCaption(title: title) {
                    if rows.count > 1 {
                        Text("Tap one to chart it")
                            .font(.bighelp(.footnote))
                            .foregroundStyle(theme.tertiaryText)
                    }
                }
                VStack(spacing: 2) {
                    ForEach(shown) { row in rowButton(row) }
                    if ranked.count > Self.shortList {
                        Button(showsAll ? "Show fewer" : "Show \(ranked.count - Self.shortList) more") {
                            withAnimation(.easeOut(duration: 0.2)) { showsAll.toggle() }
                        }
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.action)
                        .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                        .bighelpPlainButtonStyle(.rounded(BighelpTokens.radius12))
                        .accessibilityIdentifier("\(identifier).more")
                    }
                }
                .usageCard(theme, padding: EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
        }
    }

    private var metric: UsageMetric { store.metric }

    private var ranked: [UsageSummary.Row] {
        rows.enumerated().sorted { lhs, rhs in
            let a = lhs.element.amount, b = rhs.element.amount
            let (first, second) = metric == .cost ? ((a.cost, Double(a.tokens)), (b.cost, Double(b.tokens)))
                : ((Double(a.tokens), a.cost), (Double(b.tokens), b.cost))
            if first != second { return first > second }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private var whole: Double {
        metric == .cost ? summary.totals.cost : Double(summary.totals.processedTokens)
    }

    private func meta(_ row: UsageSummary.Row) -> String {
        if let failure = row.failure, row.amount == .zero { return failure }
        let share = whole > 0 ? row.amount.value(metric) / whole : 0
        var parts: [String] = []
        if showsDetail, let detail = row.detail { parts.append(detail) }
        parts.append("\(UsageFormat.percent(share)) of \(metric == .cost ? "cost" : "tokens")")
        parts.append(metric == .cost ? "\(UsageFormat.count(row.amount.tokens)) tokens"
                     : row.amount.cost > 0 ? UsageFormat.money(row.amount.cost) : "no cost")
        parts.append(row.sessions == 1 ? "1 session" : "\(UsageFormat.count(row.sessions)) sessions")
        if let cache = row.cacheShare { parts.append("\(UsageFormat.percent(cache)) cached") }
        if let failure = row.failure { parts.append(failure) }
        return parts.joined(separator: " · ")
    }

    private func rowButton(_ row: UsageSummary.Row) -> some View {
        let isOn = store.focus == row.id
        let value = row.amount.value(metric)
        let share = whole > 0 ? value / whole : 0
        let palette = UsagePalette(theme: theme)
        let unreadable = row.failure != nil && row.amount == .zero
        return Button {
            withAnimation(.easeOut(duration: 0.2)) { store.focus = isOn ? nil : row.id }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.title)
                        .font(.bighelp(.body))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(unreadable ? "–" : metric == .cost ? UsageFormat.money(row.amount.cost)
                         : UsageFormat.short(row.amount.tokens))
                        .font(.bighelp(.body).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(value > 0 ? theme.primaryText : theme.tertiaryText)
                }
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(palette.ghost)
                        Capsule().fill(palette.bar)
                            .frame(width: share > 0 ? max(proxy.size.width * 0.015, proxy.size.width * share) : 0)
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
                Text(meta(row))
                    .font(.bighelp(.footnote))
                    .monospacedDigit()
                    .foregroundStyle(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, BighelpTokens.space12)
            .padding(.horizontal, 14)
            .frame(minHeight: BighelpTokens.hitTarget)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(isOn ? palette.wash : .clear)
            }
            .overlay {
                if isOn {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.action, lineWidth: 1.5)
                }
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .bighelpPlainButtonStyle(.rounded(14))
        .disabled(unreadable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(isOn ? "Shows everything again." : "Charts this one against everything else.")
        .accessibilityIdentifier("\(identifier).row.\(row.title)")
    }
}
