import Foundation

/// Photo actions (docs/IMAGE_DRAFTS.md, plugin feature `native-image-drafts-v1`): an agent reads a
/// business card or an event poster the person sent and proposes a contact or an event as a card
/// object. Nothing is written until the person reviews it and taps Save.
///
/// The validator, the review and the writer all read a draft through these types, so a card that
/// validates always opens. Lengths are counted as the plugin counts them (Unicode scalars, Python's
/// `len`).
enum ImageDraftWire {
    static let feature = "native-image-drafts-v1"
    /// What the speaker note adds to `renders` when the plugin lists the feature.
    static let renders = ["contact_draft", "event_draft"]
    static let types: Set<String> = ["contact_draft", "event_draft"]
    static let maximumMarks = 20
    static let maximumEntries = 5
    static let maximumDestinationLength = 100
    static let maximumMessageLength = 500
}

enum ImageDraftPreset: String, Codable, CaseIterable, Sendable {
    case businessCard = "business_card"
    case eventPoster = "event_poster"

    var cardType: String {
        switch self {
        case .businessCard: "contact_draft"
        case .eventPoster: "event_draft"
        }
    }

    init?(cardType: String) {
        switch cardType {
        case "contact_draft": self = .businessCard
        case "event_draft": self = .eventPoster
        default: return nil
        }
    }
}

// MARK: - Text rules

enum ImageDraftText {
    static func length(_ text: String) -> Int { text.unicodeScalars.count }

    /// C0 and C1 controls, plus the Unicode line and paragraph separators.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029
    }

    /// No controls at all (`oneLine`), or none but line breaks and tabs.
    static func isPlain(_ text: String, oneLine: Bool) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            !isControl(scalar) || (!oneLine && (scalar == "\n" || scalar == "\t"))
        }
    }

    static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A string prop: absent is nil, spaces only read as missing, anything else must fit.
    static func prop(_ value: BighelpJSONValue?, maximum: Int, oneLine: Bool) throws -> String? {
        guard let value else { return nil }
        guard case .string(let raw) = value, length(raw) <= maximum, isPlain(raw, oneLine: oneLine) else {
            throw BighelpCardValidationError.invalid
        }
        return trimmed(raw)
    }

    /// `d_` and 32 lowercase hex characters (`draft_id`), or the 32 hex alone (`image_id`).
    static func isHex(_ text: some StringProtocol, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func isDraftID(_ text: String) -> Bool { text.hasPrefix("d_") && isHex(text.dropFirst(2), count: 32) }
}

// MARK: - Field paths and marks

/// A field a mark names: a top-level field (`given_name`, `start`), a list entry (`phones.0`) or an
/// address part (`postal_address.city`).
struct ImageDraftFieldPath: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let rawValue: String

    static let contactTopLevel: [String] = ["given_name", "family_name", "organization", "job_title",
                                            "phones", "emails", "postal_address"]
    static let addressParts: [String] = ["street", "city", "region", "postal_code", "country"]
    static let eventTopLevel: [String] = ["title", "location", "notes", "all_day", "start", "end", "time_zone",
                                          "start_date", "end_date"]

    init?(_ rawValue: String, preset: ImageDraftPreset) {
        guard Self.isValid(rawValue, preset: preset) else { return nil }
        self.rawValue = rawValue
    }

    /// For paths the app itself names; checked in DEBUG.
    init(known rawValue: String) {
        assert(Self.isValid(rawValue, preset: .businessCard) || Self.isValid(rawValue, preset: .eventPoster))
        self.rawValue = rawValue
    }

    var description: String { rawValue }
    var root: String { String(rawValue.split(separator: ".", maxSplits: 1).first ?? "") }
    var child: String? {
        let parts = rawValue.split(separator: ".", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }
    var index: Int? { child.flatMap { Int($0) } }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func isValid(_ text: String, preset: ImageDraftPreset) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        switch preset {
        case .businessCard:
            guard let root = parts.first, contactTopLevel.contains(root) else { return false }
            if parts.count == 1 { return true }
            guard parts.count == 2 else { return false }
            switch root {
            case "phones", "emails":
                // "0" through "4", one digit, no sign or leading zeros.
                guard parts[1].utf8.count == 1, let index = Int(parts[1]) else { return false }
                return (0..<ImageDraftWire.maximumEntries).contains(index)
            case "postal_address": return addressParts.contains(parts[1])
            default: return false
            }
        case .eventPoster:
            return parts.count == 1 && eventTopLevel.contains(parts[0])
        }
    }
}

enum ImageDraftMarkReason: String, Codable, CaseIterable, Sendable {
    /// Read from the picture but hard to read.
    case unclear
    /// Not read from the picture: the agent inferred it.
    case guessed
    /// Needed, and not in the picture.
    case notInImage = "not_in_image"
    /// The picture shows more than one value.
    case conflicting
}

