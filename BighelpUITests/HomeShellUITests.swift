import XCTest

/// The one home: three places (Bots or Chats, Today, Work), New chat beside the bar, Settings behind
/// the person's circle, and every chat a pushed page with Back. Set BIGHELP_HOME_EVIDENCE
/// (TEST_RUNNER_BIGHELP_HOME_EVIDENCE) to a folder to save a screenshot of each screen, light and dark.
final class HomeShellUITests: BighelpUITestCase {
    // Each scenario runs once in light and once in dark, as tests of their own: a test's launches
    // share one saved state, and the second look must start from a clean one.

    @MainActor func testALaunchLandsOnThePlaceThePersonPicked() { aLaunchLandsOnThePlaceThePersonPicked("light") }
    @MainActor func testALaunchLandsOnThePlaceThePersonPickedInDark() { aLaunchLandsOnThePlaceThePersonPicked("dark") }

    @MainActor
    private func aLaunchLandsOnThePlaceThePersonPicked(_ appearance: String) {
        do {
            let roots = ["bots": "simple-bots.home", "chats": "chats.inbox", "today": "today.home", "work": "work.screen"]
            for landing in ["bots", "chats", "today", "work"] {
                let app = launch(landing: landing, appearance: appearance)
                XCTAssertTrue(element(roots[landing]!, in: app).waitForExistence(timeout: 20), "\(landing) is the root")
                XCTAssertTrue(app.buttons["home.new-chat"].firstMatch.waitForExistence(timeout: 5), "The bar shows at the root")
                XCTAssertFalse(app.textViews["chat.composer.text"].exists, "No chat opens by itself")
                shot("landing-\(landing)", appearance, app)
                app.terminate()
            }
        }
    }

    @MainActor func testTheSwitchTheTabsAndTheCircle() { theSwitchTheTabsAndTheCircle("light") }
    @MainActor func testTheSwitchTheTabsAndTheCircleInDark() { theSwitchTheTabsAndTheCircle("dark") }

    @MainActor
    private func theSwitchTheTabsAndTheCircle(_ appearance: String) {
        do {
            let app = launch(landing: "bots", appearance: appearance)
            XCTAssertTrue(element("simple-bots.home", in: app).waitForExistence(timeout: 20))
            app.buttons["home.switch.chats"].firstMatch.tap()
            XCTAssertTrue(element("chats.inbox", in: app).waitForExistence(timeout: 10), "The switch shows Chats")
            shot("switch-to-chats", appearance, app)
            app.buttons["home.switch.bots"].firstMatch.tap()
            XCTAssertTrue(element("simple-bots.home", in: app).waitForExistence(timeout: 10), "And Bots again")

            app.buttons["home.tab.today"].firstMatch.tap()
            XCTAssertTrue(element("today.home", in: app).waitForExistence(timeout: 10))
            app.buttons["home.tab.work"].firstMatch.tap()
            XCTAssertTrue(element("work.screen", in: app).waitForExistence(timeout: 10))
            app.buttons["home.tab.conversations"].firstMatch.tap()
            XCTAssertTrue(element("simple-bots.home", in: app).waitForExistence(timeout: 10), "The view stays as it was left")

            for tab in ["conversations", "today", "work"] {
                app.buttons["home.tab.\(tab)"].firstMatch.tap()
                let circle = app.buttons["simple-bots.settings"].firstMatch
                XCTAssertTrue(circle.waitForExistence(timeout: 10), "The circle is on \(tab)")
                XCTAssertFalse(app.buttons["home.drawer.open"].exists, "iPhone has no menu on \(tab)")
                circle.tap()
                XCTAssertTrue(element("settings.screen", in: app).waitForExistence(timeout: 10), "It opens Settings from \(tab)")
                if tab == "conversations" { shot("settings", appearance, app) }
                app.buttons["Done"].firstMatch.tap()
                XCTAssertTrue(app.buttons["home.new-chat"].firstMatch.waitForExistence(timeout: 10))
            }
            app.terminate()
        }
    }

    @MainActor func testAChatIsAPushedPageWithBackTheBotAndNoBar() { aChatIsAPushedPageWithBackTheBotAndNoBar("light") }
    @MainActor func testAChatIsAPushedPageWithBackTheBotAndNoBarInDark() { aChatIsAPushedPageWithBackTheBotAndNoBar("dark") }

