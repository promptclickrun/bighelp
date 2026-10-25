import CryptoKit
import Foundation

/// One draft in one chat on one computer: drafts belong to an agent and its stored session.
struct ImageDraftKey: Codable, Hashable, Sendable {
    /// `WorkspaceOwner.cacheScopeID`, or "demo".
    let scope: String
    let agentID: String
    let sessionID: String
    let draftID: String

    /// A one-way name for files, so a file name never reveals the computer, agent or chat.
    /// Without the session: a compaction gives the chat a new stored session, and the person's
    /// edits and a Save in progress stay with the draft (its id is unique).
    var storageKey: String { ImageDraftHash.hex(["image-draft-v2", scope, agentID, draftID].joined(separator: "\u{0}")) }
}

/// Where a reviewed draft goes: a Contacts account (container) or a calendar.
struct ImageDraftDestination: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case contacts, calendar
    }

    let kind: Kind
    /// The container or calendar identifier; nil is the system's default one.
    let identifier: String?
    /// What the person sees and the host records (`iCloud`, `Home`), at most 100 characters.
    let label: String

    init(kind: Kind, identifier: String?, label: String) {
        self.kind = kind
        self.identifier = identifier
        let line = String(String.UnicodeScalarView(label.unicodeScalars.filter { !ImageDraftText.isControl($0) }))
        let clean = ImageDraftText.trimmed(line) ?? Self.fallbackLabel(kind)
        self.label = String(String.UnicodeScalarView(clean.unicodeScalars.prefix(ImageDraftWire.maximumDestinationLength)))
    }

    /// The default account or calendar, for when bighelp can't list them.
    static func systemDefault(_ kind: Kind) -> ImageDraftDestination {
        ImageDraftDestination(kind: kind, identifier: nil, label: fallbackLabel(kind))
    }

    static func fallbackLabel(_ kind: Kind) -> String {
        switch kind {
        case .contacts: "Contacts"
        case .calendar: "Calendar"
        }
    }

    static func kind(for preset: ImageDraftPreset) -> Kind {
        preset == .businessCard ? .contacts : .calendar
    }

    var fingerprint: String { [kind.rawValue, identifier ?? "", label].joined(separator: "\u{1F}") }
}

/// Where a value on the review came from.
enum ImageDraftProvenance: String, Codable, Sendable {
    /// Read from the photo.
    case image
    /// The agent's guess, never shown as read from the photo.
    case suggestion
    /// The person typed it.
    case user
}

/// The app's own words beside a field, whatever the agent's messages say.
enum ImageDraftBadge: String, Codable, Hashable, Sendable {
    /// Hard to read, or the photo shows more than one value.
    case check
    case guess
    /// Needed and empty.
    case missing
    case edited
}

struct ImageDraftCheckItem: Hashable, Sendable {
    let path: ImageDraftFieldPath
    let badge: ImageDraftBadge
    let text: String
}

enum ImageDraftSaveBlocker: Hashable, Sendable {
    case needsName
    case missing(ImageDraftFieldPath)
    case invalid(ImageDraftFieldPath, ImageDraftFieldProblem)
    case unresolved(ImageDraftFieldPath, ImageDraftMarkReason)
    case needsDestination

    /// Under Save, in plain words.
    var message: String {
        switch self {
        case .needsName:
            return "Add a first name, last name or company."
        case .missing(let path):
            switch path.rawValue {
            case "title": return "Add a title."
            case "start": return "Add when it starts."
            case "end": return "Add when it ends."
            case "time_zone": return "Choose a time zone."
            case "start_date": return "Add the date."
            default: return "Add \(ImageDraftFieldNames.name(path).lowercased())."
            }
        case .invalid(let path, let problem):
            let name = ImageDraftFieldNames.name(path)
            switch problem {
            case .tooLong: return "\(name) is too long."
            case .lineBreak: return "\(name) must be one line."
            case .phone: return "\(name) can only have digits, spaces and + ( ) - ."
            case .email: return "\(name) doesn't look like an email address."
            case .date: return "\(name) isn't a date bighelp can read."
            case .timeZone: return "Choose a time zone from the list."
            case .endBeforeStart: return "The end must be after the start."
            }
        case .unresolved(let path, let reason):
            let name = ImageDraftFieldNames.name(path)
            switch reason {
            case .conflicting: return "The photo shows more than one value for \(name.lowercased()). Pick one."
            case .guessed: return "\(name) is a guess. Check it or change it."
            case .unclear: return "\(name) is hard to read. Check it or change it."
            case .notInImage: return "\(name) isn't in the photo. Check it or change it."
            }
        case .needsDestination:
            return "Choose where to save it."
        }
    }
}

