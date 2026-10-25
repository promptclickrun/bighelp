import Foundation

/// Demo mode's Contacts: three made-up accounts and one person already saved, kept in memory, so
/// the review and its duplicate check work without asking iOS.
@MainActor
final class DemoImageDraftContacts: ImageDraftContactsDestination {
    var access: ImageDraftAccess = .granted
    private(set) var records: [DeviceContactRecord] = [
        DeviceContactRecord(id: "demo-contact-riley", givenName: "Riley", familyName: "Moss", organization: "Sample Studio",
                            emails: [DeviceContactLabeledValue(label: "work", value: "riley.moss@example.org")]),
    ]
    /// Which account each new contact went to, for tests.
    private(set) var containers: [String: String] = [:]

    static let accounts: [ImageDraftDestinationChoice] = [
        .init(destination: .init(kind: .contacts, identifier: "demo-container-icloud", label: "iCloud"),
              group: nil, colorHex: nil, isDefault: true),
        .init(destination: .init(kind: .contacts, identifier: "demo-container-gmail", label: "Gmail"),
              group: nil, colorHex: nil, isDefault: false),
        .init(destination: .init(kind: .contacts, identifier: "demo-container-local", label: "On My iPhone"),
              group: nil, colorHex: nil, isDefault: false),
    ]

    func requestAccess() async -> ImageDraftAccess { access }

    func choices() async throws -> [ImageDraftDestinationChoice] {
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        return Self.accounts
    }

    func create(_ fields: ContactDraftFields, in containerID: String?) async throws -> String {
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        let container = containerID ?? "demo-container-icloud"
        guard Self.accounts.contains(where: { $0.destination.identifier == container }) else {
            throw ImageDraftDestinationError.destinationUnavailable
        }
        let change = LiveImageDraftContacts.change(fields.normalized())
        let record = DeviceContactRecord(id: "demo-contact-\(UUID().uuidString.lowercased())").applying(change)
        records.append(record)
        containers[record.id] = container
        return record.id
    }

    func readBack(id: String) async throws -> DeviceContactRecord? {
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        return records.first { $0.id == id }
    }

    func candidates(for fields: ContactDraftFields, limit: Int) async throws -> [DeviceContactRecord] {
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        return Array(records.filter { ImageDraftMatch.isDuplicate($0, of: fields) }.prefix(limit))
    }
}

/// Demo mode's Calendar: Home, Work and Family under iCloud and Personal under Gmail.
@MainActor
final class DemoImageDraftCalendar: ImageDraftCalendarDestination {
    var access: ImageDraftAccess = .granted
    private(set) var events: [ImageDraftEventRecord] = []
    /// Which calendar each new event went to, for tests.
    private(set) var calendars: [String: String] = [:]

    static let calendarChoices: [ImageDraftDestinationChoice] = [
        .init(destination: .init(kind: .calendar, identifier: "demo-calendar-home", label: "Home"),
              group: "iCloud", colorHex: "#34C759", isDefault: true),
        .init(destination: .init(kind: .calendar, identifier: "demo-calendar-work", label: "Work"),
              group: "iCloud", colorHex: "#007AFF", isDefault: false),
        .init(destination: .init(kind: .calendar, identifier: "demo-calendar-family", label: "Family"),
              group: "iCloud", colorHex: "#FF9500", isDefault: false),
        .init(destination: .init(kind: .calendar, identifier: "demo-calendar-personal", label: "Personal"),
              group: "Gmail", colorHex: "#AF52DE", isDefault: false),
    ]

    func requestAccess() async -> ImageDraftAccess { access }

    func choices() async throws -> [ImageDraftDestinationChoice] {
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        return Self.calendarChoices
    }

    func create(_ plan: ImageDraftEventPlan, in calendarID: String?) async throws -> String {
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        let calendar = calendarID ?? "demo-calendar-home"
        guard Self.calendarChoices.contains(where: { $0.destination.identifier == calendar }) else {
            throw ImageDraftDestinationError.destinationUnavailable
        }
        let record = ImageDraftEventRecord(id: "demo-event-\(UUID().uuidString.lowercased())", title: plan.title,
                                           start: plan.start, isAllDay: plan.isAllDay)
        events.append(record)
        calendars[record.id] = calendar
        return record.id
    }

    func readBack(id: String) async throws -> ImageDraftEventRecord? {
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        return events.first { $0.id == id }
    }

    func events(from start: Date, to end: Date) async throws -> [ImageDraftEventRecord] {
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        return events.filter { $0.start >= start && $0.start < end }
    }
}

extension ImageDraftWriter {
    /// `-test-image-drafts-no-access` starts the demo as if bighelp hadn't asked for Contacts or
    /// Calendar: the review shows the default account, and Save opens Apple's own screen.
    static func demo(arguments: [String]) -> ImageDraftWriter {
        let contacts = DemoImageDraftContacts()
        let calendar = DemoImageDraftCalendar()
        if arguments.contains("-test-image-drafts-no-access") {
            contacts.access = .notDetermined
            calendar.access = .notDetermined
        }
        return ImageDraftWriter(contacts: contacts, calendar: calendar)
    }
}
