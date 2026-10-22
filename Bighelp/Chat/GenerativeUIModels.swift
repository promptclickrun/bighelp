import Foundation
import CryptoKit

enum GenerativeUIComponent: String, Codable, CaseIterable, Sendable {
    case summary
    case metrics
    case list
    case timeline
    case weatherForecast = "weather_forecast"
    case sportsGame = "sports_game"
    case stockQuote = "stock_quote"
    case chart
    case dashboard
    case form
    case checklist
    case selection
    case automation
}

enum GenerativeUICardError: Error, Equatable {
    case invalidValue
}

struct GenerativeUICard: Codable, Equatable, Sendable, Identifiable {
    private static let forbiddenKeys: Set<String> = [
        "url", "uri", "href", "style", "styles", "css", "html", "javascript",
        "js", "route", "routes", "module", "native", "command", "shell", "rpc",
        "method", "endpoint", "headers", "token", "secret", "password", "script",
        "eval", "action", "actions",
    ]

    let document: [String: BighelpJSONValue]

    var id: String {
        document["card_id"]?.string
            ?? document["content_hash"]?.string
            ?? "legacy-\(component.rawValue)-\(Self.stableIdentifier(document))"
    }

    var version: Int { document["version"]?.integer ?? 0 }

    var component: GenerativeUIComponent {
        GenerativeUIComponent(rawValue: document["component"]?.string ?? "") ?? .summary
    }