    @MainActor
    private func aChatIsAPushedPageWithBackTheBotAndNoBar(_ appearance: String) {
        do {
            let app = launch(landing: "chats", appearance: appearance)
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chats.row.")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            row.tap()
            let back = app.buttons["chat.back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 15), "A chat has Back")
            XCTAssertTrue(app.buttons["chat.options"].firstMatch.exists, "And its options")
            XCTAssertTrue(app.textViews["chat.composer.text"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["home.tab.today"].exists, "No bar under a chat")
            XCTAssertFalse(app.buttons["home.new-chat"].exists)
            shot("chat-from-chats", appearance, app)

            let identity = app.buttons["chat.identity"].firstMatch
            XCTAssertTrue(identity.waitForExistence(timeout: 5), "The bot is in the header")
            identity.tap()
            XCTAssertTrue(element("simple-bots.profile", in: app).waitForExistence(timeout: 10), "It opens the bot's page")
            shot("bot-page-from-chat", appearance, app)
            app.buttons["simple-bots.profile.back"].firstMatch.tap()

            XCTAssertTrue(back.waitForExistence(timeout: 10))
            back.tap()
            XCTAssertTrue(element("chats.inbox", in: app).waitForExistence(timeout: 10), "Back returns to Chats")
            XCTAssertTrue(app.buttons["home.tab.today"].firstMatch.waitForExistence(timeout: 5), "With the bar")
            shot("back-on-chats", appearance, app)

            // The computer in use's own Sessions page (projects, imports) is one row down the list.
            let thisComputer = app.buttons["chats.more.this-computer"].firstMatch
            for _ in 0..<20 where !(thisComputer.exists && thisComputer.isHittable) {
                element("chats.inbox", in: app).swipeUp(velocity: .fast)
            }
            XCTAssertTrue(thisComputer.exists && thisComputer.isHittable, "This computer is at the end of Chats")
            thisComputer.tap()
            XCTAssertTrue(app.navigationBars["Chats"].waitForExistence(timeout: 10), "It is a pushed page")
            XCTAssertFalse(app.buttons["home.new-chat"].exists)
            shot("chats-this-computer", appearance, app)
            app.navigationBars["Chats"].buttons.firstMatch.tap()
            XCTAssertTrue(element("chats.inbox", in: app).waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    @MainActor func testNewChatWithOneBotBecomesAnOrdinaryChat() { newChatWithOneBotBecomesAnOrdinaryChat("light") }
    @MainActor func testNewChatWithOneBotBecomesAnOrdinaryChatInDark() { newChatWithOneBotBecomesAnOrdinaryChat("dark") }

    @MainActor
    private func newChatWithOneBotBecomesAnOrdinaryChat(_ appearance: String) {
        do {
            let app = launch(landing: "chats", appearance: appearance)
            openNewChat(in: app)
            shot("new-chat", appearance, app)

            app.buttons["new-chat.bot.travel"].firstMatch.tap()
            XCTAssertTrue(element("new-chat.to.chip.travel", in: app).waitForExistence(timeout: 10), "The pick is in the To row")
            shot("new-chat-one-bot", appearance, app)

            // The plain demo's computer makes no group chats, so the other bots show dimmed: a tap on
            // one adds nobody and says why.
            app.buttons["new-chat.bot.finance"].firstMatch.tap()
            XCTAssertTrue(element("new-chat.to.refusal", in: app).waitForExistence(timeout: 5), "A bot that can't join says why")
            XCTAssertFalse(element("new-chat.to.chip.finance", in: app).exists)

            send("Plan one day in Lisbon", in: app)
            XCTAssertTrue(element("new-chat.to", in: app).waitForNonExistence(timeout: 15), "Once sent it is an ordinary chat")
            XCTAssertFalse(element("new-chat.people", in: app).exists)
            XCTAssertTrue(app.buttons["chat.identity"].firstMatch.waitForExistence(timeout: 10), "With its bot in the header")
            shot("new-chat-one-bot-sent", appearance, app)

            app.buttons["chat.back"].firstMatch.tap()
            XCTAssertTrue(element("chats.inbox", in: app).waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    @MainActor func testNewChatWithTwoBotsOpensAGroupChat() { newChatWithTwoBotsOpensAGroupChat("light") }
    @MainActor func testNewChatWithTwoBotsOpensAGroupChatInDark() { newChatWithTwoBotsOpensAGroupChat("dark") }

    @MainActor
    private func newChatWithTwoBotsOpensAGroupChat(_ appearance: String) {
        do {
            // The demo makes group chats only with this argument; they then sit quiet.
            let app = launch(landing: "bots", appearance: appearance, extra: ["-preview-group-create"])
            openNewChat(in: app)
            app.buttons["new-chat.bot.finance"].firstMatch.tap()
            XCTAssertTrue(element("new-chat.to.chip.finance", in: app).waitForExistence(timeout: 10))
            // Here a second bot can join, so nobody is dimmed.
            shot("new-chat-group-one-bot", appearance, app)
            app.buttons["new-chat.bot.travel"].firstMatch.tap()
            XCTAssertTrue(element("new-chat.to.chip.travel", in: app).waitForExistence(timeout: 10))
            shot("new-chat-two-bots", appearance, app)

            send("What should a week in Lisbon cost?", in: app)
            XCTAssertTrue(element("new-chat.to", in: app).waitForNonExistence(timeout: 20), "The group chat takes New chat's place")
            XCTAssertTrue(app.textViews["chat.composer.text"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["chat.back"].firstMatch.exists)
            // The group chat's own ⋯ has Group Settings; a chat with one bot doesn't.
            XCTAssertTrue(chatMenuItem("chat.group-settings", in: app).exists, "It is a group chat")
            app.tapCoordinate(x: 0.5, y: 0.5)
            shot("new-chat-group-sent", appearance, app)

            app.buttons["chat.back"].firstMatch.tap()
            XCTAssertTrue(element("simple-bots.home", in: app).waitForExistence(timeout: 10), "No blank chat is left under it")
            app.terminate()
        }
    }

    @MainActor func testTodayHasItsCardPanelsAndEdit() { todayHasItsCardPanelsAndEdit("light") }
    @MainActor func testTodayHasItsCardPanelsAndEditInDark() { todayHasItsCardPanelsAndEdit("dark") }

    @MainActor
    private func todayHasItsCardPanelsAndEdit(_ appearance: String) {
        do {
            let app = launch(landing: "today", appearance: appearance)
            XCTAssertTrue(element("today.home", in: app).waitForExistence(timeout: 20))
            XCTAssertTrue(element("today.boards.kind", in: app).waitForExistence(timeout: 10), "Feed, Ideas and Goals")
            shot("today", appearance, app)

            app.buttons["today.boards.see-all"].firstMatch.tap()
            XCTAssertTrue(app.buttons["today.board-page.back"].firstMatch.waitForExistence(timeout: 10), "See all is a page with Back")
            XCTAssertFalse(app.buttons["home.new-chat"].exists)
            shot("today-see-all", appearance, app)
            app.buttons["today.board-page.chip.finance"].firstMatch.tap()
            shot("today-see-all-one-bot", appearance, app)
            app.buttons["today.board-page.back"].firstMatch.tap()
            XCTAssertTrue(element("today.boards.kind", in: app).waitForExistence(timeout: 10))

            let space = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "today.space.", ".open")).firstMatch
            if space.waitForExistence(timeout: 10) {
                for _ in 0..<4 where !space.isHittable { element("today.home", in: app).swipeUp() }
                shot("today-space-panel", appearance, app)
                space.tap()
                sleep(3)
                shot("today-space-page", appearance, app)
                let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Done"])).firstMatch
                if close.waitForExistence(timeout: 5) { close.tap() }
                // The Wide panel below it, for a look at its bottom edge (whole lines only).
                element("today.home", in: app).swipeUp()
                shot("today-space-wide", appearance, app)
                element("today.home", in: app).swipeDown()
            } else {
                XCTFail("The demo's space has no panel on Today")
            }

            let edit = app.buttons["today.edit"].firstMatch
            XCTAssertTrue(edit.waitForExistence(timeout: 10))
            edit.tap()
            let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "today.edit.row."))
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "Edit lists the panels")
            shot("today-edit", appearance, app)
            edit.tap()
            XCTAssertTrue(element("today.boards.kind", in: app).waitForExistence(timeout: 10), "Done shows them again")
            app.terminate()
        }
    }

    @MainActor func testWorkHasItsChipsCardsAndDoors() { workHasItsChipsCardsAndDoors("light") }
    @MainActor func testWorkHasItsChipsCardsAndDoorsInDark() { workHasItsChipsCardsAndDoors("dark") }

    @MainActor
    private func workHasItsChipsCardsAndDoors(_ appearance: String) {
        do {
            let app = launch(landing: "work", appearance: appearance)
            XCTAssertTrue(element("work.screen", in: app).waitForExistence(timeout: 20))
            XCTAssertTrue(element("work.filters", in: app).waitForExistence(timeout: 10))
            let card = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "work.item.")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 15), "The demo has work to show")
            shot("work", appearance, app)

            app.buttons["work.filter.working"].firstMatch.tap()
            shot("work-working", appearance, app)
            app.buttons["work.filter.all"].firstMatch.tap()

            XCTAssertTrue(card.waitForExistence(timeout: 5))
            card.tap()
            XCTAssertTrue(app.buttons["home.new-chat"].firstMatch.waitForNonExistence(timeout: 10), "A card opens its page over Work")
            shot("work-card-open", appearance, app)
            leavePushedPage(in: app)
            XCTAssertTrue(element("work.screen", in: app).waitForExistence(timeout: 10))

            let door = app.buttons["work.door.schedules"].firstMatch
            for _ in 0..<5 where !(door.exists && door.isHittable) { element("work.screen", in: app).swipeUp() }
            shot("work-doors", appearance, app)
            XCTAssertTrue(door.exists && door.isHittable, "Schedules is one tap down")
            door.tap()
            XCTAssertTrue(app.buttons["home.new-chat"].firstMatch.waitForNonExistence(timeout: 10), "The door opens its page")
            shot("work-door-open", appearance, app)
            leavePushedPage(in: app)
            XCTAssertTrue(element("work.screen", in: app).waitForExistence(timeout: 10), "Back returns to Work")
            app.terminate()
        }
    }

    // MARK: Helpers

    @MainActor
    private func launch(landing: String, appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-bighelp.home.migrated-v1", "YES",
                               "-loopdy.home.landing", landing, "-bighelp.hosts.all-hosts", "NO",
                               "-loopdy.demo.appearance", appearance] + extra
        app.launch()
        return app
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    @MainActor
    private func openNewChat(in app: XCUIApplication) {
        let newChat = app.buttons["home.new-chat"].firstMatch
        XCTAssertTrue(newChat.waitForExistence(timeout: 20))
        newChat.tap()
        XCTAssertTrue(element("new-chat.to", in: app).waitForExistence(timeout: 15), "New chat has its To row")
        XCTAssertTrue(element("new-chat.people", in: app).waitForExistence(timeout: 10), "And the bots to pick from")
        XCTAssertTrue(app.buttons["chat.back"].firstMatch.exists, "It is a chat: Back leaves it")
        XCTAssertFalse(app.buttons["home.tab.today"].exists, "No bar under it")
    }

    @MainActor
    private func send(_ text: String, in app: XCUIApplication) {
        let editor = app.textViews["chat.composer.text"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText(text)
        let send = app.buttons["chat.send"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
    }

    /// A chat's own Back, a bot page's, else the navigation bar's.
    @MainActor
    private func leavePushedPage(in app: XCUIApplication) {
        for identifier in ["chat.back", "simple-bots.profile.back"] {
            let back = app.buttons[identifier].firstMatch
            if back.exists, back.isHittable { back.tap(); return }
        }
        let back = app.navigationBars.buttons.firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() }
    }

    @MainActor
    private func shot(_ name: String, _ appearance: String, _ app: XCUIApplication) {
        // A push or a sheet still moving would be caught halfway.
        usleep(700_000)
        let image = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "\(name)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_HOME_EVIDENCE"], !folder.isEmpty else { return }
        try? image.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(appearance).png"))
    }
}

private extension XCUIApplication {
    /// Closes an open menu without picking from it.
    @MainActor
    func tapCoordinate(x: CGFloat, y: CGFloat) {
        windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }
}