/// The person's work on a draft, kept on the phone so closing the review loses nothing.
struct ImageDraftEdits: Codable, Equatable, Sendable {
    var fields: ImageDraftFields
    var destination: ImageDraftDestination?
    var confirmed: Set<ImageDraftFieldPath>
    var stashedTiming: EventDraftFields.Timing?
}

enum ImageDraftReviewError: Error, Equatable, Sendable {
    case blocked([ImageDraftSaveBlocker])
}

/// The review of one draft (docs/IMAGE_DRAFTS.md › Review): editable fields starting from the
/// draft, where each value came from, what to check, and whether Save may go. Pure: no network,
/// no store.
struct ImageDraftReview: Equatable, Sendable {
    let draft: ImageDraft
    /// What the review shows and Save writes.
    var fields: ImageDraftFields
    var destination: ImageDraftDestination?
    /// Marked values the person looked at and kept.
    private(set) var confirmed: Set<ImageDraftFieldPath> = []
    /// The other variant's times, so turning All day off and on gives them back.
    private var stashedTiming: EventDraftFields.Timing?
    private let original: ImageDraftFields

    init(draft: ImageDraft, edits: ImageDraftEdits? = nil) {
        self.draft = draft
        original = draft.fields.normalized()
        if let edits, edits.fields.preset == draft.preset {
            fields = edits.fields
            destination = edits.destination?.kind == ImageDraftDestination.kind(for: draft.preset) ? edits.destination : nil
            confirmed = edits.confirmed
            stashedTiming = edits.stashedTiming
        } else {
            fields = draft.fields
        }
    }

    var edits: ImageDraftEdits {
        ImageDraftEdits(fields: fields, destination: destination, confirmed: confirmed, stashedTiming: stashedTiming)
    }

    var contact: ContactDraftFields? {
        get {
            guard case .contact(let value) = fields else { return nil }
            return value
        }
        set { if let newValue, draft.preset == .businessCard { fields = .contact(newValue) } }
    }

    var event: EventDraftFields? {
        get {
            guard case .event(let value) = fields else { return nil }
            return value
        }
        set { if let newValue, draft.preset == .eventPoster { fields = .event(newValue) } }
    }

    /// Switches between a timed and an all-day event. The day carries over; the other variant's
    /// values wait in case the person switches back.
    mutating func setAllDay(_ on: Bool) {
        guard var event = self.event, event.isAllDay != on else { return }
        let previous = event.timing
        if let stashedTiming, isAllDay(stashedTiming) == on {
            event.timing = stashedTiming
        } else if on, case .timed(let timed) = previous {
            event.timing = .allDay(.init(startDate: timed.start.flatMap(ImageDraftEventTime.dayPart(of:))))
        } else {
            event.timing = on ? .allDay(.init()) : .timed(.init())
        }
        stashedTiming = previous
        self.event = event
    }

    private func isAllDay(_ timing: EventDraftFields.Timing) -> Bool {
        if case .allDay = timing { return true }
        return false
    }

    /// The person looked at a marked value and keeps it as it is.
    mutating func confirm(_ path: ImageDraftFieldPath) {
        confirmed.insert(path)
    }

    // MARK: Where values came from

    func isEdited(_ path: ImageDraftFieldPath) -> Bool {
        fields.json(at: path) != original.json(at: path)
    }

    /// Nil while the field is empty.
    func provenance(at path: ImageDraftFieldPath) -> ImageDraftProvenance? {
        guard fields.json(at: path) != nil else { return nil }
        if isEdited(path) { return .user }
        return draft.marks(at: path).contains(.guessed) ? .suggestion : .image
    }

    /// What the agent read (or guessed), kept after the person changes it.
    func originalText(at path: ImageDraftFieldPath) -> String? {
        original.text(at: path)
    }

    private func isResolved(_ path: ImageDraftFieldPath) -> Bool {
        isEdited(path) || confirmed.contains(path)
    }

    func badges(at path: ImageDraftFieldPath) -> [ImageDraftBadge] {
        var badges: [ImageDraftBadge] = []
        let marks = draft.marks(at: path)
        let empty = fields.json(at: path) == nil
        if !isResolved(path), !empty {
            if marks.contains(.unclear) || marks.contains(.conflicting) || marks.contains(.notInImage) { badges.append(.check) }
            if marks.contains(.guessed) { badges.append(.guess) }
        }
        if empty, isNeeded(path) || marks.contains(.notInImage) { badges.append(.missing) }
        if isEdited(path) { badges.append(.edited) }
        return badges
    }

