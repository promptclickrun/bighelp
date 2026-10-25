import Foundation

/// What iOS lets bighelp do with Contacts or Calendar for a reviewed draft.
enum ImageDraftAccess: Equatable, Sendable {
    case notDetermined
    /// bighelp can list accounts or calendars, write, and read the record back.
    case granted
    /// The person said no, or allowed Calendar only to add events: bighelp can't list or read back,
    /// so Save goes through Apple's own new-contact or new-event screen.
    case denied
    case restricted
}

/// One place a draft can go, as the review lists it.
struct ImageDraftDestinationChoice: Identifiable, Hashable, Sendable {
    let destination: ImageDraftDestination
    /// The account a calendar belongs to (`iCloud`, `Gmail`); nil for Contacts accounts.
    let group: String?
    /// `#RRGGBB`, calendars only.
    let colorHex: String?
    let isDefault: Bool

    var id: String { destination.identifier ?? "default" }
}

struct ImageDraftDestinationOptions: Equatable, Sendable {
    let access: ImageDraftAccess
    let choices: [ImageDraftDestinationChoice]
    /// The default account or calendar, or the system default when bighelp can't list them.
    let suggested: ImageDraftDestination

    /// Without access, Save opens Apple's own screen filled in, and its Done is the Save.
    var savesThroughAppleEditor: Bool { access != .granted }
}

/// A record already on the phone that looks like the draft. Read only: nothing is merged or changed.
struct ImageDraftDuplicate: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String?
}

enum ImageDraftDuplicateCheck: Equatable, Sendable {
    /// No access: the row says it can't check.
    case cannotCheck
    case none
    case found([ImageDraftDuplicate])
}

enum ImageDraftDestinationError: Error, Equatable, Sendable {
    case permissionDenied, destinationUnavailable, invalidFields, writeFailed

    var reason: ImageDraftFailureReason {
        switch self {
        case .permissionDenied: .permissionDenied
        case .destinationUnavailable: .destinationUnavailable
        case .invalidFields: .invalidFields
        case .writeFailed: .writeFailed
        }
    }
}

/// An event as Calendar takes it: real dates, worked out from the reviewed fields.
struct ImageDraftEventPlan: Equatable, Sendable {
    let title: String
    let location: String?
    let notes: String?
    let start: Date
    /// Exclusive: an all-day event on one day ends at the next midnight.
    let end: Date
    /// Nil for all-day events, which float with the phone's zone.
    let timeZone: TimeZone?
    let isAllDay: Bool

    /// All-day days are read in `localZone`, so June 15 is June 15 wherever the phone is.
    init(_ fields: EventDraftFields, localZone: TimeZone = .current) throws(ImageDraftDestinationError) {
        let fields = fields.normalized()
        guard let title = fields.title, fields.problems().isEmpty else { throw .invalidFields }
        self.title = title
        location = fields.location
        notes = fields.notes
        switch fields.timing {
        case .timed(let timed):
            guard let startText = timed.start, let endText = timed.end, let zoneID = timed.timeZone,
                  let start = ImageDraftEventTime.date(startText), let end = ImageDraftEventTime.date(endText),
                  let zone = TimeZone(identifier: zoneID), end > start else { throw .invalidFields }
            self.start = start
            self.end = end
            timeZone = zone
            isAllDay = false
        case .allDay(let days):
            guard let first = days.startDate, let start = ImageDraftEventTime.startOfDay(first, in: localZone) else {
                throw .invalidFields
            }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = localZone
            let end: Date?
            if let last = days.endDate { end = ImageDraftEventTime.startOfDay(last, in: localZone) }
            else { end = calendar.date(byAdding: .day, value: 1, to: start) }
            guard let end, end > start else { throw .invalidFields }
            self.start = start
            self.end = end
            timeZone = nil
            isAllDay = true
        }
    }
}

/// An event read back from Calendar.
struct ImageDraftEventRecord: Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let isAllDay: Bool
}

/// Contacts behind a seam: the live address book or the demo's.
@MainActor
protocol ImageDraftContactsDestination: AnyObject {
    /// iOS's current answer. Never asks.
    var access: ImageDraftAccess { get }
    /// Asks iOS once, from the person's tap.
    func requestAccess() async -> ImageDraftAccess
    /// The accounts (containers) a new contact can go to.
    func choices() async throws -> [ImageDraftDestinationChoice]
    /// Adds a new contact to one account (nil: the default) and returns its identifier.
    func create(_ fields: ContactDraftFields, in containerID: String?) async throws -> String
    func readBack(id: String) async throws -> DeviceContactRecord?
    /// People with the same email, phone or name, at most `limit`.
    func candidates(for fields: ContactDraftFields, limit: Int) async throws -> [DeviceContactRecord]
}

/// Calendar behind a seam: EventKit or the demo's.
@MainActor
protocol ImageDraftCalendarDestination: AnyObject {
    var access: ImageDraftAccess { get }
    func requestAccess() async -> ImageDraftAccess
    /// Calendars that can take new events, by account.
    func choices() async throws -> [ImageDraftDestinationChoice]
    func create(_ plan: ImageDraftEventPlan, in calendarID: String?) async throws -> String
    func readBack(id: String) async throws -> ImageDraftEventRecord?
    /// Events from `start` up to `end`, in every calendar.
    func events(from start: Date, to end: Date) async throws -> [ImageDraftEventRecord]
}

