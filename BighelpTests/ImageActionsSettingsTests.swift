import Foundation
import Testing
@testable import Bighelp

/// Photo actions settings and their message templates (docs/IMAGE_DRAFTS.md › Photo actions
/// settings), checked the way the plugin checks them.
struct ImageActionsSettingsTests {
    // MARK: Templates (B14)

    @Test func eachMessageTakesOnlyItsOwnPlaceholders() throws {
        try ImageActionTemplate.validate("Saved {{name}} to {{destination}}.", for: .saved)
        try ImageActionTemplate.validate("Please check: {{fields}}.", for: .missingFields)
        try ImageActionTemplate.validate("Odd {braces} are plain text.", for: .outcomeUnknown)
        #expect(throws: ImageActionTemplateError.unknownPlaceholder("name")) {
            try ImageActionTemplate.validate("Saving {{name}}", for: .review)
        }
        #expect(throws: ImageActionTemplateError.unknownPlaceholder("destination")) {
            try ImageActionTemplate.validate("Check {{destination}}", for: .outcomeUnknown)
        }
        #expect(throws: ImageActionTemplateError.unknownPlaceholder("phone")) {
            try ImageActionTemplate.validate("{{phone}}", for: .failed)
        }
        for unbalanced in ["{{reason}", "{{reason", "reason}}", "{{ reason }}", "{{{reason}}}", "{{}}", "{{Reason}}"] {
            #expect(throws: ImageActionTemplateError.unbalanced) { try ImageActionTemplate.validate(unbalanced, for: .failed) }
        }
        #expect(throws: ImageActionTemplateError.empty) { try ImageActionTemplate.validate("  \n ", for: .failed) }
        #expect(throws: ImageActionTemplateError.tooLong) {
            try ImageActionTemplate.validate(String(repeating: "a", count: 501), for: .failed)
        }
        #expect(throws: ImageActionTemplateError.notPlainText) { try ImageActionTemplate.validate("Bell\u{7}", for: .failed) }
    }

    @Test func substitutionHappensOnceAndNeverReadsValuesAsPlaceholders() {
        let text = ImageActionTemplate.render("Saved {{name}} to {{destination}}.",
                                              values: ["name": "{{destination}}", "destination": "iCloud"])
        #expect(text == "Saved {{destination}} to iCloud.")
        #expect(ImageActionTemplate.render("That didn't save. {{reason}}", values: ["reason": "No\u{0}access"])
                == "That didn't save. No access")
        // Markup and links stay as written; the view shows plain text.
        #expect(ImageActionTemplate.render("[Open](https://example.com) {{name}}", values: ["name": "**Riley**"])
                == "[Open](https://example.com) **Riley**")
    }

    // MARK: Settings (F10, F11)

    @Test func defaultsAreTheContractsTable() {
        let card = ImageActionsSettings().effective(.businessCard)
        #expect(card.offer)
        #expect(card.question == "Do you want a contact from this card?")
        #expect(card.messages.saved == "Saved {{name}} to {{destination}}.")
        let poster = ImageActionsSettings().effective(.eventPoster)
        #expect(poster.instructions == "Read the event's title, date, time and place. Don't guess a missing year, time zone or end time.")
        #expect(poster.messages.outcomeUnknown == "It's not clear the event saved. Check Calendar before you try again.")
    }

    @Test func overridesApplyAndResetRemovesThem() throws {
        var settings = ImageActionsSettings(revision: 4)
        settings.set(question: "Make a calendar event from this poster?", for: .eventPoster)
        settings.set(message: "Added {{name}} to {{destination}}. Enjoy!", .saved, for: .eventPoster)
        settings.set(offer: false, for: .businessCard)
        // Setting a value back to its default stores nothing.
        settings.set(instructions: ImageActionsDefaults.standard[.businessCard].instructions, for: .businessCard)
        #expect(settings[.businessCard] == ImageActionsPresetOverrides(offer: false))
        #expect(settings.effective(.eventPoster).question == "Make a calendar event from this poster?")
        #expect(settings.effective(.eventPoster).messages.saved == "Added {{name}} to {{destination}}. Enjoy!")
        #expect(settings.effective(.eventPoster).messages.review == ImageActionsDefaults.standard[.eventPoster].messages.review)
        try settings.validate()
        let roundTrip = try ImageActionsSettings(json: settings.json)
        #expect(roundTrip == settings)
        settings.reset(.eventPoster)
        #expect(settings.effective(.eventPoster) == ImageActionsDefaults.standard[.eventPoster])
        #expect(settings.effective(.businessCard).offer == false)
        settings.resetAll()
        #expect(settings.presets.isEmpty)
    }

    @Test func theDocumentIsCheckedAsThePluginChecksIt() throws {
        let good: BighelpJSONValue = .object([
            "schemaVersion": .integer(1), "revision": .integer(4),
            "presets": .object([
                "business_card": .object(["offer": .boolean(true), "instructions": .null, "question": .null,
                                          "messages": .object(["review": .null, "saved": .null])]),
                "event_poster": .object(["offer": .boolean(true), "instructions": .string("Read the date carefully."),
                                         "messages": .object(["review": .string("Check {{destination}}.")])]),
            ]),
        ])
        let settings = try ImageActionsSettings(json: good)
        #expect(settings.revision == 4)
        #expect(settings[.businessCard] == ImageActionsPresetOverrides(offer: true))
        #expect(settings[.eventPoster].messages == [.review: "Check {{destination}}."])

        func refuses(_ change: (inout [String: BighelpJSONValue]) -> Void) {
            var root = good.object!
            change(&root)
            #expect(throws: ImageActionsSettingsError.self) { try ImageActionsSettings(json: .object(root)) }
        }
        refuses { $0["schemaVersion"] = .integer(2) }
        refuses { $0["extra"] = .boolean(true) }
        refuses { $0["presets"] = .object(["receipt": .object([:])]) }
        refuses { $0["presets"] = .object(["business_card": .object(["offer": .string("yes")])]) }
        refuses { $0["presets"] = .object(["business_card": .object(["question": .string("   ")])]) }
        refuses { $0["presets"] = .object(["business_card": .object(["question": .string(String(repeating: "a", count: 501))])]) }
        refuses { $0["presets"] = .object(["business_card": .object(["instructions": .string(String(repeating: "a", count: 4_001))])]) }
        refuses { $0["presets"] = .object(["business_card": .object(["messages": .object(["review": .string("{{name}}")])])]) }
        refuses { $0["presets"] = .object(["business_card": .object(["messages": .object(["signature": .string("Hi")])])]) }
        // 16 KiB for the whole document.
        var big = ImageActionsSettings()
        big.set(instructions: String(repeating: "a", count: 4_000), for: .businessCard)
        big.set(instructions: String(repeating: "b", count: 4_000), for: .eventPoster)
        for key in ImageActionMessageKey.allCases {
            big.set(message: String(repeating: "c", count: 500), key, for: .businessCard)
            big.set(message: String(repeating: "d", count: 500), key, for: .eventPoster)
        }
        try big.validate()
        // 500 characters is a valid question, but four bytes each takes the document past 16 KiB.
        big.set(question: String(repeating: "🙂", count: 500), for: .businessCard)
        big.set(question: String(repeating: "🙂", count: 500), for: .eventPoster)
        #expect(throws: ImageActionsSettingsError.tooLarge) { try big.validate() }
    }

    @Test func aReplyThatDoesntReadKeepsWhatDoes() {
        let reply: BighelpJSONValue = .object([
            "schemaVersion": .integer(1), "revision": .integer(7),
            "presets": .object(["event_poster": .object(["question": .string("Add it?"), "messages": .object([
                "review": .string("{{nope}}"), "saved": .string("Added {{name}}."),
            ])])]),
        ])
        let settings = ImageActionsSettings.lenient(reply)
        #expect(settings.revision == 7)
        #expect(settings[.eventPoster].question == "Add it?")
        #expect(settings[.eventPoster].messages == [.saved: "Added {{name}}."])
        let defaults = ImageActionsDefaults.lenient(.object(["business_card": .object(["question": .string("A contact?")])]))
        #expect(defaults[.businessCard].question == "A contact?")
        #expect(defaults[.eventPoster] == ImageActionsDefaults.standard[.eventPoster])
    }
}
