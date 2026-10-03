import Charts
import SwiftUI

/// The Usage page drawn for sharing: the same sections and numbers, laid out
/// flat (ImageRenderer leaves scroll views blank), every row listed, nothing to
/// tap. Pieces are separate blocks so a PDF can break pages between them.
struct UsageExportBlocks {
    let snapshot: UsageExportSnapshot
    /// Long lists in page-sized pieces, for PDF pages.
    var forPages = false

    private static let rowsPerPiece = 8

    @MainActor
    var blocks: [AnyView] {
        var blocks: [AnyView] = [AnyView(UsageExportHeader(snapshot: snapshot))]
        let summary = snapshot.summary
        for (index, computer) in snapshot.computers.enumerated() {
            let caption = index == 0 ? "Limits" : nil
            let name = snapshot.namesComputers ? computer.name : nil
            if computer.providers.isEmpty {
                blocks.append(AnyView(UsageExportPiece(caption: caption, computer: name) {
                    UsageMessageCard(title: computer.note ?? "No AI plans to show.")
                }))
            }
            for (cardIndex, provider) in computer.providers.enumerated() {
                blocks.append(AnyView(UsageExportPiece(caption: cardIndex == 0 ? caption : nil,
                                                       computer: cardIndex == 0 ? name : nil) {
                    UsageLimitCard(provider: provider, used: computer.used[provider.id], range: snapshot.range,
                                   isExport: true, now: snapshot.generatedAt)
                }))
            }
        }
        blocks.append(AnyView(UsageExportPiece(caption: snapshot.metric == .cost ? "Cost per day" : "Tokens per day") {
            UsageExportHero(snapshot: snapshot)
        }))
        blocks.append(AnyView(UsageTotalsSection(summary: summary)))
        if summary.weekdays.contains(where: { $0 > 0 }) {
            blocks.append(AnyView(UsageWhenSection(summary: summary)))
        }
        func rows(_ title: String, _ rows: [UsageSummary.Row], showsDetail: Bool) {
            guard !rows.isEmpty else { return }
            let ranked = UsageExportRows.ranked(rows, metric: snapshot.metric)
            let pieces = forPages ? stride(from: 0, to: ranked.count, by: Self.rowsPerPiece).map {
                Array(ranked[$0..<min($0 + Self.rowsPerPiece, ranked.count)])
            } : [ranked]
            for (index, piece) in pieces.enumerated() {
                blocks.append(AnyView(UsageExportPiece(caption: index == 0 ? title : nil) {
                    UsageExportRows(rows: piece, snapshot: snapshot, showsDetail: showsDetail)
                }))
            }
        }
        rows("By model", summary.models, showsDetail: false)
        rows("By agent", summary.agents, showsDetail: summary.isMultiHost)
        if summary.isMultiHost { rows("By computer", summary.hosts, showsDetail: false) }
        return blocks
    }
}

/// The whole page in one column, for the PNG.
struct UsageExportPage: View {
    let snapshot: UsageExportSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space16) {
            let blocks = UsageExportBlocks(snapshot: snapshot).blocks
            ForEach(blocks.indices, id: \.self) { blocks[$0] }
            UsageExportFooter()
        }
        .padding(.vertical, BighelpTokens.space24)
    }
}

/// Title, dates and when it was made.
struct UsageExportHeader: View {
    let snapshot: UsageExportSnapshot
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: BighelpTokens.space4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Usage")
                    .font(.bighelp(.largeTitle).weight(.bold))
                    .foregroundStyle(theme.primaryText)
                Spacer(minLength: BighelpTokens.space8)
                Text("bighelp")
                    .font(.bighelp(.subheadline).weight(.semibold))
                    .foregroundStyle(theme.action)
            }
            Text("\(snapshot.dateRangeText) · \(snapshot.range.days) days")
                .font(.bighelp(.headline))
                .foregroundStyle(theme.primaryText)
            Text(([snapshot.generatedText] + [snapshot.computersText].compactMap { $0 }).joined(separator: " · "))
                .font(.bighelp(.footnote))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = snapshot.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.top, BighelpTokens.space4)
            }
        }
        .padding(.horizontal, BighelpTokens.space20)
    }
}

struct UsageExportFooter: View {
    var page: (Int, Int)?
    @BighelpThemeReader private var theme

    var body: some View {
        HStack {
            Text("Numbers from Hermes on each computer. Costs are Hermes' estimates.")
            Spacer(minLength: BighelpTokens.space8)
            if let page { Text("Page \(page.0) of \(page.1)").monospacedDigit() }
        }
        .font(.bighelp(.caption))
        .foregroundStyle(theme.tertiaryText)
        .padding(.horizontal, BighelpTokens.space20)
    }
}

