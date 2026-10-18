import XCTest

/// How fast a long chat opens (from the chat list, and from a link the way a notification
/// opens it) and how smoothly it scrolls, on demo data. For comparing two builds on one
/// simulator; the numbers aren't an iPhone's. Set BIGHELP_SPEED (TEST_RUNNER_…) to run.
final class ChatLoadSpeedUITests: BighelpUITestCase {
    private static let longChat = "demo-long-transcript"

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["BIGHELP_SPEED"] != nil else {
            throw XCTSkip("Speed checks run on request")
        }
    }

    @MainActor
    func testOpeningALongChatFromTheList() throws {
        let app = launch()
        let row = app.descendants(matching: .any)["session.row.\(Self.longChat)"].firstMatch
        measureOpening(app) {
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            row.tap()
        }
    }

    @MainActor
    func testOpeningALongChatFromALink() throws {
        let app = launch()
        let row = app.descendants(matching: .any)["session.row.\(Self.longChat)"].firstMatch
        measureOpening(app) {
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            app.open(URL(string: "loopdy://chat/\(Self.longChat)")!)
        }
    }

    @MainActor
    func testScrollingALongChat() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-start-long-transcript"]
        app.launch()
        let timeline = app.descendants(matching: .any)["chat.timeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 20))
        XCTAssertTrue(latest(in: app).waitForExistence(timeout: 20))
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        options.iterationCount = 5
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            timeline.swipeDown(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
            timeline.swipeDown(velocity: .fast)
            stopMeasuring()
            timeline.swipeUp(velocity: .fast)
            timeline.swipeUp(velocity: .fast)
            timeline.swipeUp(velocity: .fast)
        }
    }

    /// From `open` until the chat's newest message shows, then back to the list.
    @MainActor
    private func measureOpening(_ app: XCUIApplication, open: () -> Void) {
        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        options.iterationCount = 5
        let sessions = URL(string: "loopdy://sessions")!
        measure(metrics: [XCTClockMetric(), XCTCPUMetric(application: app)], options: options) {
            startMeasuring()
            open()
            XCTAssertTrue(latest(in: app).waitForExistence(timeout: 20))
            stopMeasuring()
            app.open(sessions)
            XCTAssertTrue(app.descendants(matching: .any)["session.row.\(Self.longChat)"].firstMatch
                .waitForExistence(timeout: 20))
        }
    }

    private func latest(in app: XCUIApplication) -> XCUIElement {
        app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "settled sentinel 1000")).firstMatch
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.home.opens-chat", "NO"]
        app.launch()
        return app
    }
}
