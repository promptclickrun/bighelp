import XCTest

/// Photo drafts on a real, isolated Hermes with the bighelp plugin and a scripted model, started by
/// `Scripts/HostSignInMatrixProbe.py --modes drafts --plugin <plugin checkout>` (BIGHELP_SIGNIN_PROBE).
/// The app sends a made-up business card through Hermes' own upload, the plugin drafts it from that
/// picture, the review's Save writes to the simulator's Contacts, and the agent hears the outcome at
/// its next turn. Skipped without the probe.
final class ImageDraftsHostUITests: BighelpUITestCase {
    @MainActor
    func testAContactDraftFromAPhotoSavesOnceAndTheAgentHearsIt() throws {
        let app = try openChat()
        send("contact draft test", in: app)
        let card = app.descendants(matching: .any)["image-draft.card.business_card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 90), "The agent's draft shows as a card")
        save("drafts-1-card", app)

        let review = app.buttons["image-draft.card.review.business_card"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        XCTAssertTrue(app.descendants(matching: .any)["image-draft.review"].firstMatch.waitForExistence(timeout: 10))
        // The picture comes from the host's image-drafts/source, not from the message the phone kept.
        sleep(3)
        save("drafts-2-review", app)
        let saveButton = app.buttons["image-draft.review.save"].firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 10))
        saveButton.tap()
        // Without Contacts access, Contacts' own New Contact screen opens, and its Done is the Save.
        // Contacts' own buttons have labels and no identifiers.
        let done = app.navigationBars["New Contact"].buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch
        if done.waitForExistence(timeout: 8) {
            save("drafts-3-contacts-screen", app)
            done.tap()
        }
        let status = app.descendants(matching: .any)["image-draft.card.status.business_card"].firstMatch
        XCTAssertTrue(wait(for: status, labelContains: "Saved", timeout: 30), "The card says it saved: \(status.label)")
        XCTAssertFalse(app.buttons["image-draft.card.review.business_card"].exists, "A saved draft can't be saved again")
        save("drafts-4-saved", app)

        send("outcome test", in: app)
        XCTAssertTrue(message(containing: "Outcome note: saved.", in: app).waitForExistence(timeout: 60),
                      "The plugin told the agent the person saved it")
        save("drafts-5-agent-heard", app)
    }

    @MainActor
    func testAPhotoAloneGetsTheOfferAndTheAgentCantAddTheContactItself() throws {
        let app = try openChat()
        // The picture alone: Send takes a message with only an attachment.
        app.buttons["chat.send"].firstMatch.tap()
        let offer = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "contact")).firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 90), "A picture with no words gets the offer, not a draft")
        XCTAssertFalse(app.descendants(matching: .any)["image-draft.card.business_card"].exists, "No draft before the person says yes")
        save("drafts-offer-1", app)
        offer.tap()
        app.buttons["chat.generative-ui.selection.send"].firstMatch.tap()
        let card = app.descendants(matching: .any)["image-draft.card.business_card"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 90), "Saying yes makes the draft")
        save("drafts-offer-2-draft", app)

        send("direct contact test", in: app)
        let refused = message(containing: "review_required", in: app)
        let notOffered = message(containing: "Tool said:", in: app)
        XCTAssertTrue(notOffered.waitForExistence(timeout: 60), "The agent's own create got an answer")
        save("drafts-offer-3-direct-create", app)
        XCTAssertTrue(refused.exists, "In a chat with the person's picture the host refuses the agent's own create: \(notOffered.value ?? "")")
    }

    // MARK: Helpers

    private var probe: [String: String] = [:]

    @MainActor private func openChat() throws -> XCUIApplication {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes drafts")
        }
        probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == "drafts" else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        addUIInterruptionMonitor(withDescription: "System prompts") { dialog in
            for label in ["Continue", "Not Now", "Don't Allow"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                               "-test-draft-attachments", "business-card"]
        app.launch()
        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(try XCTUnwrap(probe["address"]))
        let connect = app.buttons["host-setup.connect-host"]
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
        let next = app.buttons["host-setup.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected")
        next.tap()
        let newChat = app.buttons.matching(NSPredicate(format: "identifier IN %@",
            ["sessions.empty.new-chat", "chat.home.new-chat", "chat.new-chat", "root.new-chat"])).firstMatch
        if newChat.waitForExistence(timeout: 10) {
            newChat.tap()
            confirmNewChatPicker(in: app)
        }
        XCTAssertTrue(app.textViews["chat.composer.text"].waitForExistence(timeout: 20), "A chat opens")
        XCTAssertTrue(app.descendants(matching: .any)["chat.draft-attachments"].firstMatch.waitForExistence(timeout: 10)
                      || app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "1 photo")).firstMatch.exists,
                      "The made-up business card waits in the message box")
        return app
    }

    @MainActor private func send(_ text: String, in app: XCUIApplication) {
        let composer = app.textViews["chat.composer.text"]
        composer.tap()
        composer.typeText(text)
        app.buttons["chat.send"].tap()
    }

    @MainActor private func message(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    @MainActor private func wait(for element: XCUIElement, labelContains text: String, timeout: TimeInterval) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text),
                                                         object: element)], timeout: timeout) == .completed
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
