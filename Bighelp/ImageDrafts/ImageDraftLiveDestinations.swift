@preconcurrency import Contacts
@preconcurrency import EventKit
import CoreGraphics
import Foundation

// MARK: - Contacts

/// The real address book. Reads and saves run off the main actor, because Apple says they block;
/// iOS's answer to the access question comes on its own queue, so its callback is Sendable.
@MainActor
final class LiveImageDraftContacts: ImageDraftContactsDestination {
    private let store = CNContactStore()

    var access: ImageDraftAccess {
        Self.access(LiveDeviceContactsProvider.mapAuthorization(CNContactStore.authorizationStatus(for: .contacts)))
    }

    /// Limited access still adds contacts (iOS shares the new one with bighelp).
    nonisolated static func access(_ authorization: DeviceContactsAuthorization) -> ImageDraftAccess {
        switch authorization {
        case .authorized, .limited: .granted
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        }
    }

    func requestAccess() async -> ImageDraftAccess {
        let store = store
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            store.requestAccess(for: .contacts) { @Sendable granted, _ in continuation.resume(returning: granted) }
        }
        return access
    }

    func choices() async throws -> [ImageDraftDestinationChoice] {
        let store = store
        return try await Task.detached(priority: .userInitiated) {
            try Self.requireAccess()
            let containers: [CNContainer]
            do { containers = try store.containers(matching: nil) } catch { throw ImageDraftDestinationError.destinationUnavailable }
            let defaultID = store.defaultContainerIdentifier()
            return containers.map { container in
                ImageDraftDestinationChoice(
                    destination: ImageDraftDestination(kind: .contacts, identifier: container.identifier,
                                                       label: container.name.isEmpty ? Self.name(for: container.type) : container.name),
                    group: nil, colorHex: nil, isDefault: container.identifier == defaultID)
            }
            .sorted { ($0.isDefault ? 0 : 1, $0.destination.label) < ($1.isDefault ? 0 : 1, $1.destination.label) }
        }.value
    }

    private nonisolated static func name(for type: CNContainerType) -> String {
        switch type {
        case .local: "On this device"
        case .exchange: "Exchange"
        case .cardDAV: "CardDAV"
        default: "Contacts"
        }
    }

    func create(_ fields: ContactDraftFields, in containerID: String?) async throws -> String {
        let store = store
        let change = Self.change(fields.normalized())
        return try await Task.detached(priority: .userInitiated) {
            try Self.requireAccess()
            if let containerID {
                let found = (try? store.containers(matching: CNContainer.predicateForContainers(withIdentifiers: [containerID]))) ?? []
                guard !found.isEmpty else { throw ImageDraftDestinationError.destinationUnavailable }
            }
            let contact = CNMutableContact()
            LiveDeviceContactsProvider.apply(change, to: contact)
            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: containerID)
            // Right before the save: iOS may have withdrawn access during the wait.
            try Self.requireAccess()
            do { try store.execute(request) } catch { throw ImageDraftDestinationError.writeFailed }
            return contact.identifier
        }.value
    }

    func readBack(id: String) async throws -> DeviceContactRecord? {
        let store = store
        return try await Task.detached(priority: .userInitiated) {
            try Self.requireAccess()
            do {
                return LiveDeviceContactsProvider.record(from: try store.unifiedContact(withIdentifier: id, keysToFetch: Self.keys))
            } catch let error as NSError where error.domain == CNErrorDomain
                        && error.code == CNError.Code.recordDoesNotExist.rawValue {
                return nil
            }
        }.value
    }

    func candidates(for fields: ContactDraftFields, limit: Int) async throws -> [DeviceContactRecord] {
        let store = store
        let fields = fields.normalized()
        return try await Task.detached(priority: .userInitiated) {
            try Self.requireAccess()
            var predicates: [NSPredicate] = fields.emails.map { CNContact.predicateForContacts(matchingEmailAddress: $0.value) }
            predicates += fields.phones.map { CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: $0.value)) }
            if let name = fields.displayName { predicates.append(CNContact.predicateForContacts(matchingName: name)) }
            var seen = Set<String>()
            var records: [DeviceContactRecord] = []
            for predicate in predicates where records.count < limit {
                let found = (try? store.unifiedContacts(matching: predicate, keysToFetch: Self.keys)) ?? []
                for contact in found where records.count < limit && seen.insert(contact.identifier).inserted {
                    records.append(LiveDeviceContactsProvider.record(from: contact))
                }
            }
            return records
        }.value
    }

    private nonisolated static var keys: [CNKeyDescriptor] { LiveDeviceContactsProvider.keyNames.map { $0 as CNKeyDescriptor } }

    private nonisolated static func requireAccess() throws {
        guard access(LiveDeviceContactsProvider.mapAuthorization(CNContactStore.authorizationStatus(for: .contacts))) == .granted else {
            throw ImageDraftDestinationError.permissionDenied
        }
    }

    /// The reviewed fields as the phone tool's contact change, so both write contacts the same way.
    /// A business card's address is a work address.
    nonisolated static func change(_ fields: ContactDraftFields) -> DeviceContactChange {
        var change = DeviceContactChange()
        change.givenName = fields.givenName
        change.familyName = fields.familyName
        change.organization = fields.organization
        change.jobTitle = fields.jobTitle
        change.phones = fields.phones.map {
            DeviceContactLabeledValue(label: $0.label.map { DeviceContactLabels.contactsLabel($0, kind: .phone) }, value: $0.value)
        }
        change.emails = fields.emails.map {
            DeviceContactLabeledValue(label: $0.label.map { DeviceContactLabels.contactsLabel($0, kind: .other) }, value: $0.value)
        }
        if let address = fields.postalAddress {
            change.addresses = [DeviceContactAddress(
                label: CNLabelWork, street: address.street ?? "", city: address.city ?? "", region: address.region ?? "",
                postalCode: address.postalCode ?? "", country: address.country ?? "")]
        }
        return change
    }
}

