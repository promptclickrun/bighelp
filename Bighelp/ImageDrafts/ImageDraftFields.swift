import Foundation

/// What a draft proposes, in the card's wire shape (docs/IMAGE_DRAFTS.md › `contact_draft`,
/// `event_draft`). The same rules check the agent's card and the person's edits.
enum ImageDraftFields: Codable, Equatable, Sendable {
    case contact(ContactDraftFields)
    case event(EventDraftFields)

    var preset: ImageDraftPreset {
        switch self {
        case .contact: .businessCard
        case .event: .eventPoster
        }
    }

    /// Values that break a field's rules. A missing value isn't a problem here; the review decides
    /// what Save needs.
    func problems() -> [ImageDraftFieldIssue] {
        switch self {
        case .contact(let fields): fields.problems()
        case .event(let fields): fields.problems()
        }
    }

    /// Trimmed, with empty values, entries and address parts left out.
    func normalized() -> ImageDraftFields {
        switch self {
        case .contact(let fields): .contact(fields.normalized())
        case .event(let fields): .event(fields.normalized())
        }
    }

    /// The wire `fields` object with trimmed values and nothing empty. This is what `fieldsHash`
    /// covers (`ImageDraftHash`).
    var canonicalJSON: [String: BighelpJSONValue] {
        switch self {
        case .contact(let fields): fields.canonicalJSON
        case .event(let fields): fields.canonicalJSON
        }
    }

    /// The value at a path, as the hash sees it; nil when empty.
    func json(at path: ImageDraftFieldPath) -> BighelpJSONValue? {
        guard let top = canonicalJSON[path.root] else { return nil }
        guard let child = path.child else { return top }
        if let index = Int(child) {
            guard let list = top.array, list.indices.contains(index) else { return nil }
            return list[index]
        }
        return top.object?[child]
    }

    /// The value at a path in plain words, for "Read from the photo: …".
    func text(at path: ImageDraftFieldPath) -> String? {
        guard let value = json(at: path) else { return nil }
        return Self.text(value)
    }

    private static func text(_ value: BighelpJSONValue) -> String? {
        switch value {
        case .string(let text): return text
        case .boolean(let on): return on ? "Yes" : "No"
        case .object(let object):
            if let entry = object["value"]?.string { return entry }
            let lines = ImageDraftFieldPath.addressParts.compactMap { object[$0]?.string }
            return lines.isEmpty ? nil : lines.joined(separator: ", ")
        case .array(let list):
            let parts = list.compactMap(text)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default: return nil
        }
    }

    /// The contact's name or the event's title: what `{{name}}` says.
    var displayName: String? {
        switch self {
        case .contact(let fields): fields.displayName
        case .event(let fields): ImageDraftText.trimmed(fields.title)
        }
    }

    /// Reads a JSON value as an optional string field: absent and `null` are nil.
    static func string(_ value: BighelpJSONValue?) throws -> String? {
        switch value {
        case nil, .null?: return nil
        case .string(let text)?: return ImageDraftText.trimmed(text)
        default: throw BighelpCardValidationError.invalid
        }
    }
}

enum ImageDraftFieldProblem: String, Codable, Hashable, Sendable {
    case tooLong, lineBreak, phone, email, date, timeZone, endBeforeStart
}

struct ImageDraftFieldIssue: Codable, Hashable, Sendable {
    let path: ImageDraftFieldPath
    let problem: ImageDraftFieldProblem
}

// MARK: - Contact

struct ImageDraftLabeledValue: Codable, Hashable, Sendable {
    var label: String?
    var value: String

    init(label: String? = nil, value: String) {
        self.label = label
        self.value = value
    }
}

struct ImageDraftPostalAddress: Codable, Equatable, Sendable {
    var street: String?
    var city: String?
    var region: String?
    var postalCode: String?
    var country: String?

    init(street: String? = nil, city: String? = nil, region: String? = nil, postalCode: String? = nil,
         country: String? = nil) {
        self.street = street
        self.city = city
        self.region = region
        self.postalCode = postalCode
        self.country = country
    }

    /// In the wire order of `ImageDraftFieldPath.addressParts`.
    var parts: [(key: String, value: String?)] {
        [("street", street), ("city", city), ("region", region), ("postal_code", postalCode), ("country", country)]
    }

    var isEmpty: Bool { parts.allSatisfy { ImageDraftText.trimmed($0.value) == nil } }
}

