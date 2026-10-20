import XCTest

/// A tapped scheduled task alert opens its job, or the agent's Scheduled tasks when the job is
/// gone, never "This conversation is no longer on your computer" (#181). Demo data, with the tap
/// handed over by `-test-scheduled-alert-tap` the way a real alert's is.
@MainActor
final class ScheduledAlertTapUITests: BighelpUITestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testAnAlertNamingItsJobOpensTheTask() {
        opensTheTask(appearance: "light")
    }

    func testAnAlertNamingItsJobOpensTheTaskInDarkMode() {
        opensTheTask(appearance: "dark")
    }

    func testAnAlertWhoseJobIsGoneOpensTheAgentsTasks() {
        let app = launch(tap: "gone", appearance: "dark")
        let tasks = app.descendants(matching: .any)["scheduled-tasks.screen"].firstMatch
        XCTAssertTrue(tasks.waitForExistence(timeout: 15), "The agent's Scheduled tasks open")
        XCTAssertFalse(app.alerts["Unable to open"].exists, "No dead end")
        XCTAssertFalse(app.staticTexts["This conversation is no longer on your computer."].exists)
        capture("Scheduled alert with a removed job dark")
    }

    private func opensTheTask(appearance: String) {
        let app = launch(tap: "job", appearance: appearance)
        let task = app.descendants(matching: .any)["scheduled-task.detail.7:finance:task-finance-brief"].firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 15), "The job's own page opens")
        XCTAssertTrue(app.staticTexts["Morning market brief"].firstMatch.exists)
        XCTAssertFalse(app.alerts["Unable to open"].exists, "No dead end")
        capture("Scheduled alert opens its task \(appearance)")
    }

    private func launch(tap: String, appearance: String) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "NO",
                               "-test-scheduled-alert-tap", tap, "-loopdy.demo.appearance", appearance]
        app.launch()
        return app
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