// MARK: - Calendar

/// EventKit. Reads and saves are quick and stay on the main actor with the store, as the phone
/// tool's calendar does.
@MainActor
final class LiveImageDraftCalendar: ImageDraftCalendarDestination {
    private let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    var access: ImageDraftAccess { Self.access(EKEventStore.authorizationStatus(for: .event)) }

    /// Write-only access can't list calendars or read the event back, so it counts as no access.
    nonisolated static func access(_ status: EKAuthorizationStatus) -> ImageDraftAccess {
        switch status {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        case .writeOnly, .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    func requestAccess() async -> ImageDraftAccess {
        _ = try? await store.requestFullAccessToEvents()
        return access
    }

    func choices() async throws -> [ImageDraftDestinationChoice] {
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event).filter(\.allowsContentModifications).map { calendar in
            ImageDraftDestinationChoice(
                destination: ImageDraftDestination(kind: .calendar, identifier: calendar.calendarIdentifier, label: calendar.title),
                group: calendar.source?.title, colorHex: Self.hex(calendar.cgColor),
                isDefault: calendar.calendarIdentifier == defaultID)
        }
        .sorted { ($0.group ?? "", $0.destination.label) < ($1.group ?? "", $1.destination.label) }
    }

    func create(_ plan: ImageDraftEventPlan, in calendarID: String?) async throws -> String {
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        let target: EKCalendar?
        if let calendarID { target = store.calendar(withIdentifier: calendarID) } else { target = store.defaultCalendarForNewEvents }
        guard let target, target.allowsContentModifications else { throw ImageDraftDestinationError.destinationUnavailable }
        let event = EKEvent(eventStore: store)
        event.calendar = target
        event.title = plan.title
        event.location = plan.location
        event.notes = plan.notes
        event.isAllDay = plan.isAllDay
        event.startDate = plan.start
        // Calendar keeps an all-day event's end inside its last day.
        event.endDate = plan.isAllDay ? plan.end.addingTimeInterval(-1) : plan.end
        event.timeZone = plan.timeZone
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        do { try store.save(event, span: .thisEvent, commit: true) } catch { throw ImageDraftDestinationError.writeFailed }
        let identifier: String? = event.eventIdentifier
        return identifier ?? event.calendarItemIdentifier
    }

    func readBack(id: String) async throws -> ImageDraftEventRecord? {
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        return store.event(withIdentifier: id).map(Self.record)
    }

    func events(from start: Date, to end: Date) async throws -> [ImageDraftEventRecord] {
        guard access == .granted else { throw ImageDraftDestinationError.permissionDenied }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(Self.record)
    }

    private static func record(_ event: EKEvent) -> ImageDraftEventRecord {
        let identifier: String? = event.eventIdentifier
        return ImageDraftEventRecord(id: identifier ?? event.calendarItemIdentifier, title: event.title ?? "",
                                     start: event.startDate, isAllDay: event.isAllDay)
    }

    /// `#RRGGBB` in sRGB.
    nonisolated static func hex(_ color: CGColor?) -> String? {
        guard let color, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let parts = converted.components, parts.count >= 3 else { return nil }
        let bytes = parts.prefix(3).map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }
}
