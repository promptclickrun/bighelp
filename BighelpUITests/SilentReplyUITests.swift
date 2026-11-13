import XCTest

/// A bare "NO_REPLY" answering the person's own message shows Hermes' notice
/// instead of vanishing, and the marker itself never flashes while it streams.
/// Set BIGHELP_SILENT_REPLY_EVIDENCE (TEST_RUNNER_…) to save a screenshot.
final class SilentReplyUITests: BighelpUITestCase {
    @MainActor
    func testBareMarkerToThePersonShowsHermesNotice() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-test-companion-disabled", "-test-silent-reply"]
        app.launch()
        startNewChat(with: "finance", in: app)
        let input = app.textViews["Message"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Thanks!")
        app.buttons["chat.send"].tap()

        // Message text is a native text view, so match on its label.
        func message(containing text: String) -> XCUIElement {
            app.textViews.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        let notice = message(containing: "returned only a silence marker")
        let marker = app.textViews.matching(NSPredicate(format: "label IN %@", ["NO", "NO_REP", "NO_REPLY"])).firstMatch
        var sawMarker = false
        let deadline = Date().addingTimeInterval(10)
        while !notice.exists, Date() < deadline {
            sawMarker = sawMarker || marker.exists
            usleep(50_000)
        }
        XCTAssertTrue(notice.exists, "The person sees Hermes' notice")
        XCTAssertFalse(sawMarker || marker.exists, "The marker never shows, even while it streams")
        if let folder = ProcessInfo.processInfo.environment["BIGHELP_SILENT_REPLY_EVIDENCE"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("silent-reply.png"))
        }
    }
}