struct ContactDraftFields: Codable, Equatable, Sendable {
    static let keys = Set(ImageDraftFieldPath.contactTopLevel)
    static let maximumName = 200
    static let maximumLabel = 40
    static let maximumEntryValue = 200
    static let maximumAddressPart = 100

    var givenName: String?
    var familyName: String?
    var organization: String?
    var jobTitle: String?
    var phones: [ImageDraftLabeledValue] = []
    var emails: [ImageDraftLabeledValue] = []
    var postalAddress: ImageDraftPostalAddress?

    init(givenName: String? = nil, familyName: String? = nil, organization: String? = nil, jobTitle: String? = nil,
         phones: [ImageDraftLabeledValue] = [], emails: [ImageDraftLabeledValue] = [],
         postalAddress: ImageDraftPostalAddress? = nil) {
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.jobTitle = jobTitle
        self.phones = phones
        self.emails = emails
        self.postalAddress = postalAddress
    }

    /// Unknown keys and wrong types are refused; values are checked by `problems()`.
    init(json: [String: BighelpJSONValue]) throws {
        guard Set(json.keys).isSubset(of: Self.keys) else { throw BighelpCardValidationError.invalid }
        givenName = try ImageDraftFields.string(json["given_name"])
        familyName = try ImageDraftFields.string(json["family_name"])
        organization = try ImageDraftFields.string(json["organization"])
        jobTitle = try ImageDraftFields.string(json["job_title"])
        phones = try Self.entries(json["phones"])
        emails = try Self.entries(json["emails"])
        switch json["postal_address"] {
        case nil, .null?:
            postalAddress = nil
        case .object(let parts)?:
            guard Set(parts.keys).isSubset(of: Set(ImageDraftFieldPath.addressParts)) else {
                throw BighelpCardValidationError.invalid
            }
            let address = ImageDraftPostalAddress(
                street: try ImageDraftFields.string(parts["street"]), city: try ImageDraftFields.string(parts["city"]),
                region: try ImageDraftFields.string(parts["region"]),
                postalCode: try ImageDraftFields.string(parts["postal_code"]),
                country: try ImageDraftFields.string(parts["country"]))
            postalAddress = address.isEmpty ? nil : address
        default:
            throw BighelpCardValidationError.invalid
        }
    }

    private static func entries(_ value: BighelpJSONValue?) throws -> [ImageDraftLabeledValue] {
        switch value {
        case nil, .null?: return []
        case .array(let list)?:
            guard list.count <= ImageDraftWire.maximumEntries else { throw BighelpCardValidationError.invalid }
            return try list.map { item in
                guard case .object(let entry) = item,
                      Set(entry.keys).isSubset(of: ["label", "value"]),
                      let text = try ImageDraftFields.string(entry["value"]) else {
                    throw BighelpCardValidationError.invalid
                }
                return ImageDraftLabeledValue(label: try ImageDraftFields.string(entry["label"]), value: text)
            }
        default: throw BighelpCardValidationError.invalid
        }
    }

    var hasName: Bool {
        [givenName, familyName, organization].contains { ImageDraftText.trimmed($0) != nil }
    }

    /// "Riley Moss", else the company.
    var displayName: String? {
        let person = [givenName, familyName].compactMap { ImageDraftText.trimmed($0) }.joined(separator: " ")
        return person.isEmpty ? ImageDraftText.trimmed(organization) : person
    }