/// A block with its section's caption and computer heading, when it starts one.
private struct UsageExportPiece<Content: View>: View {
    var caption: String?
    var computer: String?
    @ViewBuilder let content: () -> Content
    @BighelpThemeReader private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let caption { UsageCaption(title: caption).padding(.top, BighelpTokens.space8) }
            if let computer {
                HStack(spacing: BighelpTokens.space8) {
                    Image(systemName: "desktopcomputer")
                        .font(.bighelp(.subheadline).weight(.semibold))
                        .foregroundStyle(theme.secondaryText)
                    Text(computer)
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.primaryText)
                }
                .padding(.horizontal, BighelpTokens.space20)
                .padding(.top, caption == nil ? BighelpTokens.space12 : 0)
                .padding(.bottom, BighelpTokens.space12)
            }
            content()
        }
    }
}

/// The big number and the bars per day, without the page's controls.
private struct UsageExportHero: View {
    let snapshot: UsageExportSnapshot
    @BighelpThemeReader private var theme

    private var metric: UsageMetric { snapshot.metric }
    private var summary: UsageSummary { snapshot.summary }

    var body: some View {
        let palette = UsagePalette(theme: theme)
        let top = summary.points.map { $0.amount.value(metric) }.max() ?? 0
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                Text(snapshot.measureText)
                    .font(.bighelp(.subheadline))
                    .foregroundStyle(theme.secondaryText)
                Text(UsageFormat.value(UsageAmount(cost: summary.totals.cost, tokens: summary.totals.processedTokens),
                                       metric))
                    .font(.bighelp(.largeTitle).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.primaryText)
                Text(note)
                    .font(.bighelp(.footnote))
                    .foregroundStyle(theme.tertiaryText)
            }
            VStack(spacing: BighelpTokens.space8) {
                HStack {
                    Spacer()
                    Text(metric == .cost ? UsageFormat.axisMoney(top) : UsageFormat.short(Int(top)))
                        .font(.bighelp(.caption))
                        .monospacedDigit()
                        .foregroundStyle(theme.tertiaryText)
                }
                Chart {
                    ForEach(summary.points) { point in
                        BarMark(x: .value("Day", point.date, unit: .day), y: .value(metric.title, point.amount.value(metric)))
                            .foregroundStyle(palette.bar)
                            .cornerRadius(2)
                    }
                    if top > 0 {
                        RuleMark(y: .value("Highest", top))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .foregroundStyle(palette.grid)
                    }
                    RuleMark(y: .value("Zero", 0))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .foregroundStyle(theme.border)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...max(top, 0.000_001))
                .chartLegend(.hidden)
                .frame(height: 150)
                HStack {
                    ForEach(Array(axis.enumerated()), id: \.offset) { index, label in
                        if index > 0 { Spacer() }
                        Text(label)
                    }
                }
                .font(.bighelp(.caption))
                .monospacedDigit()
                .foregroundStyle(theme.tertiaryText)
            }
        }
        .usageCard(theme, padding: EdgeInsets(top: 18, leading: 18, bottom: 14, trailing: 18))
    }

    private var note: String {
        if metric == .tokens { return "Uncached input plus output" }
        if summary.totals.billedCost > 0 {
            return "Estimated by Hermes. Providers billed \(UsageFormat.money(summary.totals.billedCost))."
        }
        return "Estimated by Hermes from your agents' sessions"
    }

    private var axis: [String] {
        let points = summary.points
        func text(_ index: Int) -> String {
            points.indices.contains(index) ? points[index].date.formatted(.dateTime.month(.abbreviated).day()) : ""
        }
        return [text(0), points.count > 2 ? text(points.count / 2) : "", text(points.count - 1)]
    }
}

/// Ranked rows with their share, all of them.
private struct UsageExportRows: View {
    let rows: [UsageSummary.Row]
    let snapshot: UsageExportSnapshot
    let showsDetail: Bool
    @BighelpThemeReader private var theme

    static func ranked(_ rows: [UsageSummary.Row], metric: UsageMetric) -> [UsageSummary.Row] {
        rows.enumerated().sorted { lhs, rhs in
            let a = lhs.element.amount.value(metric), b = rhs.element.amount.value(metric)
            return a != b ? a > b : lhs.offset < rhs.offset
        }.map(\.element)
    }

    private var metric: UsageMetric { snapshot.metric }
    private var whole: Double {
        metric == .cost ? snapshot.summary.totals.cost : Double(snapshot.summary.totals.processedTokens)
    }

