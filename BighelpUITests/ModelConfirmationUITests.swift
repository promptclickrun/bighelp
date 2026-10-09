import XCTest

/// The demo host refuses a model change until its exact warning is approved.
final class ModelConfirmationUITests: BighelpUITestCase {
    @MainActor
    func testQuickPickerRequiresApproval() {
        checkApproval(fullPicker: false, appearance: "light")
    }

    @MainActor
    func testFullPickerRequiresApproval() {
        checkApproval(fullPicker: true, appearance: "dark")
    }

    @MainActor
    private func checkApproval(fullPicker: Bool, appearance: String) {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-test-model-confirmation", "-loopdy.demo.appearance", appearance]
        app.launch()
        openPicker(in: app, full: fullPicker)
        selectModel(in: app, full: fullPicker)
        let approve = app.buttons["model-confirmation.approve"].firstMatch
        guard approve.waitForExistence(timeout: 8) else {
            XCTFail("The host's pending model warning must offer Approve and Cancel")
            return
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "train on prompts and completions")).firstMatch.exists)
        evidence("model-approval-\(appearance)")
        app.buttons["model-confirmation.cancel"].tap()
        XCTAssertTrue(approve.waitForNonExistence(timeout: 5))
        if !fullPicker {
            XCTAssertTrue(app.buttons["chat.quick-model.openai:gpt-5.6"].exists,
                          "Cancelling must leave the quick choices usable, not stuck loading")
        }
        closePicker(in: app, full: fullPicker)

        // Cancelling must not change the saved model, even after reopening.
        openPicker(in: app, full: false)
        XCTAssertTrue(app.buttons["chat.quick-model.nous:Hermes-4-405B"].isSelected)
        if fullPicker { app.buttons["chat.models.see-all"].tap() }
        selectModel(in: app, full: fullPicker)
        XCTAssertTrue(approve.waitForExistence(timeout: 8))
        approve.tap()
        let apply = app.buttons[fullPicker ? "model-picker.apply" : "chat.session-controls.apply"]
        XCTAssertTrue(apply.waitForNonExistence(timeout: 10), "Only an accepted approval closes the picker")
        openPicker(in: app, full: false)
        XCTAssertTrue(app.buttons["chat.quick-model.openai:gpt-5.6"].isSelected)
        app.terminate()
    }

    @MainActor
    private func openPicker(in app: XCUIApplication, full: Bool) {
        _ = chatMenuItem("chat.session-controls", in: app, timeout: 2)
        // Native menu rows can expose their title instead of their SwiftUI identifier.
        let controls = app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label BEGINSWITH %@", "chat.session-controls", "Model & reasoning"
        )).firstMatch
        if !controls.waitForExistence(timeout: 2) {
            // The first tap can arrive while the native submenu is still laying out.
            let group = app.buttons["chat.options.model-speed"].firstMatch
            XCTAssertTrue(group.waitForExistence(timeout: 5))
            group.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(controls.waitForExistence(timeout: 8))
        controls.tap()
        XCTAssertTrue(app.buttons["chat.models.see-all"].waitForExistence(timeout: 8))
        if full { app.buttons["chat.models.see-all"].tap() }
    }

    @MainActor
    private func selectModel(in app: XCUIApplication, full: Bool) {
        if full {
            let provider = app.buttons["model-picker.provider.openai"]
            XCTAssertTrue(provider.waitForExistence(timeout: 8))
            provider.tap()
        }
        let model = app.buttons[full ? "model-picker.openai.gpt-5.6" : "chat.quick-model.openai:gpt-5.6"]
        XCTAssertTrue(model.waitForExistence(timeout: 8))
        model.tap()
        app.buttons[full ? "model-picker.apply" : "chat.session-controls.apply"].tap()
    }

    @MainActor
    private func closePicker(in app: XCUIApplication, full: Bool) {
        app.buttons[full ? "model-picker.dismiss" : "Cancel"].firstMatch.tap()
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
