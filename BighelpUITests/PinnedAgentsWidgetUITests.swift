import XCTest

/// The Pinned Agents widget opens bighelp with a link naming an agent, and for
/// Multi Gateway the computer it's on. On the demo data: Home Hermes is the
/// demo's own computer, Studio Mac a sample one that can be listed but not
/// opened. Set BIGHELP_PINNED_WIDGET_EVIDENCE (TEST_RUNNER_…) to save screenshots.
final class PinnedAgentsWidgetUITests: BighelpUITestCase {
    private static let homeHermes = "0D0D0D0D-0000-4000-8000-000000000001"
    private static let studioMac = "0D0D0D0D-0000-4000-8000-000000000002"

    @MainActor
    func testCurrentGatewayTapOpensThatAgentsChat() throws {
        let app = launchInBackground()
        app.open(URL(string: "loopdy://agent-chat?agent=travel")!)
        expectChat(with: "Mina Shah", in: app)
        save("current-gateway", app)
    }

    @MainActor
    func testMultiGatewayTapOpensTheAgentOnItsComputer() throws {
        let app = launchInBackground()
        app.open(URL(string: "loopdy://agent-chat?agent=home&host=\(Self.homeHermes)")!)
        expectChat(with: "Jordan Lee", in: app)
        save("multi-gateway", app)

        // Another computer's agent: the demo's sample computer can't be opened, and says so.
        app.open(URL(string: "loopdy://agent-chat?agent=research&host=\(Self.studioMac)")!)
        expectMessage("Studio Mac is a sample host in this demo.", in: app)
    }

    @MainActor
    func testUnknownComputersAndAgentsSayWhyPlainly() throws {
        let app = launchInBackground()
        app.open(URL(string: "loopdy://agent-chat?agent=finance&host=0D0D0D0D-0000-4000-8000-0000000000FF")!)
        expectMessage("That computer isn't in bighelp anymore.", in: app)
        app.open(URL(string: "loopdy://agent-chat?agent=deleted-agent")!)
        expectMessage("That agent isn't on this computer anymore.", in: app)
        app.open(URL(string: "loopdy://agent-chat?agent=deleted-agent&host=\(Self.homeHermes)")!)
        expectMessage("That agent isn't on Home Hermes anymore.", in: app)
    }

    // MARK: Helpers

    /// Like a widget tap: bighelp is in the background when the link arrives.
    @MainActor
    private func launchInBackground() -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        return app
    }

    @MainActor
    private func expectChat(with name: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let composer = app.textViews["chat.composer.text"]
        let opened = composer.waitForExistence(timeout: 20)
        let alert = app.alerts.firstMatch
        XCTAssertFalse(alert.exists, alert.exists ? alert.staticTexts.allElementsBoundByIndex.map(\.label)
            .joined(separator: " | ") : "", file: file, line: line)
        XCTAssertTrue(opened, "The link opens a chat", file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", name))
            .firstMatch.waitForExistence(timeout: 5), "It's \(name)'s chat", file: file, line: line)
    }

    @MainActor
    private func expectMessage(_ message: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let alert = app.alerts["Unable to open"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "A plain message, not a crash", file: file, line: line)
        XCTAssertTrue(alert.staticTexts[message].exists,
                      alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "), file: file, line: line)
        save("message-\(abs(message.hashValue) % 10_000)", app)
        alert.buttons.firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, file: file, line: line)
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_PINNED_WIDGET_EVIDENCE"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("pinned-link-\(name).png")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: url)
    }
}
