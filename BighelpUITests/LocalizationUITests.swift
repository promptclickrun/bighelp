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
            capture("chat-actions", language, appearance)
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
