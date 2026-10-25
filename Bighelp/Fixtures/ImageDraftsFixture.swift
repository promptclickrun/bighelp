import UIKit

#if DEBUG
/// `-test-image-drafts`: the person sends a business card and an event poster (pictures drawn here,
/// with made-up text), and the agent answers with a contact draft (a hard-to-read phone, no last
/// name) and an event draft (a guessed year, no end time). Made-up people and places only.
enum ImageDraftsFixture {
    static let contactDraftID = "d_0123456789abcdef0123456789abcdef"
    static let eventDraftID = "d_abcdef0123456789abcdef0123456789"
    static let cardImageID = "fedcba9876543210fedcba9876543210"
    static let posterImageID = "0123456789abcdef0123456789abcdef"

    /// The pictures, also served by the demo computer's `image-drafts/source`.
    @MainActor
    static func registerImages(in client: DemoImageDraftsClient = .shared) {
        client.images[contactDraftID] = (businessCard, "image/png")
        client.images[eventDraftID] = (poster, "image/png")
    }

    /// A light card: name, company, a phone and an email.
    static var businessCard: Data {
        let size = CGSize(width: 1_050, height: 600)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.16, green: 0.42, blue: 0.55, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: size.height))
            draw("Riley", at: CGPoint(x: 80, y: 90), size: 76, weight: .bold)
            draw("Designer · Sample Studio", at: CGPoint(x: 80, y: 200), size: 40, weight: .medium)
            draw("+1 555 0142", at: CGPoint(x: 80, y: 360), size: 38, weight: .regular, alpha: 0.45)
            draw("riley@example.com", at: CGPoint(x: 80, y: 430), size: 38, weight: .regular)
        }
    }

    /// A dark poster: the event's name, a day without a year, a start time and a place.
    static var poster: Data {
        let size = CGSize(width: 800, height: 1_100)
        return UIGraphicsImageRenderer(size: size).pngData { context in
            UIColor(red: 0.12, green: 0.1, blue: 0.24, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 1, green: 0.78, blue: 0.3, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 520, y: 80, width: 180, height: 180))
            draw("NIGHT", at: CGPoint(x: 70, y: 340), size: 120, weight: .heavy, color: .white)
            draw("MARKET", at: CGPoint(x: 70, y: 480), size: 120, weight: .heavy, color: .white)
            draw("Saturday, June 15 · 6 PM", at: CGPoint(x: 70, y: 700), size: 44, weight: .semibold, color: .white)
            draw("Harbor Hall", at: CGPoint(x: 70, y: 780), size: 44, weight: .regular, color: .white)
        }
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: UIFont.Weight,
                             color: UIColor = .black, alpha: CGFloat = 1) {
        NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color.withAlphaComponent(alpha),
        ]).draw(at: point)
    }

    static var contactDraft: ImageDraft {
        ImageDraft(draftID: contactDraftID, preset: .businessCard,
                   source: ImageDraftSource(imageID: cardImageID, mimeType: "image/png", width: 1_050, height: 600),
                   configRevision: 1, messages: ImageActionsDefaults.standard[.businessCard].messages,
                   marks: [ImageDraftMark(field: ImageDraftFieldPath(known: "phones.0"), reason: .unclear),
                           ImageDraftMark(field: ImageDraftFieldPath(known: "family_name"), reason: .notInImage)],
                   fields: .contact(ContactDraftFields(
                       givenName: "Riley", organization: "Sample Studio", jobTitle: "Designer",
                       phones: [ImageDraftLabeledValue(label: "work", value: "+1 555 0142")],
                       emails: [ImageDraftLabeledValue(label: "work", value: "riley@example.com")])))
    }

    static var eventDraft: ImageDraft {
        ImageDraft(draftID: eventDraftID, preset: .eventPoster,
                   source: ImageDraftSource(imageID: posterImageID, mimeType: "image/png", width: 800, height: 1_100),
                   configRevision: 1, messages: ImageActionsDefaults.standard[.eventPoster].messages,
                   marks: [ImageDraftMark(field: ImageDraftFieldPath(known: "start"), reason: .guessed),
                           ImageDraftMark(field: ImageDraftFieldPath(known: "end"), reason: .notInImage)],
                   fields: .event(EventDraftFields(title: "Night Market", location: "Harbor Hall",
                                                   timing: .timed(.init(start: "2030-06-15T18:00:00Z", timeZone: "UTC")))))
    }

    /// A card holding one draft, fenced the way hosts deliver cards in a reply, with the hash the
    /// plugin would give it.
    static func fenced(_ draft: ImageDraft, title: String) -> String {
        var document: [String: BighelpJSONValue] = [
            "schema": .string("loopdy.card"), "version": .integer(1), "title": .string(title),
            "spoken_summary": .string("A draft is ready to review. Nothing is saved yet."), "data_sources": .array([]),
            // As the plugin makes it: the draft is the card's root and only element.
            "root": .string("draft"),
            "elements": .object([
                "draft": .object(["type": .string(draft.preset.cardType), "props": .object(draft.props),
                                  "children": .array([])]),
            ]),
        ]
        let hash = ImageDraftCardHash.contentHash(of: document) ?? String(repeating: "0", count: 64)
        document["content_hash"] = .string(hash)
        document["card_id"] = .string(String(hash.prefix(32)))
        document["origin"] = .string("live")
        document["created_at"] = .string("2026-10-24T12:00:00Z")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(BighelpJSONValue.object(document))) ?? Data()
        return "```\(ChatCardMessageProjection.fenceLanguage)\n" + String(decoding: json, as: UTF8.self) + "\n```"
    }
}

extension ConversationFixtures {
    static var imageDraftsPreview: SessionRecord {
        let agent = TimelineSender.agent(id: "finance", snapshot: .init(name: "Avery Park"))
        let person = TimelineSender.user(snapshot: .init(name: "You"))
        let pictures = [
            try? ChatAttachment(id: "image-drafts-card", fileName: "card.png", mimeType: "image/png",
                                data: ImageDraftsFixture.businessCard),
            try? ChatAttachment(id: "image-drafts-poster", fileName: "poster.png", mimeType: "image/png",
                                data: ImageDraftsFixture.poster),
        ].compactMap { $0 }
        let items = [
            TimelineItem(id: "image-drafts-q", role: .human, sender: person,
                         content: .message("Add this card to my contacts, and the market to my calendar."),
                         metadata: .init(sourceOrder: 1), attachments: pictures),
            TimelineItem(id: "image-drafts-contact", role: .assistant, sender: agent,
                         content: .message("Here's the contact. The phone number is hard to read and the card has no last name.\n\n"
                                           + ImageDraftsFixture.fenced(ImageDraftsFixture.contactDraft, title: "Riley")),
                         metadata: .init(sourceOrder: 10)),
            TimelineItem(id: "image-drafts-event", role: .assistant, sender: agent,
                         content: .message("And the market. The poster has no year or end time, so check those.\n\n"
                                           + ImageDraftsFixture.fenced(ImageDraftsFixture.eventDraft, title: "Night Market")),
                         metadata: .init(sourceOrder: 20)),
        ]
        return SessionRecord(id: "demo-finance", kind: .direct, agentIDs: ["finance"], title: "Photo drafts",
                             items: items, hasAcceptedMessage: true)
    }
}
#endif
