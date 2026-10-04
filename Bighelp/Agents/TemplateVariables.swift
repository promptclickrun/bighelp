import Foundation

/// A fill-in field of an agent template: what the form asks for before `{{key}}` in the template's
/// text gets the value. The rules are in services/catalog/docs/TEMPLATE_VARIABLES.md.
struct TemplateVariable: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case text
        case longText = "long_text"
        case choice
        case number
    }

    let key: String
    var label: String
    var kind: Kind
    var isRequired = true
    var defaultValue: String?
    /// Shown greyed in the empty field; never used as a value.
    var example: String?
    var help: String?
    var maxLength: Int?
    var options: [String] = []
    var allowsOther = false
    var minimum: Double?
    var maximum: Double?
    /// What an optional field becomes when it's left empty.
    var whenEmpty: String?

    var id: String { key }

    /// The most characters a value can have.
    var lengthLimit: Int {
        switch kind {
        case .text: min(maxLength ?? 80, 200)
        case .longText: min(maxLength ?? 600, 4_000)
        case .choice: 60
        case .number: 40
        }
    }
}

/// `{{key}}` placeholders in an agent template: find them, check the values, and fill them in.
enum TemplateVariables {
    static let agentName = "agent_name"
    static let userName = "user_name"
    /// Filled by the app itself, so templates use them without declaring them.
    static let reserved: Set<String> = [agentName, userName]
    static let maximumCount = 12
    static let maximumKeyLength = 40
    /// Names are short everywhere they reach an agent.
    static let nameLength = UserIdentity.maximumNameLength