// MARK: - Matching

/// Which records look like a draft, for the duplicate check, and which one is the record a Save
/// wrote, for the check after an interrupted Save. The live and demo stores both use these.
enum ImageDraftMatch {
    static let maximumDuplicates = 10

    static func folded(_ text: String?) -> String {
        (text ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func digits(_ text: String) -> String { String(text.filter { $0.isASCII && $0.isNumber }) }

    /// "+1 555 0142" and "555-0142" are the same number when one ends with the other (7 digits or more).
    static func samePhone(_ a: String, _ b: String) -> Bool {
        let x = digits(a), y = digits(b)
        guard x.count >= 7, y.count >= 7 else { return false }
        return x.hasSuffix(y) || y.hasSuffix(x)
    }

    static func sameName(_ record: DeviceContactRecord, _ fields: ContactDraftFields) -> Bool {
        let person = folded([fields.givenName, fields.familyName].compactMap { $0 }.joined(separator: " "))
        if !person.isEmpty { return folded(record.givenName + " " + record.familyName) == person }
        let company = folded(fields.organization)
        return !company.isEmpty && folded(record.organization) == company
    }

    static func isDuplicate(_ record: DeviceContactRecord, of fields: ContactDraftFields) -> Bool {
        let emails = fields.emails.map { folded($0.value) }
        if record.emails.contains(where: { emails.contains(folded($0.value)) }) { return true }
        if record.phones.contains(where: { have in fields.phones.contains { samePhone(have.value, $0.value) } }) { return true }
        return sameName(record, fields)
    }

    /// The same name and every phone and email the draft had: the record a Save made.
    static func isSameRecord(_ record: DeviceContactRecord, as fields: ContactDraftFields) -> Bool {
        let fields = fields.normalized()
        guard sameName(record, fields) else { return false }
        let emails = Set(record.emails.map { folded($0.value) })
        guard fields.emails.allSatisfy({ emails.contains(folded($0.value)) }),
              fields.phones.allSatisfy({ phone in record.phones.contains { samePhone($0.value, phone.value) } }) else {
            return false
        }
        if let organization = fields.organization, folded(organization) != folded(record.organization) { return false }
        if let job = fields.jobTitle, folded(job) != folded(record.jobTitle) { return false }
        return true
    }

    static func duplicate(_ record: DeviceContactRecord) -> ImageDraftDuplicate {
        let name = [record.givenName, record.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let detail = [record.organization, record.emails.first?.value ?? "", record.phones.first?.value ?? ""]
            .first { !$0.isEmpty }
        return ImageDraftDuplicate(id: record.id, title: name.isEmpty ? record.organization : name,
                                   detail: name.isEmpty ? nil : detail)
    }

    static func sameTitle(_ a: String, _ b: String) -> Bool { folded(a) == folded(b) }

    /// The record a Save made: same title, and the same start (a minute either way) or, all day, the same day.
    static func isSameEvent(_ record: ImageDraftEventRecord, as plan: ImageDraftEventPlan) -> Bool {
        guard sameTitle(record.title, plan.title), record.isAllDay == plan.isAllDay else { return false }
        return abs(record.start.timeIntervalSince(plan.start)) <= 60
    }

    /// The day a plan starts on, in the zone the person reads it in.
    static func day(of plan: ImageDraftEventPlan, localZone: TimeZone = .current) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = plan.timeZone ?? localZone
        let start = calendar.startOfDay(for: plan.start)
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }
}

// MARK: - Writing

enum ImageDraftWriteResult: Equatable, Sendable {
    /// `recordID` is nil when Apple's editor saved without telling bighelp the id.
    case saved(recordID: String?, verified: Bool)
    case failed(ImageDraftFailureReason)
    /// The record may or may not be there.
    case outcomeUnknown
}

enum ImageDraftFindResult: Equatable, Sendable {
    case found(String)
    case notFound
    /// No access, or the store didn't answer.
    case cannotCheck
}

@MainActor
protocol ImageDraftWriting: AnyObject {
    /// Writes exactly the approval's fields to its destination and reads the record back.
    func write(_ approval: ImageDraftApproval) async -> ImageDraftWriteResult
    /// Looks for the record an interrupted Save may have written, never one of the approval's
    /// `existingRecordIDs`.
    func find(_ approval: ImageDraftApproval) async -> ImageDraftFindResult
    /// The records that already look like the approval's, read just before its write. Empty without access.
    func lookAlikeIDs(_ approval: ImageDraftApproval) async -> [String]
}

/// The writer over Contacts and Calendar. It takes only the frozen approval.
@MainActor
final class ImageDraftWriter: ImageDraftWriting {
    let contacts: any ImageDraftContactsDestination
    let calendar: any ImageDraftCalendarDestination

    init(contacts: any ImageDraftContactsDestination, calendar: any ImageDraftCalendarDestination) {
        self.contacts = contacts
        self.calendar = calendar
    }

    func write(_ approval: ImageDraftApproval) async -> ImageDraftWriteResult {
        guard approval.isIntact else { return .failed(.invalidFields) }
        do {
            switch approval.fields {
            case .contact(let fields):
                guard contacts.access == .granted else { return .failed(.permissionDenied) }
                let id = try await contacts.create(fields, in: approval.destination.identifier)
                let saved = try? await contacts.readBack(id: id)
                return .saved(recordID: id, verified: saved.map { ImageDraftMatch.isSameRecord($0, as: fields) } ?? false)
            case .event(let fields):
                guard calendar.access == .granted else { return .failed(.permissionDenied) }
                let plan = try ImageDraftEventPlan(fields)
                let id = try await calendar.create(plan, in: approval.destination.identifier)
                let saved = try? await calendar.readBack(id: id)
                return .saved(recordID: id, verified: saved.map { ImageDraftMatch.isSameEvent($0, as: plan) } ?? false)
            }
        } catch let error as ImageDraftDestinationError {
            return .failed(error.reason)
        } catch {
            return .failed(.writeFailed)
        }
    }

    func find(_ approval: ImageDraftApproval) async -> ImageDraftFindResult {
        let existing = Set(approval.existingRecordIDs ?? [])
        do {
            let matches = try await sameRecordIDs(approval)
            guard let matches else { return .cannotCheck }
            return matches.first { !existing.contains($0) }.map { .found($0) } ?? .notFound
        } catch {
            return .cannotCheck
        }
    }

    func lookAlikeIDs(_ approval: ImageDraftApproval) async -> [String] {
        ((try? await sameRecordIDs(approval)) ?? nil) ?? []
    }

    /// Every record that matches the approval's fields; nil without access.
    private func sameRecordIDs(_ approval: ImageDraftApproval) async throws -> [String]? {
        switch approval.fields {
        case .contact(let fields):
            guard contacts.access == .granted else { return nil }
            return try await contacts.candidates(for: fields, limit: 50)
                .filter { ImageDraftMatch.isSameRecord($0, as: fields) }.map(\.id)
        case .event(let fields):
            guard calendar.access == .granted, let plan = try? ImageDraftEventPlan(fields) else { return nil }
            return try await calendar.events(from: plan.start.addingTimeInterval(-60), to: plan.start.addingTimeInterval(61))
                .filter { ImageDraftMatch.isSameEvent($0, as: plan) }.map(\.id)
        }
    }
}

// MARK: - What the review asks for

extension ImageDraftWriter {
    func options(for preset: ImageDraftPreset) async -> ImageDraftDestinationOptions {
        let kind = ImageDraftDestination.kind(for: preset)
        let access = preset == .businessCard ? contacts.access : calendar.access
        guard access == .granted else {
            return ImageDraftDestinationOptions(access: access, choices: [], suggested: .systemDefault(kind))
        }
        let listed: [ImageDraftDestinationChoice]?
        if preset == .businessCard { listed = try? await contacts.choices() } else { listed = try? await calendar.choices() }
        let choices = listed ?? []
        let suggested = choices.first(where: \.isDefault)?.destination ?? choices.first?.destination ?? .systemDefault(kind)
        return ImageDraftDestinationOptions(access: access, choices: choices, suggested: suggested)
    }

    /// Asks iOS once (only while it hasn't answered), then lists again.
    func requestAccess(for preset: ImageDraftPreset) async -> ImageDraftDestinationOptions {
        if preset == .businessCard, contacts.access == .notDetermined { _ = await contacts.requestAccess() }
        if preset == .eventPoster, calendar.access == .notDetermined { _ = await calendar.requestAccess() }
        return await options(for: preset)
    }

    /// Read only: contacts with the same email, phone or name; events on the same day with the same title.
    func duplicates(of fields: ImageDraftFields) async -> ImageDraftDuplicateCheck {
        do {
            switch fields.normalized() {
            case .contact(let contact):
                guard contacts.access == .granted else { return .cannotCheck }
                guard contact.hasName || !contact.phones.isEmpty || !contact.emails.isEmpty else { return .none }
                let found = try await contacts.candidates(for: contact, limit: ImageDraftMatch.maximumDuplicates * 2)
                    .filter { ImageDraftMatch.isDuplicate($0, of: contact) }
                    .prefix(ImageDraftMatch.maximumDuplicates).map(ImageDraftMatch.duplicate)
                return found.isEmpty ? .none : .found(Array(found))
            case .event(let event):
                guard calendar.access == .granted else { return .cannotCheck }
                guard let plan = try? ImageDraftEventPlan(event) else { return .none }
                let day = ImageDraftMatch.day(of: plan)
                let found = try await calendar.events(from: day.start, to: day.end)
                    .filter { ImageDraftMatch.sameTitle($0.title, plan.title) }
                    .prefix(ImageDraftMatch.maximumDuplicates)
                    .map { ImageDraftDuplicate(id: $0.id, title: $0.title, detail: nil) }
                return found.isEmpty ? .none : .found(Array(found))
            }
        } catch {
            return .cannotCheck
        }
    }
}
