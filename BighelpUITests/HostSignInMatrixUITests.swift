import XCTest

/// Every way a stock Hermes host can ask for sign-in, against real isolated
/// hosts started by Scripts/HostSignInMatrixProbe.py (BIGHELP_SIGNIN_PROBE).
/// Skipped without it.
final class HostSignInMatrixUITests: BighelpUITestCase {
    private struct BrowserMissing: Error {}
    private var probe: [String: String] = [:]

    // MARK: No sign-in

    /// An open host needs no sign-in: the address alone connects, over plain
    /// HTTP once HTTPS finds nothing on this private address.
    @MainActor func testOpenHostConnectsFromTheAddressAlone() throws {
        let app = try beginSetup(mode: "open")
        XCTAssertFalse(methodPicker(app).exists, "No sign-in step")
        XCTAssertTrue(app.descendants(matching: .any)["host-setup.plain-http"].exists, "Says the link isn't encrypted")
        try expectConnected(app)
    }

    /// Leaving the app for a while doesn't cost a new chat its draft, and when the chat is
    /// still there, coming back doesn't ask to continue anything.
    @MainActor func testNewChatDraftStaysAfterLeavingTheApp() throws {
        let app = try beginSetup(mode: "open")
        let draft = try typeDraftInANewChat(app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        sleep(90) // past bighelp's 25-second background hold and Hermes' 20-second orphan grace
        app.activate()
        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30))
        sleep(8) // after reconnecting settles
        save("open-draft-2-back", app)
        XCTAssertFalse(app.alerts["Would you like to continue where you left off?"].exists, "Nothing to offer back")
        XCTAssertFalse(app.staticTexts["Route unavailable"].exists)
        XCTAssertEqual(editor.value as? String, draft, "The draft is still there")
    }

    /// When iOS closes bighelp while it's away, the chat is gone but the draft was kept on the
    /// device: coming back offers to continue it in a new chat with the same agent.
    @MainActor func testNewChatDraftSurvivesTheAppClosing() throws {
        let app = try beginSetup(mode: "open")
        let draft = try typeDraftInANewChat(app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        sleep(2)
        app.terminate()
        app.launch()
        try continueWhereILeftOff(draft, in: app, name: "open-draft-3-relaunched")
    }

    @MainActor private func typeDraftInANewChat(_ app: XCUIApplication) throws -> String {
        let composer = try openFirstChat(app)
        let draft = "Remind me what we said about the trip budget"
        composer.tap()
        composer.typeText(draft)
        save("open-draft-1-typed", app)
        return draft
    }

    @MainActor private func continueWhereILeftOff(_ draft: String, in app: XCUIApplication, name: String) throws {
        let prompt = app.alerts["Would you like to continue where you left off?"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 45), "Coming back offers the unsent draft")
        save(name, app)
        prompt.buttons["Continue"].tap()
        let editor = app.textViews["chat.composer.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 30), "Continue opens a chat")
        let kept = NSPredicate(format: "value == %@", draft)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: kept, object: editor)], timeout: 30),
                       .completed, "…with the draft in the message box")
        XCTAssertFalse(app.staticTexts["Route unavailable"].exists)
        save(name + "-continued", app)
    }

    // MARK: Hermes's username/password provider

    @MainActor func testPasswordOnlyHostPrefersUsernameAndPasswordAndChats() throws {
        let app = try beginSetup(mode: "password")
        // Every sign-in provider takes a password, so that's the form shown.
        XCTAssertTrue(methodDetail(app).contains("username and password"), methodDetail(app))
        try typeCredentials(app, password: try XCTUnwrap(probe["password"]))
        save("password-1-form", app)
        try connect(app)
        app.buttons["host-setup.continue"].tap()
        // A new host has no chats yet: start the first one.
        let firstChat = app.buttons["sessions.empty.new-chat"]
        if firstChat.waitForExistence(timeout: 10) {
            firstChat.tap()
            confirmNewChatPicker(in: app)
        }
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "A chat opens after connecting")
        composer.tap()
        composer.typeText("Run pwd once, then finish the direct streaming fixture.")
        app.buttons["chat.send"].tap()
        let answer = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                                  "Direct streaming fixture complete.", "Direct streaming fixture complete."))
            .firstMatch
        XCTAssertTrue(answer.waitForExistence(timeout: 90), "The signed-in session can chat")
        save("password-2-chat", app)
    }

    @MainActor func testWrongPasswordIsExplained() throws {
        let app = try beginSetup(mode: "password")
        try typeCredentials(app, password: "not-the-password")
        tapConnect(app)
        let rejected = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "rejected these credentials")).firstMatch
        XCTAssertTrue(rejected.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["host-setup.continue"].exists)
        save("password-3-wrong", app)
    }

    @MainActor func testAccessToken() throws {
        let app = try beginSetup(mode: "password")
        choose("Access token", in: app)
        let token = app.secureTextFields["direct-hermes.token"]
        XCTAssertTrue(token.waitForExistence(timeout: 3))
        token.tap()
        token.typeText(try XCTUnwrap(probe["token"]))
        try connect(app)
    }

    @MainActor func testBrowserSignInThroughHermesLoginPage() throws {
        let app = try beginSetup(mode: "password")
        choose("Browser sign-in", in: app)
        tapConnect(app)
        let web = try browser(app)
        let user = web.textFields.firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 15), "Hermes's login page opens in the browser")
        user.tap()
        user.typeText(try XCTUnwrap(probe["username"]))
        // Native Tab moves focus without tapping WebKit's stale pre-keyboard frame.
        user.typeText("\t")
        web.secureTextFields.firstMatch.typeText(try XCTUnwrap(probe["password"]))
        save("browser-1-hermes-login", app)
        let submit = web.buttons.matching(NSPredicate(format: "label ==[c] %@", "Sign in")).firstMatch
        XCTAssertTrue(submit.exists)
        submit.tap()
        try expectConnected(app)
    }

    // MARK: Single sign-on (self-hosted OpenID Connect)

    @MainActor func testSingleSignOnThroughIdentityProvider() throws {
        let app = try beginSetup(mode: "sso")
        // Not every provider takes a password here, so the browser leads.
        XCTAssertTrue(methodDetail(app).contains("in Safari"), methodDetail(app))
        XCTAssertTrue(app.buttons["host-setup.provider"].exists, "Two providers: the person picks one")
        app.buttons["host-setup.provider"].tap()
        app.buttons["Self-Hosted OIDC"].tap()
        save("sso-1-provider", app)
        tapConnect(app)
        let web = try browser(app)
        let approve = web.buttons["Approve sign-in"]
        XCTAssertTrue(approve.waitForExistence(timeout: 20), "The identity provider's page opens")
        save("sso-2-identity-provider", app)
        approve.tap()
        try expectConnected(app)
    }

    // MARK: Tool turns (tools mode: the bighelp plugin and a scripted model)

    /// The agent asks for a secret with bighelp's tool: the masked pop-up
    /// appears over the chat, and what's typed goes to the host, not the chat.
    @MainActor func testSecureInputPopUpSavesTheValue() throws {
        let app = try beginSetup(mode: "tools")
        let composer = try openFirstChat(app)
        send("secure input test", composer: composer, in: app)
        let field = app.secureTextFields["direct-hermes.secure-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The secure pop-up appears")
        save("tools-1-secure-pop-up", app)
        field.tap()
        field.typeText("fixture-value-not-a-secret")
        app.buttons["direct-hermes.secure-submit"].tap()
        XCTAssertTrue(text("Secure input fixture: saved.", in: app).waitForExistence(timeout: 30))
        XCTAssertFalse(text("fixture-value-not-a-secret", in: app).exists, "The value never shows in the chat")
        save("tools-2-secure-saved", app)
    }

    /// A plain tap on Send while a tool runs steers the turn: the message
    /// leaves the composer at once, and the agent gets it when the tool ends.
    @MainActor func testSteerSendsWhileAToolRuns() throws {
        let app = try beginSetup(mode: "tools")
        let composer = try openFirstChat(app)
        send("long tool test", composer: composer, in: app)
        XCTAssertTrue(app.buttons["chat.stop"].waitForExistence(timeout: 20), "The turn is running")
        // Let the 20-second command start.
        Thread.sleep(forTimeInterval: 3)
        composer.tap()
        composer.typeText("steer fixture note")
        let sendButton = app.descendants(matching: .any)["chat.send"].firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        sendButton.tap()
        let left = expectation(for: NSPredicate(format: "NOT (value CONTAINS %@)", "steer fixture note"),
                               evaluatedWith: composer)
        wait(for: [left], timeout: 5)
        save("tools-3-steered", app)
        XCTAssertTrue(text("Steer received: steer fixture note", in: app).waitForExistence(timeout: 60),
                      "The agent got the steer after the tool finished")
        save("tools-4-steer-received", app)
    }

    /// Tapping the Dynamic Island (or a notification) while the agent waits on
    /// a question brings the app back: the question opens focused, keyboard closed.
    @MainActor func testWaitingQuestionOpensFocusedWhenReturningToTheApp() throws {
        let app = try beginSetup(mode: "tools")
        let composer = try openFirstChat(app)
        send("question test", composer: composer, in: app)
        let popup = app.navigationBars["Needs attention"]
        XCTAssertTrue(popup.waitForExistence(timeout: 30), "The agent's question pops up by itself")
        popup.buttons["Later"].tap()
        XCTAssertTrue(app.buttons["direct-hermes.attention"].waitForExistence(timeout: 5), "Later leaves it waiting")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        sleep(9) // past the chat-open window: only the return opens it
        app.activate()
        XCTAssertTrue(app.navigationBars["Needs attention"].waitForExistence(timeout: 10), "The question opens focused")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "No keyboard over it")
        save("tools-5-question-focused", app)
    }

    // MARK: Media and vault prompts (Scripts/HostProbePlugin)

    /// A generated picture shows while the turn runs and must stay in the
    /// finished message after Hermes' saved history replaces the live turn,
    /// and after leaving the chat and coming back.
    @MainActor func testGeneratedImageStaysAfterTheTurnEnds() throws {
        let app = try beginSetup(mode: "media")
        let composer = try openFirstChat(app)
        send("image test", composer: composer, in: app)
        let stop = app.buttons["chat.stop"]
        let ended = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: stop)
        wait(for: [ended], timeout: 60)
        // Past the reload from saved history that follows a finished turn.
        sleep(4)
        let picture = app.descendants(matching: .any)["chat.message-attachments"].firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 20), "The picture stays when the turn ends")
        XCTAssertFalse(text("MEDIA:", in: app).exists, "No raw MEDIA line in its place")
        save("media-1-after-turn", app)

        app.buttons["chat.back"].firstMatch.tap()
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "session.row.")).firstMatch
        if !row.waitForExistence(timeout: 5) { openRootTab("tab.sessions", in: app) }
        XCTAssertTrue(row.waitForExistence(timeout: 15), "The chat is listed")
        row.tap()
        XCTAssertTrue(picture.waitForExistence(timeout: 30), "The picture is there after reopening the chat")
        XCTAssertFalse(text("MEDIA:", in: app).exists)
        save("media-2-reopened", app)
    }

    /// Hermes' browser vault asks for a one-time code with `vault.code`. It
    /// used to be refused at once; now the secure pop-up takes the code.
    @MainActor func testVaultCodePopUpEntersTheCode() throws {
        let app = try beginSetup(mode: "media")
        let composer = try openFirstChat(app)
        send("vault code test", composer: composer, in: app)
        let field = app.textFields["direct-hermes.vault-code"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "The code pop-up appears")
        XCTAssertTrue(text("example.com", in: app).exists, "It names the site asking")
        save("media-3-code-pop-up", app)
        field.tap()
        field.typeText("482913")
        app.buttons["direct-hermes.secure-submit"].tap()
        XCTAssertTrue(text("Vault fixture: received. 6 digits.", in: app).waitForExistence(timeout: 30))
        XCTAssertFalse(text("482913", in: app).exists, "The code never shows in the chat")
        save("media-4-code-entered", app)
    }

    /// `vault.save_login` asks for a site's username and password, which go
    /// straight to Hermes' vault, never into the chat.
    @MainActor func testSaveLoginPopUpSavesTheLogin() throws {
        let app = try beginSetup(mode: "media")
        let composer = try openFirstChat(app)
        send("save login test", composer: composer, in: app)
        let user = app.textFields["direct-hermes.vault-identifier"]
        XCTAssertTrue(user.waitForExistence(timeout: 30), "The save-login pop-up appears")
        save("media-5-save-login-pop-up", app)
        user.tap()
        user.typeText("fixture-user@example.com")
        let password = app.secureTextFields["direct-hermes.secure-input"]
        password.tap()
        password.typeText("fixture-password-not-real")
        app.buttons["direct-hermes.secure-submit"].tap()
        XCTAssertTrue(text("Saved for fixture-user@example.com.", in: app).waitForExistence(timeout: 30))
        XCTAssertFalse(text("fixture-password-not-real", in: app).exists, "The password never shows in the chat")
        save("media-6-login-saved", app)
    }

    /// Issue #18: a card streaming in shows the image loader in its place;
    /// its code never shows, and the card replaces the loader when it's whole.
    @MainActor func testACardStreamsBehindALoader() throws {
        let app = try beginSetup(mode: "media")
        let composer = try openFirstChat(app)
        send("card test", composer: composer, in: app)
        let loader = app.descendants(matching: .any)["chat.card.pending"].firstMatch
        XCTAssertTrue(loader.waitForExistence(timeout: 30), "The loader holds the card's place")
        XCTAssertTrue(text("Here's your card.", in: app).exists, "Words before the card stream normally")
        XCTAssertFalse(text("loopdy-card", in: app).exists, "No card code while it streams")
        XCTAssertFalse(text("\"schema\"", in: app).exists, "No card code while it streams")
        save("media-9-card-loading", app)
        XCTAssertTrue(text("The whole card arrived.", in: app).waitForExistence(timeout: 30), "The card arrives")
        XCTAssertFalse(loader.exists, "The loader is gone")
        XCTAssertTrue(text("That's all.", in: app).waitForExistence(timeout: 10))
        save("media-10-card-arrived", app)
    }

    /// ☰ › Secure credential vault on a real Hermes: a login typed here and
    /// two imported from a CSV export land in that host's own vault.
    @MainActor func testVaultSavesAndImportsLoginsOnTheHost() throws {
        let app = try beginSetup(mode: "media", extraArguments: ["-test-vault-import"])
        try connect(app)
        app.buttons["host-setup.continue"].tap()
        let menu = app.buttons["home.drawer.open"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20))
        menu.tap()
        let row = app.buttons["menu.vault"]
        for _ in 0..<6 where !(row.exists && row.isHittable) { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.staticTexts["vault.empty"].waitForExistence(timeout: 20), "A new host's vault is empty")
        app.buttons["vault.add"].tap()
        let site = app.textFields["vault.site"]
        XCTAssertTrue(site.waitForExistence(timeout: 5))
        site.tap()
        site.typeText("login.example.com")
        app.textFields["vault.username"].tap()
        app.textFields["vault.username"].typeText("fixture-user")
        app.secureTextFields["vault.password"].tap()
        app.secureTextFields["vault.password"].typeText("fixture-password-not-real")
        app.buttons["vault.save"].tap()
        XCTAssertTrue(vaultItem("login.example.com", in: app).waitForExistence(timeout: 20), "Saved on the host")
        let importRow = app.buttons["vault.import"]
        for _ in 0..<4 where !importRow.isHittable { app.swipeUp() }
        importRow.tap()
        XCTAssertTrue(app.buttons["vault.import-confirm"].waitForExistence(timeout: 10))
        save("media-7-vault-import", app)
        app.buttons["vault.import-confirm"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["vault.import-done"].waitForExistence(timeout: 30))
        app.buttons["vault.import-close"].tap()
        XCTAssertTrue(vaultItem("shop.example.org", in: app).waitForExistence(timeout: 20), "Imported on the host")
        save("media-8-vault-list", app)
    }

    @MainActor private func vaultItem(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "vault.item.", label))
            .firstMatch
    }

    @MainActor private func openFirstChat(_ app: XCUIApplication) throws -> XCUIElement {
        try connect(app)
        app.buttons["host-setup.continue"].tap()
        // A new host has no chats yet; one used by an earlier test opens its latest.
        let newChat = app.buttons.matching(NSPredicate(format: "identifier IN %@",
            ["sessions.empty.new-chat", "chat.home.new-chat", "chat.new-chat", "root.new-chat"])).firstMatch
        if newChat.waitForExistence(timeout: 10) {
            newChat.tap()
            confirmNewChatPicker(in: app)
        }
        let composer = app.textViews["chat.composer.text"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20), "A chat opens after connecting")
        return composer
    }

    @MainActor private func send(_ message: String, composer: XCUIElement, in app: XCUIApplication) {
        composer.tap()
        composer.typeText(message)
        app.buttons["chat.send"].tap()
    }

    @MainActor private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value))
            .firstMatch
    }

    // MARK: Helpers

    @MainActor private func beginSetup(mode: String, extraArguments: [String] = []) throws -> XCUIApplication {
        guard let path = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_PROBE"] else {
            throw XCTSkip("Run through Scripts/HostSignInMatrixProbe.py")
        }
        probe = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard probe["mode"] == mode else { throw XCTSkip("This host runs the \(probe["mode"] ?? "?") mode") }
        addUIInterruptionMonitor(withDescription: "Sign-in and password prompts") { dialog in
            for label in ["Continue", "Not Now"] where dialog.buttons[label].exists {
                dialog.buttons[label].tap()
                return true
            }
            return false
        }
        let app = makeApp()
        app.launchArguments = ["-use-demo-fixtures", "-disable-demo-delays", "-test-no-configured-hosts"]
            + extraArguments
        app.launch()
        let address = app.textFields["host-setup.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 10))
        address.tap()
        address.typeText(try XCTUnwrap(probe["address"]))
        tapConnect(app)
        // An open host connects straight away; a gated one shows its sign-in methods.
        let connected = app.buttons["host-setup.continue"]
        let found = NSPredicate { _, _ in connected.exists || self.methodPicker(app).exists }
        wait(for: [expectation(for: found, evaluatedWith: nil)], timeout: 45)
        return app
    }

    /// The line under the method, which names what it does.
    @MainActor private func methodDetail(_ app: XCUIApplication) -> String {
        let detail = app.staticTexts["host-setup.method-detail"]
        _ = detail.waitForExistence(timeout: 3)
        return detail.label
    }

    @MainActor private func methodPicker(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["direct-hermes.auth-picker"]
    }

    @MainActor private func choose(_ method: String, in app: XCUIApplication) {
        methodPicker(app).tap()
        let option = app.buttons[method]
        XCTAssertTrue(option.waitForExistence(timeout: 3), method)
        option.tap()
    }

    @MainActor private func typeCredentials(_ app: XCUIApplication, password: String) throws {
        let user = app.textFields["direct-hermes.username"]
        XCTAssertTrue(user.waitForExistence(timeout: 3))
        user.tap()
        user.typeText(try XCTUnwrap(probe["username"]))
        let secret = app.secureTextFields["direct-hermes.password"]
        secret.tap()
        secret.typeText(password)
    }

    @MainActor private func tapConnect(_ app: XCUIApplication) {
        let connect = app.buttons["host-setup.connect-host"]
        // The form draws rows lazily; the keyboard can hide the button.
        for _ in 0..<5 where !(connect.exists && connect.isHittable) { app.swipeUp() }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        connect.tap()
    }

    @MainActor private func connect(_ app: XCUIApplication) throws {
        if !app.buttons["host-setup.continue"].exists { tapConnect(app) }
        try expectConnected(app)
    }

    @MainActor private func expectConnected(_ app: XCUIApplication) throws {
        app.activate()
        let next = app.buttons["host-setup.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 45), "Connected")
        save("\(probe["mode"] ?? "")-connected-\(name.split(separator: " ").last ?? "")", app)
    }

    /// The system sign-in sheet: in-app web view or Safari's view service.
    @MainActor private func browser(_ app: XCUIApplication) throws -> XCUIElement {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.buttons["Continue"].waitForExistence(timeout: 5) {
            springboard.alerts.buttons["Continue"].tap()
        }
        let safari = XCUIApplication(bundleIdentifier: "com.apple.SafariViewService")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if app.webViews.firstMatch.exists { return app.webViews.firstMatch }
            if safari.webViews.firstMatch.exists { return safari.webViews.firstMatch }
            Thread.sleep(forTimeInterval: 0.5)
        }
        save("browser-missing", app)
        XCTFail("No sign-in browser appeared")
        throw BrowserMissing()
    }

    @MainActor private func save(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        guard let folder = ProcessInfo.processInfo.environment["BIGHELP_SIGNIN_EVIDENCE"] else { return }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
