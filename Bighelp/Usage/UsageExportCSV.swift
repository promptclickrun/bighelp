import Foundation

/// The Usage page's numbers as one tidy table: a row per day, model, agent,
/// computer, total and limit, its kind in `section`, with full-precision
/// numbers (no "$" or "1.5M") so spreadsheets can add them up.
enum UsageExportCSV {
    static let columns = ["section", "date", "computer", "agent", "model", "provider", "plan", "item", "value",
                          "cost_usd", "tokens", "sessions", "cache_hit_percent", "used_percent", "left_percent",
                          "resets_at", "note"]

    private typealias Row = [String: String]

    static func make(_ snapshot: UsageExportSnapshot) -> String {
        let summary = snapshot.summary
        var rows: [Row] = []

        // What this is.
        func report(_ item: String, _ value: String) { rows.append(["section": "report", "item": item, "value": value]) }
        report("Range", "\(snapshot.range.days) days")
        if let first = snapshot.firstDay, let last = snapshot.lastDay {
            report("From", day(first, snapshot.calendar))
            report("To", day(last, snapshot.calendar))
        }
        report("Measure on screen", snapshot.measureText)
        report("Generated", timestamp(snapshot.generatedAt))
        if let readAt = snapshot.readAt { report("Read from computers", timestamp(readAt)) }
        if let computers = snapshot.computersText { report("Computers", computers) }
        if let notice = snapshot.notice { report("Note", notice) }

        // Totals.
        let totals = summary.totals
        func total(_ item: String, cost: Double? = nil, tokens: Int? = nil, sessions: Int? = nil, value: String? = nil) {
            var row: Row = ["section": "total", "item": item]
            row["cost_usd"] = cost.map(money)
            row["tokens"] = tokens.map(String.init)
            row["sessions"] = sessions.map(String.init)
            row["value"] = value
            rows.append(row)
        }
        total("Estimated cost", cost: totals.cost)
        if totals.billedCost > 0 { total("Billed by providers", cost: totals.billedCost) }
        total("Processed tokens", tokens: totals.processedTokens)
        total("Input tokens (uncached)", tokens: totals.inputTokens)
        total("Output tokens", tokens: totals.outputTokens)
        total("Cached input tokens", tokens: totals.cacheReadTokens)
        if let share = totals.cacheShare { total("Cache hit rate", value: percent(share * 100)) }
        total("Sessions", sessions: totals.sessions)
        total("Model calls", value: String(totals.apiCalls))
        if let messages = totals.messages { total("Messages", value: String(messages)) }
        total("Active days", value: String(totals.activeDays))

        // Each day, then each day per computer and per model where the hosts said.
        for point in summary.points {
            rows.append(["section": "daily", "date": point.day, "cost_usd": money(point.amount.cost),
                         "tokens": String(point.amount.tokens), "sessions": String(point.sessions)])
        }
        if summary.isMultiHost {
            for host in summary.hosts {
                guard let series = summary.series(for: host.id) else { continue }
                for (point, amount) in zip(summary.points, series) {
                    rows.append(["section": "daily_by_computer", "date": point.day, "computer": host.title,
                                 "cost_usd": money(amount.cost), "tokens": String(amount.tokens)])
                }
            }
        }
        for model in summary.models {
            guard let series = summary.series(for: model.id) else { continue }
            for (point, amount) in zip(summary.points, series) where amount != .zero {
                rows.append(["section": "daily_by_model", "date": point.day, "model": model.title,
                             "provider": model.detail ?? "", "cost_usd": money(amount.cost),
                             "tokens": String(amount.tokens)])
            }
        }

        // The ranked rows, all of them.
        func breakdown(_ section: String, _ row: UsageSummary.Row, computer: String? = nil) -> Row {
            var result: Row = ["section": section, "cost_usd": money(row.amount.cost),
                               "tokens": String(row.amount.tokens), "sessions": String(row.sessions)]
            result["cache_hit_percent"] = row.cacheShare.map { percent($0 * 100) }
            result["computer"] = computer
            result["note"] = row.failure
            return result
        }
        for model in summary.models {
            var row = breakdown("model", model)
            row["model"] = model.title
            row["provider"] = model.detail
            rows.append(row)
        }
        let hostNames = Dictionary(summary.hosts.map { (String($0.id.dropFirst("host:".count)), $0.title) },
                                   uniquingKeysWith: { first, _ in first })
        for agent in summary.agents {
            // "agent:<host>/<agent>": its computer is the part before the slash.
            let hostID = agent.id.dropFirst("agent:".count).split(separator: "/", maxSplits: 1).first.map(String.init)
            var row = breakdown("agent", agent, computer: hostID.flatMap { hostNames[$0] } ?? agent.detail)
            row["agent"] = agent.title
            rows.append(row)
        }
        for host in summary.hosts {
            rows.append(breakdown("computer", host, computer: host.title))
        }

        // Plans and limits, per computer.
        for computer in snapshot.computers {
            if let note = computer.note, computer.providers.isEmpty {
                rows.append(["section": "limit", "computer": computer.name, "note": note])
            }
            for provider in computer.providers {
                let base: Row = ["computer": computer.name, "provider": provider.name, "plan": provider.plan ?? ""]
                if provider.status != .ok {
                    rows.append(base.merging(["section": "limit", "item": "Status",
                                              "value": status(provider.status), "note": provider.message ?? ""],
                                             uniquingKeysWith: { $1 }))
                    continue
                }
                for window in provider.windows {
                    var row = base.merging(["section": "limit", "item": window.label, "value": window.detail ?? "",
                                            "used_percent": percent(window.usedPercent),
                                            "left_percent": percent(window.leftPercent)], uniquingKeysWith: { $1 })
                    row["resets_at"] = window.resetsAt.map(timestamp)
                    if provider.approximate { row["note"] = "Approximate" }
                    rows.append(row)
                }
                for fact in provider.facts {
                    rows.append(base.merging(["section": "balance", "item": fact.label, "value": fact.value],
                                             uniquingKeysWith: { $1 }))
                }
                if let used = computer.used[provider.id] {
                    rows.append(base.merging(["section": "agents_used", "item": "Your agents in \(snapshot.range.days) days",
                                              "cost_usd": money(used.cost), "tokens": String(used.tokens)],
                                             uniquingKeysWith: { $1 }))
                }
            }
        }

        let lines = [columns.joined(separator: ",")] + rows.map { row in
            columns.map { field(row[$0] ?? "") }.joined(separator: ",")
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: Cells

    /// RFC 4180 quoting, and text a spreadsheet would run as a formula (a host
    /// or agent named "=HYPERLINK(…)") starts with an apostrophe instead.
    static func field(_ text: String) -> String {
        var value = text
        if let first = value.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first),
           Double(value) == nil {
            value = "'" + value
        }
        let needsQuotes = value.unicodeScalars.contains { ",\"\r\n".unicodeScalars.contains($0) }
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        return needsQuotes ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Up to six decimals, no grouping: 12.5, 0.000125.
    static func money(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)).grouping(.never).locale(posix))
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(posix))
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.locale = posix
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withInternetDateTime])
    }

    private static func status(_ status: ProviderUsage.Status) -> String {
        switch status {
        case .ok: "OK"
        case .signInNeeded: "Sign-in needed"
        case .notShared: "Not shared"
        case .error: "Couldn't be read"
        }
    }
}
