import XCTest

/// Agents' apps (`-test-html-apps`) on the demo data: each is a card in the chat, Open App shows its
/// page, an answer from the page waits for the person's Send and arrives as their next message, and
/// a live app shows the data the demo computer serves.
///
/// BIGHELP_EVIDENCE=<folder> (TEST_RUNNER_BIGHELP_EVIDENCE through xcodebuild) also saves the
/// screenshots there as PNGs.
final class HTMLAppsUITests: BighelpUITestCase {
    @MainActor
    func testAnAnswerFromAnAppWaitsForSendAndReachesTheAgent() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance)
            let open = app.buttons.matching(identifier: "html-app.open").firstMatch
            XCTAssertTrue(reveal(open, in: app).waitForExistence(timeout: 15), "The app's card shows in the chat (\(appearance))")
            save("html-app-cards-\(appearance)", app.screenshot())

            open.tap()
            XCTAssertTrue(element("html-app.screen", in: app).waitForExistence(timeout: 5), "Open App covers the screen")
            let sendPick = app.webViews.buttons["Send my pick"].firstMatch
            XCTAssertTrue(sendPick.waitForExistence(timeout: 20), "The agent's page loads (\(appearance))")
            save("html-app-open-\(appearance)", app.screenshot())

            sendPick.tap()
            let panel = element("html-app.answer", in: app)
            XCTAssertTrue(panel.waitForExistence(timeout: 5), "The page's answer waits for the person")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "My answers to “Trip budget”"))
                .firstMatch.exists, "The panel shows the exact message")
            save("html-app-answer-\(appearance)", app.screenshot())

            if appearance == "dark" {
                app.buttons["html-app.answer.cancel"].firstMatch.tap()
                XCTAssertTrue(waitForGone(panel), "Cancel sends nothing")
                app.terminate()
                continue
            }
            app.buttons["html-app.answer.send"].firstMatch.tap()
            XCTAssertTrue(waitForGone(panel))
            XCTAssertTrue(app.webViews.staticTexts["Sent. You can change it and send again."].firstMatch
                .waitForExistence(timeout: 5), "The page learns the answer went")

            app.buttons["html-app.done"].firstMatch.tap()
            let sent = app.textViews.matching(NSPredicate(format: "value BEGINSWITH %@", "My answers to “Trip budget”:"))
                .firstMatch
            XCTAssertTrue(sent.waitForExistence(timeout: 10), "The answer is the person's next message")
            // The chat draws the "- " lines as a list, as it does a form's answer.
            XCTAssertTrue(sent.value.map { "\($0)".contains("Travel: $1,100") } ?? false, "It reads like a form answer")
            XCTAssertTrue(app.staticTexts["You sent an answer"].firstMatch.waitForExistence(timeout: 5),
                          "The card says it was answered")
            save("html-app-answered", app.screenshot())
            app.terminate()
        }
    }

    @MainActor
    func testALiveAppShowsTheComputersData() throws {
        let app = launch(appearance: "light")
        let open = app.buttons.matching(identifier: "html-app.open").element(boundBy: 1)
        XCTAssertTrue(reveal(open, in: app).waitForExistence(timeout: 15))
        open.tap()
        // Only the data has this text (the zone's name is drawn in capitals).
        XCTAssertTrue(app.webViews.staticTexts["Tuesday, 7:10 AM"].firstMatch.waitForExistence(timeout: 20),
                      "The page gets the app's data")
        let status = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Live, updated")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10), "The header says how fresh the data is")
        save("html-app-live", app.screenshot())
        app.buttons["html-app.done"].firstMatch.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5), "Done goes back to the chat")
    }

    // MARK: Helpers

    @MainActor
    private func launch(appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-html-apps",
                               "-start-chat", "-loopdy.settings.nerd-mode", "NO",
                               "-loopdy.demo.appearance", appearance]
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
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            app.swipeDown(velocity: .slow)
        }
        for _ in 0..<6 where !(element.exists && element.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        return element
    }

    @MainActor
    private func waitForGone(_ element: XCUIElement) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)],
                         timeout: 5) == .completed
    }

    private func save(_ name: String, _ screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_EVIDENCE"] else { return }
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
