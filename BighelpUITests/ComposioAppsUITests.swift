import XCTest

/// Settings › Apps on the demo: Native App Connections and Composio Apps. Composio Apps shows the
/// connected apps, turns Composio on for the agent, browses a category and connects an app.
final class ComposioAppsUITests: BighelpUITestCase {
    @MainActor
    func testComposioAppsConnectAnAppAndTurnOnForTheAgent() {
        for appearance in ["light", "dark"] {
            let app = makeApp()
            app.launchArguments += ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
            app.launch()
            _ = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu", "tab.profile"]))
                .firstMatch.waitForExistence(timeout: 60)
            openSettings(in: app)
            settingsRow("settings.apps", in: app).tap()

            let composio = app.buttons["apps.composio"]
            XCTAssertTrue(composio.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["apps.native"].exists, "Hermes' own connections stay one tap away")
            evidence("apps-hub-\(appearance)", app)

            composio.tap()
            XCTAssertTrue(app.buttons["composio.app.gmail"].waitForExistence(timeout: 10), "Gmail is connected")
            XCTAssertTrue(app.buttons["composio.app.github"].exists, "and GitHub")
            let turnOn = app.buttons["composio.agent.turn-on"]
            XCTAssertTrue(turnOn.waitForExistence(timeout: 10), "The demo computer has no Composio yet")
            evidence("composio-apps-\(appearance)", app)
            turnOn.tap()
            XCTAssertTrue(app.descendants(matching: .any)["composio.agent.ready"].waitForExistence(timeout: 15),
                          "Installed, signed in, ready for the agent")

            // Calendly's demo sign-in never finishes: its page must stay open until it's closed, also
            // when bighelp becomes active again (on iPhone, iOS's "wants to use … to sign in" prompt
            // does that; build 126 closed the page then).
            let scheduling = app.buttons["composio.category.scheduling-booking"]
            for _ in 0..<4 where !scheduling.isHittable { app.swipeUp() }
            scheduling.tap()
            let calendly = app.buttons["composio.app.calendly"]
            XCTAssertTrue(calendly.waitForExistence(timeout: 10))
            calendly.tap()
            let connect = app.buttons["composio.app.connect"]
            XCTAssertTrue(connect.waitForExistence(timeout: 10))
            connect.tap()
            allowSignInPage()
            XCTAssertTrue(signInPageCancel(in: app).exists, "The sign-in page opens")
            XCUIDevice.shared.press(.home)
            sleep(2)
            app.activate()
            sleep(4)
            let pageCancel = signInPageCancel(in: app)
            XCTAssertTrue(pageCancel.exists, "Coming back to bighelp doesn't close the page")
            evidence("composio-page-open-\(appearance)", app)
            if pageCancel.exists { pageCancel.tap() }
            XCTAssertTrue(connect.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "composio.app.remove.calendly"))
                .firstMatch.exists, "Closing the page early leaves no account")

            // Notion's demo sign-in finishes: the page closes by itself and the account shows.
            app.navigationBars.buttons.element(boundBy: 0).tap()  // back to the category
            app.navigationBars.buttons.element(boundBy: 0).tap()  // back to Composio Apps
            let productivity = app.buttons["composio.category.productivity"]
            for _ in 0..<4 where !productivity.isHittable { app.swipeUp() }
            productivity.tap()
            let notion = app.buttons["composio.app.notion"]
            XCTAssertTrue(notion.waitForExistence(timeout: 10))
            evidence("composio-category-\(appearance)", app)
            notion.tap()
            XCTAssertTrue(connect.waitForExistence(timeout: 10))
            connect.tap()
            allowSignInPage()
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "composio.app.remove.notion"))
                .firstMatch.waitForExistence(timeout: 20), "Notion's account arrives and the page closes by itself")
            evidence("composio-app-connected-\(appearance)", app)
            app.terminate()
        }
    }

    /// iOS asks before a sign-in page opens.
    @MainActor
    private func allowSignInPage() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.buttons["Continue"].waitForExistence(timeout: 8) {
            springboard.alerts.buttons["Continue"].tap()
        }
    }

    /// The open sign-in page's Cancel button, in Safari's view service or in the app (up to 15 seconds).
    @MainActor
    private func signInPageCancel(in app: XCUIApplication) -> XCUIElement {
        let candidates = [XCUIApplication(bundleIdentifier: "com.apple.SafariViewService").buttons["Cancel"],
                          app.buttons["Cancel"]]
        for _ in 0..<30 {
            if let found = candidates.first(where: \.exists) { return found }
            usleep(500_000)
        }
        return candidates[0]
    }

    @MainActor
    private func evidence(_ name: String, _ app: XCUIApplication) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_UI_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
