import XCTest

/// Fixture-only coverage: launch in the actual app language, not just a SwiftUI locale preview.
@MainActor
final class LocalizationUITests: BighelpUITestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let variants = [("en", "light"), ("en", "dark"), ("zh-Hans", "light"), ("zh-Hans", "dark")]

    func testWelcomeConsentAndConnectInBothLanguagesAndAppearances() {
        for (language, appearance) in variants {
            let app = localizedApp(language, appearance, extra: [
                "-test-no-configured-hosts", "-force-signed-out-onboarding",
                "-loopdy.onboarding.first-run-v1.step", "0", "-bighelp.privacy.ai-data-agreed", "NO"
            ])
            app.launch()
            let start = app.buttons["onboarding.get-started"]
            XCTAssertTrue(start.waitForExistence(timeout: 20))
            XCTAssertEqual(start.label, language == "en" ? "Get Started" : "开始使用")
            capture("welcome", language, appearance)
            app.buttons["onboarding.customize-appearance"].tap()
            let next = app.buttons["onboarding.appearance.continue"]
            XCTAssertTrue(next.waitForExistence(timeout: 5))
            XCTAssertEqual(next.label, language == "en" ? "Continue" : "继续")
            capture("appearance", language, appearance)
            next.tap()
            let agree = app.buttons["onboarding.ai-consent.agree"]
            XCTAssertTrue(agree.waitForExistence(timeout: 5))
            XCTAssertEqual(agree.label, language == "en" ? "Agree and continue" : "同意并继续")
            capture("consent", language, appearance)
            agree.tap()
            XCTAssertTrue(app.textFields["host-setup.address"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[language == "en" ? "Connect your computer" : "连接你的电脑"].exists)
            capture("connect", language, appearance)
            app.terminate()
        }
    }

    func testOptionalPluginAndModeInBothLanguagesAndAppearances() {
        for (language, appearance) in variants {
            let app = localizedApp(language, appearance, extra: [
                "-force-signed-out-onboarding", "-bighelp.onboarding.after-connect", "YES",
                "-loopdy.onboarding.first-run-v1.step", "3"
            ])
            app.launch()
            let install = app.buttons["onboarding.plugin.install"]
            XCTAssertTrue(install.waitForExistence(timeout: 20))
            XCTAssertEqual(install.label, language == "en" ? "Install Plugin" : "安装插件")
            capture("plugin", language, appearance)
            app.buttons["onboarding.skip"].tap()
            let use = app.buttons["onboarding.mode.continue"]
            XCTAssertTrue(use.waitForExistence(timeout: 5))
            XCTAssertEqual(use.label, language == "en" ? "Use Bots" : "使用机器人")
            XCTAssertTrue(use.isHittable)
            capture("mode", language, appearance)
            app.terminate()

            let notifications = localizedApp(language, appearance, extra: [
                "-force-signed-out-onboarding", "-bighelp.onboarding.after-connect", "YES",
                "-loopdy.onboarding.first-run-v1.step", "4"
            ])
            notifications.launch()
            let enable = notifications.buttons["onboarding.notifications.enable"]
            XCTAssertTrue(enable.waitForExistence(timeout: 20))
            XCTAssertEqual(enable.label, language == "en" ? "Turn On Notifications" : "开启通知")
            capture("notifications", language, appearance)
            notifications.terminate()
        }
    }

    func testNavigationSettingsAndComposerInBothLanguagesAndAppearances() {
        for (language, appearance) in variants {
            let app = localizedApp(language, appearance)
            app.launch()
            XCTAssertTrue(app.buttons["tab.feed"].waitForExistence(timeout: 20))
            XCTAssertEqual(app.buttons["tab.feed"].label, language == "en" ? "Feed" : "动态")
            let menu = app.buttons["home.drawer.open"].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            menu.tap()
            let settings = app.buttons["menu.settings"]
            let menuList = app.descendants(matching: .any)["navigation.menu"].firstMatch
            XCTAssertTrue(menuList.waitForExistence(timeout: 5))
            for _ in 0..<4 where !settings.isHittable { menuList.swipeUp() }
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            XCTAssertTrue(settings.label.contains(language == "en" ? "Settings" : "设置"))
            capture("menu", language, appearance)
            settings.tap()
            XCTAssertTrue(app.textFields["profile.display-name"].waitForExistence(timeout: 5))
            capture("settings-identity", language, appearance)
            let appearanceRow = settingsRow("settings.themes", in: app)
            XCTAssertTrue(appearanceRow.waitForExistence(timeout: 5))
            XCTAssertTrue(appearanceRow.label.contains(language == "en" ? "Appearance" : "外观"))
            // Hittable can include a row just below a Form's viewport; reveal the lower rows for evidence.
            app.descendants(matching: .any)["settings.screen"].firstMatch.swipeUp()
            capture("settings", language, appearance)
            app.terminate()

            app.launchArguments += ["-start-chat"]
            app.launch()
            let attachment = app.buttons["chat.attachment"]
            XCTAssertTrue(attachment.waitForExistence(timeout: 20))
            XCTAssertEqual(attachment.label, language == "en" ? "Attachments and actions" : "附件与操作")
            capture("chat", language, appearance)
            let editor = app.textViews["chat.composer.text"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            editor.typeText("Settings / 海风")
            XCTAssertEqual(editor.value as? String, "Settings / 海风", "Drafts are never localization keys.")
            let send = app.buttons["chat.send"]
            XCTAssertTrue(send.waitForExistence(timeout: 5))
            XCTAssertEqual(send.label, language == "en" ? "Send message" : "发送消息")
            capture("composer-draft", language, appearance)
            attachment.tap()
            let camera = app.buttons["chat.action.camera"]
            XCTAssertTrue(camera.waitForExistence(timeout: 5))
            XCTAssertTrue(camera.label.contains(language == "en" ? "Camera" : "相机"))
            XCTAssertTrue(app.buttons["chat.action.voice"].label.contains(language == "en" ? "Voice mode" : "语音模式"))
            XCTAssertTrue(app.buttons["chat.action.pdf-pages"].label.contains(language == "en" ? "PDF as pages" : "PDF 页面"))
            capture("chat-actions", language, appearance)
            app.terminate()
        }
    }

    /// #527: Simple Bot mode's home, a bot's menu with More, Rearrange, search, New Bot with Templates, and a profile.
    func testSimpleBotHomeMenuAndProfileInBothLanguagesAndAppearances() {
        for (language, appearance) in variants {
            let say = { (english: String, chinese: String) in language == "en" ? english : chinese }
            let app = localizedApp(language, appearance, extra: ["-bighelp.settings.simple-bots", "YES"])
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.home"].waitForExistence(timeout: 20))
            let search = app.buttons["simple-bots.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            XCTAssertEqual(search.label, say("Search bots", "搜索机器人"))
            capture("simple-home", language, appearance)

            app.buttons["simple-bots.bot.travel"].press(forDuration: 1.2)
            let unread = app.buttons[say("Mark Unread", "标为未读")]
            XCTAssertTrue(unread.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons[say("Make Primary Bot", "设为主机器人")].exists)
            capture("simple-menu", language, appearance)
            app.buttons[say("Rearrange", "重新排列")].tap()
            let save = app.buttons["simple-bots.rearrange.save"]
            XCTAssertTrue(save.waitForExistence(timeout: 5))
            XCTAssertEqual(save.label, say("Save", "保存"))
            XCTAssertEqual(app.buttons["simple-bots.rearrange.cancel"].label, say("Cancel", "取消"))
            capture("simple-rearrange", language, appearance)
            app.buttons["simple-bots.rearrange.cancel"].tap()

            search.tap()
            let close = app.buttons["simple-bots.search.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertEqual(close.label, say("Close", "关闭"))
            capture("simple-search", language, appearance)
            close.tap()

            app.buttons["simple-bots.new"].tap()
            let newBot = app.buttons[say("New Bot", "新建机器人")]
            XCTAssertTrue(newBot.waitForExistence(timeout: 5))
            newBot.tap()
            XCTAssertTrue(app.textFields["simple-bots.create.name"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["simple-bots.create.submit"].label, say("Create", "创建"))
            capture("simple-create", language, appearance)
            app.buttons["simple-bots.create.templates"].tap()
            XCTAssertTrue(app.navigationBars[say("Templates", "模板")].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["agent.templates.done"].label, say("Done", "完成"))
            capture("simple-templates", language, appearance)
            app.buttons["agent.templates.done"].tap()
            app.buttons["simple-bots.create.close"].tap()

            app.buttons["simple-bots.bot.travel"].press(forDuration: 1.2)
            let more = app.buttons[say("More", "更多")]
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.tap()
            let profile = app.buttons[say("Bot Profile", "机器人资料")]
            XCTAssertTrue(profile.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons[say("Routines", "例行任务")].exists)
            capture("simple-menu-more", language, appearance)
            profile.tap()
            XCTAssertTrue(app.descendants(matching: .any)["simple-bots.profile"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts[say("Instructions", "指令")].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts[say("Default Model", "默认模型")].exists)
            capture("simple-profile", language, appearance)
            app.swipeUp()
            capture("simple-profile-lower", language, appearance)
            app.terminate()
        }
    }

    /// #527: Simple Bot mode's Settings with Teamwork, and the Notifications, Chat and Appearance pages it opens.
    func testSimpleBotSettingsAndItsPagesInBothLanguagesAndAppearances() {
        for (language, appearance) in variants {
            let say = { (english: String, chinese: String) in language == "en" ? english : chinese }
            let app = localizedApp(language, appearance, extra: ["-bighelp.settings.simple-bots", "YES"])
            app.launch()
            let person = app.buttons["simple-bots.settings"]
            XCTAssertTrue(person.waitForExistence(timeout: 20))
            person.tap()
            let teamwork = app.switches["settings.teamwork"]
            XCTAssertTrue(teamwork.waitForExistence(timeout: 10))
            XCTAssertTrue(teamwork.label.contains(say("Teamwork", "团队协作")), teamwork.label)
            XCTAssertTrue(teamwork.label.contains(say("Your bots learn about each other", "机器人会了解彼此")),
                          teamwork.label)
            capture("simple-settings", language, appearance)
            app.swipeUp()
            capture("simple-settings-lower", language, appearance)
            app.swipeDown()

            for (identifier, title) in [("notifications", say("Notifications", "通知")), ("chat", say("Chat", "聊天")),
                                        ("appearance", say("Appearance", "外观"))] {
                let row = app.buttons["simple-bots.settings.\(identifier)"]
                for _ in 0..<3 where !row.isHittable { app.swipeUp() }
                row.tap()
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), title)
                capture("settings-\(identifier)", language, appearance)
                if identifier == "notifications" {
                    let peers = app.staticTexts[say("Agents messaging each other", "智能体之间的消息")]
                    for _ in 0..<5 where !peers.exists { app.swipeUp() }
                    XCTAssertTrue(peers.exists)
                    capture("settings-notifications-lower", language, appearance)
                }
                app.navigationBars[title].buttons.element(boundBy: 0).tap()
            }
            app.terminate()
        }
    }

    /// #527: agents talking to each other, as a line in a Simple Bot mode chat and in its sheet.
    func testTeamworkLineAndSheetInBothLanguagesAndAppearances() {
        for (language, appearance) in variants {
            let say = { (english: String, chinese: String) in language == "en" ? english : chinese }
            let app = localizedApp(language, appearance, extra: [
                "-bighelp.settings.simple-bots", "YES", "-start-chat", "-preview-ui-v3", "-test-agent-talk",
                "-loopdy.chat.foldCompletedTurns", "YES",
            ])
            app.launch()
            let timeline = app.tables["chat.timeline"]
            XCTAssertTrue(timeline.waitForExistence(timeout: 20))
            let label = say("4 messages with Mina Shah and Jordan Lee", "与Mina Shah和Jordan Lee交流了 4 条消息")
            let line = app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@", "chat.agent-talk.", label)).firstMatch
            for _ in 0..<8 where !(line.exists && line.isHittable) {
                if line.exists, line.frame.minY > timeline.frame.midY { timeline.swipeUp(velocity: .slow) }
                else { timeline.swipeDown(velocity: .slow) }
            }
            XCTAssertTrue(line.isHittable, label)
            capture("teamwork-line", language, appearance)
            line.tap()
            let done = app.buttons["chat.agent-talk.done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            XCTAssertEqual(done.label, say("Done", "完成"))
            capture("teamwork-sheet", language, appearance)
            done.tap()
            app.terminate()
        }
    }

    /// The Unified Mode Toggle's pill on Bots mode's home: Bots, Chat and Code (#528).
    func testModePillInBothLanguagesAndAppearances() {
        for (language, appearance) in variants {
            let say = { (english: String, chinese: String) in language == "en" ? english : chinese }
            let app = localizedApp(language, appearance, extra: [
                "-bighelp.settings.simple-bots", "YES", "-bighelp.settings.unified-mode-toggle", "YES",
                "-bighelp.settings.code-mode", "YES",
            ])
            app.launch()
            let bots = app.buttons["mode.pill.bots"]
            XCTAssertTrue(bots.waitForExistence(timeout: 20))
            XCTAssertTrue(bots.isSelected)
            XCTAssertEqual(bots.label, say("Bots", "机器人"))
            XCTAssertEqual(app.buttons["mode.pill.chat"].label, say("Chat", "聊天"))
            XCTAssertEqual(app.buttons["mode.pill.code"].label, say("Code", "代码"))
            XCTAssertEqual(app.buttons["simple-bots.search"].label, say("Search bots", "搜索机器人"))
            capture("mode-pill", language, appearance)
            app.terminate()
        }
    }

    private func localizedApp(_ language: String, _ appearance: String, extra: [String] = []) -> XCUIApplication {
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-loopdy.settings.nerd-mode", "NO",
                               "-loopdy.demo.appearance", appearance, "-AppleLanguages", "(\(language))",
                               "-AppleLocale", language == "en" ? "en_US" : "zh_CN"] + extra
        return app
    }

    private func capture(_ surface: String, _ language: String, _ appearance: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "localization-\(language)-\(appearance)-\(surface)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