    var body: some View {
        let palette = UsagePalette(theme: theme)
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                let share = whole > 0 ? row.amount.value(metric) / whole : 0
                let unreadable = row.failure != nil && row.amount == .zero
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
                            .foregroundStyle(theme.primaryText)
                    }
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.ghost)
                            Capsule().fill(palette.bar)
                                .frame(width: share > 0 ? max(proxy.size.width * 0.015, proxy.size.width * share) : 0)
                        }
                    }
                    .frame(height: 4)
                    Text(meta(row, share: share))
                        .font(.bighelp(.footnote))
                        .monospacedDigit()
                        .foregroundStyle(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, BighelpTokens.space12)
                .padding(.horizontal, 14)
                if index < rows.count - 1 {
                    Rectangle().fill(theme.separator).frame(height: 1).padding(.horizontal, 14)
                }
            }
        }
        .usageCard(theme, padding: EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
    }

    private func meta(_ row: UsageSummary.Row, share: Double) -> String {
        if let failure = row.failure, row.amount == .zero { return failure }
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
}

// MARK: - Rendering

/// PNG: the whole page as one tall picture. PDF: the same blocks on pages,
/// each starting a new page rather than being cut in two.
@MainActor
enum UsageExportRenderer {
    static let pageWidth: CGFloat = 640

    /// Light, the person's colors, a fixed text size, opaque.
    static func prepared(_ content: some View, width: CGFloat, appearance: BighelpAppearanceContext) -> some View {
        let light = UsageExportPalette.lightAppearance(appearance)
        let theme = BighelpTheme.resolve(appearance: light, colorScheme: .light, contrast: .standard)
        return content
            .frame(width: width, alignment: .topLeading)
            .background(Color(hex: theme.canvasHex))
            .environment(\.appAppearance, light)
            .environment(\.colorScheme, .light)
            .dynamicTypeSize(.large)
    }

    static func png(_ snapshot: UsageExportSnapshot, appearance: BighelpAppearanceContext) -> Data? {
        let renderer = ImageRenderer(content: prepared(UsageExportPage(snapshot: snapshot), width: pageWidth,
                                                       appearance: appearance))
        renderer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)
        renderer.isOpaque = true
        var height: CGFloat = 0
        renderer.render { size, _ in height = size.height }
        // Sharp at twice the size, short of the largest pictures apps take.
        renderer.scale = min(2, 16_000 / max(height, 1))
        return renderer.uiImage?.pngData()
    }

    /// US Letter in the US and Canada, A4 elsewhere.
    static var pageSize: CGSize {
        [Locale.Region.unitedStates, .canada].contains(Locale.current.region ?? .unitedStates)
            ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
    }

    static func pdf(_ snapshot: UsageExportSnapshot, appearance: BighelpAppearanceContext) -> Data? {
        let page = pageSize
        let margin: CGFloat = 28
        // Laid out at the screen's width, then scaled onto the page.
        let scale = (page.width - margin * 2) / pageWidth
        let footerRoom: CGFloat = 28
        let usable = (page.height - margin * 2 - footerRoom) / scale
        let gap: CGFloat = 16

        // Measure every block, then fill pages with whole blocks.
        var pages: [[(renderer: ImageRenderer<AnyView>, y: CGFloat, height: CGFloat)]] = [[]]
        var y: CGFloat = 0
        for block in UsageExportBlocks(snapshot: snapshot, forPages: true).blocks {
            let renderer = ImageRenderer(content: AnyView(prepared(block, width: pageWidth, appearance: appearance)))
            renderer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)
            var height: CGFloat = 0
            renderer.render { size, _ in height = size.height }
            // A block taller than a page (it shouldn't be) shrinks to fit one.
            let placed = min(height, usable)
            if y > 0, y + placed > usable {
                pages.append([])
                y = 0
            }
            pages[pages.count - 1].append((renderer, y, height))
            y += placed + gap
        }

        let light = UsageExportPalette.lightAppearance(appearance)
        let theme = BighelpTheme.resolve(appearance: light, colorScheme: .light, contrast: .standard)
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: page)
        let info = [kCGPDFContextTitle: "bighelp Usage · \(snapshot.dateRangeText)",
                    kCGPDFContextCreator: "bighelp"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, info) else { return nil }
        for (index, blocks) in pages.enumerated() {
            context.beginPDFPage(nil)
            context.setFillColor(UIColor(Color(hex: theme.canvasHex)).cgColor)
            context.fill(box)
            for block in blocks {
                let fit = block.height > usable ? scale * usable / block.height : scale
                block.renderer.render { size, draw in
                    context.saveGState()
                    // PDF pages count up from the bottom.
                    context.translateBy(x: margin, y: page.height - margin - block.y * scale - size.height * fit)
                    context.scaleBy(x: fit, y: fit)
                    draw(context)
                    context.restoreGState()
                }
            }
            let footer = ImageRenderer(content: prepared(UsageExportFooter(page: (index + 1, pages.count)),
                                                         width: pageWidth, appearance: appearance))
            footer.proposedSize = ProposedViewSize(width: pageWidth, height: nil)
            footer.render { size, draw in
                context.saveGState()
                context.translateBy(x: margin, y: margin)
                context.scaleBy(x: scale, y: scale)
                draw(context)
                context.restoreGState()
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
