import XCTest

/// The lifter: its motions in the loader gallery, the chat's one-loader rule
/// and the first run's welcome. Set `BIGHELP_LIFTER_EVIDENCE`
/// (as TEST_RUNNER_…) to a folder to keep screenshots; `BIGHELP_LIFTER_APPEARANCE` picks
/// light or dark (dark by default).
final class LifterUITests: BighelpUITestCase {
    @MainActor
    func testGalleryShowsEveryMotion() throws {
        let app = makeApp()
        app.launchArguments = ["-bighelp-loader-gallery", "-bighelp-loader-gallery-section", "lifter",
                               "-bighelp-loader-gallery-appearance", appearance]
        app.launch()
        XCTAssertTrue(app.otherElements["loader-gallery"].waitForExistence(timeout: 10))

        let motions = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'lifter.'"))
        XCTAssertTrue(motions.firstMatch.waitForExistence(timeout: 5))
        save("lifter-gallery", app)

        // Two live rows, one loader (the rule itself is unit tested): the screenshot shows it.
        app.swipeUp()
        app.swipeUp()
        save("lifter-one-loader", app)
    }

    @MainActor
    func testTheFirstRunWelcomes() throws {
        let fresh = makeApp()
        fresh.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts",
                                 "-force-signed-out-onboarding", "-loopdy.demo.appearance", appearance]
        fresh.launch()
        XCTAssertTrue(fresh.descendants(matching: .any)["loopdy.brand-logo"].waitForExistence(timeout: 10))
        save("lifter-onboarding", fresh)
    }

    private var appearance: String {
        ProcessInfo.processInfo.environment["BIGHELP_LIFTER_APPEARANCE"] ?? "dark"
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: screenshot)
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_LIFTER_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(appearance).png"))
    }
}