    var title: String { document["title"]?.string ?? component.defaultTitle }
    var subtitle: String? { document["subtitle"]?.string }
    var data: [String: BighelpJSONValue] { document["data"]?.object ?? document }
    var provenance: [String: BighelpJSONValue]? { document["provenance"]?.object }
    var action: [String: BighelpJSONValue]? { document["action"]?.object }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode([String: BighelpJSONValue].self)
        try Self.validate(value)
        document = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(document)
    }

    static func decode(_ value: [String: Any]) throws -> GenerativeUICard {
        guard JSONSerialization.isValidJSONObject(value) else { throw GenerativeUICardError.invalidValue }
        return try JSONDecoder().decode(
            GenerativeUICard.self,
            from: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        )
    }

    private static func stableIdentifier(_ value: [String: BighelpJSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func validate(_ value: [String: BighelpJSONValue]) throws {
        guard
            value["schema"]?.string == "loopdy.generative_ui",
            let version = value["version"]?.integer,
            let rawComponent = value["component"]?.string,
            let component = GenerativeUIComponent(rawValue: rawComponent),
            (version == 1 && [.summary, .metrics, .list, .timeline].contains(component))
                || (version == 2 && ![.summary, .metrics, .list, .timeline].contains(component))
        else { throw GenerativeUICardError.invalidValue }
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= (version == 1 ? 16_384 : 32_768) else {
            throw GenerativeUICardError.invalidValue
        }
        try validateJSON(
            .object(value),
            depth: 0,
            allowsRootAction: version == 2 && component == .form
        )

        if version == 1 {
            let componentField = switch component {
            case .summary: "body"
            case .metrics: "metrics"
            case .list: "items"
            case .timeline: "steps"
            default: ""
            }
            let allowed = Set(["schema", "version", "component", "title", componentField])
            guard Set(value.keys).isSubset(of: allowed) else { throw GenerativeUICardError.invalidValue }
            if let title = value["title"]?.string { try bounded(title, maximum: 500) }
            guard value[componentField] != nil else { throw GenerativeUICardError.invalidValue }
            return
        }

        let allowed = Set([
            "schema", "version", "component", "title", "subtitle", "data", "provenance",
            "content_hash", "created_at", "origin", "card_id", "action",
        ])
        let required = Set([
            "schema", "version", "component", "title", "data", "content_hash",
            "created_at", "origin", "card_id",
        ])
        guard
            required.isSubset(of: Set(value.keys)),
            Set(value.keys).isSubset(of: allowed),
            let title = value["title"]?.string,
            let data = value["data"]?.object,
            let hash = value["content_hash"]?.string,
            hash.count == 64,
            hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
            let cardID = value["card_id"]?.string,
            cardID.count == 32,
            cardID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
            value["origin"]?.string == "live",
            let createdAt = value["created_at"]?.string,
            ISO8601DateFormatter().date(from: createdAt) != nil
        else { throw GenerativeUICardError.invalidValue }
        try bounded(title, maximum: 120)
        if let subtitle = value["subtitle"]?.string { try bounded(subtitle, maximum: 240) }
        if component == .form {
            let defaults = try validateForm(data)
            let owner = try validateFormAction(value["action"], cardID: cardID)
            guard BighelpLinkGenerativeUIFormSubmission.accepts(
                requestID: cardID,
                sessionID: owner.sessionID,
                profile: owner.profile,
                values: defaults
            ) else { throw GenerativeUICardError.invalidValue }
            guard value["provenance"] == nil else { throw GenerativeUICardError.invalidValue }
        } else {
            try validateV2Data(data, component: component)
            guard value["provenance"]?.object != nil, value["action"] == nil else {
                throw GenerativeUICardError.invalidValue
            }
        }
    }

    private static func validateJSON(
        _ value: BighelpJSONValue,
        depth: Int,
        allowsRootAction: Bool
    ) throws {
        guard depth <= 8 else { throw GenerativeUICardError.invalidValue }
        switch value {
        case .string(let value):
            guard value.count <= 2_000, !value.contains("\0") else { throw GenerativeUICardError.invalidValue }
        case .number(let value):
            guard value.isFinite, abs(value) <= 1_000_000_000_000 else { throw GenerativeUICardError.invalidValue }
        case .integer(let value):
            guard abs(Double(value)) <= 1_000_000_000_000 else { throw GenerativeUICardError.invalidValue }
        case .object(let value):
            for (key, child) in value {
                let normalizedKey = key.lowercased()
                guard
                    !forbiddenKeys.contains(normalizedKey)
                        || (depth == 0 && allowsRootAction && normalizedKey == "action")
                else { throw GenerativeUICardError.invalidValue }
                try validateJSON(child, depth: depth + 1, allowsRootAction: false)
            }
        case .array(let value):
            guard value.count <= 240 else { throw GenerativeUICardError.invalidValue }
            for child in value {
                try validateJSON(child, depth: depth + 1, allowsRootAction: false)
            }
        case .boolean, .null:
            break
        }
    }

    private static func validateV2Data(
        _ value: [String: BighelpJSONValue],
        component: GenerativeUIComponent
    ) throws {
        switch component {
        case .weatherForecast:
            guard value["location"]?.string != nil,
                  value["current"]?.object != nil,
                  let periods = value["periods"]?.array,
                  (1...14).contains(periods.count)
            else { throw GenerativeUICardError.invalidValue }
        case .sportsGame:
            guard value["status"]?.string != nil,
                  value["teams"]?.array?.count == 2
            else { throw GenerativeUICardError.invalidValue }
        case .stockQuote:
            guard value["symbol"]?.string != nil,
                  value["company_name"]?.string != nil,
                  value["price"]?.number != nil
            else { throw GenerativeUICardError.invalidValue }
        case .chart:
            try validateChart(value, maximumSeries: 6)
        case .dashboard:
            guard let metrics = value["metrics"]?.array, (1...12).contains(metrics.count) else {
                throw GenerativeUICardError.invalidValue
            }
            for chart in value["charts"]?.array ?? [] {
                guard let object = chart.object else { throw GenerativeUICardError.invalidValue }
                try validateChart(object, maximumSeries: 3)
            }
        case .form:
            _ = try validateForm(value)
        case .checklist:
            try validateChecklist(value)
        case .selection:
            try validateSelection(value)
        case .automation:
            try validateAutomation(value)
        default:
            throw GenerativeUICardError.invalidValue
        }
    }

    private static func validateChecklist(_ value: [String: BighelpJSONValue]) throws {
        guard Set(value.keys).isSubset(of: ["description", "items"]),
              let items = value["items"]?.array,
              (1...40).contains(items.count) else { throw GenerativeUICardError.invalidValue }
        if let description = value["description"]?.string { try bounded(description, maximum: 300) }
        var ids = Set<String>()
        for raw in items {
            guard let item = raw.object,
                  Set(item.keys).isSubset(of: ["id", "label", "detail", "completed"]),
                  let id = item["id"]?.string,
                  let label = item["label"]?.string,
                  item["completed"]?.boolean != nil,
                  ids.insert(id).inserted else { throw GenerativeUICardError.invalidValue }
            try boundedIdentifier(id)
            try bounded(label, maximum: 120)
            if let detail = item["detail"]?.string { try bounded(detail, maximum: 240) }
        }
    }

    private static func validateSelection(_ value: [String: BighelpJSONValue]) throws {
        guard Set(value.keys).isSubset(of: ["description", "mode", "options", "max_selected", "submit_label"]),
              let mode = value["mode"]?.string,
              ["single", "multiple"].contains(mode),
              let options = value["options"]?.array,
              (1...24).contains(options.count),
              let submitLabel = value["submit_label"]?.string else {
            throw GenerativeUICardError.invalidValue
        }
        try bounded(submitLabel, maximum: 40)
        if let description = value["description"]?.string { try bounded(description, maximum: 300) }
        if mode == "single" {
            guard value["max_selected"] == nil else { throw GenerativeUICardError.invalidValue }
        } else {
            let limit = value["max_selected"]?.integer ?? options.count
            guard (1...min(10, options.count)).contains(limit) else { throw GenerativeUICardError.invalidValue }
        }
        var ids = Set<String>()
        for raw in options {
            guard let option = raw.object,
                  Set(option.keys).isSubset(of: ["id", "label", "detail", "enabled", "stage_text"]),
                  let id = option["id"]?.string,
                  let label = option["label"]?.string,
                  option["enabled"]?.boolean != nil,
                  let stageText = option["stage_text"]?.string,
                  ids.insert(id).inserted else { throw GenerativeUICardError.invalidValue }
            try boundedIdentifier(id)
            try bounded(label, maximum: 120)
            try bounded(stageText, maximum: 500)
            if let detail = option["detail"]?.string { try bounded(detail, maximum: 240) }
        }
    }

    private static func validateAutomation(_ value: [String: BighelpJSONValue]) throws {
        let allowed = Set([
            "description", "job_id", "profile", "state", "schedule", "delivery",
            "prompt", "next_runs", "operations", "stage_text",
        ])
        guard Set(value.keys).isSubset(of: allowed),
              let jobID = value["job_id"]?.string,
              let profile = value["profile"]?.string,
              let state = value["state"]?.string,
              ["active", "paused", "completed", "failed"].contains(state),
              let schedule = value["schedule"]?.string,
              let delivery = value["delivery"]?.string,
              let prompt = value["prompt"]?.string,
              let rawOperations = value["operations"]?.array,
              rawOperations.count <= 3 else { throw GenerativeUICardError.invalidValue }
        try boundedCoordinate(jobID, maximum: 120)
        try boundedCoordinate(profile, maximum: 120)
        try bounded(schedule, maximum: 240)
        try bounded(delivery, maximum: 160)
        try bounded(prompt, maximum: 1_600)
        if let description = value["description"]?.string { try bounded(description, maximum: 300) }
        if let stageText = value["stage_text"]?.string { try bounded(stageText, maximum: 1_600) }
        let operations = rawOperations.compactMap(\.string)
        guard operations.count == rawOperations.count,
              Set(operations).count == operations.count,
              Set(operations).isSubset(of: ["pause", "resume", "run"]) else {
            throw GenerativeUICardError.invalidValue
        }
        guard !operations.contains("pause") || state == "active",
              !operations.contains("resume") || state == "paused" else {
            throw GenerativeUICardError.invalidValue
        }
        let nextRuns = value["next_runs"]?.array ?? []
        guard nextRuns.count <= 7,
              nextRuns.allSatisfy({ raw in
                  guard let text = raw.string else { return false }
                  return ISO8601DateFormatter().date(from: text) != nil
              }) else { throw GenerativeUICardError.invalidValue }
    }

    private static func boundedIdentifier(_ value: String) throws {
        guard let first = value.first, first.isLowercase, first.isLetter,
              value.count <= 40,
              value.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw GenerativeUICardError.invalidValue
        }
    }

    private static func validateForm(
        _ value: [String: BighelpJSONValue]
    ) throws -> [String: BighelpJSONValue] {
        let allowed = Set(["description", "submit_label", "fields"])
        guard
            Set(value.keys).isSubset(of: allowed),
            let submitLabel = value["submit_label"]?.string,
            let fields = value["fields"]?.array,
            (1...12).contains(fields.count)
        else { throw GenerativeUICardError.invalidValue }
        try bounded(submitLabel, maximum: 80)
        if let description = value["description"]?.string {
            try bounded(description, maximum: 1_000)
        }
        var fieldIDs = Set<String>()
        var defaults: [String: BighelpJSONValue] = [:]
        for field in fields {
            let validated = try validateFormField(field)
            let id = validated.id
            guard fieldIDs.insert(id).inserted else { throw GenerativeUICardError.invalidValue }
            if let value = validated.defaultValue { defaults[id] = value }
        }
        return defaults
    }

    private static func validateFormField(
        _ value: BighelpJSONValue
    ) throws -> (id: String, defaultValue: BighelpJSONValue?) {
        guard
            let field = value.object,
            Set(["id", "kind", "label", "required"]).isSubset(of: Set(field.keys)),
            Set(field.keys).isSubset(of: Set([
                "id", "kind", "label", "required", "help_text", "options",
                "max_selected", "default",
            ]).union(GenerativeUIFormFieldLimits.keys)),
            let id = field["id"]?.string,
            let kind = field["kind"]?.string,
            let label = field["label"]?.string,
            field["required"]?.boolean != nil,
            [
                "text", "textarea", "select", "multi_select", "toggle",
                "integer", "decimal", "date",
            ].contains(kind)
        else { throw GenerativeUICardError.invalidValue }
        guard BighelpLinkGenerativeUIFormSubmission.acceptsFieldID(id) else {
            throw GenerativeUICardError.invalidValue
        }
        try bounded(label, maximum: 120)
        if let helpText = field["help_text"]?.string { try bounded(helpText, maximum: 240) }

        let options = try validateFormOptions(field["options"], kind: kind)
        let maximumSelected = field["max_selected"]?.integer
        if kind == "multi_select" {
            let selectionLimit = maximumSelected ?? options.count
            guard (1...min(options.count, 10)).contains(selectionLimit) else {
                throw GenerativeUICardError.invalidValue
            }
        } else if maximumSelected != nil {
            throw GenerativeUICardError.invalidValue
        }
        try validateFormDefault(
            field["default"],
            kind: kind,
            optionIDs: Set(options),
            maximumSelected: maximumSelected
        )
        let limits = try GenerativeUIFormFieldLimits(field, kind: kind)
        if let value = field["default"] {
            let admitted = switch kind {
            case "text", "textarea": value.string.map { limits.admits(text: $0) } ?? false
            case "integer", "decimal": value.number.map { limits.admits(number: $0) } ?? false
            case "date": value.string.map { limits.admits(date: $0) } ?? false
            default: true
            }
            guard admitted else { throw GenerativeUICardError.invalidValue }
        }
        let defaultValue = switch kind {
        case "toggle": field["default"] ?? .boolean(false)
        case "multi_select": field["default"] ?? .array([])
        case "date": field["default"] ?? .string("2000-01-01")
        default: field["default"]
        }
        return (id, defaultValue)
    }

    private static func validateFormOptions(
        _ value: BighelpJSONValue?,
        kind: String
    ) throws -> [String] {
        guard kind == "select" || kind == "multi_select" else {
            guard value == nil else { throw GenerativeUICardError.invalidValue }
            return []
        }
        guard let values = value?.array, (1...40).contains(values.count) else {
            throw GenerativeUICardError.invalidValue
        }
        var ids: [String] = []
        for value in values {
            guard
                let option = value.object,
                Set(option.keys) == Set(["id", "label"]),
                let id = option["id"]?.string,
                let label = option["label"]?.string
            else { throw GenerativeUICardError.invalidValue }
            try boundedCoordinate(id, maximum: 80)
            try bounded(label, maximum: 120)
            ids.append(id)
        }
        guard Set(ids).count == ids.count else { throw GenerativeUICardError.invalidValue }
        return ids
    }

    private static func validateFormDefault(
        _ value: BighelpJSONValue?,
        kind: String,
        optionIDs: Set<String>,
        maximumSelected: Int?
    ) throws {
        guard let value else { return }
        switch kind {
        case "text", "textarea":
            guard let value = value.string else { throw GenerativeUICardError.invalidValue }
            guard value.count <= 2_000 else { throw GenerativeUICardError.invalidValue }
        case "date":
            guard
                let value = value.string,
                GenerativeUIFormDate.isCanonical(value)
            else { throw GenerativeUICardError.invalidValue }
        case "select":
            guard let value = value.string, optionIDs.contains(value) else {
                throw GenerativeUICardError.invalidValue
            }
        case "multi_select":
            guard let values = value.array else { throw GenerativeUICardError.invalidValue }
            let selections = values.compactMap(\.string)
            guard
                selections.count == values.count,
                Set(selections).count == selections.count,
                Set(selections).isSubset(of: optionIDs),
                selections.count <= (maximumSelected ?? optionIDs.count)
            else { throw GenerativeUICardError.invalidValue }
        case "toggle":
            guard value.boolean != nil else { throw GenerativeUICardError.invalidValue }
        case "integer":
            guard value.integer != nil else { throw GenerativeUICardError.invalidValue }
        case "decimal":
            guard value.number != nil else { throw GenerativeUICardError.invalidValue }
        default:
            throw GenerativeUICardError.invalidValue
        }
    }

    private static func validateFormAction(
        _ value: BighelpJSONValue?,
        cardID: String
    ) throws -> (profile: String, sessionID: String) {
        guard
            let action = value?.object,
            Set(action.keys) == Set(["kind", "request_id", "owner", "expires_at"]),
            action["kind"]?.string == "submit_form",
            action["request_id"]?.string == cardID,
            let owner = action["owner"]?.object,
            Set(owner.keys) == Set(["profile", "session_id"]),
            let profile = owner["profile"]?.string,
            let sessionID = owner["session_id"]?.string,
            let expiresAt = action["expires_at"]?.string,
            ISO8601DateFormatter().date(from: expiresAt) != nil
        else { throw GenerativeUICardError.invalidValue }
        return (profile, sessionID)
    }

    private static func boundedCoordinate(_ value: String, maximum: Int) throws {
        guard
            !value.isEmpty,
            value.utf8.count <= maximum,
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw GenerativeUICardError.invalidValue }
    }

    private static func validateChart(
        _ value: [String: BighelpJSONValue],
        maximumSeries: Int
    ) throws {
        guard
            ["line", "bar", "area"].contains(value["chart_type"]?.string ?? ""),
            let series = value["series"]?.array,
            (1...maximumSeries).contains(series.count)
        else { throw GenerativeUICardError.invalidValue }
        for item in series {
            guard let points = item.object?["points"]?.array, !points.isEmpty else {
                throw GenerativeUICardError.invalidValue
            }
        }
    }

    private static func bounded(_ value: String, maximum: Int) throws {
        guard !value.isEmpty, value.count <= maximum, !value.contains("\0") else {
            throw GenerativeUICardError.invalidValue
        }
    }
}

