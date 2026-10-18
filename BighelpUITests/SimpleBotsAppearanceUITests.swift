import XCTest

/// Simple Bot mode on demo data, switching Light and Dark the way people do: in Settings, with a
/// page open. The open page, its name field and the home behind it change at once. Back from a
/// bot's chat never shows ☰. Set BIGHELP_SIMPLE_BOTS_EVIDENCE (TEST_RUNNER_…) to a folder to save
/// the screenshots.
final class SimpleBotsAppearanceUITests: BighelpUITestCase {
    @MainActor
    func testDarkModeRepaintsWhatIsOpen() throws {
        let app = makeApp()
        // The appearance isn't pinned here, so Settings can change it.
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                               "-bighelp.settings.simple-bots", "YES"]
        app.launch()
        defer { setAppearance("Automatic", in: app) }
        XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 15))
        setAppearance("Light", in: app)
        XCTAssertGreaterThan(brightness(of: app.windows.firstMatch, in: app), 0.8, "Light: a light home")

        // Back from a bot's chat: the home's own header, never ☰ on the way.
        app.buttons["simple-bots.bot.travel"].tap()
        XCTAssertTrue(app.buttons["chat.back"].waitForExistence(timeout: 10))
        app.buttons["chat.back"].tap()
        for _ in 0..<10 {
            XCTAssertFalse(app.buttons["home.drawer.open"].exists, "☰ showed while going back")
            Thread.sleep(forTimeInterval: 0.08)
        }
        XCTAssertTrue(app.buttons["simple-bots.settings"].waitForExistence(timeout: 5))

        // Dark from Settings › Appearance: the open page changes now, not after reopening it.
        app.buttons["simple-bots.settings"].tap()
        app.buttons["simple-bots.settings.appearance"].tap()
        let mode = app.segmentedControls["appearance.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.buttons["Dark"].tap()
        Thread.sleep(forTimeInterval: 0.6)
        save("appearance-page-dark", app)
        XCTAssertLessThan(brightness(of: app.windows.firstMatch, in: app), 0.25, "The open page turned dark")

        // Your name: a dark box with light text, readable.
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["simple-bots.settings.you"].tap()
        let name = app.textFields["profile.display-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        save("appearance-name-dark", app)
        XCTAssertLessThan(brightness(of: name, in: app, edge: true), 0.35, "The name box is dark")

        // The home behind the sheet changed too.
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["simple-bots.settings.close"].tap()
        XCTAssertTrue(app.buttons["simple-bots.settings"].waitForExistence(timeout: 5))
        save("appearance-home-dark", app)
        XCTAssertLessThan(brightness(of: app.windows.firstMatch, in: app), 0.25, "The home turned dark")
    }

    /// Your name in Simple Bot mode's Settings: a box that reads in light and in dark.
    @MainActor
    func testNameRowReadsInBothModes() throws {
        for (appearance, isDark) in [("light", false), ("dark", true)] {
            let app = makeApp()
            app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-preview-ui-v3",
                                   "-bighelp.settings.simple-bots", "YES", "-loopdy.demo.appearance", appearance]
            app.launch()
            XCTAssertTrue(app.buttons["simple-bots.settings"].waitForExistence(timeout: 15))
            app.buttons["simple-bots.settings"].tap()
            app.buttons["simple-bots.settings.you"].tap()
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
        app.buttons["simple-bots.settings.appearance"].tap()
        let mode = app.segmentedControls["appearance.mode"]
        guard mode.waitForExistence(timeout: 5) else { return }
        mode.buttons[title].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["simple-bots.settings.close"].tap()
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
