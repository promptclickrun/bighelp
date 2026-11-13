import XCTest

/// #504: the Bots view shows which bots are working on a turn and which need you, and (#890) which run
/// work in the background. On the demo data with `-test-bot-activity`, Mina Shah browses the web in
/// her Bot Chat, Jordan Lee needs you and Avery Park has work in the background; with every computer
/// showing, Sage Ortiz works on the sample Studio Mac. Light and dark.
/// TEST_RUNNER_BIGHELP_BOT_ACTIVITY_EVIDENCE=<folder> saves the screenshots there, and
/// TEST_RUNNER_BIGHELP_BOT_ACTIVITY_REDUCED=1 says the simulator has Reduce Motion on (a test can't
/// switch it), which names them "-reduced".
final class SimpleBotsActivityUITests: BighelpUITestCase {
    @MainActor
    func testWorkingAndNeedsYouShowOnEachBot() throws {
        for appearance in ["light", "dark"] {
            let app = launch(appearance: appearance, extra: ["-test-bot-activity"])
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
            let mina = app.buttons["simple-bots.bot.travel"]
            let jordan = app.buttons["simple-bots.bot.home"]
            XCTAssertTrue(wait(for: mina, toSay: "Browsing the web"), mina.label)
            XCTAssertTrue(wait(for: jordan, toSay: "Needs you"), jordan.label)
            // Avery has no turn running but has work in the background: its tile says so, calmly.
            let primary = app.primaryBot
            XCTAssertTrue(wait(for: primary, toSay: "2 things running in the background"), primary.value as? String ?? "")
            // Said once: the row's value, not again in its label.
            XCTAssertFalse(mina.label.contains("Browsing the web"), mina.label)
            save("home-\(appearance)", app)

            // Search shows the same faces.
            app.buttons["simple-bots.search"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.search.bot.home"].waitForExistence(timeout: 5))
            save("search-\(appearance)", app)
            app.buttons["simple-bots.search.close"].tap()

            // Pinned to the top, Mina's tile says it too.
            mina.press(forDuration: 1.2)
            app.buttons["Pin"].tap()
            let tile = app.buttons["simple-bots.pinned.travel"]
            XCTAssertTrue(tile.waitForExistence(timeout: 5))
            XCTAssertEqual(tile.value as? String, "Browsing the web")
            save("pinned-\(appearance)", app)
            tile.press(forDuration: 1.2)
            app.buttons["Unpin"].tap()
            app.terminate()
        }
    }

    @MainActor
    func testAnotherGatewaysBotShowsItsOwnState() throws {
        // Settings › Show every computer.
        let app = launch(appearance: "light", extra: ["-test-bot-activity", "-bighelp.hosts.all-hosts", "YES"])
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
        let sage = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", "/reviewer")).firstMatch
        XCTAssertTrue(sage.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: sage, toSay: "Working"), sage.label)
        let mina = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH %@", "/travel")).firstMatch
        XCTAssertTrue(wait(for: mina, toSay: "Browsing the web"), mina.label)
        save("multi-gateway-light", app)
    }

    @MainActor
    func testNothingShowsWithoutASignal() throws {
        let app = launch(appearance: "light")
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
        let mina = app.buttons["simple-bots.bot.travel"]
        XCTAssertTrue(mina.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        for id in ["travel", "home"] {
            let row = app.buttons["simple-bots.bot.\(id)"]
            XCTAssertTrue(row.exists)
            XCTAssertEqual(row.value as? String ?? "", "", "The demo host says nothing: no guess")
        }
    }

    @MainActor
    private func launch(appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.home.landing", "bots",
                               "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        return app
    }

    private func wait(for element: XCUIElement, toSay text: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists, (element.value as? String)?.contains(text) == true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let environment = ProcessInfo.processInfo.environment
        let suffix = environment["BIGHELP_BOT_ACTIVITY_REDUCED"] != nil ? "-reduced" : ""
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name + suffix
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = environment["BIGHELP_BOT_ACTIVITY_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(
            to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)\(suffix).png"))
    }
}
