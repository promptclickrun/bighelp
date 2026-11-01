import XCTest

/// Settings › Appearance › Themes and Agent messages on demo data: the orbs pick each mode's theme
/// live, and an agent reply on the page keeps its menu and selection. Set BIGHELP_THEME_EVIDENCE
/// (TEST_RUNNER_…) to a folder to run `testEvidenceScreens` and save its screenshots there.
final class ThemePresetsUITests: BighelpUITestCase {
    @MainActor
    func testOrbsPickEachModesThemeLive() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.demo.appearance", "light"]
        app.launch()
        openAppearance(in: app)
        let studio = app.descendants(matching: .any)["appearance.studio"].firstMatch
        let paper = app.buttons["appearance.light.paper"]
        XCTAssertTrue(paper.waitForExistence(timeout: 5))
        XCTAssertTrue(paper.isSelected, "Classic's light orb is the default")
        XCTAssertEqual(paper.label, "Classic, light")
        let before = color(of: studio, in: app)

        let moss = app.buttons["appearance.light.moss"]
        moss.tap()
        XCTAssertTrue(moss.waitForSelection(), "The tapped orb is picked")
        XCTAssertFalse(paper.isSelected)
        XCTAssertTrue(app.buttons["appearance.dark.black"].isSelected, "Dark mode keeps its own theme")
        let after = color(of: studio, in: app)
        XCTAssertNotEqual(before, after, "The open page took Moss's color at once")
        XCTAssertGreaterThan(after.green, after.red, "Moss is a green page")

        app.buttons["appearance.dark.violet"].tap()
        XCTAssertTrue(app.buttons["appearance.dark.violet"].waitForSelection())
        XCTAssertTrue(moss.isSelected, "Light and dark come from different themes")
        let theme = app.buttons["appearance.bubble.theme"]
        for _ in 0..<4 where !theme.isHittable { studio.swipeUp() }
        XCTAssertTrue(theme.isSelected, "A theme with its own accent brings it to your bubbles")
        app.buttons["appearance.bubble.ocean"].tap()
        XCTAssertTrue(app.buttons["appearance.bubble.ocean"].waitForSelection())
        XCTAssertFalse(theme.isSelected, "A bubble color replaces the theme's")
    }

    @MainActor
    func testAgentRepliesOnThePageUseTheLaneAndKeepTheirMenu() throws {
        let bubbleWidth = try agentReplyWidth(style: "bubble", checkMenu: false)
        let pageWidth = try agentReplyWidth(style: "page", checkMenu: true)
        XCTAssertGreaterThan(pageWidth - bubbleWidth, 20, "On the page a reply takes the lane's full width")
    }

    /// Light and dark screenshots of Appearance and a chat with bubbles on and off, for three
    /// presets, and Bots mode's home and chat.
    @MainActor
    func testEvidenceScreens() throws {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_THEME_EVIDENCE"] else {
            throw XCTSkip("Set BIGHELP_THEME_EVIDENCE to save the screenshots")
        }
        for (light, dark) in [("moss", "violet"), ("berry", "berry"), ("harbor", "clay")] {
            for scheme in ["light", "dark"] {
                let preset = scheme == "light" ? light : dark
                let app = launch(scheme: scheme, light: light, dark: dark, style: "bubble")
                openAppearance(in: app)
                Thread.sleep(forTimeInterval: 0.6)
                save("\(preset)-\(scheme)-appearance", app, folder)
                let studio = app.descendants(matching: .any)["appearance.studio"].firstMatch
                studio.swipeUp()
                Thread.sleep(forTimeInterval: 0.4)
                save("\(preset)-\(scheme)-appearance-2", app, folder)
                app.terminate()
                for style in ["bubble", "page"] {
                    let chat = launch(scheme: scheme, light: light, dark: dark, style: style, extra: ["-start-chat"])
                    XCTAssertTrue(chat.textViews["chat.message.inline-selection"].firstMatch.waitForExistence(timeout: 10))
                    Thread.sleep(forTimeInterval: 0.8)
                    save("\(preset)-\(scheme)-chat-\(style)", chat, folder)
                    chat.terminate()
                }
            }
        }
        for (scheme, preset) in [("light", "moss"), ("dark", "violet")] {
            let app = launch(scheme: scheme, light: "moss", dark: "violet", style: "page",
                             extra: ["-bighelp.settings.simple-bots", "YES"])
            XCTAssertTrue(app.buttons["simple-bots.settings"].waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 0.6)
            save("bots-\(preset)-\(scheme)-home", app, folder)
            app.buttons["simple-bots.bot.travel"].tap()
            XCTAssertTrue(app.buttons["chat.back"].waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 0.8)
            save("bots-\(preset)-\(scheme)-chat-page", app, folder)
            app.terminate()
        }
    }

    // MARK: Helpers

    @MainActor
    private func agentReplyWidth(style: String, checkMenu: Bool) throws -> CGFloat {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-start-chat", "-preview-ui-v3",
                               "-loopdy.demo.appearance", "light", "-bighelp.appearance.agent-messages", style]
        app.launch()
        defer { app.terminate() }
        let reply = app.textViews.matching(NSPredicate(
            format: "identifier == %@ AND label BEGINSWITH %@",
            "chat.message.inline-selection", "Avery Park: Room for the conversation")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 8))
        let width = reply.frame.width
        if checkMenu {
            // Mid-text: the chat's edge-swipe strips cover the outer 28 points of the screen.
            reply.press(forDuration: 1)
            for title in ["Reply", "Copy to clipboard", "Share…", "Select text"] {
                let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
                XCTAssertTrue(item.waitForExistence(timeout: 3), "\(title) is in the menu of a reply on the page")
            }
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Select text")).firstMatch.tap()
            XCTAssertTrue(app.textViews.matching(NSPredicate(format: "value CONTAINS %@", "Room for the conversation"))
                .firstMatch.waitForExistence(timeout: 5), "Select text opens the reply's text")
        }
        return width
    }

    @MainActor
    private func launch(scheme: String, light: String, dark: String, style: String,
                        extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.demo.appearance", scheme,
                               "-loopdy.appearance.lightBackground", light, "-loopdy.appearance.darkBackground", dark,
                               "-bighelp.appearance.bubble-follows-theme", "YES",
                               "-bighelp.appearance.agent-messages", style] + extra
        app.launch()
        return app
    }

    @MainActor
    private func openAppearance(in app: XCUIApplication) {
        openSettings(in: app)
        settingsRow("settings.themes", in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["appearance.studio"].firstMatch.waitForExistence(timeout: 5))
    }

    /// The page's color at the studio's leading edge, below the preview.
    @MainActor
    private func color(of element: XCUIElement, in app: XCUIApplication) -> RGB {
        Thread.sleep(forTimeInterval: 0.6)
        guard let image = app.screenshot().image.cgImage else { return RGB(red: -1, green: -1, blue: -1) }
        let scale = CGFloat(image.width) / app.frame.width
        let x = Int((element.frame.minX + 6) * scale), y = Int(element.frame.midY * scale)
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return RGB(red: -1, green: -1, blue: -1) }
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return RGB(red: Int(pixel[0]), green: Int(pixel[1]), blue: Int(pixel[2]))
    }

    private struct RGB: Equatable {
        let red: Int, green: Int, blue: Int
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication, _ folder: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}

private extension XCUIElement {
    func waitForSelection(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isSelected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return isSelected
    }
}