/// A form field's limits, as the bighelp plugin's form tool offers them: a length
/// on text, a range and step on numbers, a range on dates. The plugin refuses
/// limits that contradict each other or the field's default; so does this.
struct GenerativeUIFormFieldLimits: Equatable, Sendable {
    static let keys: Set<String> = ["min_length", "max_length", "min", "max", "step"]

    var minimumLength: Int?
    var maximumLength: Int?
    var minimum: Double?
    var maximum: Double?
    /// Accepted so the card shows; answers aren't held to it.
    var step: Double?
    var earliestDate: String?
    var latestDate: String?

    /// Counted in Unicode scalars, as the plugin counts, so both agree on a length.
    func admits(text: String) -> Bool {
        let length = text.unicodeScalars.count
        return length >= (minimumLength ?? 0) && length <= (maximumLength ?? .max)
    }

    func admits(number: Double) -> Bool {
        number >= (minimum ?? -.infinity) && number <= (maximum ?? .infinity)
    }

    /// Form dates are `yyyy-MM-dd`, so they compare as text.
    func admits(date: String) -> Bool {
        date >= (earliestDate ?? date) && date <= (latestDate ?? date)
    }

    func clamped(date: String) -> String {
        if let earliestDate, date < earliestDate { return earliestDate }
        if let latestDate, date > latestDate { return latestDate }
        return date
    }

