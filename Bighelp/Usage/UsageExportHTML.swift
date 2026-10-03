import SwiftUI

/// The light theme's colors as hex, for a shared page that can't read them.
struct UsageExportPalette: Equatable, Sendable {
    var canvas = "#FBF7F3"
    var surface = "#FFFFFF"
    var text = "#1F1B18"
    var secondary = "#6B625C"
    var tertiary = "#8F8680"
    var border = "#E8E0DA"
    var separator = "#EEE7E2"
    var action = "#7B52E0"
    var bar = "#7B52E0"
    var ghost = "#E6DED7"
    var wash = "rgba(123, 82, 224, 0.12)"
    var warning = "#C77700"
    var danger = "#C9372C"

    /// Exports are always light, in the person's own colors.
    static func lightAppearance(_ appearance: BighelpAppearanceContext) -> BighelpAppearanceContext {
        BighelpAppearanceContext(appearance: .light, lightBackground: appearance.lightBackground,
                                 darkBackground: appearance.darkBackground, bubbleColor: appearance.bubbleColor,
                                 customBubbleHex: appearance.customBubbleHex)
    }

    init() {}

    init(appearance: BighelpAppearanceContext) {
        let theme = BighelpTheme.resolve(appearance: Self.lightAppearance(appearance), colorScheme: .light,
                                         contrast: .standard)
        func hex(_ value: String) -> String { "#" + value.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
        canvas = hex(theme.canvasHex)
        surface = hex(theme.surfaceHex)
        text = hex(theme.primaryTextHex)
        secondary = hex(theme.secondaryTextHex)
        tertiary = hex(theme.tertiaryTextHex)
        border = hex(theme.borderHex)
        separator = hex(theme.separatorHex)
        action = hex(theme.actionHex)
        bar = action
        warning = hex(theme.warningHex)
        danger = hex(theme.dangerHex)
        let value = UInt64(action.dropFirst(), radix: 16) ?? 0x7B52E0
        wash = "rgba(\((value >> 16) & 0xFF), \((value >> 8) & 0xFF), \(value & 0xFF), 0.12)"
    }
}

/// The Usage page as one self-contained web page: inline styles and SVG
/// charts, no scripts and nothing loaded from anywhere.
enum UsageExportHTML {
    static func make(_ snapshot: UsageExportSnapshot, palette: UsageExportPalette = .init()) -> String {
        let summary = snapshot.summary
        var body = ""
        body += header(snapshot)
        if !snapshot.computers.isEmpty { body += limits(snapshot, palette) }
        body += hero(snapshot, palette)
        body += totals(summary)
        body += when(summary, palette)
        body += breakdown("By model", summary.models, snapshot, palette, showsDetail: false)
        body += breakdown("By agent", summary.agents, snapshot, palette, showsDetail: summary.isMultiHost)
        if summary.isMultiHost { body += breakdown("By computer", summary.hosts, snapshot, palette, showsDetail: false) }
        body += "<footer>Numbers from Hermes on each computer. Costs are Hermes' estimates. Shared from bighelp.</footer>\n"
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light">
        <title>\(escape("bighelp Usage · \(snapshot.dateRangeText)"))</title>
        <style>
        \(style(palette))
        </style>
        </head>
        <body>
        <main>
        \(body)</main>
        </body>
        </html>

        """
    }

    // MARK: Sections

    private static func header(_ snapshot: UsageExportSnapshot) -> String {
        var lines = "<header>\n<h1>Usage</h1>\n"
        lines += "<p class=\"range\">\(escape(snapshot.dateRangeText)) · \(snapshot.range.days) days</p>\n"
        var meta = [snapshot.generatedText]
        if let computers = snapshot.computersText { meta.append(computers) }
        lines += "<p class=\"meta\">\(escape(meta.joined(separator: " · ")))</p>\n"
        if let notice = snapshot.notice { lines += "<p class=\"notice\">\(escape(notice))</p>\n" }
        return lines + "</header>\n"
    }

    private static func limits(_ snapshot: UsageExportSnapshot, _ palette: UsageExportPalette) -> String {
        var html = "<section id=\"limits\">\n<h2>Limits</h2>\n"
        for computer in snapshot.computers {
            if snapshot.namesComputers { html += "<h3 class=\"computer\">\(escape(computer.name))</h3>\n" }
            if computer.providers.isEmpty {
                html += "<div class=\"card message\">\(escape(computer.note ?? "No AI plans to show."))</div>\n"
            }
            for provider in computer.providers {
                html += "<div class=\"card plan\">\n<div class=\"plan-head\"><strong>\(escape(provider.name))</strong>"
                if provider.activeInHermes { html += "<span class=\"badge\">In use</span>" }
                if let plan = provider.plan { html += "<span class=\"badge\">\(escape(plan))</span>" }
                html += "</div>\n"
                if provider.status != .ok {
                    html += "<p class=\"muted\">\(escape(provider.message ?? "Not shared."))</p>\n"
                } else {
                    for window in provider.windows {
                        let color = window.usedPercent >= 90 ? palette.danger
                            : window.usedPercent >= 75 ? palette.warning : palette.bar
                        let left = ProviderUsagePresentation.percentText(window.leftPercent)
                        let detail = [window.detail, ProviderUsagePresentation.resetText(window.resetsAt, now: snapshot.generatedAt)]
                            .compactMap { $0 }.joined(separator: " · ")
                        html += "<div class=\"window\"><div class=\"row\"><span>\(escape(window.label))</span>"
                        html += "<span class=\"left\" style=\"color:\(color)\">\(provider.approximate ? "About " : "")\(left) left</span></div>"
                        html += "<div class=\"track\"><div style=\"width:\(cssPercent(window.leftPercent));background:\(color)\"></div></div>"
                        if !detail.isEmpty { html += "<div class=\"muted small\">\(escape(detail))</div>" }
                        html += "</div>\n"
                    }
                    for fact in provider.facts {
                        html += "<div class=\"row fact\"><span>\(escape(fact.label))</span><strong>\(escape(fact.value))</strong></div>\n"
                    }
                }
                if let used = computer.used[provider.id] {
                    var parts = ["\(UsageFormat.short(used.tokens)) tokens"]
                    if used.cost > 0 { parts.append(UsageFormat.money(used.cost)) }
                    html += "<p class=\"muted small used\">Your agents: \(escape(parts.joined(separator: " · "))) in \(snapshot.range.days) days</p>\n"
                }
                html += "</div>\n"
            }
        }
        return html + "</section>\n"
    }

    private static func hero(_ snapshot: UsageExportSnapshot, _ palette: UsageExportPalette) -> String {
        let summary = snapshot.summary
        let metric = snapshot.metric
        let total = UsageAmount(cost: summary.totals.cost, tokens: summary.totals.processedTokens)
        let note: String = if metric == .tokens { "Uncached input plus output" }
            else if summary.totals.billedCost > 0 {
                "Estimated by Hermes. Providers billed \(UsageFormat.money(summary.totals.billedCost))."
            } else { "Estimated by Hermes from your agents' sessions" }
        let values = summary.points.map { $0.amount.value(metric) }
        let top = values.max() ?? 0
        let width = 640.0, height = 150.0
        let step = values.isEmpty ? width : width / Double(values.count)
        let barWidth = max(1, step * 0.72)
        var bars = ""
        for (index, value) in values.enumerated() where value > 0 {
            let barHeight = top > 0 ? max(1, value / top * (height - 4)) : 0
            bars += "<rect x=\"\(number(Double(index) * step + (step - barWidth) / 2))\" y=\"\(number(height - barHeight))\" "
                + "width=\"\(number(barWidth))\" height=\"\(number(barHeight))\" rx=\"2\" fill=\"\(palette.bar)\">"
                + "<title>\(escape(summary.points[index].day)): \(escape(UsageFormat.value(summary.points[index].amount, metric)))</title></rect>"
        }
        let axisTop = metric == .cost ? UsageFormat.axisMoney(top) : UsageFormat.short(Int(top))
        let labels = axis(summary.points)
        return """
        <section id="trend">
        <h2>\(metric == .cost ? "Cost" : "Tokens") per day</h2>
        <div class="card hero">
        <div class="hero-label">\(snapshot.measureText)</div>
        <div class="hero-value">\(escape(UsageFormat.value(total, metric)))</div>
        <div class="muted small">\(escape(note))</div>
        <div class="axis-top">\(escape(axisTop))</div>
        <svg class="chart" viewBox="0 0 \(number(width)) \(number(height))" preserveAspectRatio="none" role="img" aria-label="\(metric == .cost ? "Cost" : "Tokens") per day">
        <line x1="0" y1="2" x2="\(number(width))" y2="2" stroke="\(palette.ghost)" stroke-dasharray="3 3"/>
        <line x1="0" y1="\(number(height))" x2="\(number(width))" y2="\(number(height))" stroke="\(palette.border)"/>
        \(bars)
        </svg>
        <div class="axis"><span>\(escape(labels.0))</span><span>\(escape(labels.1))</span><span>\(escape(labels.2))</span></div>
        </div>
        </section>

        """
    }

    private static func totals(_ summary: UsageSummary) -> String {
        let totals = summary.totals
        var rows: [(String, String, String)] = [
            ("Processed tokens", totals.tokensPerActiveDay.map { "\(UsageFormat.count($0)) per active day" }
                ?? "Uncached input plus output", UsageFormat.count(totals.processedTokens)),
        ]
        if let share = totals.cacheShare {
            rows.append(("Cached input", "Read from the cache, not sent again", UsageFormat.count(totals.cacheReadTokens)))
            rows.append(("Cache hit rate", "of all input came from the cache", UsageFormat.percent(share)))
        }
        rows.append(("Input", "uncached", UsageFormat.count(totals.inputTokens)))
        rows.append(("Output", "written by your agents", UsageFormat.count(totals.outputTokens)))
        rows.append(("Estimated cost", totals.billedCost > 0 ? "Providers billed \(UsageFormat.money(totals.billedCost))"
                        : "Estimated by Hermes", UsageFormat.money(totals.cost)))
        if let messages = totals.messages {
            rows.append(("Messages", "across \(UsageFormat.count(totals.sessions)) sessions", UsageFormat.count(messages)))
        } else {
            rows.append(("Sessions", "\(UsageFormat.count(totals.apiCalls)) model calls", UsageFormat.count(totals.sessions)))
        }
        var html = "<section id=\"totals\">\n<h2>Totals</h2>\n<div class=\"card list\">\n"
        for (title, detail, value) in rows {
            html += "<div class=\"line\"><div><div>\(escape(title))</div><div class=\"muted small\">\(escape(detail))</div></div>"
                + "<div class=\"big\">\(escape(value))</div></div>\n"
        }
        return html + "</div>\n</section>\n"
    }

    private static func when(_ summary: UsageSummary, _ palette: UsageExportPalette) -> String {
        guard summary.weekdays.contains(where: { $0 > 0 }) else { return "" }
        let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
        var html = "<section id=\"when\">\n<h2>When you use it</h2>\n<div class=\"card\">\n"
        let busiest = summary.weekdays.indices.max { summary.weekdays[$0] < summary.weekdays[$1] } ?? 0
        html += "<div class=\"row\"><strong>\(names[busiest])</strong><span class=\"badge\">Busiest</span>"
            + "<span class=\"muted\">\(UsageFormat.count(summary.weekdays[busiest])) sessions</span></div>\n"
        html += bars(summary.weekdays, labels: names.map { String($0.prefix(1)) }, highlight: busiest, height: 74, palette)
        if let hours = summary.hours {
            let top = hours.indices.max { hours[$0] < hours[$1] } ?? 0
            let hourName = "\(top % 12 == 0 ? 12 : top % 12) \(top < 12 ? "AM" : "PM")"
            html += "<div class=\"rule\"></div><div class=\"row\"><strong>\(hourName)</strong><span class=\"badge\">Busiest</span>"
                + "<span class=\"muted\">\(UsageFormat.count(hours[top])) sessions</span></div>\n"
            html += bars(hours, labels: (0..<24).map { $0 % 6 == 0 ? "\($0 % 12 == 0 ? 12 : $0 % 12) \($0 < 12 ? "AM" : "PM")" : "" },
                         highlight: top, height: 64, palette)
        }
        return html + "</div>\n</section>\n"
    }

    private static func bars(_ counts: [Int], labels: [String], highlight: Int, height: Double,
                             _ palette: UsageExportPalette) -> String {
        let top = Double(max(counts.max() ?? 0, 1))
        let width = 640.0
        let step = width / Double(max(counts.count, 1))
        var svg = "<svg class=\"chart\" viewBox=\"0 0 \(number(width)) \(number(height))\" preserveAspectRatio=\"none\" role=\"img\">"
        for (index, count) in counts.enumerated() {
            let barHeight = max(Double(count) / top * height, height * 0.04)
            svg += "<rect x=\"\(number(Double(index) * step + step * 0.09))\" y=\"\(number(height - barHeight))\" "
                + "width=\"\(number(step * 0.82))\" height=\"\(number(barHeight))\" rx=\"3\" "
                + "fill=\"\(count == 0 ? palette.ghost : palette.bar)\" fill-opacity=\"\(index == highlight || count == 0 ? "1" : "0.32")\">"
                + "<title>\(UsageFormat.count(count)) sessions</title></rect>"
        }
        svg += "</svg>\n<div class=\"ticks\">" + labels.map { "<span>\(escape($0))</span>" }.joined() + "</div>\n"
        return svg
    }

    private static func breakdown(_ title: String, _ rows: [UsageSummary.Row], _ snapshot: UsageExportSnapshot,
                                  _ palette: UsageExportPalette, showsDetail: Bool) -> String {
        guard !rows.isEmpty else { return "" }
        let metric = snapshot.metric
        let whole = metric == .cost ? snapshot.summary.totals.cost : Double(snapshot.summary.totals.processedTokens)
        let ranked = rows.sorted { $0.amount.value(metric) > $1.amount.value(metric) }
        let identifier = title.lowercased().replacingOccurrences(of: " ", with: "-")
        var html = "<section id=\"\(identifier)\">\n<h2>\(escape(title))</h2>\n<div class=\"card list\">\n"
        for row in ranked {
            let share = whole > 0 ? row.amount.value(metric) / whole : 0
            var parts: [String] = []
            if showsDetail, let detail = row.detail { parts.append(detail) }
            if let failure = row.failure, row.amount == .zero {
                parts.append(failure)
            } else {
                parts.append("\(UsageFormat.percent(share)) of \(metric == .cost ? "cost" : "tokens")")
                parts.append(metric == .cost ? "\(UsageFormat.count(row.amount.tokens)) tokens"
                             : row.amount.cost > 0 ? UsageFormat.money(row.amount.cost) : "no cost")
                parts.append(row.sessions == 1 ? "1 session" : "\(UsageFormat.count(row.sessions)) sessions")
                if let cache = row.cacheShare { parts.append("\(UsageFormat.percent(cache)) cached") }
                if let failure = row.failure { parts.append(failure) }
            }
            let value = row.failure != nil && row.amount == .zero ? "–"
                : metric == .cost ? UsageFormat.money(row.amount.cost) : UsageFormat.short(row.amount.tokens)
            html += "<div class=\"line item\"><div class=\"grow\"><div class=\"row\"><span class=\"name\">\(escape(row.title))</span>"
                + "<strong>\(escape(value))</strong></div>"
                + "<div class=\"track thin\"><div style=\"width:\(cssPercent(share * 100));background:\(palette.bar)\"></div></div>"
                + "<div class=\"muted small\">\(escape(parts.joined(separator: " · ")))</div></div></div>\n"
        }
        return html + "</div>\n</section>\n"
    }

    // MARK: Pieces

    private static func axis(_ points: [UsageSummary.Point]) -> (String, String, String) {
        func text(_ index: Int) -> String {
            points.indices.contains(index) ? points[index].date.formatted(.dateTime.month(.abbreviated).day()) : ""
        }
        return (text(0), points.count > 2 ? text(points.count / 2) : "", text(points.count - 1))
    }

    private static func style(_ palette: UsageExportPalette) -> String {
        """
        :root { color-scheme: light; }
        * { box-sizing: border-box; }
        body { margin: 0; background: \(palette.canvas); color: \(palette.text);
          font: 15px/1.4 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
          -webkit-font-smoothing: antialiased; }
        main { max-width: 720px; margin: 0 auto; padding: 32px 20px 48px; }
        header h1 { font-size: 30px; margin: 0 0 4px; }
        .range { font-size: 17px; font-weight: 600; margin: 0; }
        .meta, .muted { color: \(palette.secondary); }
        .meta { margin: 4px 0 0; font-size: 13px; }
        .notice { margin: 12px 0 0; padding: 10px 14px; border-radius: 12px; background: \(palette.wash); font-size: 13px; }
        h2 { font-size: 12px; font-weight: 700; letter-spacing: 0.9px; text-transform: uppercase; color: \(palette.tertiary);
          margin: 28px 4px 8px; }
        h3.computer { font-size: 17px; margin: 18px 4px 8px; }
        h3.computer::before { content: "\\1F5A5\\FE0E  "; color: \(palette.secondary); }
        .card { background: \(palette.surface); border: 1px solid \(palette.border); border-radius: 18px;
          padding: 16px 18px; margin: 0 0 12px; box-shadow: 0 2px 3px rgba(0, 0, 0, 0.06); }
        .card.list { padding: 2px 18px; }
        .message { text-align: center; font-weight: 600; }
        .row { display: flex; align-items: baseline; gap: 8px; justify-content: space-between; }
        .row .muted { margin-left: auto; }
        .plan-head { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; font-size: 17px; }
        .plan-head strong { flex: 1; }
        .badge { color: \(palette.action); background: \(palette.wash); border-radius: 999px; padding: 2px 8px;
          font-size: 12px; font-weight: 700; white-space: nowrap; }
        .window { margin: 10px 0; }
        .window .row span:first-child { color: \(palette.secondary); }
        .left { font-weight: 600; font-variant-numeric: tabular-nums; }
        .track { height: 6px; border-radius: 3px; background: \(palette.ghost); overflow: hidden; margin: 6px 0 4px; }
        .track.thin { height: 4px; }
        .track div { height: 100%; border-radius: 3px; }
        .fact { margin: 6px 0; }
        .fact strong { font-size: 20px; }
        .used { border-top: 1px solid \(palette.separator); padding-top: 10px; margin: 10px 0 0; }
        .small { font-size: 13px; }
        .hero-label { color: \(palette.secondary); font-size: 15px; }
        .hero-value { font-size: 34px; font-weight: 700; font-variant-numeric: tabular-nums; }
        .axis-top { text-align: right; color: \(palette.tertiary); font-size: 12px; margin-top: 12px; }
        .chart { display: block; width: 100%; height: auto; margin: 6px 0; }
        .axis, .ticks { display: flex; justify-content: space-between; color: \(palette.tertiary); font-size: 12px; }
        .ticks span { flex: 1; text-align: left; }
        .line { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 14px 0;
          border-bottom: 1px solid \(palette.separator); }
        .line:last-child { border-bottom: none; }
        .line .big { font-size: 20px; font-weight: 700; font-variant-numeric: tabular-nums; white-space: nowrap; }
        .item .grow { flex: 1; min-width: 0; }
        .item .name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .rule { border-top: 1px solid \(palette.separator); margin: 18px 0; }
        strong { font-variant-numeric: tabular-nums; }
        footer { color: \(palette.tertiary); font-size: 12px; text-align: center; margin-top: 28px; }
        @media print { body { background: #FFFFFF; } .card { box-shadow: none; break-inside: avoid; } }
        """
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    private static func cssPercent(_ value: Double) -> String { number(min(max(value, 0), 100)) + "%" }
}
