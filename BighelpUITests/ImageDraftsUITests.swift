import XCTest

/// Photo drafts (`-test-image-drafts`): a made-up business card and event poster the person sent,
/// and the agent's draft of each, on the demo data. Nothing is written before Save; Discard writes
/// nothing; an event without an end can't be saved; each agent's Photo actions page edits its text.
///
/// BIGHELP_EVIDENCE=<folder> (TEST_RUNNER_BIGHELP_EVIDENCE through xcodebuild) also saves the
/// screenshots there as PNGs.
final class ImageDraftsUITests: BighelpUITestCase {
    @MainActor
    func testReviewingAndSavingAContactInLightAndDark() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let card = element("image-draft.card.business_card", in: app)
            XCTAssertTrue(card.waitForExistence(timeout: 15), "The contact draft shows in the chat (\(appearance))")
            let status = element("image-draft.card.status.business_card", in: app)
            XCTAssertTrue(status.waitForExistence(timeout: 5))
            XCTAssertTrue(status.label.contains("to check"), "The card says what to check: \(status.label)")
            save("image-draft-card-\(appearance)", app.screenshot())

            reveal(app.buttons["image-draft.card.review.business_card"].firstMatch, in: app).tap()
            let review = element("image-draft.review", in: app)
            XCTAssertTrue(review.waitForExistence(timeout: 5), "Review opens the sheet")
            XCTAssertTrue(element("image-draft.review.check", in: app).waitForExistence(timeout: 5),
                          "The app's own box lists what to check")
            XCTAssertTrue(element("image-draft.review.note", in: app).exists, "The agent's review note shows")
            XCTAssertTrue(element("image-draft.review.photo", in: app).exists, "The photo shows beside the fields")
            save("image-draft-review-\(appearance)", app.screenshot())

