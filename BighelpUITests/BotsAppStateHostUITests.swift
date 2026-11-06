import XCTest

/// #857 on a real host with the bighelp plugin (`native-app-state-v1`): the order of Bots mode's
/// home comes back after bighelp is deleted and installed again. Scripts/HostSignInMatrixProbe.py
/// (`--modes appstate`) runs it twice against one isolated host: `save` pins a bot, drags it before
/// the primary bot and saves; the probe deletes the app; `restore` connects the new install to the
/// same host and finds the same top, pinned bot first.
///
/// TEST_RUNNER_BIGHELP_APP_STATE_HOST="<address>|<save or restore>|<profile to pin>";
/// TEST_RUNNER_BIGHELP_SIGNIN_EVIDENCE=<folder> gets the screenshots and `top-<phase>.json`.
final class BotsAppStateHostUITests: BighelpUITestCase {
    @MainActor func testBotsOrderComesBackAfterAReinstall() throws {
        guard let value = ProcessInfo.processInfo.environment["BIGHELP_APP_STATE_HOST"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py --modes appstate")
        }
        let parts = value.split(separator: "|").map(String.init)
        guard parts.count == 3 else { throw XCTSkip("TEST_RUNNER_BIGHELP_APP_STATE_HOST is \"<address>|<phase>|<profile>\"") }
        let (address, phase, profile) = (parts[0], parts[1], parts[2])
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                               "-bighelp.settings.simple-bots", "YES"]
        app.launch()
        try addHost(app, address: address)
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 30))
        let primary = app.buttons["simple-bots.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 30), "The primary bot is on top")
        let pinned = app.buttons["simple-bots.pinned.\(profile)"]

        if phase == "save" {
            let row = app.buttons["simple-bots.bot.\(profile)"]
            XCTAssertTrue(row.waitForExistence(timeout: 30), "\(profile) is in the list")
            XCTAssertFalse(pinned.exists, "A new install starts with nothing pinned but the primary bot")
            save("app-state-save-0-start", app)
            row.press(forDuration: 1.2)
            tap("Pin", in: app)
            XCTAssertTrue(pinned.waitForExistence(timeout: 5))
            pinned.press(forDuration: 1.2)
            tap("Rearrange", in: app)
            let saveButton = app.buttons["simple-bots.rearrange.save"]
            XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
            let dragged = app.descendants(matching: .any)["simple-bots.pinned.\(profile)"]
            let first = app.descendants(matching: .any)["simple-bots.primary"]
            dragged.press(forDuration: 0.1, thenDragTo: first, withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertTrue(waitUntil(timeout: 5) { dragged.frame.minX < first.frame.minX }, "Dragged before the primary bot")
            saveButton.tap()
            XCTAssertTrue(app.buttons["simple-bots.search"].waitForExistence(timeout: 5), "Save ends rearranging")
            // The change goes to the computer a moment after Save.
            sleep(8)
        } else {
            XCTAssertTrue(pinned.waitForExistence(timeout: 45), "\(profile) is pinned again, from the computer")
        }
        XCTAssertTrue(waitUntil(timeout: 20) { pinned.exists && pinned.frame.minX < primary.frame.minX },
                      "\(profile) comes before the primary bot")
        save("app-state-\(phase)-1-top", app)
        mark("top-\(phase)", ["pinnedBeforePrimary": pinned.exists && pinned.frame.minX < primary.frame.minX,
                              "pinned": profile, "at": Date().timeIntervalSince1970])
    }

    // MARK: Helpers

    @MainActor private func tap(_ title: String, in app: XCUIApplication) {
        let action = app.buttons[title]
        XCTAssertTrue(action.waitForExistence(timeout: 5), title)
        action.tap()
    }

    @MainActor private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    @MainActor private func addHost(_ app: XCUIApplication, address: String) throws {
        let field = app.textFields["host-setup.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(address)
        let connect = app.buttons["host-setup.connect-host"]
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
        let next = app.buttons["host-setup.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected")
        next.tap()
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    @MainActor private func mark(_ name: String, _ value: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        let attachment = XCTAttachment(data: json, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? json.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).json"))
    }
}
