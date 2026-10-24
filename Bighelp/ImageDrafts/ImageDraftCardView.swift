import SwiftUI
import UIKit
@preconcurrency import Contacts
#if canImport(ContactsUI)
@preconcurrency import ContactsUI
#endif

/// A contact or event draft from a photo, as a card under the agent's message: the photo, what was
/// read, what to check, and Review. When the person decides, the same card says what happened.
/// Its state comes from `ImageDraftStore`, so a decision redraws this card and nothing else.
@MainActor
struct ImageDraftCardView: View {
    let draft: ImageDraft
    /// The card's `content_hash`, checked against the plugin's record of the card it made.
    let cardHash: String?
    /// Whether the card's content still has that hash (worked out when the card was decoded).
    let isIntact: Bool

    @Environment(\.chatCardInteractions) private var interactions
    @Environment(\.openURL) private var openURL
    @State private var store = ImageDraftStore.shared
    @State private var isReviewing = false
    @State private var savedContact: ImageDraftSavedContact?
    @BighelpThemeReader private var theme

    private static let pictureSize: CGFloat = 48

    /// The chat this card is in, on the computer in use. Nil while the chat has no stored session
    /// yet: the card still shows; Review waits for it.
    private var key: ImageDraftKey? {
        guard let interactions, interactions.scope.isUsable,
              let sessionID = interactions.storedSessionID() else { return nil }
        return ImageDraftKey(scope: interactions.scope.authorityID, agentID: interactions.scope.profileID,
                             sessionID: sessionID, draftID: draft.draftID)
    }