    /// Shown under the field, so a refused answer isn't a puzzle.
    var hint: String? {
        let shortest = (minimumLength ?? 0) > 0 ? minimumLength : nil
        switch (shortest, maximumLength) {
        case let (low?, high?): return "\(low) to \(high) characters"
        case let (low?, nil): return "At least \(low) \(low == 1 ? "character" : "characters")"
        case let (nil, high?): return "Up to \(high) \(high == 1 ? "character" : "characters")"
        case (nil, nil): break
        }
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...6))
        switch (minimum, maximum) {
        case let (low?, high?): return "Between \(low.formatted(format)) and \(high.formatted(format))"
        case let (low?, nil): return "\(low.formatted(format)) or more"
        case let (nil, high?): return "\(high.formatted(format)) or less"
        case (nil, nil): return nil
        }
    }
}

extension GenerativeUIFormFieldLimits {
    init(_ field: [String: BighelpJSONValue], kind: String) throws {
        let offered: Set<String> = switch kind {
        case "text", "textarea": ["min_length", "max_length"]
        case "integer", "decimal": ["min", "max", "step"]
        case "date": ["min", "max"]
        default: []
        }
        guard Self.keys.intersection(field.keys).isSubset(of: offered) else {
            throw GenerativeUICardError.invalidValue
        }
        switch kind {
        case "text", "textarea":
            let longest = kind == "text" ? 500 : 2_000
            minimumLength = try Self.integer(field["min_length"], in: 0...longest)
            maximumLength = try Self.integer(field["max_length"], in: 1...longest)
            if let minimumLength, let maximumLength, minimumLength > maximumLength {
                throw GenerativeUICardError.invalidValue
            }
        case "integer":
            let bound = 1_000_000_000_000
            minimum = try Self.integer(field["min"], in: -bound...bound).map(Double.init)
            maximum = try Self.integer(field["max"], in: -bound...bound).map(Double.init)
            step = try Self.integer(field["step"], in: 1...1_000_000_000).map(Double.init)
        case "decimal":
            minimum = try Self.number(field["min"], in: -1e12...1e12)
            maximum = try Self.number(field["max"], in: -1e12...1e12)
            step = try Self.number(field["step"], in: 0.000001...1e9)
        case "date":
            earliestDate = try Self.date(field["min"])
            latestDate = try Self.date(field["max"])
            if let earliestDate, let latestDate, earliestDate > latestDate {
                throw GenerativeUICardError.invalidValue
            }
        default:
            break
        }
        if let minimum, let maximum, minimum > maximum {
            throw GenerativeUICardError.invalidValue
        }
    }

