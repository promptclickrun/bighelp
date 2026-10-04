import XCTest

/// ☰ › Usage on demo data: it sits right above Settings, opens one page with
/// plans and limits, the chart, totals and the models behind them, and covers
/// every computer while All hosts is on. The chat's ⋯ opens the same page.
/// BIGHELP_USAGE_EVIDENCE (TEST_RUNNER_…) saves screenshots;
/// BIGHELP_USAGE_APPEARANCE picks light or dark (light by default).
final class ProviderUsageUITests: BighelpUITestCase {
    private var appearance: String { ProcessInfo.processInfo.environment["BIGHELP_USAGE_APPEARANCE"] ?? "light" }

    @MainActor
    func testUsageOpensFromTheMenuAboveSettings() throws {
        let app = launch(["-bighelp.hosts.all-hosts", "NO"])
        openMenu(app)
        let usage = app.buttons["menu.usage"]
        let settings = app.buttons["menu.settings"]
        XCTAssertTrue(usage.waitForExistence(timeout: 8), "Usage is in ☰")
        XCTAssertTrue(usage.isHittable, "on the first screen")
        XCTAssertLessThan(usage.frame.maxY, settings.frame.minY + 2, "right above Settings")
        XCTAssertLessThan(app.buttons["menu.scheduled-tasks"].frame.maxY, usage.frame.minY + 2)
        XCTAssertEqual(app.buttons.matching(identifier: "menu.usage").count, 1, "One Usage, not a second copy under More")
        save("usage-0-menu-\(appearance)", app)
        usage.tap()

        let page = expectPage(app)
        XCTAssertTrue(app.descendants(matching: .any)["provider-usage.claude"].waitForExistence(timeout: 8),
                      "Plans and limits are on the page")
        let hero = app.descendants(matching: .any)["usage.hero.value"]
        XCTAssertTrue(hero.waitForExistence(timeout: 8))
        XCTAssertTrue(hero.label.hasPrefix("$"), "Cost first when agents spent money: \(hero.label)")
        save("usage-1-top-\(appearance)", app)

        // Seven days reads again; tokens switch the measure.
        let week = app.buttons["usage.range.week"]
        XCTAssertTrue(week.exists)
        week.tap()
        XCTAssertTrue(week.isSelected)
        app.buttons["usage.metric.tokens"].tap()
        XCTAssertFalse(hero.label.hasPrefix("$"), "Tokens: \(hero.label)")
        app.buttons["usage.metric.cost"].tap()
        app.buttons["usage.range.month"].tap()

        // A model charts against everything else; the chip clears it.
        let model = app.buttons["usage.models.row.claude-opus-5-5"]
        for _ in 0..<6 where !(model.exists && model.isHittable) { page.swipeUp() }
        XCTAssertTrue(model.exists, "Models are listed")
        save("usage-2-models-\(appearance)", app)
        model.tap()
        XCTAssertTrue(model.isSelected)
        let clear = app.buttons["usage.focus.clear"]
        for _ in 0..<6 where !clearOfHeader(clear, in: app) { page.swipeDown() }
        XCTAssertTrue(clear.waitForExistence(timeout: 3), "The chart names what it shows")
        save("usage-3-one-model-\(appearance)", app)
        clear.tap()
        XCTAssertFalse(clear.exists)

        // Choose hides a plan here; Show All brings it back.
        let choose = app.buttons["usage.limits.choose"]
        for _ in 0..<6 where !clearOfHeader(choose, in: app) { page.swipeDown() }
        choose.tap()
        let openRouter = app.switches["usage.limits.choice.openrouter"]
        XCTAssertTrue(openRouter.waitForExistence(timeout: 5))
        let showAll = app.buttons["usage.limits.show-all"]
        if showAll.exists { showAll.tap() }
        let control = openRouter.switches.firstMatch.exists ? openRouter.switches.firstMatch : openRouter
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.buttons["usage.limits.done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["provider-usage.claude"].waitForExistence(timeout: 5))
        // Two plans show at first; the rest are a tap away.
        let more = app.buttons["usage.limits.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 3))
        more.tap()
        XCTAssertTrue(app.descendants(matching: .any)["provider-usage.copilot"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["provider-usage.openrouter"].exists, "Hidden plans stay hidden")
        save("usage-6-all-plans-\(appearance)", app)
        choose.tap()
        XCTAssertTrue(showAll.waitForExistence(timeout: 5))
        showAll.tap()
        app.buttons["usage.limits.done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["provider-usage.openrouter"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testAllHostsAddsUpEveryComputer() throws {
        let app = launch(["-bighelp.hosts.all-hosts", "NO"])
        openMenu(app)
        let allHosts = app.buttons["menu.all-hosts"]
        XCTAssertTrue(allHosts.waitForExistence(timeout: 5))
        allHosts.tap()
        XCTAssertTrue(app.descendants(matching: .any)["fleet.home"].waitForExistence(timeout: 8))
        openMenu(app)
        let usage = app.buttons["menu.usage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        XCTAssertLessThan(usage.frame.maxY, app.buttons["menu.settings"].frame.minY + 2, "Above Settings here too")
        usage.tap()
        XCTAssertFalse(app.buttons["fleet.gate.host.Home Hermes"].waitForExistence(timeout: 2),
                       "Usage covers every host, so it doesn't ask which")

        let page = expectPage(app)
        save("usage-4-all-hosts-\(appearance)", app)
        let studio = app.buttons["usage.hosts.row.Studio Mac"]
        for _ in 0..<10 where !(studio.exists && studio.isHittable) { page.swipeUp() }
        XCTAssertTrue(studio.exists, "Each computer has a row")
        let office = app.buttons["usage.hosts.row.Office Linux"]
        XCTAssertTrue(office.exists)
        XCTAssertTrue(office.label.contains("Couldn't reach"), "A computer out of reach says so: \(office.label)")
        XCTAssertTrue(app.buttons["usage.agents.row.Rio Tanaka"].exists, "Agents on other computers are counted")
        save("usage-5-computers-\(appearance)", app)
        studio.tap()
        XCTAssertTrue(studio.isSelected)
    }

    /// Limits' computer menu: all of them, each under its own name, or just one.
    /// One computer has no menu at all.
    @MainActor
    func testLimitsShowOneComputerOrAllUnderTheirNames() throws {
        let app = launch(["-bighelp.hosts.all-hosts", "YES"])
        openMenu(app)
        let usage = app.buttons["menu.usage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 8))
        usage.tap()
        _ = expectPage(app)
        let any = app.descendants(matching: .any)
        let menu = app.buttons["usage.limits.computer"]
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "Several computers: a menu picks which")

        menu.tap()
        let all = app.buttons["All computers"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Home Hermes"].exists && app.buttons["Studio Mac"].exists
                      && app.buttons["Office Linux"].exists, "Every computer is a choice")
        all.tap()
        XCTAssertTrue(menu.label.contains("All computers"), menu.label)
        for name in ["Home Hermes", "Studio Mac", "Office Linux"] {
            XCTAssertTrue(any["usage.limits.host.\(name)"].waitForExistence(timeout: 8), "\(name) has its own heading")
        }
        // Home Hermes and Studio Mac both have a Claude plan, each under its own computer.
        XCTAssertEqual(any.matching(identifier: "provider-usage.claude").count, 2)
        XCTAssertLessThan(any["usage.limits.host.Home Hermes"].frame.minY,
                          any["usage.limits.host.Studio Mac"].frame.minY, "The computer in use first")
        XCTAssertTrue(any.matching(NSPredicate(format: "label CONTAINS %@", "Couldn't reach this computer"))
            .firstMatch.exists, "One out of reach says so in its own section")
        save("usage-7-limits-all-computers-\(appearance)", app)

        menu.tap()
        app.buttons["Studio Mac"].tap()
        XCTAssertTrue(menu.label.contains("Studio Mac"), menu.label)
        XCTAssertTrue(any["provider-usage.openrouter"].waitForExistence(timeout: 5))
        XCTAssertFalse(any["provider-usage.codex"].exists, "Only Studio Mac's plans")
        XCTAssertFalse(any["usage.limits.host.Studio Mac"].exists, "The menu says which; no headings")
        save("usage-8-limits-one-computer-\(appearance)", app)

        menu.tap()
        app.buttons["Home Hermes"].tap()
        XCTAssertTrue(menu.label.contains("Home Hermes"), menu.label)
        XCTAssertTrue(any["provider-usage.claude"].waitForExistence(timeout: 5))
        XCTAssertEqual(any.matching(identifier: "provider-usage.claude").count, 1)
    }

    /// Share, top right: PDF, PNG, HTML and CSV, each to the system share sheet.
    @MainActor
    func testShareOffersFourFormats() throws {
        let app = launch(["-bighelp.hosts.all-hosts", "YES", "-test-slow-usage-export"])
        openMenu(app)
        app.buttons["menu.usage"].tap()
        _ = expectPage(app)
        let share = app.buttons["usage.share"]
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        XCTAssertTrue(share.isEnabled, "Something to share once usage loads")
        XCTAssertLessThan(app.buttons["usage.refresh"].frame.minX - share.frame.minX, 200, "Top right, beside Refresh")
        share.tap()
        for title in ["PDF", "Image (PNG)", "Web page (HTML)", "Spreadsheet (CSV)"] {
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5), "\(title) is offered")
        }
        save("usage-9-share-\(appearance)", app)
        app.buttons["PDF"].tap()
        // Drawing the file takes a moment; the page says so instead of freezing.
        XCTAssertTrue(app.descendants(matching: .any)["usage.exporting"].waitForExistence(timeout: 3),
                      "Exporting shows while the file is made")
        save("usage-10-exporting-\(appearance)", app)
        // The system share sheet, with the file ready to send.
        let sheet = app.otherElements["ActivityListView"]
        let named = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Usage, ")).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 15) || named.waitForExistence(timeout: 5), "The share sheet opens")
        save("usage-11-share-sheet-\(appearance)", app)
    }

    @MainActor
    func testOneComputerHasNoLimitsMenu() throws {
        let app = launch(["-bighelp.hosts.all-hosts", "NO"])
        openMenu(app)
        app.buttons["menu.usage"].tap()
        _ = expectPage(app)
        XCTAssertTrue(app.descendants(matching: .any)["provider-usage.claude"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["usage.limits.computer"].exists)
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "usage.limits.host.")).count, 0, "No computer names")
    }

    @MainActor
    func testTheChatMenuOpensTheSamePage() throws {
        let app = launch(["-preview-simple-chat"])
        let conversation = app.buttons["session.row.demo-finance"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 15))
        conversation.tap()
        let options = app.buttons["chat.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        let usage = app.buttons["chat.provider-usage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        usage.tap()
        _ = expectPage(app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["chat.options"].waitForExistence(timeout: 5), "Back returns to the chat")
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-use-multi-host-fixtures",
                               "-loopdy.demo.appearance", appearance] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func openMenu(_ app: XCUIApplication) {
        let menu = app.buttons.matching(NSPredicate(format: "identifier IN %@", ["home.drawer.open", "chat.menu"])).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "☰ menu")
        menu.tap()
    }

    /// On screen and below the glass header, which takes taps over the page.
    @MainActor
    private func clearOfHeader(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable else { return false }
        return element.frame.minY > app.navigationBars.firstMatch.frame.maxY
    }

    @MainActor
    private func expectPage(_ app: XCUIApplication) -> XCUIElement {
        let page = app.descendants(matching: .any)["usage"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 8), "Usage opens")
        XCTAssertTrue(app.descendants(matching: .any)["usage.hero"].waitForExistence(timeout: 8), "Usage loads")
        sleep(1)
        return page
    }

    @MainActor
    private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_USAGE_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
