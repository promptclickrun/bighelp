import XCTest

/// The Bots view on demo data, switching Light and Dark the way people do: in Settings, with a
/// page open. The open page, its name field and the home behind it change at once. Settings is a
/// sheet, so its pages go back with the sheet's own Back button. Set BIGHELP_SIMPLE_BOTS_EVIDENCE
/// (TEST_RUNNER_…) to a folder to save the screenshots.
final class SimpleBotsAppearanceUITests: BighelpUITestCase {
    /// The circle on Bots opens Settings: its Chat row opens Settings › Chat.
    @MainActor
    func testSettingsOpensChatDirectly() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.home.landing", "bots"]
        app.launch()
        XCTAssertTrue(app.buttons["simple-bots.settings"].waitForExistence(timeout: 15))
        app.buttons["simple-bots.settings"].tap()
        let chat = app.buttons["settings.menu.chat"]
        for _ in 0..<4 where !(chat.exists && chat.isHittable) { app.swipeUp() }
        XCTAssertTrue(chat.isHittable, "Chat sits with Notifications and Appearance")
        chat.tap()
        XCTAssertTrue(app.navigationBars["Chat"].waitForExistence(timeout: 5), "Settings › Chat opens")
        XCTAssertTrue(app.buttons["settings.landing.screen"].firstMatch.waitForExistence(timeout: 5),
                      "Its own rows")
        save("simple-bots-chat-settings", app)
    }

    @MainActor
    func testDarkModeRepaintsWhatIsOpen() throws {
        let app = makeApp()
        // The appearance isn't pinned here, so Settings can change it.
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.home.landing", "bots"]
        app.launch()
        defer { setAppearance("System", in: app) }
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
        setAppearance("Light", in: app)
        XCTAssertGreaterThan(brightness(of: app.windows.firstMatch, in: app), 0.8, "Light: a light home")

        // Back from a bot's chat: the home's own header.
        app.buttons["simple-bots.bot.travel"].tap()
        XCTAssertTrue(app.buttons["chat.back"].waitForExistence(timeout: 10))
        app.buttons["chat.back"].tap()
        XCTAssertTrue(app.buttons["simple-bots.settings"].waitForExistence(timeout: 5))

        // Dark from Settings › Appearance: the open page changes now, not after reopening it.
        app.buttons["simple-bots.settings"].tap()
        app.buttons["settings.themes"].tap()
        let dark = app.buttons["appearance.mode.dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        dark.tap()
        Thread.sleep(forTimeInterval: 0.6)
        save("appearance-page-dark", app)
        XCTAssertLessThan(brightness(of: app.windows.firstMatch, in: app), 0.25, "The open page turned dark")

        // Your name: a dark box with light text, readable.
        app.buttons["BackButton"].firstMatch.tap()
        app.buttons["settings.you"].tap()
        let name = app.textFields["profile.display-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        save("appearance-name-dark", app)
        XCTAssertLessThan(brightness(of: name, in: app, edge: true), 0.35, "The name box is dark")

        // The home behind the sheet changed too.
        app.buttons["BackButton"].firstMatch.tap()
        app.buttons["settings.done"].tap()
        XCTAssertTrue(app.buttons["simple-bots.settings"].waitForExistence(timeout: 5))
        save("appearance-home-dark", app)
        XCTAssertLessThan(brightness(of: app.windows.firstMatch, in: app), 0.25, "The home turned dark")
    }

    /// The dark page picked in Appearance (Graphite or Black) is the Bots view's page too, and the
    /// home, Settings and a bot's chat change as soon as it's picked (#718).
    @MainActor
    func testDarkBackgroundChoiceRepaintsBots() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.home.landing", "bots", "-loopdy.demo.appearance", "dark",
                               "-loopdy.appearance.darkBackground", "black"]
        app.launch()
        let home = app.descendants(matching: .any)["simple-bots.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        let black = brightness(of: app.windows.firstMatch, in: app)
        XCTAssertLessThan(black, 0.03, "Black: a black home")
        saveScreens("black", app)

        pickDarkBackground("graphite", in: app)
        let graphite = brightness(of: app.windows.firstMatch, in: app)
        XCTAssertGreaterThan(graphite, black + 0.05, "Graphite: the home turned charcoal")
        XCTAssertLessThan(graphite, 0.25, "Still dark")
        saveScreens("graphite", app)

        pickDarkBackground("black", in: app)
        XCTAssertLessThan(brightness(of: app.windows.firstMatch, in: app), 0.03, "Black again")
    }

    /// The home in light mode, for comparison with the dark pages.
    @MainActor
    func testLightHomeKeepsItsPage() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-loopdy.home.landing", "bots", "-loopdy.demo.appearance", "light",
                               "-loopdy.appearance.darkBackground", "graphite"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
        XCTAssertGreaterThan(brightness(of: app.windows.firstMatch, in: app), 0.95, "Light: a Paper home")
        save("light-home", app)
    }

    /// Picks a dark page in Settings › Appearance and goes back to the home.
    @MainActor
    private func pickDarkBackground(_ choice: String, in app: XCUIApplication) {
        app.buttons["simple-bots.settings"].tap()
        app.buttons["settings.themes"].tap()
        let tile = app.buttons["appearance.dark.\(choice)"]
        XCTAssertTrue(tile.waitForExistence(timeout: 5))
        tile.tap()
        app.buttons["BackButton"].firstMatch.tap()
        app.buttons["settings.done"].tap()
        XCTAssertTrue(app.buttons["simple-bots.settings"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// The home, Settings and a bot's chat, for the evidence folder.
    @MainActor
    private func saveScreens(_ suffix: String, _ app: XCUIApplication) {
        save("home-\(suffix)", app)
        app.buttons["simple-bots.settings"].tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        save("settings-\(suffix)", app)
        app.buttons["settings.done"].tap()
        XCTAssertTrue(app.buttons["simple-bots.bot.travel"].waitForExistence(timeout: 5))
        app.buttons["simple-bots.bot.travel"].tap()
        XCTAssertTrue(app.buttons["chat.back"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 0.8)
        save("chat-\(suffix)", app)
        app.buttons["chat.back"].tap()
        XCTAssertTrue(app.buttons["simple-bots.settings"].waitForExistence(timeout: 5))
    }

    /// Your name in Settings, opened from Bots: a box that reads in light and in dark.
    @MainActor
    func testNameRowReadsInBothModes() throws {
        for (appearance, isDark) in [("light", false), ("dark", true)] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                   "-loopdy.home.landing", "bots", "-loopdy.demo.appearance", appearance]
            app.launch()
            XCTAssertTrue(app.buttons["simple-bots.settings"].waitForExistence(timeout: 15))
            app.buttons["simple-bots.settings"].tap()
            app.buttons["settings.you"].tap()
            let name = app.textFields["profile.display-name"]
            XCTAssertTrue(name.waitForExistence(timeout: 5))
            save("name-row-\(appearance)", app)
            let box = brightness(of: name, in: app, edge: true)
            if isDark { XCTAssertLessThan(box, 0.35, "Dark: a dark box") } else { XCTAssertGreaterThan(box, 0.6) }
            app.terminate()
        }
    }

    @MainActor
    private func setAppearance(_ title: String, in app: XCUIApplication) {
        guard app.state == .runningForeground, app.buttons["simple-bots.settings"].waitForExistence(timeout: 3)
        else { return }
        app.buttons["simple-bots.settings"].tap()
        app.buttons["settings.themes"].tap()
        let mode = app.buttons["appearance.mode.\(title.lowercased())"]
        guard mode.waitForExistence(timeout: 5) else { return }
        mode.tap()
        app.buttons["BackButton"].firstMatch.tap()
        app.buttons["settings.done"].tap()
        _ = app.buttons["simple-bots.settings"].waitForExistence(timeout: 5)
    }

    /// The average brightness (0 black, 1 white) of a few points in the element; `edge` reads
    /// near its trailing end, where a field shows its box rather than its text.
    @MainActor
    private func brightness(of element: XCUIElement, in app: XCUIApplication, edge: Bool = false) -> CGFloat {
        let image = app.screenshot().image
        guard let cgImage = image.cgImage else { return -1 }
        let scale = CGFloat(cgImage.width) / app.frame.width
        let frame = element.frame
        // A whole screen: its background, at the sides between the cards and rows.
        let xs: [CGFloat] = edge ? [frame.maxX - 12] : [frame.minX + 6, frame.maxX - 6]
        let ys: [CGFloat] = edge ? [frame.midY - 4, frame.midY + 4] : [frame.midY, frame.minY + frame.height * 0.75]
        var total: CGFloat = 0
        var count: CGFloat = 0
        var pixel = [UInt8](repeating: 0, count: 4)
        for x in xs {
            for y in ys {
                guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                let px = Int(x * scale), py = Int(y * scale)
                context.draw(cgImage, in: CGRect(x: -px, y: py - cgImage.height + 1,
                                                 width: cgImage.width, height: cgImage.height))
                total += (0.2126 * CGFloat(pixel[0]) + 0.7152 * CGFloat(pixel[1]) + 0.0722 * CGFloat(pixel[2])) / 255
                count += 1
            }
        }
        return count > 0 ? total / count : -1
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIMPLE_BOTS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