    /// The fields Save needs, in the review's order.
    var requiredPaths: [ImageDraftFieldPath] {
        switch fields {
        case .contact: ["given_name", "family_name", "organization"].map(ImageDraftFieldPath.init(known:))
        case .event(let event):
            (event.isAllDay ? ["title", "start_date"] : ["title", "start", "end", "time_zone"]).map(ImageDraftFieldPath.init(known:))
        }
    }

    private func isNeeded(_ path: ImageDraftFieldPath) -> Bool {
        switch fields {
        // Any one of the three names a contact.
        case .contact(let contact): !contact.hasName && requiredPaths.contains(path)
        case .event: requiredPaths.contains(path)
        }
    }

    private static let timePaths: Set<String> = ["start", "end", "time_zone", "start_date", "end_date"]

    /// The app-owned box: every marked value not yet looked at, and every needed empty field.
    var checkList: [ImageDraftCheckItem] {
        var paths = Set(draft.marks.map(\.field))
        paths.formUnion(requiredPaths)
        return paths.sorted { order($0) < order($1) }.flatMap { path -> [ImageDraftCheckItem] in
            badges(at: path).compactMap { badge in
                let name = ImageDraftFieldNames.name(path)
                switch badge {
                case .check:
                    let marks = draft.marks(at: path)
                    let text = marks.contains(.conflicting) ? "\(name): the photo shows more than one"
                        : marks.contains(.notInImage) ? "\(name): not in the photo" : "\(name): hard to read"
                    return ImageDraftCheckItem(path: path, badge: .check, text: text)
                case .guess: return ImageDraftCheckItem(path: path, badge: .guess, text: "\(name): a guess")
                case .missing: return ImageDraftCheckItem(path: path, badge: .missing, text: "\(name): missing")
                case .edited: return nil
                }
            }
        }
    }

    private func order(_ path: ImageDraftFieldPath) -> Int {
        let roots = draft.preset == .businessCard ? ImageDraftFieldPath.contactTopLevel
            : ["title", "all_day", "start", "end", "time_zone", "start_date", "end_date", "location", "notes"]
        let rootIndex = roots.firstIndex(of: path.root) ?? roots.count
        let childIndex = path.index ?? path.child.flatMap { ImageDraftFieldPath.addressParts.firstIndex(of: $0) } ?? -1
        return rootIndex * 100 + childIndex + 1
    }

    // MARK: Save

    /// Why Save is off. Empty means it may go.
    var saveBlockers: [ImageDraftSaveBlocker] {
        var blockers: [ImageDraftSaveBlocker] = []
        switch fields {
        case .contact(let contact):
            if !contact.hasName { blockers.append(.needsName) }
        case .event:
            for path in requiredPaths where fields.json(at: path) == nil { blockers.append(.missing(path)) }
        }
        blockers += fields.problems().map { .invalid($0.path, $0.problem) }
        for mark in Set(draft.marks).sorted(by: { (order($0.field), $0.reason.rawValue) < (order($1.field), $1.reason.rawValue) })
        where blocks(mark) {
            blockers.append(.unresolved(mark.field, mark.reason))
        }
        if destination == nil || destination?.kind != ImageDraftDestination.kind(for: draft.preset) {
            blockers.append(.needsDestination)
        }
        var seen = Set<ImageDraftSaveBlocker>()
        return blockers.filter { seen.insert($0).inserted }
    }

    /// Conflicting values always need a choice. On an event, a guessed or hard-to-read date or time
    /// needs the person to look (a missing year is never filled silently), and so does a needed
    /// field the agent said isn't in the photo.
    private func blocks(_ mark: ImageDraftMark) -> Bool {
        guard !isResolved(mark.field), fields.json(at: mark.field) != nil else { return false }
        switch (draft.preset, mark.reason) {
        case (_, .conflicting): return true
        case (.eventPoster, .notInImage): return requiredPaths.contains(mark.field)
        case (.eventPoster, .guessed), (.eventPoster, .unclear): return Self.timePaths.contains(mark.field.rawValue)
        default: return false
        }
    }

    var canSave: Bool { saveBlockers.isEmpty }

    /// The hash the host records for what the person approved (`ImageDraftHash`).
    var fieldsHash: String { ImageDraftHash.fieldsHash(fields) }

