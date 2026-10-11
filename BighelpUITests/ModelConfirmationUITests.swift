import XCTest

/// The demo host refuses a model change until its exact warning is approved.
final class ModelConfirmationUITests: BighelpUITestCase {
    @MainActor
    func testPickingFromAProviderRequiresApproval() {
        checkApproval(bySearch: false, appearance: "light")
    }

    @MainActor
    func testPickingBySearchRequiresApproval() {
        checkApproval(bySearch: true, appearance: "dark")
    }

    @MainActor
    private func checkApproval(bySearch: Bool, appearance: String) {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-model-confirmation", "-loopdy.demo.appearance", appearance]
        app.launch()
        openPicker(in: app)
        evidence("model-picker-\(appearance)")
        selectModel(in: app, bySearch: bySearch)
        let approve = app.buttons["model-confirmation.approve"].firstMatch
        let approvalShown = approve.waitForExistence(timeout: 8)
        evidence("after-apply-\(appearance)")
        guard approvalShown else {
            XCTFail("The host's pending model warning must offer Approve and Cancel")
            return
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "train on prompts and completions")).firstMatch.exists)
        evidence("model-approval-\(appearance)")
        app.buttons["model-confirmation.cancel"].tap()
        XCTAssertTrue(approve.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chat.models.row.openai:gpt-5.6"].exists,
                      "Cancelling must leave the list usable, not stuck loading")
        app.buttons["Cancel"].firstMatch.tap()

        // Cancelling must not change the saved model, even after reopening.
        openPicker(in: app)
        XCTAssertTrue(selected(in: app).label.contains("Hermes"), selected(in: app).label)
        selectModel(in: app, bySearch: bySearch)
        XCTAssertTrue(approve.waitForExistence(timeout: 8))
        approve.tap()
        XCTAssertTrue(app.buttons["chat.session-controls.apply"].waitForNonExistence(timeout: 10),
                      "Only an accepted approval closes the picker")
        openPicker(in: app)
        XCTAssertTrue(selected(in: app).label.localizedCaseInsensitiveContains("GPT-5.6"), selected(in: app).label)
        app.terminate()
    }

    /// The model the chat will use, on top of the sheet.
    @MainActor
    private func selected(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["chat.models.selected"].firstMatch
    }

    @MainActor
    private func openPicker(in app: XCUIApplication) {
        openModelAndReasoning(in: app)
        XCTAssertTrue(selected(in: app).waitForExistence(timeout: 8))
    }

    /// One screen: a provider's filter, or search, then the model, then Apply.
    @MainActor
    private func selectModel(in app: XCUIApplication, bySearch: Bool) {
        if bySearch {
            let search = app.descendants(matching: .any)["chat.models.search"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 8))
            search.tap()
            app.typeText("gpt-5.6")
        } else {
            let provider = app.buttons["chat.models.filter.provider.openai"]
            XCTAssertTrue(provider.waitForExistence(timeout: 8))
            provider.tap()
        }
        let model = app.buttons["chat.models.row.openai:gpt-5.6"]
        XCTAssertTrue(model.waitForExistence(timeout: 8))
        model.tap()
        if bySearch {
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Picking a model closes the keyboard")
        }
        let apply = app.buttons["chat.session-controls.apply"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: apply)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, "A new model waits for Apply")
        apply.tap()
    }

    @MainActor
    private func evidence(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["BIGHELP_APPROVAL_EVIDENCE"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url.appendingPathComponent("\(name).png"))
        }
    }
}