    func problems() -> [ImageDraftFieldIssue] {
        var issues: [ImageDraftFieldIssue] = []
        func check(_ text: String?, _ path: String, maximum: Int) {
            guard let text = ImageDraftText.trimmed(text) else { return }
            let field = ImageDraftFieldPath(known: path)
            if ImageDraftText.length(text) > maximum { issues.append(.init(path: field, problem: .tooLong)) }
            if !ImageDraftText.isPlain(text, oneLine: true) { issues.append(.init(path: field, problem: .lineBreak)) }
        }
        check(givenName, "given_name", maximum: Self.maximumName)
        check(familyName, "family_name", maximum: Self.maximumName)
        check(organization, "organization", maximum: Self.maximumName)
        check(jobTitle, "job_title", maximum: Self.maximumName)
        let lists: [(root: String, list: [ImageDraftLabeledValue], isValid: (String) -> Bool)] = [
            ("phones", phones, BighelpCardObjects.isPhoneNumber), ("emails", emails, BighelpCardObjects.isEmailAddress),
        ]
        for (root, list, isValid) in lists {
            let entries = list.filter { ImageDraftText.trimmed($0.value) != nil }
            if entries.count > ImageDraftWire.maximumEntries {
                issues.append(.init(path: ImageDraftFieldPath(known: root), problem: .tooLong))
            }
            for (index, entry) in entries.prefix(ImageDraftWire.maximumEntries).enumerated() {
                let path = "\(root).\(index)"
                check(entry.label, path, maximum: Self.maximumLabel)
                guard let value = ImageDraftText.trimmed(entry.value) else { continue }
                if ImageDraftText.length(value) > Self.maximumEntryValue {
                    issues.append(.init(path: ImageDraftFieldPath(known: path), problem: .tooLong))
                } else if !isValid(value) {
                    issues.append(.init(path: ImageDraftFieldPath(known: path), problem: root == "phones" ? .phone : .email))
                }
            }
        }
        for part in postalAddress?.parts ?? [] {
            check(part.value, "postal_address.\(part.key)", maximum: Self.maximumAddressPart)
        }
        return Array(Set(issues)).sorted { ($0.path, $0.problem.rawValue) < ($1.path, $1.problem.rawValue) }
    }

    func normalized() -> ContactDraftFields {
        func entries(_ list: [ImageDraftLabeledValue]) -> [ImageDraftLabeledValue] {
            list.compactMap { entry in
                ImageDraftText.trimmed(entry.value).map { ImageDraftLabeledValue(label: ImageDraftText.trimmed(entry.label), value: $0) }
            }
        }
        var address = postalAddress.map {
            ImageDraftPostalAddress(street: ImageDraftText.trimmed($0.street), city: ImageDraftText.trimmed($0.city),
                                    region: ImageDraftText.trimmed($0.region),
                                    postalCode: ImageDraftText.trimmed($0.postalCode),
                                    country: ImageDraftText.trimmed($0.country))
        }
        if address?.isEmpty == true { address = nil }
        return ContactDraftFields(
            givenName: ImageDraftText.trimmed(givenName), familyName: ImageDraftText.trimmed(familyName),
            organization: ImageDraftText.trimmed(organization), jobTitle: ImageDraftText.trimmed(jobTitle),
            phones: entries(phones), emails: entries(emails), postalAddress: address)
    }

    var canonicalJSON: [String: BighelpJSONValue] {
        let fields = normalized()
        var json: [String: BighelpJSONValue] = [:]
        let texts: [(String, String?)] = [("given_name", fields.givenName), ("family_name", fields.familyName),
                                          ("organization", fields.organization), ("job_title", fields.jobTitle)]
        for (key, value) in texts { if let value { json[key] = .string(value) } }
        func entries(_ list: [ImageDraftLabeledValue]) -> BighelpJSONValue {
            .array(list.map { entry in
                var object: [String: BighelpJSONValue] = ["value": .string(entry.value)]
                if let label = entry.label { object["label"] = .string(label) }
                return .object(object)
            })
        }
        if !fields.phones.isEmpty { json["phones"] = entries(fields.phones) }
        if !fields.emails.isEmpty { json["emails"] = entries(fields.emails) }
        if let address = fields.postalAddress {
            var parts: [String: BighelpJSONValue] = [:]
            for part in address.parts { if let value = part.value { parts[part.key] = .string(value) } }
            json["postal_address"] = .object(parts)
        }
        return json
    }
}

// MARK: - Event

struct EventDraftFields: Codable, Equatable, Sendable {
    static let maximumTitle = 200
    static let maximumLocation = 500
    static let maximumNotes = 2_000
    static let sharedKeys: Set<String> = ["title", "location", "notes", "all_day"]
    static let timedKeys: Set<String> = ["start", "end", "time_zone"]
    static let allDayKeys: Set<String> = ["start_date", "end_date"]

    /// `start` and `end` are RFC 3339 with an offset; `timeZone` an IANA ID.
    struct Timed: Codable, Equatable, Sendable {
        var start: String?
        var end: String?
        var timeZone: String?

        init(start: String? = nil, end: String? = nil, timeZone: String? = nil) {
            self.start = start
            self.end = end
            self.timeZone = timeZone
        }
    }

    /// `YYYY-MM-DD`; `endDate` is exclusive, and nil means one day.
    struct AllDay: Codable, Equatable, Sendable {
        var startDate: String?
        var endDate: String?

