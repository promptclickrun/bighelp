import Foundation
import Testing
@testable import Bighelp

/// `contact_draft` and `event_draft` card objects: exactly the props, fields, marks and limits in
/// docs/IMAGE_DRAFTS.md › Card objects, and one draft per card.
@MainActor
struct ImageDraftCardTests {
    static let draftID = "d_0123456789abcdef0123456789abcdef"

    static let messages: BighelpJSONValue = .object([
        "review": .string("Check the details before saving to {{destination}}."),
        "missing_fields": .string("Please check: {{fields}}."),
        "saved": .string("Saved {{name}} to {{destination}}."),
        "failed": .string("That didn't save. {{reason}}"),
        "outcome_unknown": .string("It's not clear the contact saved. Check Contacts before you try again."),
    ])

    static func contactProps(fields: [String: BighelpJSONValue] = ["given_name": .string("Riley")],
                             marks: [BighelpJSONValue] = []) -> [String: BighelpJSONValue] {
        [
            "draft_id": .string(draftID), "preset": .string("business_card"),
            "source": .object(["image_id": .string("fedcba9876543210fedcba9876543210"), "mime_type": .string("image/jpeg")]),
            "config_revision": .integer(1), "messages": messages, "marks": .array(marks), "fields": .object(fields),
        ]
    }

    static func eventProps(fields: [String: BighelpJSONValue], marks: [BighelpJSONValue] = []) -> [String: BighelpJSONValue] {
        var props = contactProps(fields: fields, marks: marks)
        props["preset"] = .string("event_poster")
        return props
    }

    // MARK: The plugin's fixture