struct ImageDraftMark: Codable, Hashable, Sendable {
    let field: ImageDraftFieldPath
    let reason: ImageDraftMarkReason
}

// MARK: - Source and messages

struct ImageDraftSource: Codable, Equatable, Sendable {
    static let maximumDimension = 100_000

    let imageID: String
    let mimeType: String
    let width: Int?
    let height: Int?

    init(imageID: String, mimeType: String, width: Int? = nil, height: Int? = nil) {
        self.imageID = imageID
        self.mimeType = mimeType
        self.width = width
        self.height = height
    }

    init(json value: BighelpJSONValue?) throws {
        guard case .object(let source)? = value else { throw BighelpCardValidationError.invalid }
        try BighelpCardObjects.requireKeys(source, allowed: ["image_id", "mime_type", "width", "height"],
                                           required: ["image_id", "mime_type"])
        guard case .string(let id)? = source["image_id"], ImageDraftText.isHex(id, count: 32),
              case .string(let mime)? = source["mime_type"], Self.isImageMIMEType(mime) else {
            throw BighelpCardValidationError.invalid
        }
        func dimension(_ key: String) throws -> Int? {
            guard let value = source[key] else { return nil }
            guard case .integer(let number) = value, (1...Self.maximumDimension).contains(number) else {
                throw BighelpCardValidationError.invalid
            }
            return number
        }
        self.init(imageID: id, mimeType: mime, width: try dimension("width"), height: try dimension("height"))
    }

    /// `image/` and a lowercase subtype (`jpeg`, `png`, `heic`). SVG is a document, never a photo.
    static func isImageMIMEType(_ text: String) -> Bool {
        guard text.hasPrefix("image/"), text.utf8.count <= 64 else { return false }
        let subtype = text.dropFirst(6)
        return !subtype.isEmpty && subtype != "svg+xml" && subtype.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || [43, 45, 46].contains($0)
        }
    }

    var json: BighelpJSONValue {
        var object: [String: BighelpJSONValue] = ["image_id": .string(imageID), "mime_type": .string(mimeType)]
        if let width { object["width"] = .integer(width) }
        if let height { object["height"] = .integer(height) }
        return .object(object)
    }
}

/// The review's messages, snapshot from the agent's Photo actions settings when the draft was made.
struct ImageDraftMessages: Codable, Equatable, Sendable {
    var review: String
    var missingFields: String
    var saved: String
    var failed: String
    var outcomeUnknown: String

    subscript(key: ImageActionMessageKey) -> String {
        switch key {
        case .review: review
        case .missingFields: missingFields
        case .saved: saved
        case .failed: failed
        case .outcomeUnknown: outcomeUnknown
        }
    }

    init(review: String, missingFields: String, saved: String, failed: String, outcomeUnknown: String) {
        self.review = review
        self.missingFields = missingFields
        self.saved = saved
        self.failed = failed
        self.outcomeUnknown = outcomeUnknown
    }

    init(json value: BighelpJSONValue?) throws {
        guard case .object(let messages)? = value else { throw BighelpCardValidationError.invalid }
        let keys = Set(ImageActionMessageKey.allCases.map(\.rawValue))
        try BighelpCardObjects.requireKeys(messages, allowed: keys, required: keys)
        func message(_ key: ImageActionMessageKey) throws -> String {
            guard case .string(let text)? = messages[key.rawValue],
                  (try? ImageActionTemplate.validate(text, for: key)) != nil else {
                throw BighelpCardValidationError.invalid
            }
            return text
        }
        self.init(review: try message(.review), missingFields: try message(.missingFields),
                  saved: try message(.saved), failed: try message(.failed),
                  outcomeUnknown: try message(.outcomeUnknown))
    }

    var json: BighelpJSONValue {
        .object(Dictionary(uniqueKeysWithValues: ImageActionMessageKey.allCases.map { ($0.rawValue, .string(self[$0])) }))
    }
}

// MARK: - The draft

struct ImageDraft: Codable, Equatable, Sendable {
    let draftID: String
    let preset: ImageDraftPreset
    let source: ImageDraftSource
    let configRevision: Int
    let messages: ImageDraftMessages
    let marks: [ImageDraftMark]
    let fields: ImageDraftFields

    static let propKeys: Set<String> = ["draft_id", "preset", "source", "config_revision", "messages", "marks", "fields"]
    static let requiredPropKeys: Set<String> = ["draft_id", "preset", "source", "config_revision", "messages"]