        init(startDate: String? = nil, endDate: String? = nil) {
            self.startDate = startDate
            self.endDate = endDate
        }
    }

    /// Only one variant's keys can be set, so a draft can never be timed and all day at once.
    enum Timing: Codable, Equatable, Sendable {
        case timed(Timed)
        case allDay(AllDay)
    }

    var title: String?
    var location: String?
    var notes: String?
    var timing: Timing

    init(title: String? = nil, location: String? = nil, notes: String? = nil, timing: Timing = .timed(Timed())) {
        self.title = title
        self.location = location
        self.notes = notes
        self.timing = timing
    }

    init(json: [String: BighelpJSONValue]) throws {
        let allDay: Bool
        switch json["all_day"] {
        case nil, .null?: allDay = false
        case .boolean(let value)?: allDay = value
        default: throw BighelpCardValidationError.invalid
        }
        let allowed = Self.sharedKeys.union(allDay ? Self.allDayKeys : Self.timedKeys)
        guard Set(json.keys).isSubset(of: allowed) else { throw BighelpCardValidationError.invalid }
        title = try ImageDraftFields.string(json["title"])
        location = try ImageDraftFields.string(json["location"])
        notes = try ImageDraftFields.string(json["notes"])
        if allDay {
            timing = .allDay(AllDay(startDate: try ImageDraftFields.string(json["start_date"]),
                                    endDate: try ImageDraftFields.string(json["end_date"])))
        } else {
            timing = .timed(Timed(start: try ImageDraftFields.string(json["start"]),
                                  end: try ImageDraftFields.string(json["end"]),
                                  timeZone: try ImageDraftFields.string(json["time_zone"])))
        }
    }

    var isAllDay: Bool {
        if case .allDay = timing { return true }
        return false
    }

    func problems() -> [ImageDraftFieldIssue] {
        var issues: [ImageDraftFieldIssue] = []
        func add(_ path: String, _ problem: ImageDraftFieldProblem) {
            issues.append(.init(path: ImageDraftFieldPath(known: path), problem: problem))
        }
        func check(_ text: String?, _ path: String, maximum: Int, oneLine: Bool) {
            guard let text = ImageDraftText.trimmed(text) else { return }
            if ImageDraftText.length(text) > maximum { add(path, .tooLong) }
            if !ImageDraftText.isPlain(text, oneLine: oneLine) { add(path, .lineBreak) }
        }
        check(title, "title", maximum: Self.maximumTitle, oneLine: true)
        check(location, "location", maximum: Self.maximumLocation, oneLine: false)
        check(notes, "notes", maximum: Self.maximumNotes, oneLine: false)
        switch timing {
        case .timed(let timed):
            let start = ImageDraftText.trimmed(timed.start).map { ($0, ImageDraftEventTime.date($0)) }
            let end = ImageDraftText.trimmed(timed.end).map { ($0, ImageDraftEventTime.date($0)) }
            if let start, start.1 == nil { add("start", .date) }
            if let end, end.1 == nil { add("end", .date) }
            if let startDate = start?.1, let endDate = end?.1, endDate <= startDate { add("end", .endBeforeStart) }
            if let zone = ImageDraftText.trimmed(timed.timeZone), !ImageDraftEventTime.isTimeZoneID(zone) {
                add("time_zone", .timeZone)
            }
        case .allDay(let days):
            let start = ImageDraftText.trimmed(days.startDate).map { ($0, ImageDraftEventTime.day($0)) }
            let end = ImageDraftText.trimmed(days.endDate).map { ($0, ImageDraftEventTime.day($0)) }
            if let start, start.1 == nil { add("start_date", .date) }
            if let end, end.1 == nil { add("end_date", .date) }
            // Same-width `YYYY-MM-DD` strings sort as their days do.
            if let start, let end, start.1 != nil, end.1 != nil, end.0 <= start.0 { add("end_date", .endBeforeStart) }
        }
        return Array(Set(issues)).sorted { ($0.path, $0.problem.rawValue) < ($1.path, $1.problem.rawValue) }
    }