    private static func integer(_ value: BighelpJSONValue?, in range: ClosedRange<Int>) throws -> Int? {
        guard let value else { return nil }
        guard let integer = value.integer, range.contains(integer) else { throw GenerativeUICardError.invalidValue }
        return integer
    }

    private static func number(_ value: BighelpJSONValue?, in range: ClosedRange<Double>) throws -> Double? {
        guard let value else { return nil }
        guard let number = value.number, range.contains(number) else { throw GenerativeUICardError.invalidValue }
        return number
    }

    private static func date(_ value: BighelpJSONValue?) throws -> String? {
        guard let value else { return nil }
        guard let date = value.string, GenerativeUIFormDate.isCanonical(date) else {
            throw GenerativeUICardError.invalidValue
        }
        return date
    }
}

/// A form date is a day, written `yyyy-MM-dd` with Gregorian years and ASCII digits.
/// The date picker shows days where the person is, so in the sheet a day stands for its
/// start in their time zone: the picker, its limits, the starting "today" and the
/// written answer all use that one time zone.
struct GenerativeUIFormDate: Sendable {
    let timeZone: TimeZone
    private let calendar: Calendar

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    private static let spelling = GenerativeUIFormDate(timeZone: .gmt)

    /// Only the canonical spelling, so limits compare as text in the days' order.
    static func isCanonical(_ text: String) -> Bool {
        spelling.date(from: text) != nil
    }

    /// Reads only what `text(from:)` writes: "2026-1-001" (January 1 to a lenient
    /// reader) and "2026-02-30" (March 2) aren't days.
    func date(from text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard
            text.utf8.count == 10, parts.count == 3,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
            self.text(from: date) == text
        else { return nil }
        return date
    }

    func text(from date: Date) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// Where a date field without a default starts: today, moved inside its limits.
    func today(within limits: GenerativeUIFormFieldLimits, now: Date = .now) -> String {
        limits.clamped(date: text(from: now))
    }
}

private extension GenerativeUIComponent {
    var defaultTitle: String {
        switch self {
        case .summary: "Summary"
        case .metrics: "Metrics"
        case .list: "List"
        case .timeline: "Timeline"
        case .weatherForecast: "Weather forecast"
        case .sportsGame: "Game"
        case .stockQuote: "Market quote"
        case .chart: "Chart"
        case .dashboard: "Dashboard"
        case .form: "Details needed"
        case .checklist: "Checklist"
        case .selection: "Choose an option"
        case .automation: "Automation"
        }
    }
}
