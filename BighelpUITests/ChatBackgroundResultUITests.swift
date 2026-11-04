import XCTest

/// Helpers and a background command reporting back in the demo (`-test-background-results`):
/// each shows as a card on the agent's side, and See results opens what each task reported.
final class ChatBackgroundResultUITests: BighelpUITestCase {
    @MainActor
    func testHelperResultsShowAsCardsWithTheirDetails() throws {
        try results(appearance: "light")
    }

    @MainActor
    func testHelperResultsInDarkMode() throws {
        try results(appearance: "dark")
    }

    @MainActor
    private func results(appearance: String) throws {
        continueAfterFailure = false
        let app = makeApp()
        app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                "-test-background-results", "-loopdy.demo.appearance", appearance]
        app.launch()

        let helpers = app.descendants(matching: .any)["chat.message.demo-background-results:row:3"].firstMatch
        XCTAssertTrue(helpers.waitForExistence(timeout: 20), "The helpers' report shows as a card.")
        XCTAssertEqual(helpers.staticTexts["chat.background-result.headline"].label, "2 of 3 helpers finished")
        let command = app.descendants(matching: .any)["chat.message.demo-background-results:row:7"].firstMatch
        XCTAssertTrue(command.exists, "The command's report shows as a card.")
        XCTAssertEqual(command.staticTexts["chat.background-result.headline"].label, "Command failed")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "ASYNC DELEGATION")).firstMatch.exists,
            "Hermes' report for the model never shows.")
        capture(app, "\(appearance)-1-cards")

        helpers.buttons["chat.background-result.open"].tap()
        let sheet = app.descendants(matching: .any)["chat.background-result.sheet"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "See results opens the details.")
        XCTAssertTrue(app.staticTexts["TASK 3 OF 3"].waitForExistence(timeout: 5))
        capture(app, "\(appearance)-2-details")
        app.buttons["chat.background-result.done"].tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "background-result-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_BACKGROUND_RESULT_SHOTS"], !directory.isEmpty {
            try? shot.pngRepresentation.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent("background-result-\(name).png"))
        }
    }
}
