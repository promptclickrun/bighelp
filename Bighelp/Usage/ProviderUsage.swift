import SwiftUI

/// One provider's plan and limits, as the bighelp plugin reports them
/// (`POST /native/usage/list`, feature `native-provider-usage-v1`).
struct ProviderUsage: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case ok, signInNeeded, notShared, error

        /// Unknown statuses read as errors with their message.
        init(wire: String?) {
            switch wire {
            case "ok": self = .ok
            case "signInNeeded": self = .signInNeeded
            case "notShared": self = .notShared
            default: self = .error
            }
        }
    }

    /// A limit with a share used, such as "Session (5 hours)" or "Week".
    struct Window: Equatable, Sendable, Identifiable {
        let label: String
        /// 0–100.
        let usedPercent: Double
        let resetsAt: Date?
        /// Preformatted, like "1.26M / 2.00M tokens".
        let detail: String?
        var id: String { label }
        var leftPercent: Double { max(0, 100 - usedPercent) }
    }

    /// A preformatted label and value, like "Balance · $25.00".
    struct Fact: Equatable, Sendable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    let id: String
    let name: String
    let status: Status
    let message: String?
    let plan: String?
    let detectedVia: [String]
    let activeInHermes: Bool
    let windows: [Window]
    let facts: [Fact]
    let manageURL: URL?
    let approximate: Bool
}

struct ProviderUsageReport: Equatable, Sendable {
    let agentID: String
    let fetchedAt: Date?
    let cached: Bool
    let providers: [ProviderUsage]
}

extension ProviderUsageReport {
    /// Reads the plugin's response, skipping any provider it can't make sense of
    /// rather than failing the whole list.
    init(json object: [String: BighelpJSONValue]) throws {
        guard let rows = object["providers"]?.array, rows.count <= 64 else {
            throw WorkspaceClientError.invalidResponse
        }
        agentID = object["agentId"]?.string ?? ""
        fetchedAt = object["fetchedAt"]?.string.flatMap(ProviderUsage.date)
        cached = object["cached"]?.boolean ?? false
        providers = rows.compactMap { $0.object.flatMap(ProviderUsage.init(json:)) }
    }
}

extension ProviderUsage {
    init?(json row: [String: BighelpJSONValue]) {
        guard let id = Self.text(row["id"], limit: 128), let name = Self.text(row["name"], limit: 128) else { return nil }
        self.id = id
        self.name = name
        status = Status(wire: row["status"]?.string)
        message = Self.text(row["message"], limit: 600)
        plan = Self.text(row["plan"], limit: 60)
        detectedVia = (row["detectedVia"]?.array ?? []).prefix(4).compactMap { Self.text($0, limit: 20) }
        activeInHermes = row["activeInHermes"]?.boolean ?? false
        windows = (row["windows"]?.array ?? []).prefix(12).compactMap { value -> Window? in
            guard let window = value.object, let label = Self.text(window["label"], limit: 80) else { return nil }
            let used = window["usedPercent"]?.number ?? 0
            return Window(label: label, usedPercent: used.isFinite ? min(max(used, 0), 100) : 0,
                          resetsAt: window["resetsAt"]?.string.flatMap(Self.date),
                          detail: Self.text(window["detail"], limit: 120))
        }
        facts = (row["facts"]?.array ?? []).prefix(12).compactMap { value -> Fact? in
            guard let fact = value.object, let label = Self.text(fact["label"], limit: 80),
                  let value = Self.text(fact["value"], limit: 120) else { return nil }
            return Fact(label: label, value: value)
        }
        manageURL = Self.text(row["manageUrl"], limit: 2_048).flatMap(URL.init(string:)).flatMap { url in
            url.scheme?.lowercased() == "https" ? url : nil
        }
        approximate = row["approximate"]?.boolean ?? false
    }

    private static func text(_ value: BighelpJSONValue?, limit: Int) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(limit))
    }

    static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

enum ProviderUsagePresentation {
    /// In the order the person dragged them into (Usage › Limits › Choose), then the rest: the provider
    /// the agent chats with first, then the plugin's order.
    static func visible(_ providers: [ProviderUsage], hidden: Set<String>, order: [String]) -> [ProviderUsage] {
        let shown = providers.filter { !ProviderUsagePreferences.isHidden($0.id, in: hidden) }
        return ProviderUsagePreferences.sorted(shown.filter(\.activeInHermes) + shown.filter { !$0.activeInHermes },
                                               order: order)
    }

    /// "Resets in 3 h 12 min", "Resets in 2 days".
    static func resetText(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return "Resets soon" }
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if days >= 2 { return "Resets in \(days) days" }
        if hours >= 1 { return minutes % 60 == 0 ? "Resets in \(hours) h" : "Resets in \(hours) h \(minutes % 60) min" }
        return "Resets in \(max(1, minutes)) min"
    }

    /// "Updated just now", "Updated 3 min ago".
    static func updatedText(_ date: Date?, now: Date = .now) -> String? {
        guard let date else { return nil }
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes) min ago" }
        return "Updated \(minutes / 60) h ago"
    }

    static func percentText(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Brand-colored bars; they turn to warning and danger as a limit runs out.
    static func barColor(for provider: ProviderUsage, window: ProviderUsage.Window, theme: BighelpTheme) -> Color {
        if window.usedPercent >= 90 { return theme.danger }
        if window.usedPercent >= 75 { return theme.warning }
        return accent(for: provider.id, name: provider.name, theme: theme)
    }

    static func accent(for id: String, name: String, theme: BighelpTheme) -> Color {
        switch AIProviderBrandRegistry.resolve(id: id, name: name) {
        case .anthropic, .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .openAI, .codex: Color(red: 0.25, green: 0.47, blue: 0.95)
        case .githubCopilot: Color(red: 0.54, green: 0.34, blue: 0.90)
        case .openRouter: Color(red: 0.39, green: 0.40, blue: 0.95)
        case .deepSeek: Color(red: 0.30, green: 0.42, blue: 1.0)
        case .google: theme.primaryText
        default: theme.action
        }
    }

    /// The brand the logo comes from; plugin ids like `codex-hermes` or `hermes-xai` map to it.
    static func logoProviderID(_ id: String) -> String {
        let base = id.hasPrefix("hermes-") ? String(id.dropFirst(7)) : id
        return base.hasSuffix("-hermes") ? String(base.dropLast(7)) : base
    }
}