            if appearance == "light" {
                // Correct the email the agent read; it shows as the person's change.
                let email = app.textFields["image-draft.field.emails.0"].firstMatch
                XCTAssertTrue(reveal(email, in: app).waitForExistence(timeout: 5))
                // The caret at the end, then the old address deleted letter by letter.
                email.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
                let old = (email.value as? String) ?? ""
                email.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 2))
                email.typeText("riley@sample.example")
                XCTAssertEqual(email.value as? String, "riley@sample.example")
                XCTAssertTrue(element("image-draft.badge.edited", in: app).waitForExistence(timeout: 3),
                              "A corrected field says You changed")
                dismissKeyboard(in: app)
                save("image-draft-review-edited", app.screenshot())

                let saveButton = app.buttons["image-draft.review.save"].firstMatch
                XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
                XCTAssertTrue(saveButton.isEnabled, "A contact with a name can be saved")
                saveButton.tap()
                XCTAssertTrue(review.waitForNonExistence(timeout: 10), "Save closes the review")
                let saved = element("image-draft.card.status.business_card", in: app)
                XCTAssertTrue(waitFor(saved, label: "Saved", timeout: 10), "The card says it saved: \(saved.label)")
                XCTAssertFalse(app.buttons["image-draft.card.review.business_card"].exists, "A saved draft can't be saved again")
                save("image-draft-card-saved", app.screenshot())
            }
            app.terminate()
        }
    }

    @MainActor
    func testAnEventWithoutAnEndCantBeSavedUntilOneIsPicked() throws {
        let app = launch(appearance: "light")
        let review = app.buttons["image-draft.card.review.event_poster"].firstMatch
        XCTAssertTrue(reveal(review, in: app).waitForExistence(timeout: 15))
        review.tap()
        XCTAssertTrue(element("image-draft.review", in: app).waitForExistence(timeout: 5))
        let saveButton = app.buttons["image-draft.review.save"].firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        XCTAssertFalse(saveButton.isEnabled, "Add to Calendar stays off while the end is missing")
        XCTAssertTrue(element("image-draft.review.blocker", in: app).exists, "The reason shows under the buttons")
        save("image-draft-event-blocked", app.screenshot())

        let end = element("image-draft.field.end", in: app)
        reveal(end, in: app)
        end.buttons["Add"].firstMatch.tap()
        // A guessed start or time zone needs a look before saving, then Save turns on.
        for path in ["start", "time_zone", "end"] {
            let keep = app.buttons["image-draft.confirm.\(path)"].firstMatch
            if keep.exists { reveal(keep, in: app).tap() }
        }
        XCTAssertTrue(waitForEnabled(saveButton, timeout: 5), "With an end picked, Add to Calendar turns on")
        save("image-draft-event-ready", app.screenshot())
        saveButton.tap()
        let status = element("image-draft.card.status.event_poster", in: app)
        XCTAssertTrue(waitFor(status, label: "Added", timeout: 10), "The card says it was added: \(status.label)")
    }

    @MainActor
    func testDiscardWritesNothingAndSaysSo() throws {
        let app = launch(appearance: "dark")
        reveal(app.buttons["image-draft.card.review.business_card"].firstMatch, in: app).tap()
        let discard = app.buttons["image-draft.review.discard"].firstMatch
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        let confirm = app.buttons["image-draft.review.discard.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Discard asks once")
        confirm.tap()
        let status = element("image-draft.card.status.business_card", in: app)
        XCTAssertTrue(waitFor(status, label: "Nothing was saved", timeout: 10), "The card says nothing was saved: \(status.label)")
        save("image-draft-card-discarded", app.screenshot())
    }

    @MainActor
    func testClosingKeepsTheDraftAndItsChanges() throws {
        let app = launch(appearance: "light")
        reveal(app.buttons["image-draft.card.review.business_card"].firstMatch, in: app).tap()
        let title = app.textFields["image-draft.field.job_title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(" (kept)")
        dismissKeyboard(in: app)
        app.buttons["image-draft.review.close"].firstMatch.tap()
        XCTAssertTrue(element("image-draft.review", in: app).waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["image-draft.card.review.business_card"].firstMatch.exists, "Closing keeps the draft")
        app.buttons["image-draft.card.review.business_card"].firstMatch.tap()
        let reopened = app.textFields["image-draft.field.job_title"].firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 5))
        XCTAssertTrue((reopened.value as? String ?? "").hasSuffix("(kept)"), "The change is still there")
    }

    /// Without Contacts access the review saves to the default account through Contacts' own New
    /// Contact screen: its Cancel writes nothing and the draft waits; its Done is the Save.
    @MainActor
    func testWithoutAccessContactsOwnScreenIsTheSave() throws {
        let app = launch(appearance: "light", extra: ["-test-image-drafts-no-access"])
        reveal(app.buttons["image-draft.card.review.business_card"].firstMatch, in: app).tap()
        let destination = element("image-draft.review.destination", in: app)
        XCTAssertTrue(reveal(destination, in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(destination.label.contains("Default account"), "Without access it saves to the default account: \(destination.label)")
        XCTAssertTrue(app.buttons["image-draft.review.choose-destination"].firstMatch.exists, "Choose another asks iOS once")
        save("image-draft-review-no-access", app.screenshot())

        app.buttons["image-draft.review.save"].firstMatch.tap()
        // Contacts' own buttons have labels and no identifiers.
        let cancel = app.navigationBars["New Contact"].buttons.matching(NSPredicate(format: "label == %@", "Cancel")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Contacts' own New Contact screen opens")
        save("image-draft-contacts-new-contact", app.screenshot())
        cancel.tap()
        // A filled-in new contact asks before it throws the details away.
        let confirmDiscard = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Discard")).firstMatch
        if confirmDiscard.waitForExistence(timeout: 3) {
            save("image-draft-contacts-discard-confirm", app.screenshot())
            confirmDiscard.tap()
        }
        XCTAssertTrue(element("image-draft.review", in: app).waitForExistence(timeout: 5), "Cancel comes back to the review")
        app.buttons["image-draft.review.close"].firstMatch.tap()
        let status = element("image-draft.card.status.business_card", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertFalse(status.label.contains("Saved"), "Cancel wrote nothing: \(status.label)")

        reveal(app.buttons["image-draft.card.review.business_card"].firstMatch, in: app).tap()
        app.buttons["image-draft.review.save"].firstMatch.tap()
        let done = app.navigationBars["New Contact"].buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertTrue(waitFor(status, label: "Saved", timeout: 10), "Contacts' Done is the Save: \(status.label)")
        save("image-draft-card-saved-through-contacts", app.screenshot())
    }

    @MainActor
    func testPhotoActionsSettingsSaveAndReset() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let options = app.buttons["chat.options"].firstMatch
            XCTAssertTrue(options.waitForExistence(timeout: 20))
            options.tap()
            let thisChat = app.buttons["This chat"].firstMatch
            XCTAssertTrue(thisChat.waitForExistence(timeout: 5))
            thisChat.tap()
            // SwiftUI menu items take their title as their identifier.
            let edit = app.buttons["Edit this agent"].firstMatch
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            let row = app.buttons["agent.editor.photo-actions"].firstMatch
            XCTAssertTrue(revealBelow(row, in: app).waitForExistence(timeout: 10), "Photo actions sits beside Instructions")
            row.tap()
            XCTAssertTrue(element("photo-actions.page", in: app).waitForExistence(timeout: 5))
            XCTAssertTrue(app.switches["photo-actions.business_card.offer"].firstMatch.waitForExistence(timeout: 5))
            save("photo-actions-\(appearance)", app.screenshot())

            if appearance == "light" {
                revealBelow(app.buttons["photo-actions.event_poster.question"].firstMatch, in: app).tap()
                let editor = app.textViews["photo-actions.text.editor"].firstMatch
                XCTAssertTrue(editor.waitForExistence(timeout: 5))
                editor.tap()
                editor.typeText(" Which day?")
                app.buttons["photo-actions.text.save"].firstMatch.tap()
                XCTAssertTrue(element("photo-actions.page", in: app).waitForExistence(timeout: 5), "Save goes back to the page")
                let reset = app.buttons["photo-actions.event_poster.reset"].firstMatch
                XCTAssertTrue(revealBelow(reset, in: app).waitForExistence(timeout: 5), "An edited kind offers Reset to defaults")
                save("photo-actions-edited", app.screenshot())
                reset.tap()
                app.buttons["photo-actions.reset.confirm"].firstMatch.tap()
                XCTAssertTrue(reset.waitForNonExistence(timeout: 5), "Reset brings the defaults back")

                reveal(app.buttons["photo-actions.business_card.preview"].firstMatch, in: app).tap()
                XCTAssertTrue(element("photo-actions.preview", in: app).waitForExistence(timeout: 5))
                XCTAssertTrue(element("image-draft.review.check", in: app).exists, "The preview shows the app's own warning box")
                save("photo-actions-preview", app.screenshot())
            }
            app.terminate()
        }
    }

    // MARK: Helpers

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-image-drafts",
                               "-loopdy.home.opens-chat", "YES", "-loopdy.settings.nerd-mode", "NO",
                               "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Scrolls until the element is on screen (the chat starts at its newest message).
    @MainActor
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeDown(velocity: .slow)
        }
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        return element
    }

    /// Inside a sheet: only up, since a swipe down at the top closes the sheet.
    @MainActor
    @discardableResult
    private func revealBelow(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        for _ in 0..<8 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        return element
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", label)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                                timeout: timeout) == .completed
    }

    @MainActor
    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isEnabled == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                                timeout: timeout) == .completed
    }

    @MainActor
    private func dismissKeyboard(in app: XCUIApplication) {
        if app.keyboards.firstMatch.exists { app.keyboards.buttons["Return"].firstMatch.tap() }
        if app.keyboards.firstMatch.exists { app.swipeDown(velocity: .fast) }
    }

    @MainActor
    private func save(_ name: String, _ screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_EVIDENCE"] else { return }
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
