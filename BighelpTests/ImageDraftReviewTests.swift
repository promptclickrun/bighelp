import CryptoKit
import Foundation
import Testing
@testable import Bighelp

/// Made-up drafts shared by the photo-draft tests.
enum ImageDraftTestData {
    static let contactID = "d_0123456789abcdef0123456789abcdef"
    static let eventID = "d_abcdef0123456789abcdef0123456789"
    static let key = ImageDraftKey(scope: "computer-a", agentID: "default", sessionID: "session-1", draftID: contactID)
    static let eventKey = ImageDraftKey(scope: "computer-a", agentID: "default", sessionID: "session-1", draftID: eventID)
    static let iCloud = ImageDraftDestination(kind: .contacts, identifier: "container-icloud", label: "iCloud")
    static let home = ImageDraftDestination(kind: .calendar, identifier: "calendar-home", label: "Home")

    static func path(_ raw: String) -> ImageDraftFieldPath { ImageDraftFieldPath(known: raw) }

    /// Riley from Sample Studio: a hard-to-read email, no last name on the card.
    static var contact: ImageDraft {
        ImageDraft(draftID: contactID, preset: .businessCard,
                   source: ImageDraftSource(imageID: "fedcba9876543210fedcba9876543210", mimeType: "image/jpeg"),
                   configRevision: 1, messages: ImageActionsDefaults.standard[.businessCard].messages,
                   marks: [ImageDraftMark(field: path("emails.0"), reason: .unclear),
                           ImageDraftMark(field: path("family_name"), reason: .notInImage)],
                   fields: .contact(ContactDraftFields(
                       givenName: "Riley", organization: "Sample Studio",
                       phones: [ImageDraftLabeledValue(label: "work", value: "+1 555 0142")],
                       emails: [ImageDraftLabeledValue(label: "work", value: "riley@exarnple.com")])))
    }

    /// Night Market: the year is a guess and the poster has no end time.
    static var event: ImageDraft {
        ImageDraft(draftID: eventID, preset: .eventPoster,
                   source: ImageDraftSource(imageID: "0123456789abcdef0123456789abcdef", mimeType: "image/png"),
                   configRevision: 1, messages: ImageActionsDefaults.standard[.eventPoster].messages,
                   marks: [ImageDraftMark(field: path("start"), reason: .guessed),
                           ImageDraftMark(field: path("end"), reason: .notInImage)],
                   fields: .event(EventDraftFields(title: "Night Market", location: "Harbor Hall",
                                                   timing: .timed(.init(start: "2030-06-15T18:00:00Z", timeZone: "UTC")))))
    }

    /// A contact review the person finished: email corrected, destination chosen.
    static func readyContactReview() -> ImageDraftReview {
        var review = ImageDraftReview(draft: contact)
        review.contact?.emails[0].value = "riley@example.com"
        review.destination = iCloud
        return review
    }

    static func readyEventReview() -> ImageDraftReview {
        var review = ImageDraftReview(draft: event)
        review.event?.timing = .timed(.init(start: "2030-06-15T18:00:00Z", end: "2030-06-15T19:00:00Z", timeZone: "UTC"))
        review.confirm(path("start"))
        review.destination = home
        return review
    }
}

@MainActor
struct ImageDraftReviewTests {
    typealias Fixture = ImageDraftTestData

    // MARK: Provenance (F03)

    @Test func aCorrectedValueIsWhatIsApprovedAndTheOriginalIsKept() throws {
        var review = ImageDraftReview(draft: Fixture.contact)
        let email = Fixture.path("emails.0")
        #expect(review.provenance(at: email) == .image)
        #expect(review.badges(at: email) == [.check])
        review.contact?.emails[0].value = "riley@example.com"
        #expect(review.provenance(at: email) == .user)
        #expect(review.badges(at: email) == [.edited])
        #expect(review.originalText(at: email) == "riley@exarnple.com")
        review.destination = Fixture.iCloud
        let approval = try review.approval(key: Fixture.key)
        guard case .contact(let approved) = approval.fields else { Issue.record("Not a contact"); return }
        #expect(approved.emails.map(\.value) == ["riley@example.com"])
        #expect(approval.destination == Fixture.iCloud)
        #expect(approval.isIntact)
        #expect(UUID(uuidString: approval.decisionID)?.uuidString.lowercased() == approval.decisionID)
    }