    /// The frozen snapshot Save writes. Edits after this can't change what is written.
    func approval(key: ImageDraftKey, decisionID: UUID = UUID(), now: Date = Date()) throws(ImageDraftReviewError)
        -> ImageDraftApproval {
        let blockers = saveBlockers
        guard blockers.isEmpty, let destination, key.draftID == draft.draftID else { throw .blocked(blockers) }
        let snapshot = fields.normalized()
        return ImageDraftApproval(key: key, fields: snapshot, destination: destination,
                                  fieldsHash: ImageDraftHash.fieldsHash(snapshot),
                                  decisionID: decisionID.uuidString.lowercased(), approvedAt: now)
    }

    // MARK: Messages

    /// A message from the draft's snapshot, filled in once. Plain text.
    func message(_ key: ImageActionMessageKey, reason: ImageDraftFailureReason? = nil) -> String {
        let target = destination ?? .systemDefault(ImageDraftDestination.kind(for: draft.preset))
        let names = checkList.map { ImageDraftFieldNames.name($0.path) }
        var seen = Set<String>()
        let values: [String: String] = [
            "destination": target.label,
            "name": fields.displayName ?? (draft.preset == .businessCard ? "the contact" : "the event"),
            "fields": names.filter { seen.insert($0).inserted }.joined(separator: ", "),
            "reason": reason?.message ?? "",
        ]
        return ImageActionTemplate.render(draft.messages[key], values: values)
    }

    /// The draft's `missing_fields` message, or nil when there's nothing to check.
    var missingFieldsMessage: String? {
        checkList.isEmpty ? nil : message(.missingFields)
    }
}

/// What Save writes: a frozen copy of the reviewed fields, the destination, and the hash the host
/// records. The writer takes only this, never the live review.
struct ImageDraftApproval: Codable, Equatable, Sendable {
    let key: ImageDraftKey
    let fields: ImageDraftFields
    let destination: ImageDraftDestination
    let fieldsHash: String
    /// A lowercase UUID, one per Save tap.
    let decisionID: String
    let approvedAt: Date
    /// Records that already looked like this one before the write, so the check after an
    /// interrupted Save never mistakes one of them for the record this Save made.
    var existingRecordIDs: [String]?

    var preset: ImageDraftPreset { fields.preset }

    /// The fields still hash to what was approved (a file read back from disk, say).
    var isIntact: Bool {
        ImageDraftHash.fieldsHash(fields) == fieldsHash && fields.problems().isEmpty
            && ImageDraftDestination.kind(for: preset) == destination.kind
            && UUID(uuidString: decisionID)?.uuidString.lowercased() == decisionID
    }

    var displayName: String {
        fields.displayName ?? (preset == .businessCard ? "the contact" : "the event")
    }
}

/// `fieldsHash`: SHA-256, as lowercase hex, of the canonical JSON of the reviewed fields.
///
/// Canonical form: the wire `fields` object (`given_name`, `phones`, `start`, …) after trimming,
/// with empty strings, empty lists, empty list entries and empty address parts left out; events
/// always carry `all_day` and only their variant's keys. Encoded as UTF-8 JSON with keys sorted at
/// every level, no whitespace, slashes unescaped, other characters as Foundation's `JSONEncoder`
/// writes them (`JSONEncoder.imageDraftsCanonical`).
enum ImageDraftHash {
    static func canonicalBytes(_ fields: ImageDraftFields) -> Data {
        (try? JSONEncoder.imageDraftsCanonical.encode(BighelpJSONValue.object(fields.canonicalJSON))) ?? Data()
    }

    static func fieldsHash(_ fields: ImageDraftFields) -> String {
        hex(canonicalBytes(fields))
    }

    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ text: String) -> String { hex(Data(text.utf8)) }
}

/// Plain names for fields, for the review and its messages.
enum ImageDraftFieldNames {
    static func name(_ path: ImageDraftFieldPath) -> String {
        if let index = path.index {
            return path.root == "phones" ? "Phone \(index + 1)" : "Email \(index + 1)"
        }
        switch path.child ?? path.root {
        case "given_name": return "First name"
        case "family_name": return "Last name"
        case "organization": return "Company"
        case "job_title": return "Job title"
        case "phones": return "Phones"
        case "emails": return "Emails"
        case "postal_address": return "Address"
        case "street": return "Street"
        case "city": return "City"
        case "region": return "State or region"
        case "postal_code": return "Postal code"
        case "country": return "Country"
        case "title": return "Title"
        case "location": return "Place"
        case "notes": return "Notes"
        case "all_day": return "All day"
        case "start": return "Start"
        case "end": return "End"
        case "time_zone": return "Time zone"
        case "start_date": return "Date"
        case "end_date": return "End date"
        default: return path.rawValue
        }
    }
}