    init(draftID: String, preset: ImageDraftPreset, source: ImageDraftSource, configRevision: Int,
         messages: ImageDraftMessages, marks: [ImageDraftMark], fields: ImageDraftFields) {
        self.draftID = draftID
        self.preset = preset
        self.source = source
        self.configRevision = configRevision
        self.messages = messages
        self.marks = marks
        self.fields = fields
    }

    /// A `contact_draft` or `event_draft` element's props, exactly as docs/IMAGE_DRAFTS.md › Card
    /// objects allows. `fields` may be left out (an empty draft); every key it holds is checked.
    init(type: String, props: [String: BighelpJSONValue]) throws {
        try BighelpCardObjects.requireKeys(props, allowed: Self.propKeys, required: Self.requiredPropKeys)
        guard let expected = ImageDraftPreset(cardType: type),
              case .string(let presetName)? = props["preset"], ImageDraftPreset(rawValue: presetName) == expected,
              case .string(let id)? = props["draft_id"], ImageDraftText.isDraftID(id),
              case .integer(let revision)? = props["config_revision"], revision >= 1 else {
            throw BighelpCardValidationError.invalid
        }
        let fieldsJSON: [String: BighelpJSONValue]
        switch props["fields"] {
        case nil: fieldsJSON = [:]
        case .object(let object)?: fieldsJSON = object
        default: throw BighelpCardValidationError.invalid
        }
        let fields: ImageDraftFields
        switch expected {
        case .businessCard: fields = .contact(try ContactDraftFields(json: fieldsJSON))
        case .eventPoster: fields = .event(try EventDraftFields(json: fieldsJSON))
        }
        guard fields.problems().isEmpty else { throw BighelpCardValidationError.invalid }
        self.init(draftID: id, preset: expected, source: try ImageDraftSource(json: props["source"]),
                  configRevision: revision, messages: try ImageDraftMessages(json: props["messages"]),
                  marks: try Self.marks(props["marks"], preset: expected), fields: fields)
    }

    private static func marks(_ value: BighelpJSONValue?, preset: ImageDraftPreset) throws -> [ImageDraftMark] {
        guard let value else { return [] }
        guard case .array(let list) = value, list.count <= ImageDraftWire.maximumMarks else {
            throw BighelpCardValidationError.invalid
        }
        return try list.map { item in
            guard case .object(let mark) = item else { throw BighelpCardValidationError.invalid }
            try BighelpCardObjects.requireKeys(mark, allowed: ["field", "reason"], required: ["field", "reason"])
            guard case .string(let path)? = mark["field"], let field = ImageDraftFieldPath(path, preset: preset),
                  case .string(let name)? = mark["reason"], let reason = ImageDraftMarkReason(rawValue: name) else {
                throw BighelpCardValidationError.invalid
            }
            return ImageDraftMark(field: field, reason: reason)
        }
    }

    func marks(at path: ImageDraftFieldPath) -> [ImageDraftMarkReason] {
        marks.filter { $0.field == path }.map(\.reason)
    }

    /// The card object's props, as the plugin sends them (fixtures and tests).
    var props: [String: BighelpJSONValue] {
        [
            "draft_id": .string(draftID), "preset": .string(preset.rawValue), "source": source.json,
            "config_revision": .integer(configRevision), "messages": messages.json,
            "marks": .array(marks.map { .object(["field": .string($0.field.rawValue), "reason": .string($0.reason.rawValue)]) }),
            "fields": .object(fields.canonicalJSON),
        ]
    }
}

/// Which draft a card holds. A card holds at most one draft object and, with it, no other object.
enum ImageDraftCard {
    /// Whether a card document holds a draft object, without reading its props.
    static func holdsDraft(_ document: [String: BighelpJSONValue]) -> Bool {
        document["elements"]?.object?.values.contains { ImageDraftWire.types.contains($0.object?["type"]?.string ?? "") } ?? false
    }

    static func draft(in card: BighelpCardDocument) -> ImageDraft? {
        guard let elements = card.document["elements"]?.object else { return nil }
        for element in elements.values {
            guard let object = element.object, let type = object["type"]?.string,
                  ImageDraftWire.types.contains(type), let props = object["props"]?.object else { continue }
            return try? ImageDraft(type: type, props: props)
        }
        return nil
    }

    /// The validator's composition rule: one draft, and nothing else a person could act on beside it.
    static func validateComposition(_ elements: [String: BighelpJSONValue]) throws {
        let types = elements.values.compactMap { $0.object?["type"]?.string }
        let drafts = types.filter(ImageDraftWire.types.contains).count
        guard drafts > 0 else { return }
        let otherObjects = types.filter { BighelpCardObjects.types.contains($0) && !ImageDraftWire.types.contains($0) }
        guard drafts == 1, otherObjects.isEmpty else { throw BighelpCardValidationError.invalid }
    }
}