    @Test func aGuessIsNeverShownAsReadFromThePhoto() {
        var review = ImageDraftReview(draft: Fixture.event)
        let start = Fixture.path("start")
        #expect(review.provenance(at: start) == .suggestion)
        #expect(review.badges(at: start) == [.guess])
        // Looking at it and keeping it resolves the mark but doesn't make it the person's value.
        review.confirm(start)
        #expect(review.badges(at: start).isEmpty)
        #expect(review.provenance(at: start) == .suggestion)
        #expect(review.badges(at: Fixture.path("end")) == [.missing])
        // A contact field the card didn't have is Missing, never a guess.
        #expect(ImageDraftReview(draft: Fixture.contact).badges(at: Fixture.path("family_name")) == [.missing])
    }

    @Test func theCheckListIsTheAppsOwnWhateverTheMessagesSay() {
        let review = ImageDraftReview(draft: Fixture.contact)
        #expect(review.checkList.map(\.text) == ["Last name: missing", "Email 1: hard to read"])
        #expect(review.missingFieldsMessage == "Please check: Last name, Email 1.")
        #expect(Fixture.readyContactReview().checkList.map(\.text) == ["Last name: missing"])
    }

    // MARK: Save rules (F07)

    @Test func saveStaysOffForAMissingEndAndAGuessedYear() throws {
        var review = ImageDraftReview(draft: Fixture.event)
        #expect(Set(review.saveBlockers) == [.missing(Fixture.path("end")), .unresolved(Fixture.path("start"), .guessed),
                                            .needsDestination])
        #expect(throws: ImageDraftReviewError.self) { try review.approval(key: Fixture.eventKey) }
        review.event?.timing = .timed(.init(start: "2030-06-15T18:00:00Z", end: "2030-06-15T17:00:00Z", timeZone: "UTC"))
        #expect(review.saveBlockers.contains(.invalid(Fixture.path("end"), .endBeforeStart)))
        #expect(review.saveBlockers.first { $0 == .invalid(Fixture.path("end"), .endBeforeStart) }?.message
                == "The end must be after the start.")
        let ready = Fixture.readyEventReview()
        #expect(ready.saveBlockers.isEmpty)
        _ = try ready.approval(key: Fixture.eventKey)
        // A changed start is the person's own value: no confirmation needed.
        var edited = ImageDraftReview(draft: Fixture.event)
        edited.event?.timing = .timed(.init(start: "2031-06-15T18:00:00Z", end: "2031-06-15T19:00:00Z", timeZone: "UTC"))
        edited.destination = Fixture.home
        #expect(edited.saveBlockers.isEmpty)
    }

    @Test func aContactNeedsANameAndValidPhonesAndEmails() {
        var review = Fixture.readyContactReview()
        #expect(review.saveBlockers.isEmpty)
        review.contact?.givenName = "  "
        review.contact?.organization = nil
        #expect(review.saveBlockers == [.needsName])
        #expect(review.saveBlockers.first?.message == "Add a first name, last name or company.")
        review.contact?.organization = "Sample Studio"
        review.contact?.phones[0].value = "555 0142 ext 3"
        review.contact?.emails[0].value = "riley@"
        #expect(Set(review.saveBlockers) == [.invalid(Fixture.path("phones.0"), .phone), .invalid(Fixture.path("emails.0"), .email)])
        // An emptied entry is dropped, not refused.
        review.contact?.phones[0].value = ""
        review.contact?.emails[0].value = "riley@example.com"
        #expect(review.saveBlockers.isEmpty)
        review.destination = Fixture.home
        #expect(review.saveBlockers == [.needsDestination])
    }

    @Test func conflictingValuesNeedAChoice() throws {
        let draft = ImageDraft(draftID: Fixture.contactID, preset: .businessCard, source: Fixture.contact.source, configRevision: 1,
                               messages: Fixture.contact.messages,
                               marks: [ImageDraftMark(field: Fixture.path("phones.0"), reason: .conflicting)],
                               fields: Fixture.contact.fields)
        var review = ImageDraftReview(draft: draft)
        review.destination = Fixture.iCloud
        #expect(review.saveBlockers == [.unresolved(Fixture.path("phones.0"), .conflicting)])
        review.confirm(Fixture.path("phones.0"))
        #expect(review.saveBlockers.isEmpty)
    }

    @Test func allDayKeepsTheDayAndGivesTheTimesBack() {
        var review = Fixture.readyEventReview()
        review.setAllDay(true)
        #expect(review.event?.timing == .allDay(.init(startDate: "2030-06-15")))
        #expect(review.requiredPaths.map(\.rawValue) == ["title", "start_date"])
        review.setAllDay(false)
        #expect(review.event?.timing == .timed(.init(start: "2030-06-15T18:00:00Z", end: "2030-06-15T19:00:00Z", timeZone: "UTC")))
    }

    @Test func editsComeBackAfterTheReviewCloses() {
        var review = Fixture.readyContactReview()
        review.confirm(Fixture.path("family_name"))
        let restored = ImageDraftReview(draft: Fixture.contact, edits: review.edits)
        #expect(restored == review)
        // Edits for the other kind of draft are ignored.
        #expect(ImageDraftReview(draft: Fixture.event, edits: review.edits).fields == Fixture.event.fields)
    }

    // MARK: Hash (F09)

    @Test func theHashCoversTheCanonicalJSONOfTheFields() {
        let fields = ImageDraftFields.contact(ContactDraftFields(
            givenName: " Riley ", familyName: "  ", phones: [ImageDraftLabeledValue(label: "work", value: "+1 555 0142")],
            emails: [ImageDraftLabeledValue(label: " ", value: " ")]))
        let canonical = #"{"given_name":"Riley","phones":[{"label":"work","value":"+1 555 0142"}]}"#
        #expect(String(decoding: ImageDraftHash.canonicalBytes(fields), as: UTF8.self) == canonical)
        let expected = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(ImageDraftHash.fieldsHash(fields) == expected)
        let event = ImageDraftFields.event(EventDraftFields(title: "Night Market", location: "Harbor Hall/Pier 4",
                                                           timing: .allDay(.init(startDate: "2030-06-15"))))
        #expect(String(decoding: ImageDraftHash.canonicalBytes(event), as: UTF8.self)
                == #"{"all_day":true,"location":"Harbor Hall/Pier 4","start_date":"2030-06-15","title":"Night Market"}"#)
    }

    @Test func editsAfterApprovalNeverChangeWhatIsWritten() throws {
        var review = Fixture.readyContactReview()
        let approval = try review.approval(key: Fixture.key)
        review.contact?.givenName = "Rory"
        #expect(review.fieldsHash != approval.fieldsHash)
        guard case .contact(let approved) = approval.fields else { Issue.record("Not a contact"); return }
        #expect(approved.givenName == "Riley")
        // A copy changed on disk no longer matches its hash.
        let encoded = String(decoding: try JSONEncoder().encode(approval), as: UTF8.self)
        let tampered = try JSONDecoder().decode(ImageDraftApproval.self, from: Data(encoded.replacingOccurrences(of: "Riley", with: "Rory").utf8))
        #expect(!tampered.isIntact)
    }

    // MARK: Messages

    @Test func messagesFillInOnceAsPlainText() {
        var review = Fixture.readyContactReview()
        #expect(review.message(.review) == "Check the details before saving to iCloud.")
        #expect(review.message(.failed, reason: .destinationUnavailable)
                == "That didn't save. That account or calendar isn't available. Choose another one.")
        review.contact?.givenName = "{{destination}}"
        #expect(review.message(.saved) == "Saved {{destination}} to iCloud.")
    }
}
