import SwiftUI
import UIKit
@preconcurrency import Contacts
@preconcurrency import EventKit
#if canImport(ContactsUI)
@preconcurrency import ContactsUI
#endif
#if canImport(EventKitUI)
@preconcurrency import EventKitUI
#endif

/// What Apple's own new-contact or new-event screen reported. Its Done (or Add) is the person's
/// Save; Cancel writes nothing.
enum ImageDraftEditorResult: Equatable, Sendable {
    /// `recordID` is what the screen handed back. Calendar may hand back none when bighelp has no
    /// Calendar access, so the outcome says Calendar reported it saved instead of claiming a check.
    case saved(recordID: String?)
    case cancelled
}

/// The record Apple's screens start from, filled in with exactly the reviewed fields.
@MainActor
enum ImageDraftNativeRecords {
    static func contact(_ fields: ContactDraftFields) -> CNMutableContact {
        let fields = fields.normalized()
        let person = CNMutableContact()
        person.givenName = fields.givenName ?? ""
        person.familyName = fields.familyName ?? ""
        person.organizationName = fields.organization ?? ""
        person.jobTitle = fields.jobTitle ?? ""
        person.phoneNumbers = fields.phones.map {
            CNLabeledValue(label: DeviceContactLabels.contactsLabel($0.label ?? "mobile", kind: .phone), value: CNPhoneNumber(stringValue: $0.value))
        }
        person.emailAddresses = fields.emails.map {
            CNLabeledValue(label: DeviceContactLabels.contactsLabel($0.label ?? "work", kind: .other), value: $0.value as NSString)
        }
        if let address = fields.postalAddress, !address.isEmpty {
            let postal = CNMutablePostalAddress()
            postal.street = address.street ?? ""
            postal.city = address.city ?? ""
            postal.state = address.region ?? ""
            postal.postalCode = address.postalCode ?? ""
            postal.country = address.country ?? ""
            person.postalAddresses = [CNLabeledValue(label: CNLabelWork, value: postal)]
        }
        return person
    }

    static func event(_ plan: ImageDraftEventPlan, in store: EKEventStore) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.title = plan.title
        event.location = plan.location
        event.notes = plan.notes
        event.isAllDay = plan.isAllDay
        event.startDate = plan.start
        // EventKit's all-day end is the last day itself, not the next midnight.
        event.endDate = plan.isAllDay ? plan.end.addingTimeInterval(-1) : plan.end
        event.timeZone = plan.timeZone
        return event
    }
}

#if canImport(ContactsUI)
/// Contacts' own New Contact screen. It runs outside bighelp, so it saves without Contacts access,
/// into the default account, and its delegate hands back the saved contact (nil for Cancel).
struct ImageDraftContactEditor: UIViewControllerRepresentable {
    let fields: ContactDraftFields
    let onFinish: @MainActor (ImageDraftEditorResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = CNContactViewController(forNewContact: ImageDraftNativeRecords.contact(fields))
        controller.contactStore = CNContactStore()
        controller.delegate = context.coordinator
        controller.allowsActions = false
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency CNContactViewControllerDelegate {
        var onFinish: @MainActor (ImageDraftEditorResult) -> Void
        private var finished = false

        init(onFinish: @escaping @MainActor (ImageDraftEditorResult) -> Void) { self.onFinish = onFinish }

        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            // Contacts calls this once per screen; a second call must not report a second outcome.
            guard !finished else { return }
            finished = true
            if let contact { onFinish(.saved(recordID: contact.identifier.isEmpty ? nil : contact.identifier)) }
            else { onFinish(.cancelled) }
        }
    }
}
#endif

#if canImport(EventKitUI)
/// Calendar's own New Event screen, with its own calendar picker. Since iOS 17 it saves without
/// Calendar access; its delegate says Saved or Cancelled.
struct ImageDraftEventEditor: UIViewControllerRepresentable {
    let plan: ImageDraftEventPlan
    let onFinish: @MainActor (ImageDraftEditorResult) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = ImageDraftNativeRecords.event(plan, in: store)
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency EKEventEditViewDelegate {
        var onFinish: @MainActor (ImageDraftEditorResult) -> Void
        private var finished = false

        init(onFinish: @escaping @MainActor (ImageDraftEditorResult) -> Void) { self.onFinish = onFinish }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            guard !finished else { return }
            finished = true
            switch action {
            case .saved:
                let id = controller.event?.eventIdentifier
                onFinish(.saved(recordID: (id?.isEmpty ?? true) ? nil : id))
            case .canceled, .deleted:
                // A new event's screen has no Delete; anything but Saved wrote nothing.
                onFinish(.cancelled)
            @unknown default:
                onFinish(.cancelled)
            }
        }
    }
}
#endif