    /// Lowercase letters, digits and underscores, starting with a letter, at most 40 characters.
    static func isKey(_ key: some StringProtocol) -> Bool {
        guard let first = key.unicodeScalars.first, key.unicodeScalars.count <= maximumKeyLength,
              ("a"..."z").contains(first) else { return false }
        return key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// The keys a text uses, in the order they first appear.
    static func keys(in text: String) -> [String] {
        var seen = Set<String>()
        return placeholders(in: text).map(\.key).filter { seen.insert($0).inserted }
    }

    /// Replaces every placeholder in one pass, so a value is never read as a placeholder. Keys
    /// without a value stay as they are. Values lose any `{{` and `}}`.
    static func fill(_ text: String, values: [String: String]) -> String {
        var result = ""
        var rest = text.startIndex
        for placeholder in placeholders(in: text) {
            guard let value = values[placeholder.key] else { continue }
            result += text[rest..<placeholder.range.lowerBound]
            result += removingBraces(value)
            rest = placeholder.range.upperBound
        }
        result += text[rest...]
        return result
    }

    /// A value as it goes into the text: trimmed, one line unless it's long text, without braces.
    static func clean(_ value: String, kind: TemplateVariable.Kind) -> String {
        var value = value
        if kind != .longText {
            value = value.components(separatedBy: .newlines).joined(separator: " ")
        } else {
            value = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        return removingBraces(value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "operating_context" → "Operating context", for keys a template didn't declare.
    static func label(forKey key: String) -> String {
        let words = key.split(separator: "_").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// The form's fields: the agent's name, the person's name when there's no saved one, the
    /// declared fields the text uses (in their order), then any key it uses without declaring.
    static func fields(texts: [String], declared: [TemplateVariable], asksForUserName: Bool) -> [TemplateVariable] {
        var used: [String] = []
        for text in texts {
            for key in keys(in: text) where !used.contains(key) { used.append(key) }
        }
        var fields = [TemplateVariable(key: agentName, label: "Name", kind: .text, example: "Give your agent a name",
                                       maxLength: nameLength)]
        if asksForUserName, used.contains(userName) {
            fields.append(TemplateVariable(key: userName, label: "Your name", kind: .text, example: "Your first name",
                                           help: "So your agent knows what to call you.", maxLength: nameLength))
        }
        var taken = reserved
        for variable in declared where used.contains(variable.key) && taken.insert(variable.key).inserted {
            fields.append(variable)
        }
        for key in used where taken.insert(key).inserted {
            fields.append(TemplateVariable(key: key, label: label(forKey: key), kind: .text))
        }
        return fields
    }

    /// Text shown on a template's card: each placeholder becomes "[Its label]".
    static func preview(_ text: String, variables: [TemplateVariable]) -> String {
        var labels = [agentName: "Name", userName: "Your name"]
        for variable in variables { labels[variable.key] = variable.label }
        let used = keys(in: text)
        guard !used.isEmpty else { return text }
        return fill(text, values: Dictionary(uniqueKeysWithValues: used.map { ($0, "[\(labels[$0] ?? label(forKey: $0))]") }))
    }

    // MARK: Reading the catalog

    /// A catalog template's `variables`, leniently: a field that doesn't read is dropped (the form
    /// then asks for its key as plain text), and so are reserved and repeated keys.
    static func parse(_ value: Any?) -> [TemplateVariable] {
        guard let rows = value as? [Any] else { return [] }
        var seen = reserved
        var result: [TemplateVariable] = []
        for row in rows.prefix(maximumCount * 2) {
            guard result.count < maximumCount, let row = row as? [String: Any],
                  let variable = variable(row), seen.insert(variable.key).inserted else { continue }
            result.append(variable)
        }
        return result
    }

    private static func variable(_ row: [String: Any]) -> TemplateVariable? {
        func line(_ key: String, max: Int) -> String? {
            guard let value = (row[key] as? String).map({ clean($0, kind: .text) }), !value.isEmpty,
                  value.count <= max else { return nil }
            return value
        }
        guard let key = row["key"] as? String, isKey(key),
              let label = line("label", max: 40),
              let kind = (row["type"] as? String).flatMap(TemplateVariable.Kind.init(rawValue:)) else { return nil }
        var variable = TemplateVariable(key: key, label: label, kind: kind)
        variable.isRequired = (row["required"] as? Bool) ?? true
        variable.example = line("example", max: 120)
        variable.help = line("help", max: 160)
        if !variable.isRequired, let whenEmpty = row["whenEmpty"] as? String {
            let cleaned = clean(whenEmpty, kind: .longText)
            if !cleaned.isEmpty, cleaned.count <= 200 { variable.whenEmpty = cleaned }
        }
        let rawDefault: String? = switch row["default"] {
        case let text as String: text
        case let number as NSNumber where !isBool(number) && kind == .number: number.stringValue
        default: nil
        }
        switch kind {
        case .text, .longText:
            let ceiling = kind == .text ? 200 : 4_000
            if let maxLength = row["maxLength"] as? Int { variable.maxLength = max(1, min(maxLength, ceiling)) }
        case .choice:
            var options: [String] = []
            for option in (row["options"] as? [Any] ?? []).prefix(12) {
                guard let text = (option as? String).map({ clean($0, kind: .text) }), !text.isEmpty,
                      text.count <= 60, !options.contains(text) else { continue }
                options.append(text)
            }
            guard options.count >= 2 else { return nil }
            variable.options = options
            variable.allowsOther = (row["allowOther"] as? Bool) ?? false
        case .number:
            variable.minimum = number(row["min"])
            variable.maximum = number(row["max"])
            if let low = variable.minimum, let high = variable.maximum, low > high { variable.maximum = nil }
        }
        if let rawDefault {
            let value = clean(rawDefault, kind: kind)
            if !value.isEmpty, variable.problem(with: value) == nil { variable.defaultValue = value }
        }
        return variable
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBool(number), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    /// JSON's true and false arrive as NSNumbers too.
    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    // MARK: Scanning

    private struct Placeholder {
        let range: Range<String.Index>
        let key: String
    }

    private static func placeholders(in text: String) -> [Placeholder] {
        var result: [Placeholder] = []
        var index = text.startIndex
        while let open = text.range(of: "{{", range: index..<text.endIndex) {
            // A key is at most 40 characters, so its closing braces are near.
            let window = text[open.upperBound...].prefix(maximumKeyLength + 2)
            if let close = window.range(of: "}}"), isKey(text[open.upperBound..<close.lowerBound]) {
                result.append(Placeholder(range: open.lowerBound..<close.upperBound,
                                          key: String(text[open.upperBound..<close.lowerBound])))
                index = close.upperBound
            } else {
                index = text.index(after: open.lowerBound)
            }
        }
        return result
    }

    private static func removingBraces(_ value: String) -> String {
        var value = value
        while value.contains("{{") || value.contains("}}") {
            value = value.replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: "")
        }
        return value
    }
}

extension TemplateVariable {
    /// What's wrong with a value already cleaned for this field, if anything.
    enum Problem: Equatable, Sendable {
        case missing
        case tooLong(Int)
        case notANumber
        case belowMinimum(Double)
        case aboveMaximum(Double)
        case notAChoice

        /// One plain line under the field. A missing value only keeps Continue off.
        var message: String? {
            switch self {
            case .missing: nil
            case .tooLong(let limit): "Keep it to \(limit) characters or fewer."
            case .notANumber: "Enter a number."
            case .belowMinimum(let minimum): "Enter \(Self.format(minimum)) or more."
            case .aboveMaximum(let maximum): "Enter \(Self.format(maximum)) or less."
            case .notAChoice: "Pick one of the choices."
            }
        }

        static func format(_ number: Double) -> String {
            number.formatted(.number.grouping(.never))
        }
    }

    func problem(with value: String) -> Problem? {
        if value.isEmpty { return isRequired ? .missing : nil }
        if value.count > lengthLimit { return .tooLong(lengthLimit) }
        switch kind {
        case .text, .longText:
            return nil
        case .choice:
            return options.contains(value) || allowsOther ? nil : .notAChoice
        case .number:
            guard let number = Self.number(value) else { return .notANumber }
            if let minimum, number < minimum { return .belowMinimum(minimum) }
            if let maximum, number > maximum { return .aboveMaximum(maximum) }
            return nil
        }
    }

    /// Accepts "12", "-3.5" and the device's own decimal mark ("3,5").
    static func number(_ text: String) -> Double? {
        if let value = Double(text), value.isFinite { return value }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.number(from: text)?.doubleValue
    }
}

/// The values someone types into a template's form, and whether it can finish.
struct TemplateForm: Equatable, Sendable {
    let fields: [TemplateVariable]
    var values: [String: String]
    /// The person's saved name, used for `{{user_name}}` when the form doesn't ask for it.
    let savedUserName: String

    /// Nil when the template has nothing to ask but the name: it fills in as before.
    init?(texts: [String], declared: [TemplateVariable], agentName: String, savedUserName: String) {
        let saved = UserIdentity.savedName(savedUserName)
        let fields = TemplateVariables.fields(texts: texts, declared: declared, asksForUserName: saved.isEmpty)
        guard fields.count > 1 else { return nil }
        self.fields = fields
        self.savedUserName = saved
        var values: [String: String] = [:]
        for field in fields { values[field.key] = field.defaultValue ?? "" }
        values[TemplateVariables.agentName] = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.values = values
    }

    func cleanedValue(for field: TemplateVariable) -> String {
        TemplateVariables.clean(values[field.key] ?? "", kind: field.kind)
    }

    func problem(for field: TemplateVariable) -> TemplateVariable.Problem? {
        field.problem(with: cleanedValue(for: field))
    }

    var canContinue: Bool { fields.allSatisfy { problem(for: $0) == nil } }

    /// Every key's value, ready for `TemplateVariables.fill`: cleaned, with `whenEmpty` for
    /// optional fields left empty and the saved name for `{{user_name}}`.
    func filledValues() -> [String: String] {
        var result: [String: String] = [:]
        if !savedUserName.isEmpty { result[TemplateVariables.userName] = savedUserName }
        for field in fields {
            let value = cleanedValue(for: field)
            result[field.key] = value.isEmpty ? (field.whenEmpty ?? "") : value
        }
        return result
    }
}