    func normalized() -> EventDraftFields {
        let timing: Timing
        switch self.timing {
        case .timed(let timed):
            timing = .timed(Timed(start: ImageDraftText.trimmed(timed.start), end: ImageDraftText.trimmed(timed.end),
                                  timeZone: ImageDraftText.trimmed(timed.timeZone)))
        case .allDay(let days):
            timing = .allDay(AllDay(startDate: ImageDraftText.trimmed(days.startDate),
                                    endDate: ImageDraftText.trimmed(days.endDate)))
        }
        return EventDraftFields(title: ImageDraftText.trimmed(title), location: ImageDraftText.trimmed(location),
                                notes: ImageDraftText.trimmed(notes), timing: timing)
    }

    var canonicalJSON: [String: BighelpJSONValue] {
        let fields = normalized()
        var json: [String: BighelpJSONValue] = ["all_day": .boolean(fields.isAllDay)]
        var texts: [(String, String?)] = [("title", fields.title), ("location", fields.location), ("notes", fields.notes)]
        switch fields.timing {
        case .timed(let timed): texts += [("start", timed.start), ("end", timed.end), ("time_zone", timed.timeZone)]
        case .allDay(let days): texts += [("start_date", days.startDate), ("end_date", days.endDate)]
        }
        for (key, value) in texts { if let value { json[key] = .string(value) } }
        return json
    }
}

// MARK: - Dates and times

/// RFC 3339 times with an offset, `YYYY-MM-DD` days and IANA time zones, checked byte by byte so
/// every device reads them the same.
enum ImageDraftEventTime {
    private static let pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt][0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?([Zz]|[+-][0-9]{2}:[0-9]{2})$"

    /// `2030-06-15T18:00:00Z` or `2030-06-15T11:00:00-07:00`. Nil for anything else, a day the
    /// calendar lacks, or an hour, minute or offset out of range.
    static func date(_ text: String) -> Date? {
        guard text.utf8.count <= 40, text.range(of: pattern, options: .regularExpression) != nil,
              day(String(text.prefix(10))) != nil else { return nil }
        let bytes = Array(text.utf8)
        func number(_ start: Int, _ count: Int) -> Int { Int(String(decoding: bytes[start..<(start + count)], as: UTF8.self)) ?? -1 }
        guard (0...23).contains(number(11, 2)), (0...59).contains(number(14, 2)), (0...59).contains(number(17, 2)) else {
            return nil
        }
        let upper = text.uppercased()
        if !upper.hasSuffix("Z") {
            let offset = bytes.count - 5
            guard (0...23).contains(number(offset, 2)), (0...59).contains(number(offset + 3, 2)) else { return nil }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = upper.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        if let date = formatter.date(from: upper) { return date }
        // ISO8601DateFormatter reads at most three fraction digits; the rest change nothing that matters.
        guard let dot = upper.firstIndex(of: ".") else { return nil }
        var end = upper.index(after: dot)
        while end < upper.endIndex, upper[end].isASCII, upper[end].isNumber { end = upper.index(after: end) }
        let digits = upper[upper.index(after: dot)..<end].prefix(3)
        return formatter.date(from: String(upper[..<dot]) + "." + String(digits) + String(upper[end...]))
    }

    /// `YYYY-MM-DD` as year, month and day; nil for anything else or a day the calendar lacks.
    static func day(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].utf8.count == 4, parts[1].utf8.count == 2, parts[2].utf8.count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let dayNumber = Int(parts[2]),
              year >= 1, (1...12).contains(month) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: first), days.contains(dayNumber) else { return nil }
        return DateComponents(year: year, month: month, day: dayNumber)
    }

    /// An IANA zone the system knows (`Europe/Lisbon`, `UTC`).
    static func isTimeZoneID(_ text: String) -> Bool {
        guard (1...64).contains(text.utf8.count),
              text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                  || [43, 45, 47, 95].contains($0) }) else { return false }
        return TimeZone(identifier: text) != nil
    }

    /// The time written with the zone's offset at that moment: `2030-06-15T11:00:00-07:00`.
    static func string(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        return formatter.string(from: date)
    }

    /// The day as `YYYY-MM-DD` in a zone.
    static func dayString(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1, parts.month ?? 1, parts.day ?? 1)
    }

    /// The day a time falls on, as written (in its own offset).
    static func dayPart(of text: String) -> String? {
        guard date(text) != nil else { return nil }
        return String(text.prefix(10))
    }

    /// Midnight of a `YYYY-MM-DD` day in a zone.
    static func startOfDay(_ text: String, in timeZone: TimeZone) -> Date? {
        guard let parts = day(text) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: parts)
    }
}