    var body: some View {
        let key = key
        let status = key.map(store.status) ?? .unknown
        let review = ImageDraftReview(draft: draft, edits: key.flatMap(store.edits))
        VStack(alignment: .leading, spacing: BighelpTokens.space12) {
            HStack(spacing: BighelpTokens.space12) {
                picture(key)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kindTitle)
                        .font(.bighelp(.caption2, weight: .bold))
                        .tracking(0.7)
                        .textCase(.uppercase)
                        .foregroundStyle(theme.secondaryText)
                    Text(title(review))
                        .font(.bighelp(.headline))
                        .foregroundStyle(theme.primaryText)
                        .lineLimit(2)
                    if let subtitle = subtitle(review) {
                        Text(subtitle)
                            .font(.bighelp(.subheadline))
                            .foregroundStyle(theme.secondaryText)
                            .lineLimit(2)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            statusLine(status, review: review)
            action(status, key: key, review: review)
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(theme.surface, in: .rect(cornerRadius: BighelpCardDesignTokens.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpCardDesignTokens.cornerRadius, style: .continuous)
                .stroke(theme.border, lineWidth: 0.5)
        }
        .contextMenu { macMenu(status, key: key) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("image-draft.card.\(draft.preset.rawValue)")
        .task(id: key) {
            guard let key else { return }
            if !isIntact { store.markMismatched(key) }
            store.noteVisible(key, cardHash: cardHash)
            await store.loadImages(key, source: draft.source)
        }
        .bighelpSheet(isPresented: $isReviewing) {
            if let key {
                ImageDraftReviewSheet(draft: draft, key: key)
                    .bighelpSheetSize(.large)
            }
        }
        #if canImport(ContactsUI)
        .bighelpSheet(item: $savedContact) { saved in
            ImageDraftSavedContactSheet(contact: saved.contact)
                .ignoresSafeArea()
                .bighelpSheetSize(.standard)
        }
        #endif
    }

    // MARK: Parts

    private var kindTitle: String {
        draft.preset == .businessCard ? String(localized: "Contact draft") : String(localized: "Event draft")
    }

    private func title(_ review: ImageDraftReview) -> String {
        review.fields.displayName
            ?? (draft.preset == .businessCard ? String(localized: "New contact") : String(localized: "New event"))
    }

    private func subtitle(_ review: ImageDraftReview) -> String? {
        switch review.fields {
        case .contact(let contact):
            let parts = [contact.jobTitle, contact.organization].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .event(let event):
            let parts = [ImageDraftEventSummary.when(event), event.location].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    @ViewBuilder
    private func picture(_ key: ImageDraftKey?) -> some View {
        Group {
            if let key, let image = store.thumbnail(key) {
                // The whole card or poster, on a quiet tile: a square crop hid most of a wide card.
                ZStack {
                    theme.raisedSurface
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
            } else {
                ZStack {
                    theme.raisedSurface
                    Image(systemName: draft.preset == .businessCard ? "person.text.rectangle" : "calendar")
                        .font(.bighelp(.title3))
                        .foregroundStyle(theme.tertiaryText)
                }
            }
        }
        .frame(width: Self.pictureSize, height: Self.pictureSize)
        .clipShape(.rect(cornerRadius: 11, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func statusLine(_ status: ImageDraftStatus, review: ImageDraftReview) -> some View {
        switch status {
        case .unknown, .awaitingReview:
            let count = review.checkList.count
            if count > 0 {
                line(count == 1 ? String(localized: "1 thing to check") : String(localized: "\(count) things to check"),
                     systemImage: "circle.fill", color: theme.warning, small: true)
            } else {
                // Until the computer answers, the card doesn't claim that nothing was saved.
                line(status == .awaitingReview ? String(localized: "Ready for you to review. Nothing is saved yet.")
                                               : String(localized: "Ready for you to review."),
                     systemImage: nil, color: theme.secondaryText)
            }
        case .applying:
            HStack(spacing: BighelpTokens.space8) {
                ProgressView().controlSize(.small)
                Text("Saving…").font(.bighelp(.subheadline)).foregroundStyle(theme.secondaryText)
            }
            .accessibilityIdentifier("image-draft.card.status.\(draft.preset.rawValue)")
        case .saved(_, let recordID, let verified):
            line(savedText(review, recordID: recordID, verified: verified), systemImage: "checkmark.circle.fill",
                 color: theme.success)
        case .failed(let reason):
            line(review.message(.failed, reason: reason), systemImage: "xmark.circle.fill", color: theme.danger)
        case .outcomeUnknown:
            line(review.message(.outcomeUnknown), systemImage: "questionmark.circle.fill", color: theme.warning)
        case .discarded:
            line(String(localized: "Discarded. Nothing was saved."), systemImage: nil, color: theme.secondaryText)
        case .replaced:
            line(String(localized: "Replaced by a newer draft."), systemImage: nil, color: theme.secondaryText)
        case .mismatched:
            line(String(localized: "This card doesn't match the draft the agent made. Ask for it again."),
                 systemImage: "exclamationmark.triangle.fill", color: theme.warning)
        }
    }

    private func savedText(_ review: ImageDraftReview, recordID: String?, verified: Bool) -> String {
        let message = review.message(.saved)
        // Apple's screen said it saved, but without Calendar access bighelp can't look.
        guard !verified, recordID == nil else { return message }
        return draft.preset == .businessCard
            ? String(localized: "\(message) Contacts reported it saved.")
            : String(localized: "\(message) Calendar reported it saved.")
    }

    private func line(_ text: String, systemImage: String?, color: Color, small: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(small ? .system(size: 7) : .bighelp(.subheadline))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(.bighelp(.subheadline))
                .foregroundStyle(small ? color : (systemImage == nil ? theme.secondaryText : theme.primaryText))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("image-draft.card.status.\(draft.preset.rawValue)")
    }

    @ViewBuilder
    private func action(_ status: ImageDraftStatus, key: ImageDraftKey?, review: ImageDraftReview) -> some View {
        switch status {
        case .unknown, .awaitingReview, .failed:
            cardButton(String(localized: "Review"), prominent: true, identifier: "image-draft.card.review.\(draft.preset.rawValue)") {
                isReviewing = true
            }
            .disabled(key == nil)
        case .outcomeUnknown:
            cardButton(String(localized: "Check"), prominent: true, identifier: "image-draft.card.check.\(draft.preset.rawValue)") {
                isReviewing = true
            }
            .disabled(key == nil)
        case .saved(_, let recordID, _):
            if let recordID, let open = openAction(recordID: recordID, review: review) {
                cardButton(open.title, prominent: false, identifier: "image-draft.card.open.\(draft.preset.rawValue)", run: open.run)
            }
        case .applying, .discarded, .replaced, .mismatched:
            EmptyView()
        }
    }

    private func cardButton(_ title: String, prominent: Bool, identifier: String,
                            run: @escaping @MainActor () -> Void) -> some View {
        Button(action: run) {
            Text(title)
                .font(.bighelp(.body, weight: .semibold))
                .foregroundStyle(prominent ? theme.actionForeground : theme.primaryText)
                .frame(maxWidth: .infinity, minHeight: BighelpTokens.hitTarget)
                .background(prominent ? theme.action : theme.raisedSurface, in: .capsule)
                .overlay { if !prominent { Capsule().stroke(theme.border, lineWidth: 1) } }
                .contentShape(.capsule)
        }
        .bighelpPlainButtonStyle()
        .accessibilityIdentifier(identifier)
    }

    private func openAction(recordID: String, review: ImageDraftReview) -> (title: String, run: @MainActor () -> Void)? {
        switch review.fields {
        case .contact:
            guard BighelpCardContacts.canReadSaved else { return nil }
            return (String(localized: "Open in Contacts"), {
                savedContact = ImageDraftSavedContact.read(recordID)
            })
        case .event(let event):
            guard let url = ImageDraftEventSummary.calendarURL(event) else { return nil }
            return (String(localized: "Open in Calendar"), { openURL(url) })
        }
    }

    @ViewBuilder
    private func macMenu(_ status: ImageDraftStatus, key: ImageDraftKey?) -> some View {
        #if targetEnvironment(macCatalyst)
        switch status {
        case .unknown, .awaitingReview, .failed, .outcomeUnknown:
            Button("Review") { isReviewing = true }.disabled(key == nil)
        default:
            EmptyView()
        }
        #endif
    }
}

/// Short words for an event's time, for the card and the review's title.
enum ImageDraftEventSummary {
    static func when(_ event: EventDraftFields) -> String? {
        switch event.timing {
        case .timed(let timed):
            guard let start = timed.start.flatMap(ImageDraftEventTime.date) else { return nil }
            var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            style.timeZone = timed.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
            return start.formatted(style)
        case .allDay(let days):
            guard let first = days.startDate, let start = ImageDraftEventTime.startOfDay(first, in: .current) else {
                return nil
            }
            return start.formatted(date: .abbreviated, time: .omitted)
        }
    }

    /// Calendar on the event's day (`calshow:` takes seconds since 2001).
    static func calendarURL(_ event: EventDraftFields) -> URL? {
        let start: Date?
        switch event.timing {
        case .timed(let timed): start = timed.start.flatMap(ImageDraftEventTime.date)
        case .allDay(let days): start = days.startDate.flatMap { ImageDraftEventTime.startOfDay($0, in: .current) }
        }
        guard let start else { return nil }
        return URL(string: "calshow:\(Int(start.timeIntervalSinceReferenceDate))")
    }
}

/// A saved contact bighelp may read, for Open in Contacts.
struct ImageDraftSavedContact: Identifiable {
    let id = UUID()
    let contact: CNContact

    @MainActor
    static func read(_ identifier: String) -> ImageDraftSavedContact? {
        #if canImport(ContactsUI)
        guard BighelpCardContacts.canReadSaved,
              let contact = try? CNContactStore().unifiedContact(
                withIdentifier: identifier, keysToFetch: [CNContactViewController.descriptorForRequiredKeys()]) else {
            return nil
        }
        return ImageDraftSavedContact(contact: contact)
        #else
        return nil
        #endif
    }
}

#if canImport(ContactsUI)
/// Contacts' own card for a saved person, with Done.
private struct ImageDraftSavedContactSheet: UIViewControllerRepresentable {
    let contact: CNContact
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = CNContactViewController(for: contact)
        let dismiss = dismiss
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { _ in dismiss() })
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
#endif
