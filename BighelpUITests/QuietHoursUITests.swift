import XCTest

/// Settings › Notifications › Quiet Hours on the demo data, where Studio Mac has an older
/// plugin (`-demo-quiet-hours-old-plugin`). Set BIGHELP_QUIET_HOURS_EVIDENCE
/// (TEST_RUNNER_BIGHELP_QUIET_HOURS_EVIDENCE) to a folder to save screenshots.
final class QuietHoursUITests: BighelpUITestCase {
    @MainActor
    func testQuietHoursLight() throws { try exercise(appearance: "light") }

    @MainActor
    func testQuietHoursDark() throws { try exercise(appearance: "dark") }

    @MainActor
    private func exercise(appearance: String) throws {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-demo-quiet-hours-old-plugin",
                               "-loopdy.demo.appearance", appearance]
        app.launch()
        openSettings(in: app)
        settingsRow("settings.menu.notifications", in: app).tap()

        let page = app.descendants(matching: .any)["settings.notifications"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 8))
        let toggle = app.switches["settings.notifications.quiet-hours"].firstMatch
        for _ in 0..<8 where !(toggle.exists && toggle.isHittable) { page.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Quiet Hours is on the Notifications page")
        if toggle.value as? String != "On" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        XCTAssertEqual(toggle.value as? String, "On")

        let start = app.datePickers["settings.notifications.quiet-hours.start"].firstMatch
        let end = app.datePickers["settings.notifications.quiet-hours.end"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5), "Start time shows once it's on")
        XCTAssertTrue(end.exists, "End time shows once it's on")
        let note = app.staticTexts["settings.notifications.quiet-hours.note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.label, "Quiet Hours needs a plugin update on Studio Mac.")
        for _ in 0..<3 where !note.isHittable { page.swipeUp() }
        save("quiet-hours-\(appearance)", app)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_QUIET_HOURS_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