    @Test func thePluginFixtureCardsValidateAndReadBack() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CardExamples/static-image-drafts.json")
        let documents = try JSONDecoder().decode([[String: BighelpJSONValue]].self, from: Data(contentsOf: url))
        #expect(documents.count == 2)
        let drafts = try documents.map { raw -> ImageDraft in
            try #require(ImageDraftCard.draft(in: try card(document: raw)))
        }
        guard case .contact(let contact) = drafts[0].fields, case .event(let event) = drafts[1].fields else {
            Issue.record("Wrong kinds of draft")
            return
        }
        #expect(contact.displayName == "Riley Moss")
        #expect(contact.phones.first?.value == "+1 555 0142")
        #expect(contact.postalAddress?.city == "Testville")
        #expect(drafts[0].marks(at: ImageDraftFieldPath(known: "phones.0")) == [.unclear])
        #expect(event.title == "Night Market")
        #expect(event.timing == .timed(.init(start: "2030-06-15T18:00:00Z", end: "2030-06-15T19:00:00Z", timeZone: "UTC")))
        #expect(drafts[1].source.width == nil)
    }

    /// Cards rendered by the plugin's own `render_card` (`rendered-image-drafts.json`, one with quotes,
    /// a backslash, accents, CJK and an emoji): the app works out the same hash. An edited copy that
    /// keeps the old hash is not intact.
    @Test @MainActor func theAppWorksOutThePluginsCardHash() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CardExamples/rendered-image-drafts.json")
        let documents = try JSONDecoder().decode([[String: BighelpJSONValue]].self, from: Data(contentsOf: url))
        #expect(documents.count == 3)
        for raw in documents {
            let card = try BighelpCardDocument(document: raw)
            #expect(ImageDraftCardHash.contentHash(of: raw) == raw["content_hash"]?.string)
            #expect(ImageDraftCardHash.isIntact(card))
        }
        var edited = documents[0]
        guard case .object(var elements)? = edited["elements"], case .object(var draft)? = elements["draft"],
              case .object(var props)? = draft["props"], case .object(var fields)? = props["fields"] else {
            Issue.record("Unexpected fixture shape")
            return
        }
        fields["emails"] = .array([.object(["label": .string("work"), "value": .string("someone@example.net")])])
        props["fields"] = .object(fields)
        draft["props"] = .object(props)
        elements["draft"] = .object(draft)
        edited["elements"] = .object(elements)
        #expect(!ImageDraftCardHash.isIntact(try BighelpCardDocument(document: edited)), "An edited copy with the old hash")
    }

    // MARK: Props

    @Test func aDraftNeedsItsServerMadePropsAndNothingElse() throws {
        try accepts("contact_draft", Self.contactProps())
        // `fields` and `marks` may be left out: an empty draft.
        var bare = Self.contactProps()
        bare["fields"] = nil
        bare["marks"] = nil
        try accepts("contact_draft", bare)
        for key in ["draft_id", "preset", "source", "config_revision", "messages"] {
            var props = Self.contactProps()
            props[key] = nil
            try refuses("contact_draft", props)
        }
        try refuses("contact_draft", Self.contactProps().merging(["note": .string("x")]) { $1 })
        // The preset must match the object.
        try refuses("event_draft", Self.contactProps())
        for bad in ["d_0123456789ABCDEF0123456789abcdef", "d_0123", "x_0123456789abcdef0123456789abcdef"] {
            try refuses("contact_draft", Self.contactProps().merging(["draft_id": .string(bad)]) { $1 })
        }
        try refuses("contact_draft", Self.contactProps().merging(["config_revision": .integer(0)]) { $1 })
        try refuses("contact_draft", Self.contactProps().merging(["source": .object([
            "image_id": .string("not-hex"), "mime_type": .string("image/jpeg")])]) { $1 })
        try refuses("contact_draft", Self.contactProps().merging(["source": .object([
            "image_id": .string("fedcba9876543210fedcba9876543210"), "mime_type": .string("text/html")])]) { $1 })
        try refuses("contact_draft", Self.contactProps().merging(["source": .object([
            "image_id": .string("fedcba9876543210fedcba9876543210"), "mime_type": .string("image/png"),
            "path": .string("/tmp/card.png")])]) { $1 })
    }

    @Test func messagesTakeOnlyTheirOwnPlaceholders() throws {
        func with(_ key: String, _ text: String) -> [String: BighelpJSONValue] {
            var messages = Self.messages.object!
            messages[key] = .string(text)
            return Self.contactProps().merging(["messages": .object(messages)]) { $1 }
        }
        try accepts("contact_draft", with("saved", "Done: {{name}} in {{destination}}."))
        try refuses("contact_draft", with("review", "Saving {{name}}."))
        try refuses("contact_draft", with("outcome_unknown", "Check {{destination}}."))
        try refuses("contact_draft", with("failed", "Oops {{reason}"))
        try refuses("contact_draft", with("failed", "   "))
        try refuses("contact_draft", with("failed", String(repeating: "a", count: 501)))
        var missing = Self.messages.object!
        missing["saved"] = nil
        try refuses("contact_draft", Self.contactProps().merging(["messages": .object(missing)]) { $1 })
    }

    // MARK: Contact fields

    @Test func contactFieldsFollowTheContract() throws {
        func fields(_ extra: [String: BighelpJSONValue]) -> [String: BighelpJSONValue] {
            Self.contactProps(fields: extra)
        }
        try accepts("contact_draft", fields(["given_name": .string(String(repeating: "a", count: 200))]))
        try refuses("contact_draft", fields(["given_name": .string(String(repeating: "a", count: 201))]))
        // Counted as the plugin counts: one scalar each.
        try accepts("contact_draft", fields(["organization": .string(String(repeating: "é", count: 200))]))
        try refuses("contact_draft", fields(["job_title": .string("Designer\nLead")]))
        try refuses("contact_draft", fields(["notes": .string("Met at the market")]))
        try refuses("contact_draft", fields(["given_name": .integer(3)]))
        let phone: (String) -> BighelpJSONValue = { .array([.object(["value": .string($0)])]) }
        try accepts("contact_draft", fields(["phones": phone("+1 (555) 014-2.0")]))
        try refuses("contact_draft", fields(["phones": phone("555 0142 ext 3")]))
        try refuses("contact_draft", fields(["phones": .array(Array(repeating: .object(["value": .string("5550142")]), count: 6))]))
        try refuses("contact_draft", fields(["phones": .array([.object(["value": .string("5550142"), "kind": .string("x")])])]))
        try refuses("contact_draft", fields(["phones": .array([.object(["label": .string(String(repeating: "a", count: 41)),
                                                                         "value": .string("5550142")])])]))
        try refuses("contact_draft", fields(["emails": .array([.object(["value": .string("riley@example")])])]))
        try accepts("contact_draft", fields(["emails": .array([.object(["value": .string("riley@example.com")])])]))
        try refuses("contact_draft", fields(["postal_address": .object(["planet": .string("Earth")])]))
        try refuses("contact_draft", fields(["postal_address": .object(["city": .string(String(repeating: "a", count: 101))])]))
    }

    @Test func marksNameRealFieldsWithKnownReasons() throws {
        func mark(_ field: String, _ reason: String = "unclear") -> BighelpJSONValue {
            .object(["field": .string(field), "reason": .string(reason)])
        }
        for good in ["given_name", "phones", "phones.0", "phones.4", "emails.1", "postal_address", "postal_address.postal_code"] {
            try accepts("contact_draft", Self.contactProps(marks: [mark(good)]))
        }
        for bad in ["phones.5", "phones.01", "phones.-1", "postal_address.planet", "given_name.0", "start", "notes", ""] {
            try refuses("contact_draft", Self.contactProps(marks: [mark(bad)]))
        }
        for reason in ["unclear", "guessed", "not_in_image", "conflicting"] {
            try accepts("contact_draft", Self.contactProps(marks: [mark("family_name", reason)]))
        }
        try refuses("contact_draft", Self.contactProps(marks: [mark("family_name", "blurry")]))
        try refuses("contact_draft", Self.contactProps(marks: [.object(["field": .string("given_name"),
                                                                        "reason": .string("unclear"), "note": .string("x")])]))
        try accepts("contact_draft", Self.contactProps(marks: Array(repeating: mark("given_name"), count: 20)))
        try refuses("contact_draft", Self.contactProps(marks: Array(repeating: mark("given_name"), count: 21)))
        try refuses("event_draft", Self.eventProps(fields: [:], marks: [mark("phones.0")]))
        try accepts("event_draft", Self.eventProps(fields: [:], marks: [mark("end", "not_in_image")]))
    }

    // MARK: Event fields

    @Test func anEventIsTimedOrAllDayNeverBoth() throws {
        let timed: [String: BighelpJSONValue] = ["title": .string("Night Market"), "all_day": .boolean(false),
                                                 "start": .string("2030-06-15T18:00:00Z"),
                                                 "end": .string("2030-06-15T19:00:00Z"), "time_zone": .string("UTC")]
        try accepts("event_draft", Self.eventProps(fields: timed))
        // `all_day` left out is timed.
        try accepts("event_draft", Self.eventProps(fields: timed.filter { $0.key != "all_day" }))
        try refuses("event_draft", Self.eventProps(fields: timed.merging(["start_date": .string("2030-06-15")]) { $1 }))
        try refuses("event_draft", Self.eventProps(fields: timed.merging(["all_day": .boolean(true)]) { $1 }))
        try refuses("event_draft", Self.eventProps(fields: timed.merging(["all_day": .string("no")]) { $1 }))
        let allDay: [String: BighelpJSONValue] = ["title": .string("Night Market"), "all_day": .boolean(true),
                                                  "start_date": .string("2030-06-15"), "end_date": .string("2030-06-17")]
        try accepts("event_draft", Self.eventProps(fields: allDay))
        try accepts("event_draft", Self.eventProps(fields: allDay.filter { $0.key != "end_date" }))
        try refuses("event_draft", Self.eventProps(fields: allDay.merging(["time_zone": .string("UTC")]) { $1 }))
        // End and time zone may be missing from the draft; the review asks for them.
        try accepts("event_draft", Self.eventProps(fields: ["title": .string("Night Market"),
                                                            "start": .string("2030-06-15T18:00:00+02:00")]))
    }

    @Test func eventValuesFollowTheContract() throws {
        func timed(_ start: String, _ end: String? = nil, zone: String? = nil) -> [String: BighelpJSONValue] {
            var fields: [String: BighelpJSONValue] = ["start": .string(start)]
            if let end { fields["end"] = .string(end) }
            if let zone { fields["time_zone"] = .string(zone) }
            return Self.eventProps(fields: fields)
        }
        try accepts("event_draft", timed("2030-06-15T18:00:00.250-07:00", "2030-06-15T19:00:00-07:00", zone: "America/Los_Angeles"))
        for bad in ["2030-06-15T18:00:00", "2030-06-15 18:00:00Z", "2030-06-15", "2030-02-30T18:00:00Z",
                    "2030-06-15T25:00:00Z", "2030-06-15T18:00:00+24:00", "June 15 2030"] {
            try refuses("event_draft", timed(bad))
        }
        try refuses("event_draft", timed("2030-06-15T19:00:00Z", "2030-06-15T18:00:00Z"))
        try refuses("event_draft", timed("2030-06-15T18:00:00Z", "2030-06-15T18:00:00Z"))
        try refuses("event_draft", timed("2030-06-15T18:00:00Z", zone: "Mars/Olympus"))
        try refuses("event_draft", timed("2030-06-15T18:00:00Z", zone: "UTC; rm"))
        func days(_ start: String, _ end: String?) -> [String: BighelpJSONValue] {
            var fields: [String: BighelpJSONValue] = ["all_day": .boolean(true), "start_date": .string(start)]
            if let end { fields["end_date"] = .string(end) }
            return Self.eventProps(fields: fields)
        }
        try refuses("event_draft", days("2030-06-15", "2030-06-15"))
        try refuses("event_draft", days("2030-06-15", "2030-06-14"))
        try refuses("event_draft", days("2031-02-29", nil))
        try refuses("event_draft", days("2030-6-15", nil))
        try accepts("event_draft", Self.eventProps(fields: ["title": .string(String(repeating: "a", count: 200))]))
        try refuses("event_draft", Self.eventProps(fields: ["title": .string(String(repeating: "a", count: 201))]))
        try refuses("event_draft", Self.eventProps(fields: ["title": .string("Night\nMarket")]))
        try accepts("event_draft", Self.eventProps(fields: ["location": .string("Harbor Hall\nPier 4")]))
        try refuses("event_draft", Self.eventProps(fields: ["location": .string(String(repeating: "a", count: 501))]))
        try refuses("event_draft", Self.eventProps(fields: ["notes": .string(String(repeating: "a", count: 2_001))]))
        try refuses("event_draft", Self.eventProps(fields: ["attendees": .array([])]))
    }

    // MARK: One draft per card

    @Test func aCardHoldsOneDraftAndNothingElseToActOn() throws {
        let draft = node("contact_draft", Self.contactProps())
        _ = try card(elements: ["root": node("card", ["title": .string("Riley Moss")], ["draft"]), "draft": draft])
        _ = try card(elements: ["root": node("card", ["title": .string("Riley Moss")], ["note", "draft"]),
                      "note": node("text", ["value": .object(["literal": .string("From your photo")])]), "draft": draft])
        var second = Self.contactProps()
        second["draft_id"] = .string("d_ffffffffffffffffffffffffffffffff")
        #expect(throws: BighelpCardValidationError.self) {
            try card(elements: ["root": node("card", ["title": .string("Two")], ["a", "b"]), "a": draft,
                      "b": node("contact_draft", second)])
        }
        #expect(throws: BighelpCardValidationError.self) {
            try card(elements: ["root": node("card", ["title": .string("Mixed")], ["a", "b"]), "a": draft,
                      "b": node("contact", ["name": .string("Riley Moss")])])
        }
        // Objects take no children.
        #expect(throws: BighelpCardValidationError.self) {
            try card(elements: ["root": node("contact_draft", Self.contactProps(), ["x"]),
                      "x": node("divider", [:])])
        }
    }

    // MARK: Speaker note

    @Test func theSpeakerNoteListsDraftsOnlyWithTheirFeature() {
        func renders(_ features: Set<String>) -> BighelpJSONValue? {
            DirectHermesChatSpeakerNote.payload(agentID: "a", storedSessionID: "s", personID: "p", name: "Riley",
                                                pluginFeatures: features)["renders"]
        }
        #expect(renders(["native-people-v1"]) == nil)
        // Drafts need both: an older plugin refuses names it doesn't know.
        #expect(renders(["native-image-drafts-v1"]) == nil)
        #expect(renders(["native-card-objects-v1"]) == .array([.string("contact"), .string("place"), .string("music")]))
        #expect(renders(["native-card-objects-v1", "native-image-drafts-v1"]) == .array([
            .string("contact"), .string("place"), .string("music"), .string("contact_draft"), .string("event_draft"),
        ]))
    }

    // MARK: Helpers

    private func accepts(_ type: String, _ props: [String: BighelpJSONValue],
                         sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(throws: Never.self, sourceLocation: sourceLocation) { try BighelpCardObjects.validate(type: type, props: props) }
    }

    private func refuses(_ type: String, _ props: [String: BighelpJSONValue],
                         sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(throws: BighelpCardValidationError.self, sourceLocation: sourceLocation) {
            try BighelpCardObjects.validate(type: type, props: props)
        }
    }

    private func node(_ type: String, _ props: [String: BighelpJSONValue], _ children: [String] = []) -> BighelpJSONValue {
        .object(["type": .string(type), "props": .object(props), "children": .array(children.map(BighelpJSONValue.string))])
    }

    @discardableResult
    private func card(elements: [String: BighelpJSONValue]) throws -> BighelpCardDocument {
        try card(document: ["schema": .string("loopdy.card"), "version": .integer(1), "title": .string("Draft"),
                  "spoken_summary": .string("A draft."), "data_sources": .array([]), "root": .string("root"),
                  "elements": .object(elements)])
    }

    private func card(document raw: [String: BighelpJSONValue]) throws -> BighelpCardDocument {
        var document = raw
        document["content_hash"] = .string(String(repeating: "a", count: 64))
        document["card_id"] = .string(String(repeating: "b", count: 32))
        document["origin"] = .string("live")
        document["created_at"] = .string("2026-09-02T12:00:00Z")
        return try BighelpCardValidator.validateForStaticRelease(BighelpCardDocument(document: document))
    }
}
