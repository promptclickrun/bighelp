import Foundation

/// How much of a provider's plan is left, from its `model.options` row
/// (`usage` windows and `limit`; Hermes `tui_gateway/contracts/
/// config_free_tier_control.py`). Read tolerantly: unknown or broken parts are
/// skipped, and a provider that reports nothing usable has no plan.
struct ModelProviderPlan: Equatable, Sendable {
    struct Window: Equatable, Sendable {
        let usedPercent: Double
        let resetsAt: Date?
    }

    /// One login of a provider with several (`usage.accounts`).
    struct Account: Equatable, Sendable {
        let isLimited: Bool
        let resetsAt: Date?
    }

    /// What the picker shows beside the provider.
    struct Summary: Equatable, Sendable {
        let text: String
        /// Nearly out, or out: drawn as a warning.
        let isLow: Bool
    }

    static let lowPercent = 10

    let windows: [Window]
    let accounts: [Account]
    /// The whole login is limited (`limit.scope: account`).
    let isLimited: Bool
    let limitResetsAt: Date?
    /// Models limited on their own (`limit.scope: models`), until when.
    let modelLimits: [String: Date]

    init(windows: [Window] = [], accounts: [Account] = [], isLimited: Bool = false, limitResetsAt: Date? = nil,
         modelLimits: [String: Date] = [:]) {
        self.windows = windows
        self.accounts = accounts
        self.isLimited = isLimited
        self.limitResetsAt = limitResetsAt
        self.modelLimits = modelLimits
    }

    init?(row: [String: BighelpJSONValue]) {
        let usage = row["usage"]?.object
        let limit = row["limit"]?.object
        windows = Self.windows(usage?["windows"])
        accounts = (usage?["accounts"]?.array ?? []).prefix(32).compactMap { value in
            guard let account = value.object else { return nil }
            return Account(isLimited: account["state"]?.string == "limited",
                           resetsAt: Self.date(account["resets_at"]))
        }
        isLimited = limit?["scope"]?.string == "account"
        limitResetsAt = isLimited ? Self.date(limit?["resets_at"]) : nil
        var modelLimits: [String: Date] = [:]
        if limit?["scope"]?.string == "models" {
            for (model, value) in (limit?["models"]?.object ?? [:]).prefix(256) {
                if let date = Self.date(value) { modelLimits[model] = date }
            }
        }
        self.modelLimits = modelLimits
        guard !windows.isEmpty || !accounts.isEmpty || isLimited || !modelLimits.isEmpty else { return nil }
    }

    /// "17% left · resets 3:00 PM" for the tightest window, "Limited until
    /// 3:00 PM" while the login is out, or how many of several logins are out.
    /// Nil when there's nothing true to say.
    func summary(now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> Summary? {
        func time(_ date: Date) -> String {
            BighelpResetTime.describe(date, now: now, locale: locale, timeZone: timeZone).short
        }
        // A limit whose time has passed has lifted; a stale catalog clears itself.
        if isLimited, limitResetsAt.map({ $0 > now }) ?? true {
            return Summary(text: limitResetsAt.map { "Limited until \(time($0))" } ?? "Limited", isLow: true)
        }
        if !accounts.isEmpty {
            // Each login's quota says nothing about the others: never one percentage for all.
            let limited = accounts.filter { $0.isLimited && ($0.resetsAt.map { $0 > now } ?? true) }
            guard !limited.isEmpty else { return nil }
            guard limited.count == accounts.count else {
                return Summary(text: "\(limited.count) of \(accounts.count) accounts limited", isLow: false)
            }
            let resets = limited.compactMap(\.resetsAt)
            let until = resets.count == limited.count ? resets.min() : nil
            return Summary(text: until.map { "Limited until \(time($0))" } ?? "Limited", isLow: true)
        }
        let live = windows.filter { $0.resetsAt.map { $0 > now } ?? true }
        guard let tightest = live.min(by: { $0.usedPercent > $1.usedPercent }) else { return nil }
        let left = Int(max(0, min(100, (100 - tightest.usedPercent).rounded())))
        let text = tightest.resetsAt.map { "\(left)% left · resets \(time($0))" } ?? "\(left)% left"
        return Summary(text: text, isLow: left <= Self.lowPercent)
    }

    /// "Limited until 3:00 PM" for a model limited on its own.
    func modelLimit(_ model: String, now: Date, locale: Locale = .current,
                    timeZone: TimeZone = .current) -> String? {
        guard let until = modelLimits[model], until > now else { return nil }
        return "Limited until \(BighelpResetTime.describe(until, now: now, locale: locale, timeZone: timeZone).short)"
    }

    private static func windows(_ value: BighelpJSONValue?) -> [Window] {
        (value?.array ?? []).prefix(16).compactMap { value in
            guard let window = value.object, let used = window["used_percent"]?.number, used.isFinite else {
                return nil
            }
            return Window(usedPercent: used, resetsAt: date(window["resets_at"]))
        }
    }

    /// ISO 8601 as Python writes it: an offset, and maybe microseconds (dropped).
    private static func date(_ value: BighelpJSONValue?) -> Date? {
        guard let text = value?.string, text.utf8.count <= 64 else { return nil }
        let whole = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return try? Date(whole, strategy: .iso8601)
    }
}

/// When a limit lifts, in the person's own clock: "3:00 PM" today or within a
/// few hours, with the day further out.
enum BighelpResetTime {
    struct Description: Equatable, Sendable {
        let time: String
        /// "Oct 20" when it isn't today and more than a few hours away.
        let day: String?

        /// "3:00 PM", "Oct 20, 6:13 AM".
        var short: String { day.map { "\($0), \(time)" } ?? time }
        /// "at 3:00 PM", "on Oct 20 at 6:13 AM".
        var phrase: String { day.map { "on \($0) at \(time)" } ?? "at \(time)" }
    }

    static func describe(_ date: Date, now: Date, locale: Locale = .current,
                         timeZone: TimeZone = .current) -> Description {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
        timeStyle.locale = locale
        timeStyle.timeZone = timeZone
        let time = date.formatted(timeStyle)
        guard !calendar.isDate(date, inSameDayAs: now), date.timeIntervalSince(now) > 6 * 60 * 60 else {
            return Description(time: time, day: nil)
        }
        var dayStyle = Date.FormatStyle().month(.abbreviated).day()
        dayStyle.locale = locale
        dayStyle.timeZone = timeZone
        return Description(time: time, day: date.formatted(dayStyle))
    }
}
