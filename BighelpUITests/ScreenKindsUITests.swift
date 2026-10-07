import XCTest

/// Long-stay screens (Kanban, Workflows, Projects) open from ☰ as screens of their own with ☰
/// in the corner. Quick ones (Usage; Feed when the bottom bar doesn't hold it) slide in with
/// Back, and Settings is a sheet: Back steps through its pages, Done closes it. Demo data.
final class ScreenKindsUITests: BighelpUITestCase {
    @MainActor
    func testLongStayScreensHaveTheMenuAndQuickOnesHaveBack() throws {
        let app = launch()
        app.buttons["tab.agents"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 10))

        // Kanban: a screen of its own.
        openFromMenu("menu.kanban", in: app)
        XCTAssertTrue(kanban(app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["home.drawer.open"].firstMatch.isHittable, "☰ in the corner")
        XCTAssertFalse(app.navigationBars.buttons["BackButton"].exists, "No Back on a long-stay screen")

        // Usage: over Kanban, and Back returns there.
        openFromMenu("menu.usage", in: app)
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Back on a quick screen")
        back.tap()
        XCTAssertTrue(kanban(app).waitForExistence(timeout: 5), "Back returns to Kanban")

        // Feed isn't in the bar here: a quick screen with Back.
        openFromMenu("menu.feed", in: app)
        let boardBack = app.buttons["board.back"].firstMatch
        XCTAssertTrue(boardBack.waitForExistence(timeout: 10), "Back where ☰ would be")
        boardBack.tap()
        XCTAssertTrue(kanban(app).waitForExistence(timeout: 5), "Back returns to Kanban")
    }

    @MainActor
    func testSettingsIsASheetWithDone() throws {
        let app = launch()
        app.buttons["tab.agents"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 10))
        openFromMenu("menu.settings", in: app)
        let done = app.buttons["settings.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Done, top right")
        let appearance = settingsRow("settings.themes", in: app)
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "Back inside Settings")
        back.tap()
        XCTAssertTrue(app.buttons["settings.themes"].firstMatch.waitForExistence(timeout: 5), "One step back")
        XCTAssertTrue(done.exists, "Still in Settings")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Agents"].waitForExistence(timeout: 5), "Done returns to where you were")
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.home.opens-chat", "YES",
                               "-bighelp.app-layout", "{pinned=(agents,ideas,goals,files);menu=();}"]
        app.launch()
        XCTAssertTrue(app.buttons["tab.agents"].waitForExistence(timeout: 20), "Agents is pinned")
        return app
    }

    @MainActor private func kanban(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["kanban.screen"].firstMatch
    }

    @MainActor private func openFromMenu(_ identifier: String, in app: XCUIApplication) {
        let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"]))
            .firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let row = app.buttons[identifier].firstMatch
        for _ in 0..<6 where !(row.waitForExistence(timeout: 1) && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.isHittable, identifier)
        row.tap()
    }
}
