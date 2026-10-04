import XCTest

final class ToolDisclosureUITests: BighelpUITestCase {
    @MainActor
    func testOpenedToolSurvivesEnclosingWorkTrailRecreation() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3", "-test-tool-disclosure-scroll", "-loopdy.chat.foldCompletedTurns", "NO"]
        app.launch()
        let trail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat.work-trail.")).firstMatch
        XCTAssertTrue(app.tables["chat.timeline"].waitForExistence(timeout: 5))
        func revealAndTap(_ element: XCUIElement) {
            for _ in 0..<8 where !element.isHittable {
                app.tables["chat.timeline"].swipeDown()
            }
            element.tap()
        }
        revealAndTap(trail)
        let tool = app.buttons["chat.activity.v3-sample-tool-0"]
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        tool.tap()
        XCTAssertEqual(tool.value as? String, "Expanded")
        let timeline = app.tables["chat.timeline"]
        for _ in 0..<4 where tool.isHittable { timeline.swipeUp(velocity: .fast) }
        XCTAssertFalse(tool.isHittable, "Move the expanded tool out of the native table's visible cells.")
        for _ in 0..<8 where !tool.isHittable { timeline.swipeDown(velocity: .fast) }
        XCTAssertTrue(tool.isHittable)
        XCTAssertEqual(tool.value as? String, "Expanded", "Cell recycling must retain the reader's tool disclosure choice.")
        revealAndTap(trail)
        XCTAssertEqual(trail.value as? String, "Collapsed")
        revealAndTap(trail)
        XCTAssertTrue(tool.waitForExistence(timeout: 5))
        XCTAssertEqual(tool.value as? String, "Expanded", "Recreating the visible work trail must not discard the reader's tool disclosure choice")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "retained-tool-disclosure"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        tool.tap()
        XCTAssertEqual(tool.value as? String, "Collapsed")
        revealAndTap(trail)
        revealAndTap(trail)
        XCTAssertEqual(tool.value as? String, "Collapsed", "Explicit close must also persist")
    }
}
