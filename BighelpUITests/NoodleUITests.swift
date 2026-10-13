import XCTest

/// The brand kit's Noodle: its motions in the loader gallery, the chat's one-loader rule,
/// the wordmark in the header and the first run's reveal. Set `BIGHELP_NOODLE_EVIDENCE`
/// (as TEST_RUNNER_…) to a folder to keep screenshots; `BIGHELP_NOODLE_APPEARANCE` picks
/// light or dark (dark by default).
final class NoodleUITests: BighelpUITestCase {
    @MainActor
    func testGalleryShowsEveryMotion() throws {
        let app = makeApp()
        app.launchArguments = ["-bighelp-loader-gallery", "-bighelp-loader-gallery-section", "noodle",
                               "-bighelp-loader-gallery-appearance", appearance]
        app.launch()
        XCTAssertTrue(app.otherElements["loader-gallery"].waitForExistence(timeout: 10))

        let motions = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'noodle.'"))
        XCTAssertTrue(motions.firstMatch.waitForExistence(timeout: 5))
        save("noodle-gallery", app)

        // Two live rows, one loader (the rule itself is unit tested): the screenshot shows it.
        app.swipeUp()
        app.swipeUp()
        save("noodle-one-loader", app)
    }

    @MainActor
    func testHeaderShowsTheWordmarkAndTheFirstRunWritesTheMark() throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.demo.appearance", appearance]
        app.launch()
        XCTAssertTrue(app.buttons["brand.host-switcher"].waitForExistence(timeout: 15)
                      || app.otherElements["brand.host-switcher"].exists)
        save("noodle-header", app)
        app.terminate()

        let fresh = makeApp()
        fresh.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                                 "-force-signed-out-onboarding", "-loopdy.demo.appearance", appearance]
        fresh.launch()
        XCTAssertTrue(fresh.descendants(matching: .any)["loopdy.brand-logo"].waitForExistence(timeout: 10))
        save("noodle-onboarding", fresh)
    }

    private var appearance: String {
        ProcessInfo.processInfo.environment["BIGHELP_NOODLE_APPEARANCE"] ?? "dark"
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_NOODLE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(appearance).png"))
    }
}
